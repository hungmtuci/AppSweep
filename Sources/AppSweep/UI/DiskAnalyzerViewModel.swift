import AppKit
import Foundation
import SwiftUI

@MainActor
final class DiskAnalyzerViewModel: ObservableObject {
    @Published var selectedPreset: DiskScanPreset = .home
    @Published var customRootPath: String? = nil
    @Published var activeMode: DiskAnalyzerMode = .mapAndExplorer

    // Scan Progress & State
    @Published private(set) var isScanning: Bool = false
    @Published private(set) var isDrillingDown: Bool = false
    @Published private(set) var scanProgressFraction: Double = 0
    @Published private(set) var scanCurrentPath: String = ""
    @Published private(set) var scannedBytesLive: Int64 = 0
    @Published private(set) var lastElapsedSeconds: Double = 0

    // Volume & Tree Data
    @Published private(set) var volumeMetrics: VolumeSpaceMetrics? = nil
    @Published private(set) var rootNode: DiskSpaceNode? = nil
    @Published private(set) var breadcrumbNodes: [DiskSpaceNode] = []
    @Published var highlightedNodeID: String? = nil

    // Explorer Filtering
    @Published var explorerSearchQuery: String = "" {
        didSet { rebuildCurrentExplorerChildren() }
    }
    @Published private(set) var visibleExplorerChildren: [DiskSpaceNode] = []

    // Smart Cleanup Recommendations & Memoized Derivations
    @Published private(set) var recommendations: [DiskCleanupSuggestion] = []
    @Published var recommendationSafetyFilter: CleanupSafetyFilter = .all {
        didSet { rebuildFilteredRecommendations() }
    }
    @Published var recommendationSearchQuery: String = "" {
        didSet { rebuildFilteredRecommendations() }
    }
    @Published private(set) var filteredRecommendations: [DiskCleanupSuggestion] = []
    @Published private(set) var groupedRecommendations: [(kind: CleanupRuleKind, items: [DiskCleanupSuggestion], totalBytes: Int64)] = []
    @Published private(set) var totalRecommendedBytes: Int64 = 0
    @Published private(set) var safeRecommendedBytes: Int64 = 0
    @Published private(set) var reviewRecommendedBytes: Int64 = 0
    @Published private(set) var cleanablePathPrefixes: [String] = []
    private var suggestionByPath: [String: DiskCleanupSuggestion] = [:]

    // Unified Cleanup Selection (works across both Map Explorer & Recommendations)
    @Published var selectedCleanupPaths: Set<String> = []
    private var manualSelectedNodesByPath: [String: DiskSpaceNode] = [:]

    @Published var showCleanupConfirmation: Bool = false

    private var activeScanTask: Task<Void, Never>?
    private var drillDownTask: Task<Void, Never>?

    var currentNode: DiskSpaceNode? {
        breadcrumbNodes.last ?? rootNode
    }

    var canNavigateUp: Bool {
        breadcrumbNodes.count > 1
    }

    // MARK: - Scan Lifecycle

    func startScanIfNeeded() {
        if rootNode == nil && !isScanning {
            rescanCurrentRoot()
        }
    }

    func selectPreset(_ preset: DiskScanPreset) {
        if preset == .custom {
            chooseCustomDirectoryWithPanel()
            return
        }
        selectedPreset = preset
        rescanCurrentRoot()
    }

    func chooseCustomDirectoryWithPanel() {
        let panel = NSOpenPanel()
        panel.title = "Chọn thư mục hoặc ổ đĩa cần phân tích dung lượng"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = URL(fileURLWithPath: customRootPath ?? NSHomeDirectory())

        if panel.runModal() == .OK, let picked = panel.url {
            scanCustomDirectoryURL(picked)
        }
    }

    func scanCustomDirectoryURL(_ url: URL) {
        let stdPath = url.standardizedFileURL.path
        customRootPath = stdPath
        selectedPreset = .custom
        rescanCurrentRoot()
    }

