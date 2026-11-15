import Darwin
import Foundation

enum DiskSpaceAnalyzerService {
    private struct InodeKey: Hashable {
        let dev: dev_t
        let ino: ino_t
    }

    private static let packageExtensions: Set<String> = [
        "app", "prefpane", "qlgenerator", "saver", "plugin", "component",
        "vst", "vst3", "appex", "wdgt", "photoslibrary", "xcodeproj",
        "xcworkspace", "playground", "bundle", "framework", "kext", "systemextension"
    ]

    private static let skippedVirtualPaths: Set<String> = [
        "/Volumes",
        "/System/Volumes",
        "/dev",
        "/net",
        "/home",
        "/cores",
        "/private/var/vm"
    ]

    private static let protectedAppleCacheTokens: Set<String> = [
        "cloudkit", "familycircle", "geoservices", "passkit", "apple.bird",
        "com.apple.nsurlsessiond", "com.apple.safari", "com.apple.ap.adprivacyd"
    ]

    private static let nonDeletableExtraPaths: Set<String> = {
        let home = NSHomeDirectory()
        return Set([
            "\(home)/Applications",
            "\(home)/Library/Mobile Documents",
            "\(home)/Library/CloudStorage",
            "\(home)/Library/Keychains",
            "\(home)/Library/Mail",
            "\(home)/Library/Messages",
            "\(home)/Library/Safari",
            "\(home)/Library/Photos",
            "\(home)/Library/Calendars",
            "\(home)/Library/Contacts",
            "/Applications/AppSweep.app",
            "/Applications/Safari.app",
            "/opt",
            "/opt/homebrew",
            "/usr/local",
            "/private/var",
            "/private/etc"
        ])
    }()

    // MARK: - Volume Capacity Query

    static func queryVolumeMetrics(for path: String) -> VolumeSpaceMetrics? {
        let targetURL = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [
            .volumeLocalizedNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ]

        let resolvedURL = FileManager.default.fileExists(atPath: path) ? targetURL : URL(fileURLWithPath: "/")
        guard let values = try? resolvedURL.resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity,
              total > 0 else {
            return nil
        }

        let name = values.volumeLocalizedName ?? "Macintosh HD"
        let availImportant = values.volumeAvailableCapacityForImportantUsage ?? 0
        let availStandard = Int64(values.volumeAvailableCapacity ?? 0)
        let bestAvailable = max(availImportant, availStandard)

        return VolumeSpaceMetrics(
            volumeName: name,
            totalBytes: Int64(total),
            availableBytes: min(Int64(total), max(0, bestAvailable))
        )
    }

    // MARK: - Deletability Guard

    static func isProtectedFromCleanup(_ rawPath: String) -> Bool {
        let std = URL(fileURLWithPath: rawPath).standardizedFileURL.path
        if DeepFileScanner.isProtectedPath(std) || nonDeletableExtraPaths.contains(std) {
            return true
        }
        let ownBundle = Bundle.main.bundleURL.standardizedFileURL.path
        if !ownBundle.isEmpty && (std == ownBundle || std.hasPrefix(ownBundle + "/")) {
            return true
        }
        let comps = std.split(separator: "/")
        if comps.count < 2 {
            return true
        }
        if (comps.first == "Users" || comps.first == "Library" || comps.first == "System") && comps.count < 3 {
            return true
        }
        return false
    }

    // MARK: - Public Multi-Core Analysis Entry Points

    static func analyzeRoot(
        preset: DiskScanPreset,
        customPath: String?,
        maxRetainedDepth: Int = 4,
        onProgress: (@Sendable (DiskScanProgress) -> Void)? = nil
    ) async -> DiskAnalysisSnapshot? {
        let startTime = CFAbsoluteTimeGetCurrent()
        let home = NSHomeDirectory()
        let effectivePath: String = {
            if preset == .custom, let customPath, !customPath.isEmpty {
                return URL(fileURLWithPath: customPath).standardizedFileURL.path
            }
            return preset.resolvedRootPath ?? home
        }()

        let metrics = queryVolumeMetrics(for: effectivePath)

        // Build list of top-level scan units (with 1-level hub expansion for ~/Library & /Users so all CPU cores stay busy)
        let plan = buildParallelScanPlan(for: effectivePath, preset: preset)
        if Task.isCancelled { return nil }

        let totalUnits = max(1, plan.subdirectories.count + (plan.directFiles.isEmpty ? 0 : 1))

        struct UnitResult: Sendable {
            let hubGroupPath: String?
            let node: DiskSpaceNode
            let suggestions: [DiskCleanupSuggestion]
        }

        var unitResults: [UnitResult] = []
        unitResults.reserveCapacity(plan.subdirectories.count)

        await withTaskGroup(of: UnitResult?.self) { group in
            let maxWorkers = 6
            var nextIdx = 0
            let initial = min(maxWorkers, plan.subdirectories.count)

            while nextIdx < initial {
                let unit = plan.subdirectories[nextIdx]
                nextIdx += 1
                group.addTask(priority: .userInitiated) {
                    guard !Task.isCancelled else { return nil }
                    let childDepth = unit.hubParentPath != nil ? max(2, maxRetainedDepth - 2) : max(2, maxRetainedDepth - 1)
                    let scanned = scanSubtreeSync(
                        at: unit.path,
                        maxRetainedDepth: childDepth,
                        collectSuggestions: true
                    )
                    guard let node = scanned.node else { return nil }
                    return UnitResult(hubGroupPath: unit.hubParentPath, node: node, suggestions: scanned.suggestions)
                }
            }

            var completed = 0
            var bytesAccumulated: Int64 = plan.directFiles.reduce(0) { $0 + $1.sizeBytes }
            var lastReport = CFAbsoluteTimeGetCurrent()

            while let finished = await group.next() {
                if Task.isCancelled {
                    group.cancelAll()
                    return
                }
                completed += 1
                if let res = finished {
                    bytesAccumulated += res.node.sizeBytes
                    unitResults.append(res)

                    let now = CFAbsoluteTimeGetCurrent()
                    if (now - lastReport) >= 0.12 || completed == plan.subdirectories.count {
                        lastReport = now
                        onProgress?(DiskScanProgress(
                            currentPath: res.node.displayPath,
                            scannedBytes: bytesAccumulated,
                            completedUnits: completed,
                            totalUnits: totalUnits
                        ))
                    }
                }

                if nextIdx < plan.subdirectories.count {
                    let nextUnit = plan.subdirectories[nextIdx]
                    nextIdx += 1
                    group.addTask(priority: .userInitiated) {
                        guard !Task.isCancelled else { return nil }
                        let childDepth = nextUnit.hubParentPath != nil ? max(2, maxRetainedDepth - 2) : max(2, maxRetainedDepth - 1)
                        let scanned = scanSubtreeSync(
                            at: nextUnit.path,
                            maxRetainedDepth: childDepth,
                            collectSuggestions: true
                        )
                        guard let node = scanned.node else { return nil }
                        return UnitResult(hubGroupPath: nextUnit.hubParentPath, node: node, suggestions: scanned.suggestions)
                    }
                }
            }
        }

        if Task.isCancelled { return nil }

        // Reassemble hub directories (such as ~/Library or /Users) and root children
        var directRootChildren: [DiskSpaceNode] = plan.directFiles
        var hubBuckets: [String: [DiskSpaceNode]] = [:]
        var rawSuggestions: [DiskCleanupSuggestion] = plan.directFileSuggestions

        for res in unitResults {
            rawSuggestions.append(contentsOf: res.suggestions)
            if let hubPath = res.hubGroupPath {
                hubBuckets[hubPath, default: []].append(res.node)
            } else {
                directRootChildren.append(res.node)
            }
        }

        for hubMeta in plan.expandedHubs {
            var hubChildren = hubBuckets[hubMeta.path] ?? []
            hubChildren.append(contentsOf: hubMeta.directFiles)
            hubChildren.sort { $0.sizeBytes > $1.sizeBytes }

            let totalHubBytes = hubChildren.reduce(Int64(0)) { $0 + $1.sizeBytes }
            let totalHubItems = hubChildren.reduce(0) { $0 + max(1, $1.itemCount) }
            let hubNode = finalizeDirectoryNode(
                path: hubMeta.path,
                name: (hubMeta.path as NSString).lastPathComponent,
                totalBytes: totalHubBytes,
                itemCount: totalHubItems,
                modifiedDate: hubMeta.modifiedDate,
                children: hubChildren,
                maxChildren: 60,
                hasUnexpandedSubtree: false
            )
            directRootChildren.append(hubNode)
        }

        directRootChildren.sort { $0.sizeBytes > $1.sizeBytes }
        let rootTotalBytes = directRootChildren.reduce(Int64(0)) { $0 + $1.sizeBytes }
        let rootTotalItems = directRootChildren.reduce(0) { $0 + max(1, $1.itemCount) }

        let rootTitle: String = {
            if preset == .mainDisk && effectivePath == "/" {
                return metrics?.volumeName ?? "Ổ đĩa chính"
            }
            let last = (effectivePath as NSString).lastPathComponent
            return last.isEmpty ? effectivePath : last
        }()

        let rootNode = finalizeDirectoryNode(
            path: effectivePath,
            name: rootTitle,
            totalBytes: rootTotalBytes,
            itemCount: rootTotalItems,
            modifiedDate: Date(),
            children: directRootChildren,
            maxChildren: 80,
            hasUnexpandedSubtree: false
        )

        let deduplicated = deduplicateAndRankSuggestions(rawSuggestions)
        let elapsed = max(0.01, CFAbsoluteTimeGetCurrent() - startTime)

        return DiskAnalysisSnapshot(
            rootNode: rootNode,
            recommendations: deduplicated,
            volumeMetrics: metrics,
            elapsedSeconds: elapsed
        )
    }

