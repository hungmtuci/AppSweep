import AppKit
import CoreServices
import Darwin
import Foundation
import Security

enum DiskSizeCalculator {
    private struct InodeKey: Hashable {
        let dev: dev_t
        let ino: ino_t
    }

    /// High-speed POSIX `fts_open` physical disk size calculator.
    /// Avoids Foundation `NSURL` / `NSDirectoryEnumerator` heap allocations per file,
    /// handles sparse files accurately via `st_blocks`, and deduplicates hard links (`st_nlink > 1`).
    static func allocatedSize(at url: URL) -> Int64 {
        allocatedSize(atPath: url.path)
    }

    static func allocatedSize(atPath path: String) -> Int64 {
        var rootStat = stat()
        guard lstat(path, &rootStat) == 0 else { return 0 }

        let modeType = rootStat.st_mode & S_IFMT
        if modeType == S_IFLNK {
            return max(0, Int64(rootStat.st_size))
        }
        if modeType != S_IFDIR {
            let blocksBytes = Int64(rootStat.st_blocks) * 512
            return blocksBytes > 0 ? blocksBytes : max(0, Int64(rootStat.st_size))
        }

        guard let cPath = strdup(path) else { return 0 }
        defer { free(cPath) }

        var pathArray: [UnsafeMutablePointer<CChar>?] = [cPath, nil]
        guard let fts = pathArray.withUnsafeMutableBufferPointer({ buf in
            fts_open(buf.baseAddress, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil)
        }) else {
            return 0
        }
        defer { fts_close(fts) }

        var total: Int64 = 0
        var seenHardLinks = Set<InodeKey>()
        var counter: Int = 0

        while let entry = fts_read(fts) {
            counter &+= 1
            if (counter & 511) == 0 && Task.isCancelled {
                break
            }

            let info = Int32(entry.pointee.fts_info)
            if info == FTS_F, let stPtr = entry.pointee.fts_statp {
                if stPtr.pointee.st_nlink > 1 {
                    let key = InodeKey(dev: stPtr.pointee.st_dev, ino: stPtr.pointee.st_ino)
                    if !seenHardLinks.insert(key).inserted {
                        continue
                    }
                }
                let blocksBytes = Int64(stPtr.pointee.st_blocks) * 512
                total += (blocksBytes > 0) ? blocksBytes : max(0, Int64(stPtr.pointee.st_size))
            } else if (info == FTS_SL || info == FTS_SLNONE), let stPtr = entry.pointee.fts_statp {
                total += max(0, Int64(stPtr.pointee.st_size))
            }
        }
        return total
    }

