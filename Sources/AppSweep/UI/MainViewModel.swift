import AppKit
import Combine
import Foundation
import SwiftUI

struct BannerToast: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let subtitle: String?
    let isError: Bool
    let restorableRecordID: UUID?
}

@MainActor
final class MainViewModel: ObservableObject {
    static let shared = MainViewModel()

    // Navigation & Global State
    @Published var activeSection: NavigationSection = .apps
    @Published var hasFullDiskAccess: Bool = PermissionService.hasFullDiskAccess()

    // Catalogs
    @Published var installedApps: [TargetBundle] = []
    @Published var addons: [TargetBundle] = []
    @Published var orphans: [OrphanItem] = []
    @Published var historyRecords: [UninstallHistoryRecord] = []

    // Loading Indicators
    @Published var isLoadingCatalog: Bool = false
    @Published var isCalculatingAppSizes: Bool = false
    @Published var isScanningTarget: Bool = false
    @Published var isScanningOrphans: Bool = false
    @Published var isExecutingAction: Bool = false

    // Filtering & Sorting
    @Published var searchQuery: String = ""
    @Published var sortOrder: AppSortOrder = .nameAsc
    @Published var filterScope: AppFilterScope = .all
    @Published var usageFilter: AppUsageFilter = .all
    @Published var addonFilterKind: BundleKind? = nil
    @Published var orphanSearchQuery: String = ""

    // Selected Target & Deep Scan Results
    @Published var selectedTarget: TargetBundle? = nil
    @Published var associatedItems: [AssociatedFileItem] = []

    // Uninstall Options
    @Published var removalMode: RemovalMode = .moveToTrash
    @Published var createZipBackup: Bool = false
    @Published var cleanDockIcon: Bool = true

    // Confirmation Dialogs & Toast
    @Published var showUninstallConfirmation: Bool = false
    @Published var showBatchUninstallConfirmation: Bool = false
    @Published var showOrphanConfirmation: Bool = false
    @Published var bannerToast: BannerToast? = nil

    // Multi-Selection & Batch Uninstall State
    @Published var isMultiSelectMode: Bool = false
    @Published var checkedTargetPaths: Set<String> = []
    @Published var batchItemsByAppPath: [String: [AssociatedFileItem]] = [:]
    @Published var scanningBatchPaths: Set<String> = []
    @Published var expandedBatchAppPaths: Set<String> = []

    // Local UI State (avoids SwiftUIMacros.StateMacro dependency on macOS 27 CommandLineTools)
    @Published var isGlobalDropTargeted: Bool = false
    @Published var isDropZoneTargeted: Bool = false
    @Published var expandedHistoryRecordIDs: Set<UUID> = []

    private var lastAnchorPathForRangeSelect: String? = nil

    private var systemIndex = InstalledSystemIndex(
        apps: [],
        allKnownBundleIDs: [],
        allKnownAppNamesNormalized: [],
        teamIDToAppPaths: [:],
        vendorPrefixToAppPaths: [:]
    )

    private var iconCache: [String: NSImage] = [:]
    private var scanTargetTask: Task<Void, Never>?
    private var sizeCalcTask: Task<Void, Never>?
    private var orphanScanTask: Task<Void, Never>?
    private var toastDismissTask: Task<Void, Never>?
    private var runningPIDsRefreshTimer: Timer?
    @Published private(set) var runningBundleIDs: Set<String> = []
    @Published private(set) var runningBundlePaths: Set<String> = []

    private init() {
        historyRecords = UninstallEngine.loadHistory()
        refreshRunningAppsSnapshot()
        startRunningMonitor()
    }

    // MARK: - Initial Load & Refresh

    func initialLoadIfNeeded() {
        if installedApps.isEmpty && !isLoadingCatalog {
            reloadAllCatalogs()
        }
    }

    func refreshPermissions() {
        hasFullDiskAccess = PermissionService.hasFullDiskAccess()
    }

