import AppKit
import Darwin
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

    private static let sharedHelperKeywords = [
        "keystone", "autoupdate", "updater", "licensing", "ipc", "shared", "oneauth", "crashreporter"
    ]

    private struct PendingOrphan {
        let path: String
        let name: String
        let inferredIdentifier: String
        let category: FileCategory
        let reason: String
        let modifiedDate: Date?
    }

    static func scanOrphans(systemIndex: InstalledSystemIndex) -> [OrphanItem] {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        let ownBundleID = (Bundle.main.bundleIdentifier ?? "com.hunglx.AppSweep").lowercased()

        let runningBundleIDs: Set<String> = Set(
            NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier?.lowercased() }
        )

        // Pre-index all segment prefixes of installed bundle IDs so parent/child matching is O(1) instead of O(M)
        var installedParentSegments = Set<String>()
        for known in systemIndex.allKnownBundleIDs {
            let parts = known.split(separator: ".")
            if parts.count >= 3 {
                var acc = "\(parts[0]).\(parts[1]).\(parts[2])"
                installedParentSegments.insert(acc)
                for idx in 3..<parts.count {
                    acc.append(".")
                    acc.append(contentsOf: parts[idx])
                    installedParentSegments.insert(acc)
                }
            }
        }

        var installedMemo: [String: Bool] = [:]

        func isBundleIDInstalledAnywhere(_ rawCandidate: String) -> Bool {
            let candidate = rawCandidate.lowercased()
            if let cached = installedMemo[candidate] {
                return cached
            }

            let installed = computeIsInstalled(candidate)
            installedMemo[candidate] = installed
            return installed
        }

        func computeIsInstalled(_ candidate: String) -> Bool {
            if candidate.isEmpty || candidate == ownBundleID { return true }
            for prefix in ignoredPrefixes where candidate.hasPrefix(prefix) {
                return true
            }
            if runningBundleIDs.contains(candidate) || systemIndex.allKnownBundleIDs.contains(candidate) {
                return true
            }
            if installedParentSegments.contains(candidate) {
                return true
            }

            // O(k) check whether any prefix of `candidate` (>= 3 segments) is an installed app bundle ID
            let parts = candidate.split(separator: ".")
            if parts.count >= 3 {
                var prefixAcc = "\(parts[0]).\(parts[1]).\(parts[2])"
                if systemIndex.allKnownBundleIDs.contains(prefixAcc) || runningBundleIDs.contains(prefixAcc) {
                    return true
                }
                for idx in 3..<parts.count {
                    prefixAcc.append(".")
                    prefixAcc.append(contentsOf: parts[idx])
                    if systemIndex.allKnownBundleIDs.contains(prefixAcc) || runningBundleIDs.contains(prefixAcc) {
                        return true
                    }
                }
            }

            let strippedIDs = candidateBundleIDForms(from: candidate)
            for idForm in strippedIDs {
                if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: idForm) {
                    let appPath = appURL.standardizedFileURL.path
                    if !appPath.contains("/.Trash/"), fm.fileExists(atPath: appPath) {
                        return true
                    }
                }
            }

            if parts.count >= 2 {
                let vendorPrefix = "\(parts[0]).\(parts[1])"
                if systemIndex.vendorPrefixToAppPaths[vendorPrefix]?.isEmpty == false,
                   sharedHelperKeywords.contains(where: { candidate.contains($0) }) {
                    return true
                }
            }

            return false
        }

        var pendingByPath: [String: PendingOrphan] = [:]

        // 1. Scan Broken LaunchAgents & LaunchDaemons
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
                    let modDate = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                    pendingByPath[canonical] = PendingOrphan(
                        path: canonical,
                        name: fileName,
                        inferredIdentifier: stem,
                        category: .launchDaemons,
                        reason: "Tiến trình đích không còn tồn tại (\(PathFormatter.prettyPath(program)))",
                        modifiedDate: modDate
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
                if pendingByPath[canonical] != nil { continue }

                guard let bundleID = extractBundleIdentifier(for: item, inCategory: category) else { continue }

                if !isBundleIDInstalledAnywhere(bundleID) {
                    let modDate = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                    pendingByPath[canonical] = PendingOrphan(
                        path: canonical,
                        name: item.lastPathComponent,
                        inferredIdentifier: bundleID,
                        category: category,
                        reason: "Không còn ứng dụng nào khớp Bundle ID (\(bundleID))",
                        modifiedDate: modDate
                    )
                }
            }
        }

        let pendingList = Array(pendingByPath.values)
        guard !pendingList.isEmpty else { return [] }

        // 3. Parallel size & permission computation via fast POSIX fts_open
        let lock = NSLock()
        var builtResults: [OrphanItem] = []
        builtResults.reserveCapacity(pendingList.count)

        DispatchQueue.concurrentPerform(iterations: pendingList.count) { idx in
            if Task.isCancelled { return }
            let p = pendingList[idx]
            let size = DiskSizeCalculator.allocatedSize(atPath: p.path)
            if p.category == .preferences && size == 0 {
                return
            }
            let item = OrphanItem(
                id: p.path,
                path: p.path,
                name: p.name,
                inferredIdentifier: p.inferredIdentifier,
                category: p.category,
                sizeBytes: size,
                reason: p.reason,
                requiresAdmin: DiskSizeCalculator.requiresAdminToModify(path: p.path),
                modifiedDate: p.modifiedDate,
                isSelected: true
            )
            lock.lock()
            builtResults.append(item)
            lock.unlock()
        }

        return builtResults.sorted { lhs, rhs in
            if lhs.category == .launchDaemons && rhs.category != .launchDaemons { return true }
            if lhs.category != .launchDaemons && rhs.category == .launchDaemons { return false }
            if lhs.sizeBytes != rhs.sizeBytes { return lhs.sizeBytes > rhs.sizeBytes }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private static let removableSuffixes = [".savedState", ".savedstate", ".binarycookies", ".plist"]

    private static func extractBundleIdentifier(for itemURL: URL, inCategory category: FileCategory) -> String? {
        if category == .containers {
            let metaPlist = itemURL.appendingPathComponent(".com.apple.containermanagerd.metadata.plist")
            if let dict = NSDictionary(contentsOf: metaPlist) as? [String: Any],
               let metaID = dict["MCMMetadataIdentifier"] as? String,
               isReverseDNSIdentifier(metaID) {
                return metaID.lowercased()
            }
        }

        var raw = itemURL.lastPathComponent
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
        let parts = lower.split(separator: ".")
        guard parts.count >= 3 else { return false }
        guard validReverseDNSPrefixes.contains(String(parts[0])) else { return false }
        if parts.last == "lockfile" { return false }
        return parts.allSatisfy { !$0.isEmpty && !$0.contains(" ") }
    }

    private static let helperSuffixes = [
        ".helper", ".shipit", ".loginhelper", ".launcher", ".updater",
        ".renderer", ".gpu", ".plugin", ".agent", ".daemon", ".xpc"
    ]

    private static func candidateBundleIDForms(from candidate: String) -> [String] {
        var forms = [candidate]
        for suffix in helperSuffixes where candidate.hasSuffix(suffix) {
            let parent = String(candidate.dropLast(suffix.count))
            if parent.split(separator: ".").count >= 3 {
                forms.append(parent)
            }
        }
        return forms
    }
}
