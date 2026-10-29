import AppKit
import CoreServices
import Foundation
import Security

enum DiskSizeCalculator {
    /// Calculates actual allocated bytes on disk (handles sparse files and symlinks safely).
    static func allocatedSize(at url: URL) -> Int64 {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey,
            .totalFileSizeKey,
            .fileSizeKey
        ]

        guard let rootValues = try? url.resourceValues(forKeys: keys) else {
            return 0
        }

        if rootValues.isSymbolicLink == true {
            return Int64(rootValues.fileSize ?? 0)
        }

        if rootValues.isDirectory != true {
            return Int64(
                rootValues.totalFileAllocatedSize
                ?? rootValues.fileAllocatedSize
                ?? rootValues.totalFileSize
                ?? rootValues.fileSize
                ?? 0
            )
        }

        var total: Int64 = 0
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            return 0
        }

        for case let fileURL as URL in enumerator {
            if Task.isCancelled { break }
            guard let values = try? fileURL.resourceValues(forKeys: keys) else { continue }
            if values.isSymbolicLink == true { continue }
            if values.isRegularFile == true {
                let bytes = values.totalFileAllocatedSize
                    ?? values.fileAllocatedSize
                    ?? values.totalFileSize
                    ?? values.fileSize
                    ?? 0
                total += Int64(bytes)
            }
        }
        return total
    }

    /// Checks whether removing `path` likely requires Administrator privileges.
    static func requiresAdminToModify(path: String) -> Bool {
        let fm = FileManager.default
        let parent = (path as NSString).deletingLastPathComponent
        if !fm.isWritableFile(atPath: parent) {
            return true
        }
        if fm.fileExists(atPath: path) && !fm.isWritableFile(atPath: path) {
            // Check ownership: if owned by current user, chmod/trash usually works; if root (uid 0), admin is required.
            if let attrs = try? fm.attributesOfItem(atPath: path),
               let ownerID = attrs[.ownerAccountID] as? NSNumber {
                return ownerID.uint32Value != getuid()
            }
            return true
        }
        if let attrs = try? fm.attributesOfItem(atPath: path),
           let ownerID = attrs[.ownerAccountID] as? NSNumber,
           ownerID.uint32Value == 0,
           !path.hasPrefix(NSHomeDirectory()) {
            return true
        }
        return false
    }
}

struct InstalledSystemIndex: Sendable {
    let apps: [TargetBundle]
    let allKnownBundleIDs: Set<String>
    let allKnownAppNamesNormalized: Set<String>
    let teamIDToAppPaths: [String: Set<String>]
    let vendorPrefixToAppPaths: [String: Set<String>]
}

enum AppCatalogService {
    private static let supportedAddonExtensions: [String: BundleKind] = [
        "prefpane": .preferencePane,
        "qlgenerator": .quickLook,
        "saver": .screenSaver,
        "plugin": .internetPlugin,
        "component": .audioPlugin,
        "vst": .audioPlugin,
        "vst3": .audioPlugin,
        "service": .service,
        "workflow": .service,
        "wdgt": .widget,
        "appex": .widget
    ]

    /// Scans installed user & third-party apps plus indexes system apps for orphan & sibling-vendor safety.
    static func scanInstalledApps() -> InstalledSystemIndex {
        let home = NSHomeDirectory()
        let userAppRoots = [
            "/Applications",
            (home as NSString).appendingPathComponent("Applications")
        ]
        let systemRoots = [
            "/System/Applications",
            "/System/Applications/Utilities",
            "/System/Library/CoreServices"
        ]

        var seenPaths = Set<String>()
        var visibleApps: [TargetBundle] = []
        var allBundleIDs = Set<String>()
        var allAppNames = Set<String>()
        var teamMap: [String: Set<String>] = [:]
        var vendorMap: [String: Set<String>] = [:]

        for root in userAppRoots {
            let urls = discoverAppBundles(in: URL(fileURLWithPath: root), maxDepth: 2)
            for url in urls {
                let canonical = url.standardizedFileURL.path
                guard seenPaths.insert(canonical).inserted else { continue }
                guard let bundle = inspectBundle(at: url, kindOverride: .application) else { continue }
                visibleApps.append(bundle)
                registerInIndex(
                    bundle: bundle,
                    allBundleIDs: &allBundleIDs,
                    allAppNames: &allAppNames,
                    teamMap: &teamMap,
                    vendorMap: &vendorMap
                )
            }
        }

        for root in systemRoots {
            let urls = discoverAppBundles(in: URL(fileURLWithPath: root), maxDepth: 2)
            for url in urls {
                let canonical = url.standardizedFileURL.path
                guard seenPaths.insert(canonical).inserted else { continue }
                guard let bundle = inspectBundle(at: url, kindOverride: .application, includeCodeSignTeam: false) else { continue }
                registerInIndex(
                    bundle: bundle,
                    allBundleIDs: &allBundleIDs,
                    allAppNames: &allAppNames,
                    teamMap: &teamMap,
                    vendorMap: &vendorMap
                )
            }
        }

        visibleApps.sort {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }

        return InstalledSystemIndex(
            apps: visibleApps,
            allKnownBundleIDs: allBundleIDs,
            allKnownAppNamesNormalized: allAppNames,
            teamIDToAppPaths: teamMap,
            vendorPrefixToAppPaths: vendorMap
        )
    }