    /// Checks whether removing `path` likely requires Administrator privileges using fast `access(2)` & `lstat(2)`.
    static func requiresAdminToModify(path: String) -> Bool {
        let parent = (path as NSString).deletingLastPathComponent
        if access(parent, W_OK) != 0 {
            return true
        }

        var st = stat()
        guard lstat(path, &st) == 0 else { return false }

        let currentUID = getuid()
        if access(path, W_OK) != 0 {
            return st.st_uid != currentUID
        }
        if st.st_uid == 0 && !path.hasPrefix(NSHomeDirectory()) {
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

    /// Scans installed user & third-party apps in parallel across CPU cores, plus indexes system apps for safety.
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
        var userURLs: [URL] = []
        for root in userAppRoots {
            for url in discoverAppBundles(in: URL(fileURLWithPath: root), maxDepth: 2) {
                let canonical = url.standardizedFileURL.path
                if seenPaths.insert(canonical).inserted {
                    userURLs.append(url)
                }
            }
        }

        var systemURLs: [URL] = []
        for root in systemRoots {
            for url in discoverAppBundles(in: URL(fileURLWithPath: root), maxDepth: 2) {
                let canonical = url.standardizedFileURL.path
                if seenPaths.insert(canonical).inserted {
                    systemURLs.append(url)
                }
            }
        }

        let visibleApps = inspectBundlesConcurrently(urls: userURLs, kindOverride: .application, includeCodeSignTeam: true)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        let systemApps = inspectBundlesConcurrently(urls: systemURLs, kindOverride: .application, includeCodeSignTeam: false)

        var allBundleIDs = Set<String>()
        var allAppNames = Set<String>()
        var teamMap: [String: Set<String>] = [:]
        var vendorMap: [String: Set<String>] = [:]

        for bundle in visibleApps {
            registerInIndex(
                bundle: bundle,
                allBundleIDs: &allBundleIDs,
                allAppNames: &allAppNames,
                teamMap: &teamMap,
                vendorMap: &vendorMap
            )
        }
        for bundle in systemApps {
            registerInIndex(
                bundle: bundle,
                allBundleIDs: &allBundleIDs,
                allAppNames: &allAppNames,
                teamMap: &teamMap,
                vendorMap: &vendorMap
            )
        }

        return InstalledSystemIndex(
            apps: visibleApps,
            allKnownBundleIDs: allBundleIDs,
            allKnownAppNamesNormalized: allAppNames,
            teamIDToAppPaths: teamMap,
            vendorPrefixToAppPaths: vendorMap
        )
    }

    private static func inspectBundlesConcurrently(
        urls: [URL],
        kindOverride: BundleKind?,
        includeCodeSignTeam: Bool
    ) -> [TargetBundle] {
        guard !urls.isEmpty else { return [] }
        let lock = NSLock()
        var collected: [TargetBundle] = []
        collected.reserveCapacity(urls.count)

        DispatchQueue.concurrentPerform(iterations: urls.count) { idx in
            if let bundle = inspectBundle(
                at: urls[idx],
                kindOverride: kindOverride,
                includeCodeSignTeam: includeCodeSignTeam
            ) {
                lock.lock()
                collected.append(bundle)
                lock.unlock()
            }
        }
        return collected
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
        var candidates: [(URL, BundleKind)] = []
        var seen = Set<String>()

        for (dirPath, defaultKind) in locations {
            guard let items = try? fm.contentsOfDirectory(
                at: URL(fileURLWithPath: dirPath),
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for itemURL in items {
                let ext = itemURL.pathExtension.lowercased()
                guard let kind = supportedAddonExtensions[ext] ?? defaultKind else { continue }
                let canonical = itemURL.standardizedFileURL.path
                guard seen.insert(canonical).inserted else { continue }
                candidates.append((itemURL, kind))
            }
        }

        guard !candidates.isEmpty else { return [] }
        let lock = NSLock()
        var results: [TargetBundle] = []
        results.reserveCapacity(candidates.count)

        DispatchQueue.concurrentPerform(iterations: candidates.count) { idx in
            let (url, kind) = candidates[idx]
            if let bundle = inspectBundle(at: url, kindOverride: kind, includeCodeSignTeam: false) {
                lock.lock()
                results.append(bundle)
                lock.unlock()
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

        let (childIDs, childExecs) = includeCodeSignTeam
            ? scanEmbeddedChildBundles(contentsURL: contentsURL)
            : ([], [])

        let arch: AppArchitecture
        let execURL = contentsURL.appendingPathComponent("MacOS").appendingPathComponent(executableName)
        if fm.fileExists(atPath: execURL.path) {
            arch = detectMachOArchitecture(at: execURL)
        } else {
            arch = .unknown
        }

        let teamID: String? = includeCodeSignTeam ? extractCodeSignTeamID(at: url) : nil

        let modDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let (lastUsedDate, useCount, dateAdded, spotlightBytes) = includeCodeSignTeam
            ? extractUsageAndSizeMetadata(bundleURL: url, bundleID: bundleID)
            : (nil, 0, nil, nil)

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
            bundleSizeBytes: spotlightBytes,
            modifiedDate: modDate,
            lastUsedDate: lastUsedDate,
            useCount: useCount,
            dateAdded: dateAdded,
            isSystemProtected: isProtected,
            kind: kind
        )
    }

    private static let spotlightAttrNames: CFArray = [
        "kMDItemLastUsedDate" as CFString,
        "kMDItemUseCount" as CFString,
        "kMDItemDateAdded" as CFString,
        "kMDItemFSSize" as CFString
    ] as CFArray

    private static func extractUsageAndSizeMetadata(
        bundleURL: URL,
        bundleID: String
    ) -> (Date?, Int, Date?, Int64?) {
        var spotlightLastUsed: Date? = nil
        var spotlightUseCount: Int = 0
        var spotlightDateAdded: Date? = nil
        var spotlightSize: Int64? = nil

        if let mdItem = MDItemCreateWithURL(kCFAllocatorDefault, bundleURL as CFURL),
           let attrs = MDItemCopyAttributes(mdItem, spotlightAttrNames) as? [String: Any] {
            spotlightLastUsed = attrs["kMDItemLastUsedDate"] as? Date
            spotlightUseCount = (attrs["kMDItemUseCount"] as? NSNumber)?.intValue ?? 0
            spotlightDateAdded = attrs["kMDItemDateAdded"] as? Date
            if let rawSize = (attrs["kMDItemFSSize"] as? NSNumber)?.int64Value, rawSize > 0 {
                spotlightSize = rawSize
            }
        }

        // Augment with ~/Library/Saved Application State/<bundleID>.savedState modification date
        if !bundleID.isEmpty {
            let savedStatePath = (NSHomeDirectory() as NSString)
                .appendingPathComponent("Library/Saved Application State/\(bundleID).savedState")
            var st = stat()
            if stat(savedStatePath, &st) == 0 {
                let stateMod = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
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

        return (spotlightLastUsed, spotlightUseCount, spotlightDateAdded, spotlightSize)
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
        let fd = open(executableURL.path, O_RDONLY)
        guard fd >= 0 else { return .unknown }
        defer { close(fd) }

        var header = [UInt8](repeating: 0, count: 8)
        let bytesRead = read(fd, &header, 8)
        guard bytesRead == 8 else { return .unknown }

        let magic = header.withUnsafeBytes { $0.load(as: UInt32.self) }
        switch magic {
        case 0xCAFEBABE, 0xBEBAFECA, 0xCAFEBABF, 0xBFBAFECA:
            return .universal
        case 0xFEEDFACF, 0xFEEDFACE:
            let cpuType = header.withUnsafeBytes { $0.load(fromByteOffset: 4, as: Int32.self) }
            if (cpuType & 0x00FF_FFFF) == 12 { return .appleSilicon }
            if (cpuType & 0x00FF_FFFF) == 7 { return .intel }
            return .unknown
        case 0xCFFAEDFE, 0xCEFAEDFE:
            let swapped = header.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self).byteSwapped }
            if (swapped & 0x00FF_FFFF) == 12 { return .appleSilicon }
            if (swapped & 0x00FF_FFFF) == 7 { return .intel }
            return .unknown
        default:
            return .unknown
        }
    }

    static func normalizeToken(_ raw: String) -> String {
        var result = ""
        result.reserveCapacity(raw.utf8.count)
        let folded = raw.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                result.unicodeScalars.append(scalar)
            }
        }
        return result.lowercased()
    }
}