    func reloadAllCatalogs() {
        refreshPermissions()
        refreshRunningAppsSnapshot()
        historyRecords = UninstallEngine.loadHistory()
        isLoadingCatalog = true
        sizeCalcTask?.cancel()

        Task {
            let (index, scannedAddons) = await Task.detached(priority: .userInitiated) {
                let idx = AppCatalogService.scanInstalledApps()
                let add = AppCatalogService.scanAddons()
                return (idx, add)
            }.value

            self.systemIndex = index
            self.installedApps = index.apps
            self.addons = scannedAddons
            self.isLoadingCatalog = false

            // Auto-select first user app if nothing is selected
            if let current = self.selectedTarget {
                if let updated = index.apps.first(where: { $0.path == current.path })
                    ?? scannedAddons.first(where: { $0.path == current.path }) {
                    self.selectTarget(updated)
                } else if !FileManager.default.fileExists(atPath: current.path) {
                    self.selectedTarget = nil
                    self.associatedItems = []
                }
            } else if let firstApp = index.apps.first(where: { !$0.isSystemProtected }) ?? index.apps.first {
                self.selectTarget(firstApp)
            }

            self.computeBundleSizesInBackground()
        }
    }

    private func computeBundleSizesInBackground() {
        sizeCalcTask?.cancel()
        isCalculatingAppSizes = true
        let appsSnapshot = installedApps
        let addonsSnapshot = addons

        sizeCalcTask = Task {
            for bundle in appsSnapshot {
                if Task.isCancelled { break }
                let path = bundle.path
                let bytes = await Task.detached(priority: .utility) {
                    DiskSizeCalculator.allocatedSize(at: URL(fileURLWithPath: path))
                }.value
                if Task.isCancelled { break }
                if let idx = self.installedApps.firstIndex(where: { $0.path == path }) {
                    self.installedApps[idx].bundleSizeBytes = bytes
                    if self.selectedTarget?.path == path {
                        self.selectedTarget?.bundleSizeBytes = bytes
                    }
                }
            }

            for addon in addonsSnapshot {
                if Task.isCancelled { break }
                let path = addon.path
                let bytes = await Task.detached(priority: .utility) {
                    DiskSizeCalculator.allocatedSize(at: URL(fileURLWithPath: path))
                }.value
                if Task.isCancelled { break }
                if let idx = self.addons.firstIndex(where: { $0.path == path }) {
                    self.addons[idx].bundleSizeBytes = bytes
                    if self.selectedTarget?.path == path {
                        self.selectedTarget?.bundleSizeBytes = bytes
                    }
                }
            }

            if !Task.isCancelled {
                self.isCalculatingAppSizes = false
            }
        }
    }

    // MARK: - Running Apps Live Monitor