    /// Scans a single folder on-demand when the user drills down deeper than the pre-retained tree depth.
    static func scanSubfolderOnDemand(
        at path: String,
        maxDepth: Int = 3
    ) async -> (node: DiskSpaceNode?, suggestions: [DiskCleanupSuggestion]) {
        await Task.detached(priority: .userInitiated) {
            let raw = scanSubtreeSync(at: path, maxRetainedDepth: maxDepth, collectSuggestions: true)
            return (raw.node, deduplicateAndRankSuggestions(raw.suggestions))
        }.value
    }

    // MARK: - Parallel Plan Construction

    private struct SubdirWorkUnit: Sendable {
        let path: String
        let hubParentPath: String?
    }

    private struct ExpandedHubMeta: Sendable {
        let path: String
        let modifiedDate: Date?
        let directFiles: [DiskSpaceNode]
    }

    private struct ParallelScanPlan: Sendable {
        let subdirectories: [SubdirWorkUnit]
        let expandedHubs: [ExpandedHubMeta]
        let directFiles: [DiskSpaceNode]
        let directFileSuggestions: [DiskCleanupSuggestion]
    }

    private static func buildParallelScanPlan(for rootPath: String, preset: DiskScanPreset) -> ParallelScanPlan {
        let fm = FileManager.default
        let home = NSHomeDirectory()

        // Special safe roots for Main Disk ("/") to avoid APFS firmlink double-counting on /System/Volumes/Data
        if preset == .mainDisk && rootPath == "/" {
            let candidates = ["/Users", "/Applications", "/Library", "/opt", "/usr/local", "/private/var"]
            var subdirs: [SubdirWorkUnit] = []
            var hubs: [ExpandedHubMeta] = []

            for candidate in candidates where fm.fileExists(atPath: candidate) {
                if candidate == "/Users" || candidate == "/Library" {
                    let expanded = expandHubDirectory(at: candidate)
                    subdirs.append(contentsOf: expanded.units)
                    hubs.append(expanded.meta)
                } else {
                    subdirs.append(SubdirWorkUnit(path: candidate, hubParentPath: nil))
                }
            }
            return ParallelScanPlan(subdirectories: subdirs, expandedHubs: hubs, directFiles: [], directFileSuggestions: [])
        }

        let entries = (try? fm.contentsOfDirectory(atPath: rootPath)) ?? []
        var subdirs: [SubdirWorkUnit] = []
        var hubs: [ExpandedHubMeta] = []
        var directFiles: [DiskSpaceNode] = []
        var fileSuggestions: [DiskCleanupSuggestion] = []

        for name in entries {
            if name == "." || name == ".." || name == ".DS_Store" { continue }
            let fullPath = (rootPath as NSString).appendingPathComponent(name)
            if skippedVirtualPaths.contains(fullPath) { continue }

            var st = stat()
            guard lstat(fullPath, &st) == 0 else { continue }
            let modeType = st.st_mode & S_IFMT
            let mtime = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))