    func rescanCurrentRoot() {
        activeScanTask?.cancel()
        drillDownTask?.cancel()

        let presetSnapshot = selectedPreset
        let customSnapshot = customRootPath
        let targetForMetrics = customSnapshot ?? presetSnapshot.resolvedRootPath ?? NSHomeDirectory()

        volumeMetrics = DiskSpaceAnalyzerService.queryVolumeMetrics(for: targetForMetrics)
        isScanning = true
        scanProgressFraction = 0.03
        scannedBytesLive = 0
        scanCurrentPath = PathFormatter.prettyPath(targetForMetrics)

        activeScanTask = Task { [weak self] in
            let snapshot = await DiskSpaceAnalyzerService.analyzeRoot(
                preset: presetSnapshot,
                customPath: customSnapshot,
                maxRetainedDepth: 4
            ) { [weak self] prog in
                Task { @MainActor in
                    guard let self, self.isScanning else { return }
                    self.scanProgressFraction = prog.fraction
                    self.scanCurrentPath = prog.currentPath
                    self.scannedBytesLive = prog.scannedBytes
                }
            }

            guard let self, !Task.isCancelled else { return }
            self.isScanning = false

            guard let snapshot else { return }
            self.volumeMetrics = snapshot.volumeMetrics ?? self.volumeMetrics
            self.lastElapsedSeconds = snapshot.elapsedSeconds
            self.rootNode = snapshot.rootNode
            self.breadcrumbNodes = [snapshot.rootNode]
            self.highlightedNodeID = snapshot.rootNode.children.first?.id

            self.recommendations = snapshot.recommendations
            self.selectedCleanupPaths.removeAll()
            self.manualSelectedNodesByPath.removeAll()
            self.rebuildRecommendationCaches()
            self.rebuildCurrentExplorerChildren()
        }
    }

    // MARK: - Breadcrumb & Drill-Down Navigation

    func selectNodeOnMap(_ node: DiskSpaceNode) {
        highlightedNodeID = node.id
    }

    func drillDown(into node: DiskSpaceNode) {
        guard node.canDrillDown else { return }

        // Already inside this node
        if currentNode?.path == node.path { return }

        if !node.children.isEmpty && !node.hasUnexpandedSubtree {
            breadcrumbNodes.append(node)
            explorerSearchQuery = ""
            highlightedNodeID = node.children.first?.id
            rebuildCurrentExplorerChildren()
            return
        }

        // On-demand scan for deep subfolders beyond initial retained depth
        drillDownTask?.cancel()
        isDrillingDown = true
        let targetPath = node.path

        drillDownTask = Task {
            let expanded = await DiskSpaceAnalyzerService.scanSubfolderOnDemand(at: targetPath, maxDepth: 3)
            guard !Task.isCancelled else { return }
            self.isDrillingDown = false

            guard let expanded else { return }
            if var root = self.rootNode {
                Self.replaceSubtree(in: &root, targetPath: targetPath, with: expanded)
                self.rootNode = root
                self.refreshBreadcrumbsFromRoot()
            }
            self.breadcrumbNodes.append(expanded)
            self.explorerSearchQuery = ""
            self.highlightedNodeID = expanded.children.first?.id
            self.rebuildCurrentExplorerChildren()
        }
    }

    func navigateUp() {
        guard breadcrumbNodes.count > 1 else { return }
        let exited = breadcrumbNodes.removeLast()
        explorerSearchQuery = ""
        highlightedNodeID = exited.id
        rebuildCurrentExplorerChildren()
    }

    func navigateToBreadcrumb(at index: Int) {
        guard index >= 0, index < breadcrumbNodes.count else { return }
        if index == breadcrumbNodes.count - 1 { return }
        let nextChild = breadcrumbNodes[index + 1]
        breadcrumbNodes = Array(breadcrumbNodes.prefix(index + 1))
        explorerSearchQuery = ""
        highlightedNodeID = nextChild.id
        rebuildCurrentExplorerChildren()
    }

