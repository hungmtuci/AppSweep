import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

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

    // Raw Catalogs
    @Published var installedApps: [TargetBundle] = [] {
        didSet { if !isSuppressingDerivedRebuild { rebuildAppCatalogDerivedState() } }
    }
    @Published var addons: [TargetBundle] = [] {
        didSet { if !isSuppressingDerivedRebuild { rebuildAddonsDerivedState() } }
    }
    @Published var orphans: [OrphanItem] = [] {
        didSet { rebuildOrphansDerivedState() }
    }
    @Published var historyRecords: [UninstallHistoryRecord] = []

    // Memoized Derived Collections (O(1) reads during SwiftUI rendering)
    @Published private(set) var filteredApps: [TargetBundle] = []
    @Published private(set) var filteredAppsTotalBytes: Int64 = 0
    @Published private(set) var usageFilterCounts: [AppUsageFilter: Int] = [:]
    @Published private(set) var filteredAddons: [TargetBundle] = []
    @Published private(set) var filteredOrphans: [OrphanItem] = []

    // Loading Indicators
    @Published var isLoadingCatalog: Bool = false
    @Published var isCalculatingAppSizes: Bool = false
    @Published var isScanningTarget: Bool = false
    @Published var isScanningOrphans: Bool = false
    @Published var isExecutingAction: Bool = false

    // Filtering & Sorting
    @Published var searchQuery: String = "" {
        didSet {
            rebuildAppCatalogDerivedState()
            rebuildAddonsDerivedState()
        }
    }
    @Published var sortOrder: AppSortOrder = .nameAsc {
        didSet { rebuildAppCatalogDerivedState() }
    }
    @Published var filterScope: AppFilterScope = .all {
        didSet { rebuildAppCatalogDerivedState() }
    }
    @Published var usageFilter: AppUsageFilter = .all {
        didSet { rebuildAppCatalogDerivedState() }
    }
    @Published var addonFilterKind: BundleKind? = nil {
        didSet { rebuildAddonsDerivedState() }
    }
    @Published var orphanSearchQuery: String = "" {
        didSet { rebuildOrphansDerivedState() }
    }

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

    private var isSuppressingDerivedRebuild: Bool = false
    private var lastAnchorPathForRangeSelect: String? = nil

    private var systemIndex = InstalledSystemIndex(
        apps: [],
        allKnownBundleIDs: [],
        allKnownAppNamesNormalized: [],
        teamIDToAppPaths: [:],
        vendorPrefixToAppPaths: [:]
    )

    private let iconCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 400
        return cache
    }()

    private static let genericFileIconExtensions: Set<String> = [
        "plist", "bom", "log", "ips", "diag", "crash", "out", "err", "json", "txt", "db", "sqlite", "binarycookies", "sfl2", "sfl3"
    ]

    private var scanTargetTask: Task<Void, Never>?
    private var sizeCalcTask: Task<Void, Never>?
    private var batchScanCoordinatorTask: Task<Void, Never>?
    private var queuedBatchBundles: [String: TargetBundle] = [:]
    private var orphanScanTask: Task<Void, Never>?
    private var toastDismissTask: Task<Void, Never>?

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
        let current = PermissionService.hasFullDiskAccess()
        if hasFullDiskAccess != current {
            hasFullDiskAccess = current
        }
    }

    func reloadAllCatalogs() {
        refreshPermissions()
        refreshRunningAppsSnapshot()
        historyRecords = UninstallEngine.loadHistory()
        isLoadingCatalog = true
        sizeCalcTask?.cancel()

        Task {
            let (index, scannedAddons) = await Task.detached(priority: .userInitiated) {
                async let idx = AppCatalogService.scanInstalledApps()
                async let add = AppCatalogService.scanAddons()
                return await (idx, add)
            }.value

            self.systemIndex = index
            self.isSuppressingDerivedRebuild = true
            self.installedApps = index.apps
            self.addons = scannedAddons
            self.isSuppressingDerivedRebuild = false
            self.rebuildAppCatalogDerivedState()
            self.rebuildAddonsDerivedState()
            self.isLoadingCatalog = false

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

    /// Computes exact physical bundle sizes concurrently (max 6 workers) and flushes UI updates in coalesced batches.
    private func computeBundleSizesInBackground() {
        sizeCalcTask?.cancel()
        isCalculatingAppSizes = true

        let appPaths = installedApps.map(\.path)
        let addonPaths = addons.map(\.path)

        sizeCalcTask = Task {
            await withTaskGroup(of: (path: String, bytes: Int64, isAddon: Bool).self) { group in
                let maxConcurrency = 6
                var workItems: [(path: String, isAddon: Bool)] = []
                workItems.reserveCapacity(appPaths.count + addonPaths.count)
                for p in appPaths { workItems.append((p, false)) }
                for p in addonPaths { workItems.append((p, true)) }

                var nextIndex = 0
                let initialCount = min(maxConcurrency, workItems.count)
                while nextIndex < initialCount {
                    let item = workItems[nextIndex]
                    nextIndex += 1
                    group.addTask(priority: .utility) {
                        let b = DiskSizeCalculator.allocatedSize(atPath: item.path)
                        return (item.path, b, item.isAddon)
                    }
                }

                var pendingAppUpdates: [String: Int64] = [:]
                var pendingAddonUpdates: [String: Int64] = [:]
                var lastFlushTime = CFAbsoluteTimeGetCurrent()

                while let finished = await group.next() {
                    if Task.isCancelled {
                        group.cancelAll()
                        return
                    }

                    if finished.isAddon {
                        pendingAddonUpdates[finished.path] = finished.bytes
                    } else {
                        pendingAppUpdates[finished.path] = finished.bytes
                    }

                    if nextIndex < workItems.count {
                        let nextItem = workItems[nextIndex]
                        nextIndex += 1
                        group.addTask(priority: .utility) {
                            let b = DiskSizeCalculator.allocatedSize(atPath: nextItem.path)
                            return (nextItem.path, b, nextItem.isAddon)
                        }
                    }

                    let now = CFAbsoluteTimeGetCurrent()
                    if (now - lastFlushTime) >= 0.20 {
                        self.applyCoalescedSizeUpdates(appSizes: pendingAppUpdates, addonSizes: pendingAddonUpdates)
                        pendingAppUpdates.removeAll(keepingCapacity: true)
                        pendingAddonUpdates.removeAll(keepingCapacity: true)
                        lastFlushTime = now
                    }
                }

                if !Task.isCancelled && (!pendingAppUpdates.isEmpty || !pendingAddonUpdates.isEmpty) {
                    self.applyCoalescedSizeUpdates(appSizes: pendingAppUpdates, addonSizes: pendingAddonUpdates)
                }
            }

            if !Task.isCancelled {
                self.isCalculatingAppSizes = false
            }
        }
    }

    private func applyCoalescedSizeUpdates(appSizes: [String: Int64], addonSizes: [String: Int64]) {
        isSuppressingDerivedRebuild = true
        var appsChanged = false
        var addonsChanged = false

        if !appSizes.isEmpty {
            var updated = installedApps
            for i in updated.indices {
                if let newBytes = appSizes[updated[i].path], updated[i].bundleSizeBytes != newBytes {
                    updated[i].bundleSizeBytes = newBytes
                    appsChanged = true
                    if selectedTarget?.path == updated[i].path {
                        selectedTarget?.bundleSizeBytes = newBytes
                    }
                }
            }
            if appsChanged {
                installedApps = updated
            }
        }

        if !addonSizes.isEmpty {
            var updatedAddons = addons
            for i in updatedAddons.indices {
                if let newBytes = addonSizes[updatedAddons[i].path], updatedAddons[i].bundleSizeBytes != newBytes {
                    updatedAddons[i].bundleSizeBytes = newBytes
                    addonsChanged = true
                    if selectedTarget?.path == updatedAddons[i].path {
                        selectedTarget?.bundleSizeBytes = newBytes
                    }
                }
            }
            if addonsChanged {
                addons = updatedAddons
            }
        }

        isSuppressingDerivedRebuild = false
        if appsChanged {
            rebuildAppCatalogDerivedState()
        }
        if addonsChanged {
            rebuildAddonsDerivedState()
        }
    }

    // MARK: - Running Apps Live Monitor

    private func startRunningMonitor() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.refreshRunningAppsSnapshot()
                self?.rebuildAppCatalogDerivedState()
            }
        }
        nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.refreshRunningAppsSnapshot()
                self?.rebuildAppCatalogDerivedState()
            }
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
        for child in bundle.childBundleIdentifiers where runningBundleIDs.contains(child.lowercased()) {
            return true
        }
        return false
    }

    // MARK: - Bounded Icon Cache

    func icon(for path: String) -> NSImage {
        let ext = (path as NSString).pathExtension.lowercased()
        let cacheKey: NSString = Self.genericFileIconExtensions.contains(ext)
            ? ("__ext__." + ext) as NSString
            : path as NSString

        if let cached = iconCache.object(forKey: cacheKey) {
            return cached
        }

        let img: NSImage
        if Self.genericFileIconExtensions.contains(ext) {
            let contentType = UTType(filenameExtension: ext) ?? .data
            img = NSWorkspace.shared.icon(for: contentType)
        } else {
            img = NSWorkspace.shared.icon(forFile: path)
        }
        img.size = NSSize(width: 64, height: 64)
        iconCache.setObject(img, forKey: cacheKey)
        return img
    }

    // MARK: - Single-Pass Memoized Filtering & Sorting

    func usageLevel(for app: TargetBundle, now: Date = Date()) -> AppUsageLevel {
        app.usageLevel(isRunning: isRunning(app), now: now)
    }

    func countForUsageFilter(_ filter: AppUsageFilter) -> Int {
        usageFilterCounts[filter] ?? 0
    }

    private func rebuildAppCatalogDerivedState() {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasQuery = !q.isEmpty
        let now = Date()

        // 1. Scope & Search pass + Precompute usage level once per matching app
        var scopedWithLevel: [(app: TargetBundle, level: AppUsageLevel, isRunning: Bool)] = []
        scopedWithLevel.reserveCapacity(installedApps.count)

        var counts: [AppUsageFilter: Int] = [
            .all: 0,
            .suggestedCleanup: 0,
            .neverUsed: 0,
            .dormant90Days: 0,
            .rarelyUsed: 0,
            .frequentlyUsed: 0
        ]

        for app in installedApps {
            let appRunning = isRunning(app)
            switch filterScope {
            case .all:
                break
            case .userApps:
                if app.isSystemProtected || app.bundleIdentifier.lowercased().hasPrefix("com.apple.") {
                    continue
                }
            case .running:
                if !appRunning { continue }
            case .large:
                if (app.bundleSizeBytes ?? 0) < 200 * 1024 * 1024 { continue }
            }

            if hasQuery {
                let matched = app.name.localizedCaseInsensitiveContains(q)
                    || app.bundleIdentifier.localizedCaseInsensitiveContains(q)
                    || app.path.localizedCaseInsensitiveContains(q)
                if !matched { continue }
            }

            let level = app.usageLevel(isRunning: appRunning, now: now)
            scopedWithLevel.append((app, level, appRunning))

            counts[.all, default: 0] += 1
            if !app.isSystemProtected && (level == .neverUsed || level == .dormant) {
                counts[.suggestedCleanup, default: 0] += 1
            }
            switch level {
            case .neverUsed:
                counts[.neverUsed, default: 0] += 1
            case .dormant:
                counts[.dormant90Days, default: 0] += 1
            case .rarelyUsed:
                counts[.rarelyUsed, default: 0] += 1
            case .frequent:
                counts[.frequentlyUsed, default: 0] += 1
            }
        }

        // 2. Apply active usageFilter
        var matching: [(app: TargetBundle, isRunning: Bool)] = []
        matching.reserveCapacity(scopedWithLevel.count)
        for entry in scopedWithLevel {
            let keep: Bool
            switch usageFilter {
            case .all:
                keep = true
            case .suggestedCleanup:
                keep = !entry.app.isSystemProtected && (entry.level == .neverUsed || entry.level == .dormant)
            case .neverUsed:
                keep = (entry.level == .neverUsed)
            case .dormant90Days:
                keep = (entry.level == .dormant)
            case .rarelyUsed:
                keep = (entry.level == .rarelyUsed)
            case .frequentlyUsed:
                keep = (entry.level == .frequent)
            }
            if keep {
                matching.append((entry.app, entry.isRunning))
            }
        }

        // 3. Sort
        switch sortOrder {
        case .nameAsc:
            matching.sort { $0.app.name.localizedCaseInsensitiveCompare($1.app.name) == .orderedAscending }

        case .leastUsedFirst:
            matching.sort { lhs, rhs in
                if lhs.isRunning != rhs.isRunning { return !lhs.isRunning }
                switch (lhs.app.lastUsedDate, rhs.app.lastUsedDate) {
                case (nil, nil):
                    let lSize = lhs.app.bundleSizeBytes ?? 0
                    let rSize = rhs.app.bundleSizeBytes ?? 0
                    if lSize != rSize { return lSize > rSize }
                    return lhs.app.name.localizedCaseInsensitiveCompare(rhs.app.name) == .orderedAscending
                case (nil, _?):
                    return true
                case (_?, nil):
                    return false
                case let (l?, r?):
                    if abs(l.timeIntervalSince(r)) > 3600 {
                        return l < r
                    }
                    if lhs.app.useCount != rhs.app.useCount {
                        return lhs.app.useCount < rhs.app.useCount
                    }
                    return lhs.app.name.localizedCaseInsensitiveCompare(rhs.app.name) == .orderedAscending
                }
            }

        case .mostUsedFirst:
            matching.sort { lhs, rhs in
                if lhs.app.useCount != rhs.app.useCount {
                    return lhs.app.useCount > rhs.app.useCount
                }
                if lhs.isRunning != rhs.isRunning { return lhs.isRunning }
                return (lhs.app.lastUsedDate ?? .distantPast) > (rhs.app.lastUsedDate ?? .distantPast)
            }

        case .sizeDesc:
            matching.sort { ($0.app.bundleSizeBytes ?? -1) > ($1.app.bundleSizeBytes ?? -1) }

        case .vendorAsc:
            matching.sort { $0.app.bundleIdentifier.localizedCaseInsensitiveCompare($1.app.bundleIdentifier) == .orderedAscending }
        }

        let finalApps = matching.map(\.app)
        let sumBytes = finalApps.reduce(Int64(0)) { $0 + ($1.bundleSizeBytes ?? 0) }

        self.usageFilterCounts = counts
        self.filteredApps = finalApps
        self.filteredAppsTotalBytes = sumBytes
    }

    private func rebuildAddonsDerivedState() {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasQuery = !q.isEmpty

        filteredAddons = addons.filter { item in
            if let kind = addonFilterKind, item.kind != kind {
                return false
            }
            guard hasQuery else { return true }
            return item.name.localizedCaseInsensitiveContains(q)
                || item.bundleIdentifier.localizedCaseInsensitiveContains(q)
                || item.kind.rawValue.localizedCaseInsensitiveContains(q)
        }
    }

    private func rebuildOrphansDerivedState() {
        let q = orphanSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            filteredOrphans = orphans
            return
        }
        filteredOrphans = orphans.filter {
            $0.name.localizedCaseInsensitiveContains(q)
            || $0.inferredIdentifier.localizedCaseInsensitiveContains(q)
            || $0.path.localizedCaseInsensitiveContains(q)
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

            if let appItem = items.first(where: { $0.path == target.path }) {
                self.updateSingleBundleSize(path: target.path, bytes: appItem.sizeBytes)
            }
        }
    }

    private func updateSingleBundleSize(path: String, bytes: Int64) {
        if let idx = installedApps.firstIndex(where: { $0.path == path }), installedApps[idx].bundleSizeBytes != bytes {
            installedApps[idx].bundleSizeBytes = bytes
        }
        if let idx = addons.firstIndex(where: { $0.path == path }), addons[idx].bundleSizeBytes != bytes {
            addons[idx].bundleSizeBytes = bytes
        }
        if selectedTarget?.path == path {
            selectedTarget?.bundleSizeBytes = bytes
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
                title: "Đã phân tích \(single.name)",
                subtitle: "Kiểm tra danh sách các tệp liên quan bên phải trước khi gỡ cài đặt.",
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
                title: "Đã thêm \(validBundles.count) mục vào danh sách chọn nhiều",
                subtitle: "Đang quét các tệp liên quan cho ứng dụng đã chọn.",
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
        associatedItems.reduce(0) { $0 + ($1.isSelected ? $1.sizeBytes : 0) }
    }

    var selectedRequiresAdmin: Bool {
        associatedItems.contains { $0.isSelected && $0.requiresAdmin }
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

    func applyPresetCompleteUninstall() {
        for idx in associatedItems.indices {
            if let target = selectedTarget, target.isSystemProtected, associatedItems[idx].path == target.path {
                associatedItems[idx].isSelected = false
            } else {
                associatedItems[idx].isSelected = (associatedItems[idx].confidence != .sharedVendor)
            }
        }
    }

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
                    self.batchItemsByAppPath.removeValue(forKey: target.path)
                    self.selectedTarget = self.filteredApps.first(where: { !$0.isSystemProtected })
                        ?? self.installedApps.first(where: { !$0.isSystemProtected })
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
                let backupNote = result.record.archiveZipPath != nil ? " · Đã lưu bản sao .zip" : ""
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

    // MARK: - Multi-Select & Bounded Batch Scanner

    var activeCheckedTargets: [TargetBundle] {
        guard !checkedTargetPaths.isEmpty else { return [] }
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
        batchScanCoordinatorTask?.cancel()
        batchScanCoordinatorTask = nil
        queuedBatchBundles.removeAll()
        scanningBatchPaths.removeAll()
        isMultiSelectMode = false
        checkedTargetPaths.removeAll()
        expandedBatchAppPaths.removeAll()
    }

    func toggleCheckForTarget(_ bundle: TargetBundle) {
        guard !bundle.isSystemProtected else { return }
        if checkedTargetPaths.contains(bundle.path) {
            checkedTargetPaths.remove(bundle.path)
            expandedBatchAppPaths.remove(bundle.path)
            queuedBatchBundles.removeValue(forKey: bundle.path)
            if checkedTargetPaths.isEmpty {
                exitMultiSelectMode()
            }
        } else {
            checkedTargetPaths.insert(bundle.path)
            isMultiSelectMode = true
            ensureBatchScanned(for: bundle)
        }
        lastAnchorPathForRangeSelect = bundle.path
    }

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
        if !forceRescan {
            if batchItemsByAppPath[path] != nil {
                return
            }
            if selectedTarget?.path == path, !isScanningTarget, !associatedItems.isEmpty {
                batchItemsByAppPath[path] = associatedItems
                return
            }
            if scanningBatchPaths.contains(path) || queuedBatchBundles[path] != nil {
                return
            }
        } else {
            batchItemsByAppPath.removeValue(forKey: path)
        }

        queuedBatchBundles[path] = bundle
        scanningBatchPaths.insert(path)
        startBatchCoordinatorIfNeeded()
    }

    /// Processes queued batch deep-scans with a bounded pool of 4 concurrent workers instead of spawning unbounded Tasks.
    private func startBatchCoordinatorIfNeeded() {
        guard batchScanCoordinatorTask == nil else { return }

        batchScanCoordinatorTask = Task {
            while !Task.isCancelled && !self.queuedBatchBundles.isEmpty {
                // Take up to 16 queued items per wave and run max 4 concurrently
                let currentWave = Array(self.queuedBatchBundles.values.prefix(16))
                for b in currentWave {
                    self.queuedBatchBundles.removeValue(forKey: b.path)
                }
                let indexSnapshot = self.systemIndex

                await withTaskGroup(of: (String, [AssociatedFileItem]).self) { group in
                    let maxWorkers = 4
                    var nextIdx = 0
                    let initial = min(maxWorkers, currentWave.count)
                    while nextIdx < initial {
                        let target = currentWave[nextIdx]
                        nextIdx += 1
                        group.addTask(priority: .userInitiated) {
                            let items = DeepFileScanner.scanAssociatedFiles(for: target, systemIndex: indexSnapshot)
                            return (target.path, items)
                        }
                    }

                    while let (donePath, scannedItems) = await group.next() {
                        if Task.isCancelled {
                            group.cancelAll()
                            return
                        }
                        self.scanningBatchPaths.remove(donePath)
                        if self.checkedTargetPaths.contains(donePath) {
                            self.batchItemsByAppPath[donePath] = scannedItems
                        }
                        if let primary = scannedItems.first(where: { $0.path == donePath }) {
                            self.updateSingleBundleSize(path: donePath, bytes: primary.sizeBytes)
                        }

                        if nextIdx < currentWave.count {
                            let nextTarget = currentWave[nextIdx]
                            nextIdx += 1
                            group.addTask(priority: .userInitiated) {
                                let items = DeepFileScanner.scanAssociatedFiles(for: nextTarget, systemIndex: indexSnapshot)
                                return (nextTarget.path, items)
                            }
                        }
                    }
                }
            }
            self.batchScanCoordinatorTask = nil
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
        !scanningBatchPaths.isEmpty && activeCheckedTargets.contains { scanningBatchPaths.contains($0.path) }
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
        var seen = Set<String>()
        var total: Int64 = 0
        for bundle in activeCheckedTargets {
            for item in (batchItemsByAppPath[bundle.path] ?? []) where item.isSelected {
                if seen.insert(item.path).inserted {
                    total += item.sizeBytes
                }
            }
        }
        return total
    }

    var batchRequiresAdmin: Bool {
        for bundle in activeCheckedTargets {
            for item in (batchItemsByAppPath[bundle.path] ?? []) where item.isSelected && item.requiresAdmin {
                return true
            }
        }
        return false
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

                self.isSuppressingDerivedRebuild = true
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
                self.isSuppressingDerivedRebuild = false
                self.rebuildAppCatalogDerivedState()
                self.rebuildAddonsDerivedState()

                if self.checkedTargetPaths.isEmpty {
                    self.exitMultiSelectMode()
                    self.selectedTarget = self.filteredApps.first(where: { !$0.isSystemProtected })
                        ?? self.installedApps.first(where: { !$0.isSystemProtected })
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
        var copy = orphans
        for idx in copy.indices {
            copy[idx].isSelected = selected
        }
        orphans = copy
    }

    var selectedOrphansCount: Int {
        orphans.reduce(0) { $0 + ($1.isSelected ? 1 : 0) }
    }

    var selectedOrphansBytes: Int64 {
        orphans.reduce(0) { $0 + ($1.isSelected ? $1.sizeBytes : 0) }
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
                    subtitle: "Các tệp đã được đặt trả về đúng thư mục gốc trước khi xóa.",
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