            if modeType == S_IFDIR {
                let ext = (name as NSString).pathExtension.lowercased()
                let isPkg = packageExtensions.contains(ext)
                // Expand ~/Library when scanning ~ so all workers process ~/Library/* concurrently
                if !isPkg && fullPath == (home as NSString).appendingPathComponent("Library") {
                    let expanded = expandHubDirectory(at: fullPath)
                    subdirs.append(contentsOf: expanded.units)
                    hubs.append(expanded.meta)
                } else {
                    subdirs.append(SubdirWorkUnit(path: fullPath, hubParentPath: nil))
                }
            } else {
                let fBytes = (modeType == S_IFLNK)
                    ? max(0, Int64(st.st_size))
                    : DiskSizeCalculator.physicalBytes(from: st)
                guard fBytes > 0 else { continue }
                let node = DiskSpaceNode(
                    id: fullPath,
                    path: fullPath,
                    name: name,
                    sizeBytes: fBytes,
                    isDirectory: false,
                    isPackageBundle: false,
                    isSyntheticOther: false,
                    hasUnexpandedSubtree: false,
                    itemCount: 1,
                    modifiedDate: mtime,
                    requiresAdmin: DiskSizeCalculator.requiresAdminToModify(path: fullPath),
                    isProtected: isProtectedFromCleanup(fullPath),
                    children: []
                )
                directFiles.append(node)
                if let sug = evaluateFileSuggestion(path: fullPath, name: name, sizeBytes: fBytes, mtime: mtime) {
                    fileSuggestions.append(sug)
                }
            }
        }

        return ParallelScanPlan(
            subdirectories: subdirs,
            expandedHubs: hubs,
            directFiles: directFiles,
            directFileSuggestions: fileSuggestions
        )
    }

    private static func expandHubDirectory(at hubPath: String) -> (units: [SubdirWorkUnit], meta: ExpandedHubMeta) {
        var hubStat = stat()
        let hubMtime: Date? = (lstat(hubPath, &hubStat) == 0)
            ? Date(timeIntervalSince1970: TimeInterval(hubStat.st_mtimespec.tv_sec))
            : nil

        let entries = (try? FileManager.default.contentsOfDirectory(atPath: hubPath)) ?? []
        var units: [SubdirWorkUnit] = []
        var files: [DiskSpaceNode] = []

        for name in entries where name != "." && name != ".." && name != ".DS_Store" {
            let full = (hubPath as NSString).appendingPathComponent(name)
            if skippedVirtualPaths.contains(full) { continue }
            var st = stat()
            guard lstat(full, &st) == 0 else { continue }
            let modeType = st.st_mode & S_IFMT
            if modeType == S_IFDIR {
                units.append(SubdirWorkUnit(path: full, hubParentPath: hubPath))
            } else {
                let sz = (modeType == S_IFLNK)
                    ? max(0, Int64(st.st_size))
                    : DiskSizeCalculator.physicalBytes(from: st)
                if sz > 0 {
                    files.append(DiskSpaceNode(
                        id: full,
                        path: full,
                        name: name,
                        sizeBytes: sz,
                        isDirectory: false,
                        isPackageBundle: false,
                        isSyntheticOther: false,
                        hasUnexpandedSubtree: false,
                        itemCount: 1,
                        modifiedDate: Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)),
                        requiresAdmin: DiskSizeCalculator.requiresAdminToModify(path: full),
                        isProtected: isProtectedFromCleanup(full),
                        children: []
                    ))
                }
            }
        }
        return (units, ExpandedHubMeta(path: hubPath, modifiedDate: hubMtime, directFiles: files))
    }

    // MARK: - Single-Pass Stack-Based POSIX `fts_open` Scanner

    private struct DirStackFrame {
        let level: Int
        let path: String
        let name: String
        let isPackageBundle: Bool
        let modifiedDate: Date?
        var totalBytes: Int64
        var itemCount: Int
        var sawSubdirectories: Bool
        var retainedChildren: [DiskSpaceNode]
    }

    private static func scanSubtreeSync(
        at rootPath: String,
        maxRetainedDepth: Int,
        collectSuggestions: Bool
    ) -> (node: DiskSpaceNode?, suggestions: [DiskCleanupSuggestion]) {
        var rootStat = stat()
        guard lstat(rootPath, &rootStat) == 0 else { return (nil, []) }

        let rootMode = rootStat.st_mode & S_IFMT
        let rootName = (rootPath as NSString).lastPathComponent
        let rootMtime = Date(timeIntervalSince1970: TimeInterval(rootStat.st_mtimespec.tv_sec))

        if rootMode != S_IFDIR {
            let fBytes = (rootMode == S_IFLNK)
                ? max(0, Int64(rootStat.st_size))
                : DiskSizeCalculator.physicalBytes(from: rootStat)
            let fileNode = DiskSpaceNode(
                id: rootPath,
                path: rootPath,
                name: rootName,
                sizeBytes: fBytes,
                isDirectory: false,
                isPackageBundle: false,
                isSyntheticOther: false,
                hasUnexpandedSubtree: false,
                itemCount: 1,
                modifiedDate: rootMtime,
                requiresAdmin: DiskSizeCalculator.requiresAdminToModify(path: rootPath),
                isProtected: isProtectedFromCleanup(rootPath),
                children: []
            )
            var sugs: [DiskCleanupSuggestion] = []
            if collectSuggestions, let s = evaluateFileSuggestion(path: rootPath, name: rootName, sizeBytes: fBytes, mtime: rootMtime) {
                sugs.append(s)
            }
            return (fileNode, sugs)
        }

        guard let cPath = strdup(rootPath) else { return (nil, []) }
        defer { free(cPath) }

        var pathArray: [UnsafeMutablePointer<CChar>?] = [cPath, nil]
        guard let fts = pathArray.withUnsafeMutableBufferPointer({ buf in
            fts_open(buf.baseAddress, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil)
        }) else {
            return (nil, [])
        }
        defer { fts_close(fts) }

        var stack: [DirStackFrame] = []
        stack.reserveCapacity(16)
        var seenHardLinks = Set<InodeKey>()
        var suggestions: [DiskCleanupSuggestion] = []
        var completedRootNode: DiskSpaceNode? = nil
        var counter = 0
        var insidePackageLevel: Int? = nil

        while let entry = fts_read(fts) {
            counter &+= 1
            if (counter & 511) == 0 && Task.isCancelled {
                return (nil, [])
            }

            let info = Int32(entry.pointee.fts_info)
            let level = max(0, Int(entry.pointee.fts_level))

            switch info {
            case FTS_D:
                let dirPath = String(cString: entry.pointee.fts_path)
                if level > 0 && skippedVirtualPaths.contains(dirPath) {
                    fts_set(fts, entry, FTS_SKIP)
                    continue
                }

                let dirName: String = {
                    if level == 0 {
                        return rootName.isEmpty ? dirPath : rootName
                    }
                    return (dirPath as NSString).lastPathComponent
                }()
                let ext = (dirName as NSString).pathExtension.lowercased()
                let isPkg = packageExtensions.contains(ext)
                if insidePackageLevel == nil && isPkg {
                    insidePackageLevel = level
                }

                let mtime: Date? = {
                    guard let stPtr = entry.pointee.fts_statp else { return nil }
                    return Date(timeIntervalSince1970: TimeInterval(stPtr.pointee.st_mtimespec.tv_sec))
                }()

                if level > 0 && !stack.isEmpty {
                    stack[stack.count - 1].sawSubdirectories = true
                }

                stack.append(DirStackFrame(
                    level: level,
                    path: dirPath,
                    name: dirName,
                    isPackageBundle: isPkg,
                    modifiedDate: mtime,
                    totalBytes: 0,
                    itemCount: 0,
                    sawSubdirectories: false,
                    retainedChildren: []
                ))

            case FTS_DP:
                guard let top = stack.last, top.level == level else { continue }
                let popped = stack.removeLast()
                if insidePackageLevel == popped.level {
                    insidePackageLevel = nil
                }

                // Evaluate top-level .app bundles (for duplicate / build-output .app detection) and regular directories
                if collectSuggestions && insidePackageLevel == nil {
                    if popped.isPackageBundle {
                        if popped.path.lowercased().hasSuffix(".app"),
                           let appSug = evaluateAppBundleSuggestion(
                               path: popped.path,
                               name: popped.name,
                               sizeBytes: popped.totalBytes,
                               mtime: popped.modifiedDate
                           ) {
                            suggestions.append(appSug)
                        }
                    } else if let dirSug = evaluateDirectorySuggestion(
                        path: popped.path,
                        name: popped.name,
                        sizeBytes: popped.totalBytes,
                        mtime: popped.modifiedDate
                    ) {
                        suggestions.append(dirSug)
                    }
                }

                let shouldMaterialize = (popped.level <= maxRetainedDepth)
                var materializedNode: DiskSpaceNode? = nil
                if shouldMaterialize {
                    let unexpanded = (popped.level == maxRetainedDepth) && popped.sawSubdirectories && popped.retainedChildren.isEmpty
                    materializedNode = finalizeDirectoryNode(
                        path: popped.path,
                        name: popped.name,
                        totalBytes: popped.totalBytes,
                        itemCount: max(1, popped.itemCount),
                        modifiedDate: popped.modifiedDate,
                        children: popped.retainedChildren,
                        maxChildren: 60,
                        hasUnexpandedSubtree: unexpanded
                    )
                }

                if !stack.isEmpty {
                    let parentIdx = stack.count - 1
                    stack[parentIdx].totalBytes += popped.totalBytes
                    stack[parentIdx].itemCount += max(1, popped.itemCount)
                    if let childNode = materializedNode, popped.level <= maxRetainedDepth, childNode.sizeBytes > 0 {
                        stack[parentIdx].retainedChildren.append(childNode)
                    }
                } else {
                    completedRootNode = materializedNode
                }

            case FTS_F, FTS_SL, FTS_SLNONE:
                guard !stack.isEmpty, let stPtr = entry.pointee.fts_statp else { continue }
                let fileBytes: Int64
                if info == FTS_F {
                    if stPtr.pointee.st_nlink > 1 {
                        let key = InodeKey(dev: stPtr.pointee.st_dev, ino: stPtr.pointee.st_ino)
                        if !seenHardLinks.insert(key).inserted {
                            continue
                        }
                    }
                    fileBytes = DiskSizeCalculator.physicalBytes(from: stPtr.pointee)
                } else {
                    fileBytes = max(0, Int64(stPtr.pointee.st_size))
                }

                guard fileBytes > 0 else { continue }

                let parentIdx = stack.count - 1
                stack[parentIdx].totalBytes += fileBytes
                stack[parentIdx].itemCount += 1

                let needNode = (level <= maxRetainedDepth) && (insidePackageLevel == nil)
                let needSuggestionCheck = collectSuggestions && (insidePackageLevel == nil) && (fileBytes >= 2_097_152) // >= 2 MB

                if needNode || needSuggestionCheck {
                    let filePath = String(cString: entry.pointee.fts_path)
                    let fileName = (filePath as NSString).lastPathComponent
                    if fileName == ".DS_Store" { continue }
                    let mtime = Date(timeIntervalSince1970: TimeInterval(stPtr.pointee.st_mtimespec.tv_sec))

                    if needSuggestionCheck,
                       let fileSug = evaluateFileSuggestion(path: filePath, name: fileName, sizeBytes: fileBytes, mtime: mtime) {
                        suggestions.append(fileSug)
                    }

                    if needNode {
                        let fNode = DiskSpaceNode(
                            id: filePath,
                            path: filePath,
                            name: fileName,
                            sizeBytes: fileBytes,
                            isDirectory: false,
                            isPackageBundle: false,
                            isSyntheticOther: false,
                            hasUnexpandedSubtree: false,
                            itemCount: 1,
                            modifiedDate: mtime,
                            requiresAdmin: false,
                            isProtected: isProtectedFromCleanup(filePath),
                            children: []
                        )
                        stack[parentIdx].retainedChildren.append(fNode)
                    }
                }

            default:
                // FTS_DNR (unreadable directory), FTS_DC, FTS_ERR: no matching FTS_DP is emitted
                break
            }
        }

        return (completedRootNode, suggestions)
    }

    private static func finalizeDirectoryNode(
        path: String,
        name: String,
        totalBytes: Int64,
        itemCount: Int,
        modifiedDate: Date?,
        children: [DiskSpaceNode],
        maxChildren: Int,
        hasUnexpandedSubtree: Bool
    ) -> DiskSpaceNode {
        var sorted = children.filter { $0.sizeBytes > 0 }
        sorted.sort { $0.sizeBytes > $1.sizeBytes }

        var finalChildren: [DiskSpaceNode] = []
        if sorted.count <= maxChildren {
            finalChildren = sorted
        } else {
            finalChildren = Array(sorted.prefix(maxChildren))
            let tailSlice = sorted.dropFirst(maxChildren)
            let tailBytes = tailSlice.reduce(Int64(0)) { $0 + $1.sizeBytes }
            let tailItems = tailSlice.reduce(0) { $0 + max(1, $1.itemCount) }
            if tailBytes > 0 {
                finalChildren.append(DiskSpaceNode(
                    id: "__other__:\(path)",
                    path: "\(tailSlice.count) mục nhỏ khác bên trong \(PathFormatter.prettyPath(path))",
                    name: "Các mục nhỏ khác (\(tailSlice.count))",
                    sizeBytes: tailBytes,
                    isDirectory: false,
                    isPackageBundle: false,
                    isSyntheticOther: true,
                    hasUnexpandedSubtree: false,
                    itemCount: tailItems,
                    modifiedDate: nil,
                    requiresAdmin: false,
                    isProtected: true,
                    children: []
                ))
            }
        }

        let ext = (name as NSString).pathExtension.lowercased()
        let isPkg = packageExtensions.contains(ext)

        return DiskSpaceNode(
            id: path,
            path: path,
            name: name,
            sizeBytes: totalBytes,
            isDirectory: true,
            isPackageBundle: isPkg,
            isSyntheticOther: false,
            hasUnexpandedSubtree: hasUnexpandedSubtree,
            itemCount: itemCount,
            modifiedDate: modifiedDate,
            requiresAdmin: DiskSizeCalculator.requiresAdminToModify(path: path),
            isProtected: isProtectedFromCleanup(path),
            children: finalChildren
        )
    }

    // MARK: - Smart Cleanup Advisor Rules

    /// Detects duplicate `.app` bundles (`* 2.app`, `* 3.app`, `* copy.app`) and build-output `.app` bundles outside `/Applications`.
    private static func evaluateAppBundleSuggestion(
        path: String,
        name: String,
        sizeBytes: Int64,
        mtime: Date?
    ) -> DiskCleanupSuggestion? {
        guard sizeBytes >= 512 * 1024 else { return nil }
        guard !isProtectedFromCleanup(path) else { return nil }

        let home = NSHomeDirectory()
        if path.hasPrefix("/System/") || path.hasPrefix("/Library/") || path.hasPrefix(home + "/Library/") || path.hasPrefix(home + "/.Trash/") {
            return nil
        }

        let parentPath = (path as NSString).deletingLastPathComponent
        let parentName = (parentPath as NSString).lastPathComponent
        let requiresAdmin = DiskSizeCalculator.requiresAdminToModify(path: path)
        let baseName = (name as NSString).deletingPathExtension

        // Skip primary installed apps in /Applications or ~/Applications (managed in Uninstaller tab)
        if parentPath == "/Applications" || parentPath == "\(home)/Applications" {
            return nil
        }

        // 1. Check if this `.app` is a numbered duplicate or copy (e.g. "DriveBar 2.app", "AppSweep 3.app", "App copy.app", "App (1).app")
        if let canonicalBase = extractCanonicalAppBaseName(from: baseName) {
            let canonicalAppName = "\(canonicalBase).app"
            let hasOriginalBeside = FileManager.default.fileExists(atPath: (parentPath as NSString).appendingPathComponent(canonicalAppName))
            let hasOriginalInApps = FileManager.default.fileExists(atPath: "/Applications/\(canonicalAppName)")
                || FileManager.default.fileExists(atPath: "\(home)/Applications/\(canonicalAppName)")
            let safety: CleanupSafetyLevel = (hasOriginalBeside || hasOriginalInApps) ? .safeRecreate : .reviewRecommended

            return DiskCleanupSuggestion(
                id: path,
                path: path,
                title: "\(name) — Bản sao trùng lặp",
                sizeBytes: sizeBytes,
                safety: safety,
                ruleKind: .builtAndDuplicateApps,
                reason: "Bản ứng dụng bị nhân bản trong thư mục '\(parentName)' (được tạo ra khi đóng gói hoặc tải về nhiều lần).",
                impactIfDeleted: (hasOriginalBeside || hasOriginalInApps)
                    ? "Xóa hoàn toàn an toàn — Đã có bản '\(canonicalAppName)' gốc, xóa bản trùng này không mất dữ liệu."
                    : "An toàn để dọn nếu bạn không còn dùng bản sao này.",
                lastModified: mtime,
                isDirectory: true,
                requiresAdmin: requiresAdmin
            )
        }

        // 2. Check if this `.app` sits inside a build/project workspace (like BuildApp or BuildApp/AppSweep) or is already installed in /Applications
        let installedInApplications = FileManager.default.fileExists(atPath: "/Applications/\(name)")
            || FileManager.default.fileExists(atPath: "\(home)/Applications/\(name)")

        let siblingProjectDir = (parentPath as NSString).appendingPathComponent(baseName)
        var isDir: ObjCBool = false
        let hasSiblingProjectFolder = FileManager.default.fileExists(atPath: siblingProjectDir, isDirectory: &isDir) && isDir.boolValue
        let isInsideOwnProjectFolder = parentName.lowercased() == baseName.lowercased()
        let hasBuildMarkers = directoryHasProjectOrBuildMarkers(parentPath)
            || parentName.lowercased().contains("build")

        if hasSiblingProjectFolder || isInsideOwnProjectFolder || hasBuildMarkers {
            return DiskCleanupSuggestion(
                id: path,
                path: path,
                title: "\(name) — Bản build trong '\(parentName)'",
                sizeBytes: sizeBytes,
                safety: .safeRecreate,
                ruleKind: .builtAndDuplicateApps,
                reason: installedInApplications
                    ? "File .app tạo ra khi đóng gói trong '\(parentName)' (ứng dụng chính đã cài trong /Applications)."
                    : "File .app được tạo ra trong quá trình build thử nghiệm tại thư mục '\(parentName)'.",
                impactIfDeleted: installedInApplications
                    ? "Xóa hoàn toàn an toàn — Ứng dụng trong /Applications và thư mục mã nguồn gốc không bị ảnh hưởng."
                    : "Xóa an toàn — Thư mục mã nguồn gốc vẫn giữ nguyên, có thể đóng gói lại bất cứ lúc nào.",
                lastModified: mtime,
                isDirectory: true,
                requiresAdmin: requiresAdmin
            )
        }

        if installedInApplications {
            return DiskCleanupSuggestion(
                id: path,
                path: path,
                title: "\(name) — Bản dư ngoài Applications",
                sizeBytes: sizeBytes,
                safety: .safeRecreate,
                ruleKind: .builtAndDuplicateApps,
                reason: "Bản .app nằm lẻ trong '\(parentName)' trong khi ứng dụng đã được cài đặt sẵn trong /Applications.",
                impactIfDeleted: "Xóa hoàn toàn an toàn — Bạn vẫn dùng ứng dụng bình thường từ /Applications.",
                lastModified: mtime,
                isDirectory: true,
                requiresAdmin: requiresAdmin
            )
        }

        // 3. Standalone `.app` bundle in Downloads / Desktop / Documents not installed in /Applications
        return DiskCleanupSuggestion(
            id: path,
            path: path,
            title: "\(name) — Ứng dụng rời trong '\(parentName)'",
            sizeBytes: sizeBytes,
            safety: .reviewRecommended,
            ruleKind: .builtAndDuplicateApps,
            reason: "Gói ứng dụng (.app) nằm trong thư mục '\(parentName)' thay vì trong /Applications.",
            impactIfDeleted: "Nếu không còn chạy bản ứng dụng rời này hoặc đã cài xong, bạn có thể xóa để lấy lại dung lượng.",
            lastModified: mtime,
            isDirectory: true,
            requiresAdmin: requiresAdmin
        )
    }

    /// If `baseName` ends with a duplicate suffix (`" 2"`, `" 3"`, `" copy"`, `" (1)"`, `"-old"`), returns the canonical base name.
    private static func extractCanonicalAppBaseName(from baseName: String) -> String? {
        let trimmed = baseName.trimmingCharacters(in: .whitespaces)
        let lower = trimmed.lowercased()

        for copySuffix in [" copy", "-copy", "_copy", "-old", "_old", " backup"] {
            if lower.hasSuffix(copySuffix) {
                let prefix = String(trimmed.dropLast(copySuffix.count)).trimmingCharacters(in: .whitespaces)
                if !prefix.isEmpty { return prefix }
            }
        }

        // Pattern: "<Name> (<number>)" e.g. "AppSweep (1)"
        if trimmed.hasSuffix(")"), let openParen = trimmed.lastIndex(of: "(") {
            let inside = trimmed[trimmed.index(after: openParen)..<trimmed.index(before: trimmed.endIndex)]
            if !inside.isEmpty && inside.allSatisfy({ $0.isNumber }) {
                let prefix = String(trimmed[..<openParen]).trimmingCharacters(in: .whitespaces)
                if !prefix.isEmpty { return prefix }
            }
        }

        // Pattern: "<Name> <number>" where number is 2...99 (e.g. "DriveBar 2", "AppSweep 3", "WebBox 2")
        if let lastSpace = trimmed.lastIndex(of: " ") {
            let tail = String(trimmed[trimmed.index(after: lastSpace)...])
            if let num = Int(tail), (2...99).contains(num) {
                let prefix = String(trimmed[..<lastSpace]).trimmingCharacters(in: .whitespaces)
                // Avoid matching legitimate versioned app names like "1Password 7", "Alfred 5", "Bartender 5", "Bartender 6", "CamScanner 2" unless base `.app` exists
                let parentCheckApps = ["/Applications/\(prefix).app", "\(NSHomeDirectory())/Applications/\(prefix).app"]
                if parentCheckApps.contains(where: { FileManager.default.fileExists(atPath: $0) }) || num >= 2 {
                    // Extra guard: if it's in /Applications, only treat as duplicate if `<prefix>.app` also exists
                    return prefix
                }
            }
        }

        return nil
    }

    private static func directoryHasProjectOrBuildMarkers(_ dirPath: String) -> Bool {
        let fm = FileManager.default
        let markers = [
            "Package.swift", "Sources", ".build", "dist", "scripts",
            "package.json", "Cargo.toml", "pyproject.toml", "Makefile", ".git"
        ]
        for marker in markers {
            if fm.fileExists(atPath: (dirPath as NSString).appendingPathComponent(marker)) {
                return true
            }
        }
        return false
    }

    private static func evaluateDirectorySuggestion(
        path: String,
        name: String,
        sizeBytes: Int64,
        mtime: Date?
    ) -> DiskCleanupSuggestion? {
        let MB: Int64 = 1_048_576
        guard sizeBytes >= 2 * MB else { return nil }
        guard !isProtectedFromCleanup(path) else { return nil }

        let home = NSHomeDirectory()
        // Exclude items already inside Trash from cleanup suggestions
        if path.hasPrefix(home + "/.Trash/") { return nil }

        let lowerName = name.lowercased()
        let parentPath = (path as NSString).deletingLastPathComponent
        let requiresAdmin = DiskSizeCalculator.requiresAdminToModify(path: path)

        // 1. Known Developer & Package Manager Cache roots
        if path == "\(home)/Library/Developer/Xcode/DerivedData", sizeBytes >= 20 * MB {
            return DiskCleanupSuggestion(
                id: path,
                path: path,
                title: "Bộ nhớ nháp Xcode (DerivedData)",
                sizeBytes: sizeBytes,
                safety: .safeRecreate,
                ruleKind: .developerBuild,
                reason: "File nháp sinh ra khi chạy Xcode — chiếm rất nhiều bộ nhớ nhưng không chứa mã nguồn.",
                impactIfDeleted: "Xóa hoàn toàn an toàn — Xcode sẽ tự tạo lại khi bạn mở dự án.",
                lastModified: mtime,
                isDirectory: true,
                requiresAdmin: requiresAdmin
            )
        }

        if (path == "\(home)/Library/Developer/Xcode/iOS DeviceSupport"
            || path == "\(home)/Library/Developer/Xcode/watchOS DeviceSupport"
            || path == "\(home)/Library/Developer/Xcode/tvOS DeviceSupport"),
           sizeBytes >= 40 * MB {
            return DiskCleanupSuggestion(
                id: path,
                path: path,
                title: "Dữ liệu thiết bị cũ Xcode (\(name))",
                sizeBytes: sizeBytes,
                safety: .safeRecreate,
                ruleKind: .developerBuild,
                reason: "Dữ liệu gỡ lỗi của các phiên bản iOS cũ từng cắm vào máy.",
                impactIfDeleted: "Xóa hoàn toàn an toàn — Tự nạp lại nếu bạn cắm thiết bị vào Xcode.",
                lastModified: mtime,
                isDirectory: true,
                requiresAdmin: requiresAdmin
            )
        }

        if path == "\(home)/Library/Developer/CoreSimulator/Caches", sizeBytes >= 25 * MB {
            return DiskCleanupSuggestion(
                id: path,
                path: path,
                title: "Bộ nhớ tạm máy ảo iPhone (CoreSimulator Caches)",
                sizeBytes: sizeBytes,
                safety: .safeRecreate,
                ruleKind: .developerBuild,
                reason: "Bộ nhớ đệm tạm thời của trình giả lập iOS Simulator.",
                impactIfDeleted: "Xóa hoàn toàn an toàn — Không làm mất ứng dụng hay mã nguồn.",
                lastModified: mtime,
                isDirectory: true,
                requiresAdmin: requiresAdmin
            )
        }

        if path == "\(home)/Library/Developer/Xcode/Archives", sizeBytes >= 80 * MB {
            return DiskCleanupSuggestion(
                id: path,
                path: path,
                title: "Bản đóng gói Xcode cũ (Archives)",
                sizeBytes: sizeBytes,
                safety: .reviewRecommended,
                ruleKind: .developerBuild,
                reason: "Các bản đóng gói phát hành cũ của Xcode.",
                impactIfDeleted: "Có thể xóa nếu bạn không còn cần kiểm tra các bản phát hành cũ này.",
                lastModified: mtime,
                isDirectory: true,
                requiresAdmin: requiresAdmin
            )
        }

        if path == "\(home)/Library/Developer/CoreSimulator/Devices", sizeBytes >= 400 * MB {
            return DiskCleanupSuggestion(
                id: path,
                path: path,
                title: "Máy ảo iPhone / iPad thử nghiệm (Simulator Devices)",
                sizeBytes: sizeBytes,
                safety: .reviewRecommended,
                ruleKind: .iosBackupsAndVMs,
                reason: "Ổ đĩa các máy ảo iOS Simulator dùng để chạy thử ứng dụng.",
                impactIfDeleted: "Chỉ dọn nếu bạn không cần giữ dữ liệu đang thử nghiệm bên trong máy ảo iOS.",
                lastModified: mtime,
                isDirectory: true,
                requiresAdmin: requiresAdmin
            )
        }

        // 2. Package Manager Caches (Homebrew, npm, pip, uv, Yarn, Cargo, Gradle, HuggingFace, Playwright)
        let knownPkgCaches: [(exactPath: String, label: String, detail: String)] = [
            ("\(home)/.npm/_cacache", "Bộ cài tạm của Node.js (npm cache)", "Các tệp thư viện tải về tạm thời — tự tải lại khi cần"),
            ("\(home)/.cache/pip", "Bộ cài tạm của Python (pip cache)", "Các gói cài đặt lưu tạm của Python — xóa không làm hỏng Python"),
            ("\(home)/Library/Caches/pip", "Bộ cài tạm của Python (Library pip)", "Các gói cài đặt lưu tạm của Python — xóa không làm hỏng Python"),
            ("\(home)/.cache/uv", "Bộ cài tạm của Python uv", "Kho tệp tải tạm của công cụ Python uv — hoàn toàn an toàn để dọn"),
            ("\(home)/Library/Caches/uv", "Bộ cài tạm của Python uv (Library)", "Kho tệp tải tạm của công cụ Python uv — hoàn toàn an toàn để dọn"),
            ("\(home)/Library/Caches/Homebrew", "Gói tải về cũ của Homebrew", "Các bộ cài phần mềm đã tải xong của Homebrew — không ảnh hưởng phần mềm đang chạy"),
            ("\(home)/.cache/yarn", "Bộ cài tạm của Yarn", "Gói lưu đệm của trình quản lý Yarn — tự tải lại khi cần"),
            ("\(home)/Library/Caches/Yarn", "Bộ cài tạm của Yarn (Library)", "Gói lưu đệm của trình quản lý Yarn — tự tải lại khi cần"),
            ("\(home)/Library/pnpm/store", "Kho lưu đệm pnpm store", "Các gói Node.js lưu đệm của pnpm — tự tải lại khi cần"),
            ("\(home)/.gradle/caches", "Bộ đệm biên dịch Gradle", "Bộ đệm biên dịch Android / Java Gradle — tự tạo lại khi cần"),
            ("\(home)/.cargo/registry/cache", "Bộ đệm thư viện Rust Cargo", "Các gói thư viện tải tạm của Rust Cargo"),
            ("\(home)/Library/Caches/CocoaPods", "Bộ đệm thư viện CocoaPods", "Kho lưu đệm thư viện CocoaPods — tự tải lại khi cần"),
            ("\(home)/Library/Caches/org.swift.swiftpm", "Bộ đệm gói Swift (SwiftPM)", "Kho lưu đệm các gói thư viện Swift — tự tải lại khi build"),
            ("\(home)/.cache/huggingface", "Mô hình AI tải về (HuggingFace Cache)", "Trọng số mô hình AI dung lượng lớn lưu trong ~/.cache/huggingface")
        ]

        for entry in knownPkgCaches where path == entry.exactPath && sizeBytes >= 25 * MB {
            let safety: CleanupSafetyLevel = path.hasSuffix("/huggingface") ? .reviewRecommended : .safeRecreate
            return DiskCleanupSuggestion(
                id: path,
                path: path,
                title: entry.label,
                sizeBytes: sizeBytes,
                safety: safety,
                ruleKind: .packageCache,
                reason: entry.detail,
                impactIfDeleted: safety == .safeRecreate
                    ? "Xóa hoàn toàn an toàn — Các phần mềm đã cài vẫn hoạt động bình thường."
                    : "Nếu xóa, phần mềm AI sẽ cần tải lại mô hình từ mạng khi bạn chạy lại.",
                lastModified: mtime,
                isDirectory: true,
                requiresAdmin: requiresAdmin
            )
        }

        // 3. Direct children of ~/Library/Caches or /Library/Caches
        if (parentPath == "\(home)/Library/Caches" || parentPath == "/Library/Caches"), sizeBytes >= 20 * MB {
            if protectedAppleCacheTokens.contains(where: { lowerName.contains($0) }) || lowerName.hasPrefix("com.apple.") {
                return nil
            }
            return DiskCleanupSuggestion(
                id: path,
                path: path,
                title: "Bộ nhớ tạm: \(name)",
                sizeBytes: sizeBytes,
                safety: .safeRecreate,
                ruleKind: .appCaches,
                reason: "File hình ảnh & dữ liệu lưu tạm để tăng tốc ứng dụng.",
                impactIfDeleted: "Xóa hoàn toàn an toàn — Không làm mất tài khoản đăng nhập, cài đặt hay tài liệu của bạn.",
                lastModified: mtime,
                isDirectory: true,
                requiresAdmin: requiresAdmin
            )
        }

        // 4. Direct children of ~/Library/Logs or /Library/Logs
        if (parentPath == "\(home)/Library/Logs" || parentPath == "/Library/Logs"), sizeBytes >= 10 * MB {
            return DiskCleanupSuggestion(
                id: path,
                path: path,
                title: "Nhật ký hệ thống cũ: \(name)",
                sizeBytes: sizeBytes,
                safety: .safeRecreate,
                ruleKind: .logsAndCrash,
                reason: "Tệp văn bản ghi lịch sử hoạt động & báo cáo lỗi cũ của phần mềm.",
                impactIfDeleted: "Xóa hoàn toàn an toàn — Giải phóng bộ nhớ ngay lập tức.",
                lastModified: mtime,
                isDirectory: true,
                requiresAdmin: requiresAdmin
            )
        }

        // 5. iOS MobileSync Backups & Docker/OrbStack VM disks
        if path == "\(home)/Library/Application Support/MobileSync/Backup", sizeBytes >= 150 * MB {
            return DiskCleanupSuggestion(
                id: path,
                path: path,
                title: "Bản sao lưu iPhone / iPad cũ trên máy",
                sizeBytes: sizeBytes,
                safety: .reviewRecommended,
                ruleKind: .iosBackupsAndVMs,
                reason: "Bản sao lưu thiết bị iOS lưu trên ổ cứng máy Mac.",
                impactIfDeleted: "Chỉ xóa nếu điện thoại của bạn đã sao lưu lên iCloud hoặc không cần bản sao lưu cũ này.",
                lastModified: mtime,
                isDirectory: true,
                requiresAdmin: requiresAdmin
            )
        }

        if (path == "\(home)/Library/Containers/com.docker.docker" || path == "\(home)/.orbstack"),
           sizeBytes >= 1024 * MB {
            return DiskCleanupSuggestion(
                id: path,
                path: path,
                title: lowerName.contains("orbstack") ? "Dữ liệu máy ảo OrbStack" : "Dữ liệu máy ảo Docker Desktop",
                sizeBytes: sizeBytes,
                safety: .reviewRecommended,
                ruleKind: .iosBackupsAndVMs,
                reason: "Chứa các máy ảo & container của Docker / OrbStack.",
                impactIfDeleted: "Kiểm tra kỹ trước khi xóa — Xóa mục này sẽ xóa toàn bộ container bên trong.",
                lastModified: mtime,
                isDirectory: true,
                requiresAdmin: requiresAdmin
            )
        }

        // 6. Project Build / Distribution / Dependency Artifacts outside System & Library folders
        let isOutsideLibrary = !path.contains("/Library/") && !path.hasPrefix("/System") && !path.hasPrefix("/Applications")
        if isOutsideLibrary {
            let projectName = (parentPath as NSString).lastPathComponent
            let pureBuildDirs: Set<String> = [".build", ".next", ".nuxt", ".turbo", ".parcel-cache", ".pytest_cache", "__pycache__", "DerivedData"]
            if pureBuildDirs.contains(name), sizeBytes >= 2 * MB {
                return DiskCleanupSuggestion(
                    id: path,
                    path: path,
                    title: "File nháp đóng gói (\(projectName)/\(name))",
                    sizeBytes: sizeBytes,
                    safety: .safeRecreate,
                    ruleKind: .developerBuild,
                    reason: "Tệp trung gian sinh ra tự động khi biên dịch ứng dụng '\(projectName)' — chiếm nhiều dung lượng nhưng không chứa mã nguồn.",
                    impactIfDeleted: "Xóa hoàn toàn an toàn — Mã nguồn, tài liệu và ứng dụng đã cài đều giữ nguyên 100%.",
                    lastModified: mtime,
                    isDirectory: true,
                    requiresAdmin: requiresAdmin
                )
            }

            // Distribution / release output folders (e.g. BuildApp/dist, AppSweep/dist, BarFlow/dist)
            let distDirs: Set<String> = ["dist", "release", "releases", "artifacts", "build-output"]
            if distDirs.contains(lowerName), sizeBytes >= 2 * MB, directoryHasProjectOrBuildMarkers(parentPath) || projectName.lowercased().contains("build") {
                return DiskCleanupSuggestion(
                    id: path,
                    path: path,
                    title: "Thư mục xuất bộ cài (\(projectName)/\(name))",
                    sizeBytes: sizeBytes,
                    safety: .safeRecreate,
                    ruleKind: .developerBuild,
                    reason: "Chứa các tệp bộ cài (.dmg, .zip, .app) đã đóng gói xong trong thư mục '\(projectName)'.",
                    impactIfDeleted: "Xóa hoàn toàn an toàn — Chỉ dọn các tệp bộ cài xuất ra, không ảnh hưởng mã nguồn hay ứng dụng chính.",
                    lastModified: mtime,
                    isDirectory: true,
                    requiresAdmin: requiresAdmin
                )
            }

            if (name == "node_modules" && !path.dropLast(name.count).contains("/node_modules/")) || name == "Pods",
               sizeBytes >= 40 * MB {
                return DiskCleanupSuggestion(
                    id: path,
                    path: path,
                    title: "Thư viện tải về (\(projectName)/\(name))",
                    sizeBytes: sizeBytes,
                    safety: .reviewRecommended,
                    ruleKind: .developerBuild,
                    reason: "Thư viện phụ thuộc tải từ mạng của dự án '\(projectName)'.",
                    impactIfDeleted: "Không làm mất mã nguồn của bạn — Nếu cần làm việc lại với dự án này, chỉ cần chạy lệnh cài lại thư viện.",
                    lastModified: mtime,
                    isDirectory: true,
                    requiresAdmin: requiresAdmin
                )
            }

            if name == "target", sizeBytes >= 50 * MB {
                let cargoToml = (parentPath as NSString).appendingPathComponent("Cargo.toml")
                let pomXml = (parentPath as NSString).appendingPathComponent("pom.xml")
                if FileManager.default.fileExists(atPath: cargoToml) || FileManager.default.fileExists(atPath: pomXml) {
                    return DiskCleanupSuggestion(
                        id: path,
                        path: path,
                        title: "File nháp đóng gói (\(projectName)/target)",
                        sizeBytes: sizeBytes,
                        safety: .safeRecreate,
                        ruleKind: .developerBuild,
                        reason: "Tệp trung gian sinh ra khi biên dịch dự án '\(projectName)'.",
                        impactIfDeleted: "Xóa hoàn toàn an toàn — Mã nguồn gốc được giữ nguyên 100%.",
                        lastModified: mtime,
                        isDirectory: true,
                        requiresAdmin: requiresAdmin
                    )
                }
            }
        }

        return nil
    }

    private static func evaluateFileSuggestion(
        path: String,
        name: String,
        sizeBytes: Int64,
        mtime: Date?
    ) -> DiskCleanupSuggestion? {
        let MB: Int64 = 1_048_576
        guard sizeBytes >= 3 * MB else { return nil }
        guard !isProtectedFromCleanup(path) else { return nil }

        let home = NSHomeDirectory()
        if path.hasPrefix(home + "/.Trash/") { return nil }

        let ext = (name as NSString).pathExtension.lowercased()
        let parentPath = (path as NSString).deletingLastPathComponent
        let parentName = (parentPath as NSString).lastPathComponent
        let inDownloads = path.hasPrefix(home + "/Downloads/")
        let requiresAdmin = DiskSizeCalculator.requiresAdminToModify(path: path)

        // 1. Disk images & installer packages (.dmg, .pkg, .iso, .ipsw) in Downloads or build folders
        let installerExts: Set<String> = ["dmg", "pkg", "iso", "ipsw", "xip"]
        if installerExts.contains(ext), (inDownloads || !path.contains("/Library/")), sizeBytes >= 3 * MB {
            let isInBuildOrDist = parentName.lowercased() == "dist" || parentName.lowercased().contains("build") || directoryHasProjectOrBuildMarkers(parentPath)
            return DiskCleanupSuggestion(
                id: path,
                path: path,
                title: isInBuildOrDist ? "Bộ cài đóng gói: \(name)" : "Bộ cài đặt: \(name)",
                sizeBytes: sizeBytes,
                safety: isInBuildOrDist ? .safeRecreate : .reviewRecommended,
                ruleKind: .oldInstallers,
                reason: inDownloads
                    ? "Tệp bộ cài đặt ứng dụng trong thư mục Tải về (Downloads)."
                    : "Tệp bộ cài đặt (.dmg / .pkg) nằm trong thư mục '\(parentName)'.",
                impactIfDeleted: "Xóa bộ cài này hoàn toàn không làm mất ứng dụng bạn đã cài đặt trong máy.",
                lastModified: mtime,
                isDirectory: false,
                requiresAdmin: requiresAdmin
            )
        }

        // 2. Compressed archives (.zip, .tar.gz) inside dist/build folders or large old archives in ~/Downloads
        let archiveExts: Set<String> = ["zip", "gz", "tgz", "bz2", "xz", "7z", "rar", "tar"]
        if archiveExts.contains(ext) {
            let lowerName = name.lowercased()
            let isInDistOrRelease = ["dist", "release", "releases", "artifacts"].contains(parentName.lowercased())
                || (lowerName.contains("-macos.zip") || lowerName.contains("installer"))
            if isInDistOrRelease && !path.contains("/Library/") && sizeBytes >= 3 * MB {
                return DiskCleanupSuggestion(
                    id: path,
                    path: path,
                    title: "Gói nén phát hành: \(name)",
                    sizeBytes: sizeBytes,
                    safety: .safeRecreate,
                    ruleKind: .oldInstallers,
                    reason: "Bản nén .zip tạo ra khi đóng gói phần mềm trong '\(parentName)'.",
                    impactIfDeleted: "Xóa hoàn toàn an toàn — Không làm mất mã nguồn hay ứng dụng chính.",
                    lastModified: mtime,
                    isDirectory: false,
                    requiresAdmin: requiresAdmin
                )
            }

            if inDownloads && sizeBytes >= 50 * MB {
                let ageDays = mtime.map { Calendar.current.dateComponents([.day], from: $0, to: Date()).day ?? 0 } ?? 0
                if ageDays >= 7 {
                    return DiskCleanupSuggestion(
                        id: path,
                        path: path,
                        title: "File nén cũ: \(name)",
                        sizeBytes: sizeBytes,
                        safety: .reviewRecommended,
                        ruleKind: .oldInstallers,
                        reason: "Tệp nén tải về từ \(ageDays) ngày trước trong thư mục Downloads.",
                        impactIfDeleted: "Nếu bạn đã giải nén tệp này rồi, xóa file .zip gốc sẽ giúp tiết kiệm gấp đôi dung lượng.",
                        lastModified: mtime,
                        isDirectory: false,
                        requiresAdmin: requiresAdmin
                    )
                }
            }
        }

        // 3. Large standalone log files anywhere
        if (ext == "log" || ext == "out" || ext == "err"), sizeBytes >= 15 * MB {
            return DiskCleanupSuggestion(
                id: path,
                path: path,
                title: "Tệp nhật ký: \(name)",
                sizeBytes: sizeBytes,
                safety: .safeRecreate,
                ruleKind: .logsAndCrash,
                reason: "Tệp văn bản ghi nhật ký hoạt động phình to.",
                impactIfDeleted: "Xóa hoàn toàn an toàn — Không ảnh hưởng dữ liệu cá nhân.",
                lastModified: mtime,
                isDirectory: false,
                requiresAdmin: requiresAdmin
            )
        }

        // 4. Very large standalone files (>= 500 MB) outside Library internal databases
        if sizeBytes >= 500 * MB && !path.contains("/Library/Containers/com.docker.docker/") && !path.contains("/.orbstack/") {
            return DiskCleanupSuggestion(
                id: path,
                path: path,
                title: name,
                sizeBytes: sizeBytes,
                safety: .reviewRecommended,
                ruleKind: .largeFiles,
                reason: "Tệp dung lượng rất lớn (trên 500 MB) nằm trong '\(parentName)'.",
                impactIfDeleted: "Hãy kiểm tra xem bạn còn cần tệp này không trước khi chuyển vào Thùng rác.",
                lastModified: mtime,
                isDirectory: false,
                requiresAdmin: requiresAdmin
            )
        }

        return nil
    }

    /// Prunes nested child suggestions when an ancestor directory is already recommended so bytes are never double-counted.
    private static func deduplicateAndRankSuggestions(_ candidates: [DiskCleanupSuggestion]) -> [DiskCleanupSuggestion] {
        guard !candidates.isEmpty else { return [] }

        let sortedByDepth = candidates.sorted { lhs, rhs in
            if lhs.path.count != rhs.path.count {
                return lhs.path.count < rhs.path.count
            }
            return lhs.sizeBytes > rhs.sizeBytes
        }

        var kept: [DiskCleanupSuggestion] = []
        var keptExact = Set<String>()
        var keptDirPrefixes: [String] = []

        for item in sortedByDepth {
            guard !keptExact.contains(item.path) else { continue }
            let isNestedInKeptDir = keptDirPrefixes.contains { item.path.hasPrefix($0) }
            guard !isNestedInKeptDir else { continue }

            keptExact.insert(item.path)
            if item.isDirectory {
                keptDirPrefixes.append(item.path.hasSuffix("/") ? item.path : (item.path + "/"))
            }
            kept.append(item)
        }

        return kept.sorted { lhs, rhs in
            if lhs.sizeBytes != rhs.sizeBytes {
                return lhs.sizeBytes > rhs.sizeBytes
            }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }
}