    /// Switches to the Storage Map tab, drills down to the deepest materialized parent containing `suggestion`, and highlights it.
    func revealSuggestionOnMap(_ suggestion: DiskCleanupSuggestion) {
        guard let root = rootNode else { return }
        activeMode = .mapAndExplorer
        explorerSearchQuery = ""

        var chain: [DiskSpaceNode] = [root]
        var cursor = root
        let targetPath = suggestion.path

        while true {
            if let exactChild = cursor.children.first(where: { $0.path == targetPath }) {
                breadcrumbNodes = chain
                highlightedNodeID = exactChild.id
                rebuildCurrentExplorerChildren()
                return
            }
            let prefixMatch = cursor.children.first { child in
                child.isDirectory && !child.isSyntheticOther && targetPath.hasPrefix(child.path + "/")
            }
            if let nextDir = prefixMatch, !nextDir.children.isEmpty {
                chain.append(nextDir)
                cursor = nextDir
            } else {
                breadcrumbNodes = chain
                highlightedNodeID = prefixMatch?.id ?? cursor.children.first?.id
                rebuildCurrentExplorerChildren()
                return
            }
        }
    }

    // MARK: - Derived State Memoization

    func suggestion(forPath path: String) -> DiskCleanupSuggestion? {
        suggestionByPath[path]
    }

    func hasCleanableDescendant(for node: DiskSpaceNode) -> Bool {
        guard !node.isSyntheticOther else { return false }
        if suggestionByPath[node.path] != nil { return true }
        guard node.isDirectory else { return false }
        let prefix = node.path.hasSuffix("/") ? node.path : (node.path + "/")
        return cleanablePathPrefixes.contains { $0.hasPrefix(prefix) }
    }

