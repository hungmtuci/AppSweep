import AppKit
import Foundation

enum OrphanScannerService {
    private static let ignoredPrefixes: [String] = [
        "com.apple.",
        "group.com.apple.",
        "systemgroup.com.apple.",
        "org.cups.",
        "org.swift.",
        "org.openbsd.",
        "org.x.",
        "com.openssh."
    ]

    private static let validReverseDNSPrefixes: Set<String> = [
        "com", "org", "net", "io", "app", "dev", "me", "co", "uk", "de", "fr", "jp", "kr", "cn", "vn", "pro", "studio", "tech", "ai", "so", "sh"
    ]

    static func scanOrphans(systemIndex: InstalledSystemIndex) -> [OrphanItem] {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        let ownBundleID = (Bundle.main.bundleIdentifier ?? "com.hunglx.AppSweep").lowercased()

        // Also index running processes' bundle IDs so active background tools are never flagged
        let runningBundleIDs: Set<String> = Set(
            NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier?.lowercased() }
        )

        var results: [String: OrphanItem] = [:]

        func isBundleIDInstalledAnywhere(_ rawCandidate: String) -> Bool {
            let candidate = rawCandidate.lowercased()
            if candidate.isEmpty || candidate == ownBundleID { return true }
            for prefix in ignoredPrefixes where candidate.hasPrefix(prefix) {
                return true
            }
            if runningBundleIDs.contains(candidate) {
                return true
            }
            if systemIndex.allKnownBundleIDs.contains(candidate) {
                return true
            }
            // Check parent/child bundle ID relation (e.g., com.spotify.client.helper <-> com.spotify.client)
            for known in systemIndex.allKnownBundleIDs {
                if candidate.hasPrefix(known + ".") || known.hasPrefix(candidate + ".") {
                    return true
                }
            }

            // Query macOS LaunchServices for apps located outside /Applications (e.g., developer workspace folders)
            let strippedIDs = candidateBundleIDForms(from: candidate)
            for idForm in strippedIDs {
                if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: idForm) {
                    let appPath = appURL.standardizedFileURL.path
                    if !appPath.contains("/.Trash/"), fm.fileExists(atPath: appPath) {
                        return true
                    }
                }
            }

            // Check if vendor prefix belongs to an installed suite (e.g. Adobe, Microsoft, Google, JetBrains)
            // for shared suite plists like com.microsoft.autoupdate2 or com.google.Keystone
            let parts = candidate.split(separator: ".").map(String.init)
            if parts.count >= 2 {
                let vendorPrefix = "\(parts[0]).\(parts[1])"
                let sharedHelperKeywords = ["keystone", "autoupdate", "updater", "licensing", "ipc", "shared", "oneauth", "crashreporter"]
                if systemIndex.vendorPrefixToAppPaths[vendorPrefix]?.isEmpty == false,
                   sharedHelperKeywords.contains(where: { candidate.contains($0) }) {
                    return true
                }
            }