    private static func registerInIndex(
        bundle: TargetBundle,
        allBundleIDs: inout Set<String>,
        allAppNames: inout Set<String>,
        teamMap: inout [String: Set<String>],
        vendorMap: inout [String: Set<String>]
    ) {
        if !bundle.bundleIdentifier.isEmpty {
            allBundleIDs.insert(bundle.bundleIdentifier.lowercased())
        }
        for childID in bundle.childBundleIdentifiers {
            allBundleIDs.insert(childID.lowercased())
        }
        let normName = normalizeToken(bundle.name)
        if normName.count >= 3 {
            allAppNames.insert(normName)
        }
        let normBundleName = normalizeToken(bundle.bundleName)
        if normBundleName.count >= 3 {
            allAppNames.insert(normBundleName)
        }
        if let team = bundle.teamIdentifier, !team.isEmpty {
            teamMap[team, default: []].insert(bundle.path)
        }
        if let vendor = bundle.vendorPrefix {
            vendorMap[vendor, default: []].insert(bundle.path)
        }
    }

    /// Scans macOS Addons, PreferencePanes, QuickLook generators, Screen Savers, Audio & Internet Plug-Ins.
    static func scanAddons() -> [TargetBundle] {
        let home = NSHomeDirectory()
        let locations: [(String, BundleKind?)] = [
            ("\(home)/Library/PreferencePanes", .preferencePane),
            ("/Library/PreferencePanes", .preferencePane),
            ("\(home)/Library/QuickLook", .quickLook),
            ("/Library/QuickLook", .quickLook),
            ("\(home)/Library/Screen Savers", .screenSaver),
            ("/Library/Screen Savers", .screenSaver),
            ("\(home)/Library/Internet Plug-Ins", .internetPlugin),
            ("/Library/Internet Plug-Ins", .internetPlugin),
            ("\(home)/Library/Audio/Plug-Ins/Components", .audioPlugin),
            ("/Library/Audio/Plug-Ins/Components", .audioPlugin),
            ("\(home)/Library/Audio/Plug-Ins/VST", .audioPlugin),
            ("/Library/Audio/Plug-Ins/VST", .audioPlugin),
            ("\(home)/Library/Audio/Plug-Ins/VST3", .audioPlugin),
            ("/Library/Audio/Plug-Ins/VST3", .audioPlugin),
            ("\(home)/Library/Services", .service),
            ("\(home)/Library/Widgets", .widget)
        ]

        let fm = FileManager.default
        var results: [TargetBundle] = []
        var seen = Set<String>()

        for (dirPath, defaultKind) in locations {
            guard let items = try? fm.contentsOfDirectory(
                at: URL(fileURLWithPath: dirPath),
                includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for itemURL in items {
                let ext = itemURL.pathExtension.lowercased()
                guard let kind = supportedAddonExtensions[ext] ?? defaultKind else { continue }
                let canonical = itemURL.standardizedFileURL.path
                guard seen.insert(canonical).inserted else { continue }
                if let bundle = inspectBundle(at: itemURL, kindOverride: kind, includeCodeSignTeam: false) {
                    results.append(bundle)
                }
            }
        }

        results.sort {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        return results
    }

    private static func discoverAppBundles(in directory: URL, maxDepth: Int) -> [URL] {
        guard maxDepth >= 0 else { return [] }
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var found: [URL] = []
        for entry in entries {
            let ext = entry.pathExtension.lowercased()
            if ext == "app" {
                found.append(entry)
            } else if maxDepth > 0 {
                let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values?.isDirectory == true, values?.isSymbolicLink != true, ext.isEmpty {
                    found.append(contentsOf: discoverAppBundles(in: entry, maxDepth: maxDepth - 1))
                }
            }
        }
        return found
    }

    /// Inspects any `.app` or addon bundle on disk (including dragged-and-dropped items).
    static func inspectBundle(
        at rawURL: URL,
        kindOverride: BundleKind? = nil,
        includeCodeSignTeam: Bool = true
    ) -> TargetBundle? {
        let url = rawURL.standardizedFileURL
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return nil }

        let ext = url.pathExtension.lowercased()
        let kind: BundleKind
        if let kindOverride {
            kind = kindOverride
        } else if ext == "app" {
            kind = .application
        } else if let mapped = supportedAddonExtensions[ext] {
            kind = mapped
        } else {
            return nil
        }

        let contentsURL = url.appendingPathComponent("Contents")
        let infoPlistURL = contentsURL.appendingPathComponent("Info.plist")
        let fallbackInfoURL = url.appendingPathComponent("Info.plist")

        var plist: [String: Any] = [:]
        if let dict = NSDictionary(contentsOf: infoPlistURL) as? [String: Any] {
            plist = dict
        } else if let dict = NSDictionary(contentsOf: fallbackInfoURL) as? [String: Any] {
            plist = dict
        }

        let fileStem = url.deletingPathExtension().lastPathComponent
        let displayName = (plist["CFBundleDisplayName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let bundleName = (plist["CFBundleName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let executableName = (plist["CFBundleExecutable"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? fileStem
        let resolvedName: String = {
            // Prefer localized Finder display name if cleaner, otherwise Info.plist display name / file stem
            let finderName = fm.displayName(atPath: url.path)
            let cleanedFinder = finderName.hasSuffix(".\(url.pathExtension)")
                ? String(finderName.dropLast(url.pathExtension.count + 1))
                : finderName
            if !cleanedFinder.isEmpty { return cleanedFinder }
            if let displayName, !displayName.isEmpty { return displayName }
            if let bundleName, !bundleName.isEmpty { return bundleName }
            return fileStem
        }()

        let bundleID = (plist["CFBundleIdentifier"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let shortVer = (plist["CFBundleShortVersionString"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let buildVer = (plist["CFBundleVersion"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let version = (shortVer?.isEmpty == false ? shortVer! : (buildVer ?? "1.0"))

        var privilegedLabels: [String] = []
        if let smDict = plist["SMPrivilegedExecutables"] as? [String: Any] {
            privilegedLabels = Array(smDict.keys)
        }

        let (childIDs, childExecs) = scanEmbeddedChildBundles(contentsURL: contentsURL)

        let arch: AppArchitecture
        let execURL = contentsURL.appendingPathComponent("MacOS").appendingPathComponent(executableName)
        if fm.fileExists(atPath: execURL.path) {
            arch = detectMachOArchitecture(at: execURL)
        } else {
            arch = .unknown
        }

        let teamID: String? = includeCodeSignTeam ? extractCodeSignTeamID(at: url) : nil

        let modDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let (lastUsedDate, useCount, dateAdded) = extractUsageMetadata(bundleURL: url, bundleID: bundleID)

        let ownBundleID = Bundle.main.bundleIdentifier ?? "com.hunglx.AppSweep"
        let lowerID = bundleID.lowercased()
        let isProtected = url.path.hasPrefix("/System/")
            || url.path == "/Applications/Safari.app"
            || lowerID == "com.apple.finder"
            || lowerID == "com.apple.safari"
            || lowerID == ownBundleID.lowercased()

        return TargetBundle(
            id: url.path,
            name: resolvedName,
            bundleName: bundleName ?? fileStem,
            executableName: executableName,
            bundleIdentifier: bundleID,
            version: version,
            path: url.path,
            teamIdentifier: teamID,
            childBundleIdentifiers: childIDs,
            childExecutableNames: childExecs,
            privilegedHelperLabels: privilegedLabels,
            architecture: arch,
            bundleSizeBytes: nil,
            modifiedDate: modDate,
            lastUsedDate: lastUsedDate,
            useCount: useCount,
            dateAdded: dateAdded,
            isSystemProtected: isProtected,
            kind: kind
        )
    }

    private static func extractUsageMetadata(bundleURL: URL, bundleID: String) -> (Date?, Int, Date?) {
        var spotlightLastUsed: Date? = nil
        var spotlightUseCount: Int = 0
        var spotlightDateAdded: Date? = nil

        if let mdItem = MDItemCreateWithURL(kCFAllocatorDefault, bundleURL as CFURL) {
            let attrNames = [
                "kMDItemLastUsedDate" as CFString,
                "kMDItemUseCount" as CFString,
                "kMDItemDateAdded" as CFString
            ] as CFArray
            if let attrs = MDItemCopyAttributes(mdItem, attrNames) as? [String: Any] {
                spotlightLastUsed = attrs["kMDItemLastUsedDate"] as? Date
                spotlightUseCount = (attrs["kMDItemUseCount"] as? NSNumber)?.intValue ?? 0
                spotlightDateAdded = attrs["kMDItemDateAdded"] as? Date
            }
        }

        // Augment with ~/Library/Saved Application State/<bundleID>.savedState modification date
        // so apps launched via URL schemes, CLI, or Login Items still reflect accurate recent activity.
        if !bundleID.isEmpty {
            let savedStatePath = (NSHomeDirectory() as NSString)
                .appendingPathComponent("Library/Saved Application State/\(bundleID).savedState")
            if FileManager.default.fileExists(atPath: savedStatePath),
               let stateMod = (try? URL(fileURLWithPath: savedStatePath).resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
                if let current = spotlightLastUsed {
                    if stateMod > current {
                        spotlightLastUsed = stateMod
                    }
                } else {
                    spotlightLastUsed = stateMod
                    spotlightUseCount = max(1, spotlightUseCount)
                }
            }
        }

        return (spotlightLastUsed, spotlightUseCount, spotlightDateAdded)
    }

    private static func scanEmbeddedChildBundles(contentsURL: URL) -> ([String], [String]) {
        let fm = FileManager.default
        let subdirs = [
            "Library/LoginItems",
            "XPCServices",
            "PlugIns",
            "Helpers"
        ]
        var childIDs = Set<String>()
        var childExecs = Set<String>()

        for rel in subdirs {
            let dir = contentsURL.appendingPathComponent(rel)
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
                continue
            }
            for item in items {
                let infoURL = item.appendingPathComponent("Contents/Info.plist")
                if let dict = NSDictionary(contentsOf: infoURL) as? [String: Any] {
                    if let cid = dict["CFBundleIdentifier"] as? String, !cid.isEmpty {
                        childIDs.insert(cid)
                    }
                    if let cexec = dict["CFBundleExecutable"] as? String, !cexec.isEmpty {
                        childExecs.insert(cexec)
                    }
                } else {
                    // Bare helper executable inside Helpers/
                    let name = item.lastPathComponent
                    if !name.isEmpty, item.pathExtension.isEmpty {
                        childExecs.insert(name)
                    }
                }
            }
        }
        return (Array(childIDs), Array(childExecs))
    }

    private static func extractCodeSignTeamID(at bundleURL: URL) -> String? {
        var staticCode: SecStaticCode?
        let status = SecStaticCodeCreateWithPath(bundleURL as CFURL, SecCSFlags(), &staticCode)
        guard status == errSecSuccess, let code = staticCode else { return nil }

        var infoCF: CFDictionary?
        let infoStatus = SecCodeCopySigningInformation(
            code,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &infoCF
        )
        guard infoStatus == errSecSuccess, let info = infoCF as? [String: Any] else { return nil }
        if let team = info[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty {
            return team
        }
        return nil
    }

    private static func detectMachOArchitecture(at executableURL: URL) -> AppArchitecture {
        guard let handle = try? FileHandle(forReadingFrom: executableURL) else { return .unknown }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 32), data.count >= 8 else { return .unknown }

        let magic = data.withUnsafeBytes { $0.load(as: UInt32.self) }
        switch magic {
        case 0xCAFEBABE, 0xBEBAFECA, 0xCAFEBABF, 0xBFBAFECA:
            return .universal
        case 0xFEEDFACF, 0xFEEDFACE:
            let cpuType = data.withUnsafeBytes { $0.load(fromByteOffset: 4, as: Int32.self) }
            if (cpuType & 0x00FF_FFFF) == 12 { return .appleSilicon }
            if (cpuType & 0x00FF_FFFF) == 7 { return .intel }
            return .unknown
        case 0xCFFAEDFE, 0xCEFAEDFE:
            let swapped = data.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self).byteSwapped }
            if (swapped & 0x00FF_FFFF) == 12 { return .appleSilicon }
            if (swapped & 0x00FF_FFFF) == 7 { return .intel }
            return .unknown
        default:
            return .unknown
        }
    }

    static func normalizeToken(_ raw: String) -> String {
        let folded = raw.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let allowed = folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        return String(String.UnicodeScalarView(allowed)).lowercased()
    }
}