    private func rebuildCurrentExplorerChildren() {
        guard let current = currentNode else {
            visibleExplorerChildren = []
            return
        }
        let q = explorerSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            visibleExplorerChildren = current.children
            return
        }
        visibleExplorerChildren = current.children.filter {
            $0.name.localizedCaseInsensitiveContains(q) || $0.path.localizedCaseInsensitiveContains(q)
        }
    }

    private func rebuildRecommendationCaches() {
        var dict: [String: DiskCleanupSuggestion] = [:]
        dict.reserveCapacity(recommendations.count)
        var total: Int64 = 0
        var safe: Int64 = 0
        var review: Int64 = 0

        for rec in recommendations {
            dict[rec.path] = rec
            total += rec.sizeBytes
            if rec.safety == .safeRecreate {
                safe += rec.sizeBytes
            } else {
                review += rec.sizeBytes
            }
        }

        suggestionByPath = dict
        cleanablePathPrefixes = recommendations.map(\.path)
        totalRecommendedBytes = total
        safeRecommendedBytes = safe
        reviewRecommendedBytes = review
        rebuildFilteredRecommendations()
    }

    private func rebuildFilteredRecommendations() {
        let q = recommendationSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasQuery = !q.isEmpty

        let filtered = recommendations.filter { item in
            switch recommendationSafetyFilter {
            case .all: break
            case .safeOnly:
                if item.safety != .safeRecreate { return false }
            case .reviewOnly:
                if item.safety != .reviewRecommended { return false }
            }
            guard hasQuery else { return true }
            return item.title.localizedCaseInsensitiveContains(q)
                || item.path.localizedCaseInsensitiveContains(q)
                || item.reason.localizedCaseInsensitiveContains(q)
        }

        filteredRecommendations = filtered

        var byKind: [CleanupRuleKind: [DiskCleanupSuggestion]] = [:]
        for rec in filtered {
            byKind[rec.ruleKind, default: []].append(rec)
        }

        groupedRecommendations = byKind.keys
            .sorted { $0.sortOrder < $1.sortOrder }
            .compactMap { kind in
                guard let list = byKind[kind], !list.isEmpty else { return nil }
                let sum = list.reduce(Int64(0)) { $0 + $1.sizeBytes }
                return (kind: kind, items: list, totalBytes: sum)
            }
    }

    // MARK: - Unified Cleanup Selection

    func isPathSelectedForCleanup(_ path: String) -> Bool {
        selectedCleanupPaths.contains(path)
    }

    func toggleNodeCleanupSelection(_ node: DiskSpaceNode) {
        guard !node.isProtected && !node.isSyntheticOther else { return }
        if selectedCleanupPaths.contains(node.path) {
            selectedCleanupPaths.remove(node.path)
            manualSelectedNodesByPath.removeValue(forKey: node.path)
        } else {
            selectedCleanupPaths.insert(node.path)
            if suggestionByPath[node.path] == nil {
                manualSelectedNodesByPath[node.path] = node
            }
        }
    }

    func toggleSuggestionSelection(_ suggestion: DiskCleanupSuggestion) {
        if selectedCleanupPaths.contains(suggestion.path) {
            selectedCleanupPaths.remove(suggestion.path)
        } else {
            selectedCleanupPaths.insert(suggestion.path)
        }
    }

    func setCategorySelection(_ kind: CleanupRuleKind, selected: Bool) {
        for rec in filteredRecommendations where rec.ruleKind == kind {
            if selected {
                selectedCleanupPaths.insert(rec.path)
            } else {
                selectedCleanupPaths.remove(rec.path)
            }
        }
    }

    func selectSafeRecommendations() {
        for rec in recommendations where rec.safety == .safeRecreate {
            selectedCleanupPaths.insert(rec.path)
        }
    }

    func selectAllFilteredRecommendations() {
        for rec in filteredRecommendations {
            selectedCleanupPaths.insert(rec.path)
        }
    }

    func clearCleanupSelection() {
        selectedCleanupPaths.removeAll()
        manualSelectedNodesByPath.removeAll()
    }

    var resolvedSelectedCleanupItems: [DiskCleanupSuggestion] {
        guard !selectedCleanupPaths.isEmpty else { return [] }

        var raw: [DiskCleanupSuggestion] = []
        raw.reserveCapacity(selectedCleanupPaths.count)

        for path in selectedCleanupPaths {
            if let rec = suggestionByPath[path] {
                raw.append(rec)
            } else if let manual = manualSelectedNodesByPath[path] {
                raw.append(DiskCleanupSuggestion(
                    id: manual.path,
                    path: manual.path,
                    title: manual.name,
                    sizeBytes: manual.sizeBytes,
                    safety: .reviewRecommended,
                    ruleKind: manual.isDirectory ? .developerBuild : .largeFiles,
                    reason: "Được chọn thủ công từ sơ đồ dung lượng thư mục",
                    lastModified: manual.modifiedDate,
                    isDirectory: manual.isDirectory,
                    requiresAdmin: manual.requiresAdmin
                ))
            }
        }

        // Prune nested selections so total byte display never double-counts parent + child
        let sorted = raw.sorted { $0.path.count < $1.path.count }
        var deduped: [DiskCleanupSuggestion] = []
        var dirPrefixes: [String] = []
        for item in sorted {
            if dirPrefixes.contains(where: { item.path.hasPrefix($0) }) { continue }
            if item.isDirectory {
                dirPrefixes.append(item.path.hasSuffix("/") ? item.path : (item.path + "/"))
            }
            deduped.append(item)
        }
        return deduped
    }

    var selectedCleanupCount: Int {
        resolvedSelectedCleanupItems.count
    }

    var selectedCleanupBytes: Int64 {
        resolvedSelectedCleanupItems.reduce(0) { $0 + $1.sizeBytes }
    }

    var selectedCleanupRequiresAdmin: Bool {
        resolvedSelectedCleanupItems.contains(where: \.requiresAdmin)
    }

    // MARK: - Cleanup Execution & Instant Tree Surgical Update

    func executeCleanup(mainViewModel: MainViewModel) {
        let itemsToClean = resolvedSelectedCleanupItems
        guard !itemsToClean.isEmpty else { return }

        let modeSnapshot = mainViewModel.removalMode
        let backupSnapshot = mainViewModel.createZipBackup

        mainViewModel.isExecutingAction = true

        Task {
            do {
                let record = try await Task.detached(priority: .userInitiated) {
                    try UninstallEngine.cleanDiskAnalysisItems(
                        items: itemsToClean,
                        mode: modeSnapshot,
                        createZipBackup: backupSnapshot
                    )
                }.value

                mainViewModel.isExecutingAction = false
                mainViewModel.historyRecords = UninstallEngine.loadHistory()

                let removedPaths = Set(record.entries.map(\.originalPath))
                self.applySurgicalTreeRemoval(removedPaths: removedPaths)
                if let rootPath = self.rootNode?.path {
                    self.volumeMetrics = DiskSpaceAnalyzerService.queryVolumeMetrics(for: rootPath)
                }

                let failNote = record.failedPaths.isEmpty
                    ? ""
                    : " (Còn \(record.failedPaths.count) mục bị từ chối quyền)"
                mainViewModel.showToast(
                    title: "Đã dọn dẹp \(record.removedCount) mục trên ổ đĩa",
                    subtitle: "Giải phóng \(ByteFormatter.string(record.totalBytesFreed))\(failNote)",
                    isError: !record.failedPaths.isEmpty,
                    restorableRecordID: record.canRestore ? record.id : nil
                )
            } catch {
                mainViewModel.isExecutingAction = false
                mainViewModel.showToast(
                    title: "Không thể hoàn tất dọn ổ đĩa",
                    subtitle: error.localizedDescription,
                    isError: true
                )
            }
        }
    }

    private func applySurgicalTreeRemoval(removedPaths: Set<String>) {
        guard !removedPaths.isEmpty else { return }

        for p in removedPaths {
            selectedCleanupPaths.remove(p)
            manualSelectedNodesByPath.removeValue(forKey: p)
        }

        let dirPrefixes = removedPaths.map { $0.hasSuffix("/") ? $0 : ($0 + "/") }
        recommendations.removeAll { rec in
            removedPaths.contains(rec.path) || dirPrefixes.contains(where: { rec.path.hasPrefix($0) })
        }
        rebuildRecommendationCaches()

        if var root = rootNode {
            _ = Self.pruneRemovedNodes(in: &root, removedPaths: removedPaths)
            rootNode = root
            refreshBreadcrumbsFromRoot()
            rebuildCurrentExplorerChildren()
        }
    }

    private func refreshBreadcrumbsFromRoot() {
        guard let root = rootNode else {
            breadcrumbNodes = []
            return
        }
        let previousPaths = breadcrumbNodes.map(\.path)
        var rebuilt: [DiskSpaceNode] = [root]
        var cursor = root

        for path in previousPaths.dropFirst() {
            if let match = cursor.children.first(where: { $0.path == path }) {
                rebuilt.append(match)
                cursor = match
            } else {
                break
            }
        }
        breadcrumbNodes = rebuilt
        if let hid = highlightedNodeID,
           !(currentNode?.children.contains(where: { $0.id == hid }) ?? false) {
            highlightedNodeID = currentNode?.children.first?.id
        }
    }

    // MARK: - Tree Mutation Helpers

    private static func replaceSubtree(in node: inout DiskSpaceNode, targetPath: String, with replacement: DiskSpaceNode) {
        if node.path == targetPath {
            node = replacement
            return
        }
        guard targetPath.hasPrefix(node.path == "/" ? "/" : (node.path + "/")) else { return }
        for i in node.children.indices {
            if node.children[i].path == targetPath {
                node.children[i] = replacement
                return
            } else if node.children[i].isDirectory && targetPath.hasPrefix(node.children[i].path + "/") {
                replaceSubtree(in: &node.children[i], targetPath: targetPath, with: replacement)
                return
            }
        }
    }

    @discardableResult
    private static func pruneRemovedNodes(in node: inout DiskSpaceNode, removedPaths: Set<String>) -> Int64 {
        var subtractedTotal: Int64 = 0
        var retained: [DiskSpaceNode] = []
        retained.reserveCapacity(node.children.count)

        for var child in node.children {
            if removedPaths.contains(child.path) {
                subtractedTotal += child.sizeBytes
                continue
            }
            if child.isDirectory && !child.isSyntheticOther {
                let childFreed = pruneRemovedNodes(in: &child, removedPaths: removedPaths)
                if childFreed > 0 {
                    subtractedTotal += childFreed
                }
            }
            if child.sizeBytes > 0 {
                retained.append(child)
            }
        }

        if subtractedTotal > 0 {
            retained.sort { $0.sizeBytes > $1.sizeBytes }
            node.children = retained
            node.sizeBytes = max(0, node.sizeBytes - subtractedTotal)
        }
        return subtractedTotal
    }
}