            return false
        }

        // 1. Scan Broken LaunchAgents & LaunchDaemons (100% deterministic check on missing target executable)
        let launchLocations = [
            "\(home)/Library/LaunchAgents",
            "/Library/LaunchAgents",
            "/Library/LaunchDaemons"
        ]

        for dir in launchLocations {
            guard let items = try? fm.contentsOfDirectory(
                at: URL(fileURLWithPath: dir),
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for item in items where item.pathExtension.lowercased() == "plist" {
                let fileName = item.lastPathComponent
                let stem = item.deletingPathExtension().lastPathComponent
                if ignoredPrefixes.contains(where: { stem.lowercased().hasPrefix($0) }) { continue }

                guard let dict = NSDictionary(contentsOf: item) as? [String: Any] else { continue }
                let program: String? = {
                    if let p = dict["Program"] as? String { return p }
                    if let args = dict["ProgramArguments"] as? [String], let first = args.first { return first }
                    return nil
                }()

                if let program, program.hasPrefix("/"),
                   !program.hasPrefix("/bin/"),
                   !program.hasPrefix("/usr/bin/"),
                   !program.hasPrefix("/sbin/"),
                   !program.hasPrefix("/System/"),
                   !fm.fileExists(atPath: program) {
                    let canonical = item.standardizedFileURL.path
                    let size = DiskSizeCalculator.allocatedSize(at: item)
                    let modDate = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                    results[canonical] = OrphanItem(
                        id: canonical,
                        path: canonical,
                        name: fileName,
                        inferredIdentifier: stem,
                        category: .launchDaemons,
                        sizeBytes: size,
                        reason: "Tiến trình đích không còn tồn tại (\(PathFormatter.prettyPath(program)))",
                        requiresAdmin: DiskSizeCalculator.requiresAdminToModify(path: canonical),
                        modifiedDate: modDate,
                        isSelected: true
                    )
                }
            }
        }

        // 2. Scan Bundle-ID keyed Library directories for uninstalled apps
        let libraryScanSpecs: [(String, FileCategory)] = [
            ("\(home)/Library/Application Support", .applicationSupport),
            ("\(home)/Library/Containers", .containers),
            ("\(home)/Library/Caches", .caches),
            ("\(home)/Library/Saved Application State", .savedState),
            ("\(home)/Library/HTTPStorages", .webData),
            ("\(home)/Library/WebKit", .webData),
            ("\(home)/Library/Preferences", .preferences)
        ]

        for (dirPath, category) in libraryScanSpecs {
            if Task.isCancelled { break }
            guard let items = try? fm.contentsOfDirectory(
                at: URL(fileURLWithPath: dirPath),
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for item in items {
                if Task.isCancelled { break }
                let canonical = item.standardizedFileURL.path
                if results[canonical] != nil { continue }

                let extractedID = extractBundleIdentifier(for: item, inCategory: category)
                guard let bundleID = extractedID else { continue }

                if !isBundleIDInstalledAnywhere(bundleID) {
                    let size = DiskSizeCalculator.allocatedSize(at: item)
                    // Skip 0-byte empty preference stubs
                    if category == .preferences && size == 0 { continue }

                    let modDate = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                    results[canonical] = OrphanItem(
                        id: canonical,
                        path: canonical,
                        name: item.lastPathComponent,
                        inferredIdentifier: bundleID,
                        category: category,
                        sizeBytes: size,
                        reason: "Không còn ứng dụng nào khớp Bundle ID (\(bundleID))",
                        requiresAdmin: DiskSizeCalculator.requiresAdminToModify(path: canonical),
                        modifiedDate: modDate,
                        isSelected: true
                    )
                }
            }
        }

        return results.values.sorted { lhs, rhs in
            if lhs.category == .launchDaemons && rhs.category != .launchDaemons { return true }
            if lhs.category != .launchDaemons && rhs.category == .launchDaemons { return false }
            if lhs.sizeBytes != rhs.sizeBytes { return lhs.sizeBytes > rhs.sizeBytes }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private static func extractBundleIdentifier(for itemURL: URL, inCategory category: FileCategory) -> String? {
        // For ~/Library/Containers on modern macOS, check metadata plist first if UUID folder
        if category == .containers {
            let metaPlist = itemURL.appendingPathComponent(".com.apple.containermanagerd.metadata.plist")
            if let dict = NSDictionary(contentsOf: metaPlist) as? [String: Any],
               let metaID = dict["MCMMetadataIdentifier"] as? String,
               isReverseDNSIdentifier(metaID) {
                return metaID.lowercased()
            }
        }

        var raw = itemURL.lastPathComponent
        let removableSuffixes = [".savedState", ".savedstate", ".binarycookies", ".plist"]
        for suffix in removableSuffixes where raw.hasSuffix(suffix) {
            raw = String(raw.dropLast(suffix.count))
            break
        }

        guard isReverseDNSIdentifier(raw) else { return nil }
        return raw.lowercased()
    }

    private static func isReverseDNSIdentifier(_ text: String) -> Bool {
        let lower = text.lowercased()
        for prefix in ignoredPrefixes where lower.hasPrefix(prefix) {
            return false
        }
        let parts = lower.split(separator: ".").map(String.init)
        guard parts.count >= 3 else { return false }
        guard validReverseDNSPrefixes.contains(parts[0]) else { return false }
        // Reject lockfiles or UUID suffixes in ByHost
        if parts.last == "lockfile" { return false }
        return parts.allSatisfy { !$0.isEmpty && !$0.contains(" ") }
    }

    private static func candidateBundleIDForms(from candidate: String) -> [String] {
        var forms = [candidate]
        // Also strip trailing helper suffixes like .helper, .ShipIt, .Renderer, .LoginHelper
        let helperSuffixes = [
            ".helper", ".shipit", ".loginhelper", ".launcher", ".updater",
            ".renderer", ".gpu", ".plugin", ".agent", ".daemon", ".xpc"
        ]
        for suffix in helperSuffixes where candidate.hasSuffix(suffix) {
            let parent = String(candidate.dropLast(suffix.count))
            if parent.split(separator: ".").count >= 3 {
                forms.append(parent)
            }
        }
        return forms
    }
}