    private func startRunningMonitor() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshRunningAppsSnapshot() }
        }
        nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshRunningAppsSnapshot() }
        }
    }

    func refreshRunningAppsSnapshot() {
        let apps = NSWorkspace.shared.runningApplications
        runningBundleIDs = Set(apps.compactMap { $0.bundleIdentifier?.lowercased() })
        runningBundlePaths = Set(apps.compactMap { $0.bundleURL?.standardizedFileURL.path })
    }

    func isRunning(_ bundle: TargetBundle) -> Bool {
        let bid = bundle.bundleIdentifier.lowercased()
        if !bid.isEmpty && runningBundleIDs.contains(bid) { return true }
        if runningBundlePaths.contains(bundle.path) { return true }
        return false
    }

    // MARK: - Icon Cache

    func icon(for path: String) -> NSImage {
        if let cached = iconCache[path] {
            return cached
        }
        let img = NSWorkspace.shared.icon(forFile: path)
        img.size = NSSize(width: 64, height: 64)
        iconCache[path] = img
        return img
    }

    // MARK: - Filtered & Sorted Collections

    func usageLevel(for app: TargetBundle, now: Date = Date()) -> AppUsageLevel {
        app.usageLevel(isRunning: isRunning(app), now: now)
    }

    func matchesUsageFilter(_ app: TargetBundle, filter: AppUsageFilter, now: Date = Date()) -> Bool {
        let level = usageLevel(for: app, now: now)
        switch filter {
        case .all:
            return true
        case .suggestedCleanup:
            if app.isSystemProtected { return false }
            return level == .neverUsed || level == .dormant
        case .neverUsed:
            return level == .neverUsed
        case .dormant90Days:
            return level == .dormant
        case .rarelyUsed:
            return level == .rarelyUsed
        case .frequentlyUsed:
            return level == .frequent
        }
    }

    private func appsMatchingScopeAndSearch() -> [TargetBundle] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return installedApps.filter { app in
            switch filterScope {
            case .all:
                break
            case .userApps:
                if app.isSystemProtected || app.bundleIdentifier.lowercased().hasPrefix("com.apple.") {
                    return false
                }
            case .running:
                if !isRunning(app) { return false }
            case .large:
                if (app.bundleSizeBytes ?? 0) < 200 * 1024 * 1024 { return false }
            }

            guard !q.isEmpty else { return true }
            return app.name.lowercased().contains(q)
                || app.bundleIdentifier.lowercased().contains(q)
                || app.path.lowercased().contains(q)
        }
    }

    func countForUsageFilter(_ filter: AppUsageFilter) -> Int {
        let now = Date()
        return appsMatchingScopeAndSearch().filter { matchesUsageFilter($0, filter: filter, now: now) }.count
    }

    var filteredAppsTotalBytes: Int64 {
        filteredApps.reduce(Int64(0)) { $0 + ($1.bundleSizeBytes ?? 0) }
    }

    var filteredApps: [TargetBundle] {
        let now = Date()
        var list = appsMatchingScopeAndSearch().filter {
            matchesUsageFilter($0, filter: usageFilter, now: now)
        }

        switch sortOrder {
        case .nameAsc:
            list.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        case .leastUsedFirst:
            list.sort { lhs, rhs in
                let lhsRun = isRunning(lhs)
                let rhsRun = isRunning(rhs)
                if lhsRun != rhsRun { return !lhsRun } // Running apps sink to bottom

                let lhsDate = lhs.lastUsedDate
                let rhsDate = rhs.lastUsedDate
                switch (lhsDate, rhsDate) {
                case (nil, nil):
                    // Among never-opened apps, put largest bundle size first!
                    let lSize = lhs.bundleSizeBytes ?? 0
                    let rSize = rhs.bundleSizeBytes ?? 0
                    if lSize != rSize { return lSize > rSize }
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                case (nil, _?):
                    return true // Never opened comes first
                case (_?, nil):
                    return false
                case let (l?, r?):
                    if abs(l.timeIntervalSince(r)) > 3600 {
                        return l < r // Older lastUsedDate comes first
                    }
                    if lhs.useCount != rhs.useCount {
                        return lhs.useCount < rhs.useCount
                    }
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
            }

        case .mostUsedFirst:
            list.sort { lhs, rhs in
                if lhs.useCount != rhs.useCount {
                    return lhs.useCount > rhs.useCount
                }
                let lhsRun = isRunning(lhs)
                let rhsRun = isRunning(rhs)
                if lhsRun != rhsRun { return lhsRun }
                return (lhs.lastUsedDate ?? .distantPast) > (rhs.lastUsedDate ?? .distantPast)
            }

        case .sizeDesc:
            list.sort { ($0.bundleSizeBytes ?? -1) > ($1.bundleSizeBytes ?? -1) }

        case .vendorAsc:
            list.sort { $0.bundleIdentifier.localizedCaseInsensitiveCompare($1.bundleIdentifier) == .orderedAscending }
        }

        return list
    }

    var filteredAddons: [TargetBundle] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return addons.filter { item in
            if let kind = addonFilterKind, item.kind != kind {
                return false
            }
            guard !q.isEmpty else { return true }
            return item.name.lowercased().contains(q)
                || item.bundleIdentifier.lowercased().contains(q)
                || item.kind.rawValue.lowercased().contains(q)
        }
    }

    var filteredOrphans: [OrphanItem] {
        let q = orphanSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return orphans }
        return orphans.filter {
            $0.name.lowercased().contains(q)
            || $0.inferredIdentifier.lowercased().contains(q)
            || $0.path.lowercased().contains(q)
        }
    }

    // MARK: - Deep Scan Target Selection

    func selectTarget(_ target: TargetBundle) {
        selectedTarget = target
        scanTargetTask?.cancel()
        isScanningTarget = true
        associatedItems = []

        let indexSnapshot = systemIndex
        scanTargetTask = Task {
            let items = await Task.detached(priority: .userInitiated) {
                DeepFileScanner.scanAssociatedFiles(for: target, systemIndex: indexSnapshot)
            }.value

            guard !Task.isCancelled, self.selectedTarget?.path == target.path else { return }
            self.associatedItems = items
            self.isScanningTarget = false

            // Update bundle size if discovered from primary item
            if let appItem = items.first(where: { $0.path == target.path }) {
                if let idx = self.installedApps.firstIndex(where: { $0.path == target.path }) {
                    self.installedApps[idx].bundleSizeBytes = appItem.sizeBytes
                }
                if let idx = self.addons.firstIndex(where: { $0.path == target.path }) {
                    self.addons[idx].bundleSizeBytes = appItem.sizeBytes
                }
                self.selectedTarget?.bundleSizeBytes = appItem.sizeBytes
            }
        }
    }

    func rescanSelectedTarget() {
        if let target = selectedTarget {
            selectTarget(target)
        }
    }

    // MARK: - Drag & Drop / External File Picker Handling

    @discardableResult
    func handleDroppedURLs(_ urls: [URL]) -> Bool {
        var validBundles: [TargetBundle] = []
        for rawURL in urls {
            let stdURL = rawURL.standardizedFileURL
            if let bundle = AppCatalogService.inspectBundle(at: stdURL) {
                validBundles.append(bundle)
                if bundle.kind == .application {
                    if !installedApps.contains(where: { $0.path == bundle.path }) {
                        installedApps.insert(bundle, at: 0)
                    }
                } else {
                    if !addons.contains(where: { $0.path == bundle.path }) {
                        addons.insert(bundle, at: 0)
                    }
                }
            }
        }

        guard !validBundles.isEmpty else {
            showToast(
                title: "Không hỗ trợ định dạng này",
                subtitle: "Vui lòng thả gói ứng dụng (.app) hoặc tiện ích (.prefPane, .saver, .qlgenerator, .plugin, .vst3).",
                isError: true
            )
            return false
        }

        if validBundles.count == 1, let single = validBundles.first {
            exitMultiSelectMode()
            activeSection = (single.kind == .application) ? .apps : .addons
            selectTarget(single)
            showToast(
                title: "Đã phân tích sâu \(single.name)",
                subtitle: "Kiểm tra danh sách các file liên quan bên phải trước khi gỡ cài đặt.",
                isError: false
            )
        } else {
            let preferApps = validBundles.contains(where: { $0.kind == .application })
            activeSection = preferApps ? .apps : .addons
            isMultiSelectMode = true
            for bundle in validBundles where !bundle.isSystemProtected {
                checkedTargetPaths.insert(bundle.path)
                ensureBatchScanned(for: bundle)
            }
            showToast(
                title: "Đã thêm \(validBundles.count) mục vào danh sách gỡ hàng loạt",
                subtitle: "Đang quét toàn bộ file rác liên quan cho tất cả ứng dụng đã chọn.",
                isError: false
            )
        }
        return true
    }

    // MARK: - Selection Helpers & Presets

    var selectedAssociatedItems: [AssociatedFileItem] {
        associatedItems.filter(\.isSelected)
    }

    var totalDiscoveredBytes: Int64 {
        associatedItems.reduce(0) { $0 + $1.sizeBytes }
    }

    var selectedBytesToRemove: Int64 {
        selectedAssociatedItems.reduce(0) { $0 + $1.sizeBytes }
    }

    var selectedRequiresAdmin: Bool {
        selectedAssociatedItems.contains(where: \.requiresAdmin)
    }

    func toggleItemSelection(_ itemID: String) {
        guard let idx = associatedItems.firstIndex(where: { $0.id == itemID }) else { return }
        if let target = selectedTarget, target.isSystemProtected, associatedItems[idx].path == target.path {
            return
        }
        associatedItems[idx].isSelected.toggle()
    }

    func setCategorySelection(_ category: FileCategory, selected: Bool) {
        for idx in associatedItems.indices where associatedItems[idx].category == category {
            if let target = selectedTarget, target.isSystemProtected, associatedItems[idx].path == target.path {
                continue
            }
            associatedItems[idx].isSelected = selected
        }
    }

    /// Selects everything safe for complete uninstallation.
    func applyPresetCompleteUninstall() {
        for idx in associatedItems.indices {
            if let target = selectedTarget, target.isSystemProtected, associatedItems[idx].path == target.path {
                associatedItems[idx].isSelected = false
            } else {
                associatedItems[idx].isSelected = (associatedItems[idx].confidence != .sharedVendor)
            }
        }
    }

    /// Keeps the .app bundle intact and selects all user data, prefs, caches & containers (Factory Reset App!).
    func applyPresetResetAppDataOnly() {
        for idx in associatedItems.indices {
            let cat = associatedItems[idx].category
            if cat == .appBundle || cat == .addonBundle || cat == .receiptsAndConfig {
                associatedItems[idx].isSelected = false
            } else {
                associatedItems[idx].isSelected = (associatedItems[idx].confidence != .sharedVendor)
            }
        }
    }

    /// Selects only Caches, Logs & Saved State for safe space reclamation.
    func applyPresetCachesAndLogsOnly() {
        for idx in associatedItems.indices {
            let cat = associatedItems[idx].category
            associatedItems[idx].isSelected = (cat == .caches || cat == .logs || cat == .savedState)
        }
    }

    // MARK: - Execute Uninstall

    func executeSelectedUninstall() {
        guard let target = selectedTarget else { return }
        let itemsSnapshot = associatedItems
        let modeSnapshot = removalMode
        let backupSnapshot = createZipBackup
        let dockSnapshot = cleanDockIcon

        isExecutingAction = true
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try UninstallEngine.performUninstall(
                        target: target,
                        items: itemsSnapshot,
                        mode: modeSnapshot,
                        createZipBackup: backupSnapshot,
                        cleanDockIcon: dockSnapshot
                    )
                }.value

                self.isExecutingAction = false
                self.historyRecords = UninstallEngine.loadHistory()

                let appStillExists = FileManager.default.fileExists(atPath: target.path)
                if !appStillExists {
                    self.installedApps.removeAll { $0.path == target.path }
                    self.addons.removeAll { $0.path == target.path }
                    self.selectedTarget = self.installedApps.first(where: { !$0.isSystemProtected })
                    if let next = self.selectedTarget {
                        self.selectTarget(next)
                    } else {
                        self.associatedItems = []
                    }
                } else {
                    self.selectTarget(target)
                }

                let failNote = result.record.failedPaths.isEmpty
                    ? nil
                    : " (Còn \(result.record.failedPaths.count) mục bị từ chối quyền)"
                let backupNote = result.record.archiveZipPath != nil ? " • Đã lưu bản sao .zip" : ""
                self.showToast(
                    title: "Đã dọn sạch \(result.record.removedCount) mục của \(target.name)",
                    subtitle: "Giải phóng \(ByteFormatter.string(result.record.totalBytesFreed))\(backupNote)\(failNote ?? "")",
                    isError: !result.record.failedPaths.isEmpty,
                    restorableRecordID: result.record.canRestore ? result.record.id : nil
                )
            } catch {
                self.isExecutingAction = false
                self.showToast(
                    title: "Không thể hoàn tất gỡ bỏ",
                    subtitle: error.localizedDescription,
                    isError: true
                )
            }
        }
    }

    // MARK: - Multi-Select & Batch Uninstall

    var activeCheckedTargets: [TargetBundle] {
        let source = (activeSection == .addons) ? addons : installedApps
        return source.filter { checkedTargetPaths.contains($0.path) && !$0.isSystemProtected }
    }

    func isTargetChecked(_ bundle: TargetBundle) -> Bool {
        checkedTargetPaths.contains(bundle.path)
    }

    func toggleMultiSelectMode() {
        if isMultiSelectMode {
            exitMultiSelectMode()
        } else {
            isMultiSelectMode = true
        }
    }

    func exitMultiSelectMode() {
        isMultiSelectMode = false
        checkedTargetPaths.removeAll()
        expandedBatchAppPaths.removeAll()
    }

    func toggleCheckForTarget(_ bundle: TargetBundle) {
        guard !bundle.isSystemProtected else { return }
        if checkedTargetPaths.contains(bundle.path) {
            checkedTargetPaths.remove(bundle.path)
            expandedBatchAppPaths.remove(bundle.path)
            if checkedTargetPaths.isEmpty {
                isMultiSelectMode = false
            }
        } else {
            checkedTargetPaths.insert(bundle.path)
            isMultiSelectMode = true
            ensureBatchScanned(for: bundle)
        }
        lastAnchorPathForRangeSelect = bundle.path
    }

    /// Handles row click with native macOS `⌘ + Click` (toggle multi-select) and `⇧ + Click` (range select).
    func handleTargetRowClick(_ bundle: TargetBundle, in visibleList: [TargetBundle]) {
        let flags = NSEvent.modifierFlags

        if flags.contains(.shift), !bundle.isSystemProtected {
            let anchorPath = lastAnchorPathForRangeSelect ?? selectedTarget?.path
            if let anchor = anchorPath,
               let startIdx = visibleList.firstIndex(where: { $0.path == anchor }),
               let endIdx = visibleList.firstIndex(where: { $0.path == bundle.path }) {
                let lower = min(startIdx, endIdx)
                let upper = max(startIdx, endIdx)
                isMultiSelectMode = true
                for i in lower...upper {
                    let candidate = visibleList[i]
                    if !candidate.isSystemProtected {
                        checkedTargetPaths.insert(candidate.path)
                        ensureBatchScanned(for: candidate)
                    }
                }
                lastAnchorPathForRangeSelect = bundle.path
                return
            }
        }

        if flags.contains(.command), !bundle.isSystemProtected {
            // If transitioning from single selection via Cmd+Click, include the currently focused app too
            if checkedTargetPaths.isEmpty,
               let current = selectedTarget,
               !current.isSystemProtected,
               current.path != bundle.path,
               visibleList.contains(where: { $0.path == current.path }) {
                checkedTargetPaths.insert(current.path)
                ensureBatchScanned(for: current)
            }
            toggleCheckForTarget(bundle)
            return
        }

        if isMultiSelectMode {
            toggleCheckForTarget(bundle)
        } else {
            lastAnchorPathForRangeSelect = bundle.path
            selectTarget(bundle)
        }
    }

    func selectAllVisibleTargets(_ visibleList: [TargetBundle]) {
        let selectable = visibleList.filter { !$0.isSystemProtected }
        guard !selectable.isEmpty else { return }
        isMultiSelectMode = true
        for item in selectable {
            checkedTargetPaths.insert(item.path)
            ensureBatchScanned(for: item)
        }
    }

    func ensureBatchScanned(for bundle: TargetBundle, forceRescan: Bool = false) {
        let path = bundle.path
        if !forceRescan, batchItemsByAppPath[path] != nil || scanningBatchPaths.contains(path) {
            // Reuse single-target scan if we literally just scanned this exact target!
            if batchItemsByAppPath[path] == nil, selectedTarget?.path == path, !isScanningTarget, !associatedItems.isEmpty {
                batchItemsByAppPath[path] = associatedItems
            }
            return
        }
        if !forceRescan, selectedTarget?.path == path, !isScanningTarget, !associatedItems.isEmpty {
            batchItemsByAppPath[path] = associatedItems
            return
        }

        scanningBatchPaths.insert(path)
        let indexSnapshot = systemIndex

        Task {
            let scanned = await Task.detached(priority: .userInitiated) {
                DeepFileScanner.scanAssociatedFiles(for: bundle, systemIndex: indexSnapshot)
            }.value

            self.scanningBatchPaths.remove(path)
            self.batchItemsByAppPath[path] = scanned

            if let primary = scanned.first(where: { $0.path == path }) {
                if let idx = self.installedApps.firstIndex(where: { $0.path == path }) {
                    self.installedApps[idx].bundleSizeBytes = primary.sizeBytes
                }
                if let idx = self.addons.firstIndex(where: { $0.path == path }) {
                    self.addons[idx].bundleSizeBytes = primary.sizeBytes
                }
            }
        }
    }

    func rescanAllCheckedTargets() {
        for bundle in activeCheckedTargets {
            ensureBatchScanned(for: bundle, forceRescan: true)
        }
    }

    func toggleBatchExpand(appPath: String) {
        if expandedBatchAppPaths.contains(appPath) {
            expandedBatchAppPaths.remove(appPath)
        } else {
            expandedBatchAppPaths.insert(appPath)
        }
    }

    func toggleBatchAssociatedItem(appPath: String, itemID: String) {
        guard var list = batchItemsByAppPath[appPath],
              let idx = list.firstIndex(where: { $0.id == itemID }) else { return }
        list[idx].isSelected.toggle()
        batchItemsByAppPath[appPath] = list
    }

    func applyBatchPresetComplete() {
        for bundle in activeCheckedTargets {
            guard var list = batchItemsByAppPath[bundle.path] else { continue }
            for i in list.indices {
                list[i].isSelected = (list[i].confidence != .sharedVendor)
            }
            batchItemsByAppPath[bundle.path] = list
        }
    }

    func applyBatchPresetResetDataOnly() {
        for bundle in activeCheckedTargets {
            guard var list = batchItemsByAppPath[bundle.path] else { continue }
            for i in list.indices {
                let cat = list[i].category
                if cat == .appBundle || cat == .addonBundle || cat == .receiptsAndConfig {
                    list[i].isSelected = false
                } else {
                    list[i].isSelected = (list[i].confidence != .sharedVendor)
                }
            }
            batchItemsByAppPath[bundle.path] = list
        }
    }

    func applyBatchPresetCachesOnly() {
        for bundle in activeCheckedTargets {
            guard var list = batchItemsByAppPath[bundle.path] else { continue }
            for i in list.indices {
                let cat = list[i].category
                list[i].isSelected = (cat == .caches || cat == .logs || cat == .savedState)
            }
            batchItemsByAppPath[bundle.path] = list
        }
    }

    var isScanningAnyCheckedTarget: Bool {
        activeCheckedTargets.contains { scanningBatchPaths.contains($0.path) }
    }

    var batchAllSelectedItemsDeduplicated: [AssociatedFileItem] {
        var seen = Set<String>()
        var result: [AssociatedFileItem] = []
        for bundle in activeCheckedTargets {
            for item in (batchItemsByAppPath[bundle.path] ?? []) where item.isSelected {
                if seen.insert(item.path).inserted {
                    result.append(item)
                }
            }
        }
        return result
    }

    var batchTotalDiscoveredBytes: Int64 {
        var seen = Set<String>()
        var total: Int64 = 0
        for bundle in activeCheckedTargets {
            for item in (batchItemsByAppPath[bundle.path] ?? []) {
                if seen.insert(item.path).inserted {
                    total += item.sizeBytes
                }
            }
        }
        return total
    }

    var batchSelectedBytesToRemove: Int64 {
        batchAllSelectedItemsDeduplicated.reduce(0) { $0 + $1.sizeBytes }
    }

    var batchRequiresAdmin: Bool {
        batchAllSelectedItemsDeduplicated.contains(where: \.requiresAdmin)
    }

    func executeBatchUninstall() {
        let targets = activeCheckedTargets
        guard !targets.isEmpty else { return }

        let payloads: [BatchTargetPayload] = targets.compactMap { target in
            guard let items = batchItemsByAppPath[target.path], items.contains(where: \.isSelected) else {
                return nil
            }
            return BatchTargetPayload(target: target, items: items)
        }
        guard !payloads.isEmpty else { return }

        let modeSnapshot = removalMode
        let backupSnapshot = createZipBackup
        let dockSnapshot = cleanDockIcon

        isExecutingAction = true
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try UninstallEngine.performBatchUninstall(
                        batches: payloads,
                        mode: modeSnapshot,
                        createZipBackup: backupSnapshot,
                        cleanDockIcon: dockSnapshot
                    )
                }.value

                self.isExecutingAction = false
                self.historyRecords = UninstallEngine.loadHistory()

                for target in targets {
                    let stillExists = FileManager.default.fileExists(atPath: target.path)
                    if !stillExists {
                        self.installedApps.removeAll { $0.path == target.path }
                        self.addons.removeAll { $0.path == target.path }
                        self.checkedTargetPaths.remove(target.path)
                        self.batchItemsByAppPath.removeValue(forKey: target.path)
                        self.expandedBatchAppPaths.remove(target.path)
                    } else {
                        self.ensureBatchScanned(for: target, forceRescan: true)
                    }
                }

                if self.checkedTargetPaths.isEmpty {
                    self.isMultiSelectMode = false
                    self.selectedTarget = self.installedApps.first(where: { !$0.isSystemProtected })
                    if let next = self.selectedTarget {
                        self.selectTarget(next)
                    } else {
                        self.associatedItems = []
                    }
                }

                let failNote = result.failedCount > 0 ? " (\(result.failedCount) mục từ chối quyền)" : ""
                self.showToast(
                    title: "Đã gỡ hàng loạt \(result.records.count) ứng dụng (\(result.totalRemovedCount) mục)",
                    subtitle: "Giải phóng tổng cộng \(ByteFormatter.string(result.totalBytesFreed))\(failNote)",
                    isError: result.failedCount > 0,
                    restorableRecordID: result.records.count == 1 && result.records[0].canRestore ? result.records[0].id : nil
                )
            } catch {
                self.isExecutingAction = false
                self.showToast(
                    title: "Không thể hoàn tất gỡ hàng loạt",
                    subtitle: error.localizedDescription,
                    isError: true
                )
            }
        }
    }

    // MARK: - Orphan Scanning & Cleaning

    func scanOrphansNow() {
        orphanScanTask?.cancel()
        isScanningOrphans = true
        orphans = []
        let indexSnapshot = systemIndex

        orphanScanTask = Task {
            let freshIndex: InstalledSystemIndex
            if indexSnapshot.allKnownBundleIDs.isEmpty {
                freshIndex = await Task.detached(priority: .userInitiated) {
                    AppCatalogService.scanInstalledApps()
                }.value
                self.systemIndex = freshIndex
            } else {
                freshIndex = indexSnapshot
            }

            let found = await Task.detached(priority: .userInitiated) {
                OrphanScannerService.scanOrphans(systemIndex: freshIndex)
            }.value

            guard !Task.isCancelled else { return }
            self.orphans = found
            self.isScanningOrphans = false
        }
    }

    func toggleOrphanSelection(_ id: String) {
        if let idx = orphans.firstIndex(where: { $0.id == id }) {
            orphans[idx].isSelected.toggle()
        }
    }

    func setAllOrphansSelection(_ selected: Bool) {
        for idx in orphans.indices {
            orphans[idx].isSelected = selected
        }
    }

    var selectedOrphansCount: Int {
        orphans.filter(\.isSelected).count
    }

    var selectedOrphansBytes: Int64 {
        orphans.filter(\.isSelected).reduce(0) { $0 + $1.sizeBytes }
    }

    func executeOrphanCleanup() {
        let snapshot = orphans
        let modeSnapshot = removalMode
        isExecutingAction = true

        Task {
            do {
                let record = try await Task.detached(priority: .userInitiated) {
                    try UninstallEngine.cleanOrphans(orphans: snapshot, mode: modeSnapshot)
                }.value

                self.isExecutingAction = false
                self.historyRecords = UninstallEngine.loadHistory()
                let removedSet = Set(record.entries.map(\.originalPath))
                self.orphans.removeAll { removedSet.contains($0.path) }

                self.showToast(
                    title: "Đã dọn sạch \(record.removedCount) file rác mồ côi",
                    subtitle: "Giải phóng \(ByteFormatter.string(record.totalBytesFreed))",
                    isError: false,
                    restorableRecordID: record.canRestore ? record.id : nil
                )
            } catch {
                self.isExecutingAction = false
                self.showToast(
                    title: "Lỗi khi dọn file mồ côi",
                    subtitle: error.localizedDescription,
                    isError: true
                )
            }
        }
    }

    // MARK: - Undo / Restore History Record

    func restoreFromHistory(_ recordID: UUID) {
        isExecutingAction = true
        Task {
            do {
                let restored = try await Task.detached(priority: .userInitiated) {
                    try UninstallEngine.restoreUninstallRecord(recordID)
                }.value

                self.isExecutingAction = false
                self.historyRecords = UninstallEngine.loadHistory()
                self.reloadAllCatalogs()
                self.showToast(
                    title: "Đã hoàn tác & khôi phục \(restored.targetName)",
                    subtitle: "Các file đã được đặt trả về đúng thư mục gốc trước khi xóa.",
                    isError: false
                )
            } catch {
                self.isExecutingAction = false
                self.showToast(
                    title: "Không thể khôi phục",
                    subtitle: error.localizedDescription,
                    isError: true
                )
            }
        }
    }

    func clearHistoryLog() {
        UninstallEngine.saveHistory([])
        historyRecords = []
    }

    // MARK: - Finder Helpers & Toast

    func revealInFinder(_ path: String) {
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func showToast(
        title: String,
        subtitle: String? = nil,
        isError: Bool = false,
        restorableRecordID: UUID? = nil
    ) {
        toastDismissTask?.cancel()
        let toast = BannerToast(
            title: title,
            subtitle: subtitle,
            isError: isError,
            restorableRecordID: restorableRecordID
        )
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            bannerToast = toast
        }

        toastDismissTask = Task {
            try? await Task.sleep(nanoseconds: 6_500_000_000)
            guard !Task.isCancelled else { return }
            if self.bannerToast?.id == toast.id {
                withAnimation(.easeOut(duration: 0.25)) {
                    self.bannerToast = nil
                }
            }
        }
    }
}
