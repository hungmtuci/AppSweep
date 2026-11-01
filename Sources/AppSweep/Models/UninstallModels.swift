import Foundation
import SwiftUI

enum NavigationSection: String, CaseIterable, Identifiable {
    case apps = "apps"
    case dropZone = "dropZone"
    case addons = "addons"
    case orphans = "orphans"
    case history = "history"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .apps: return "Ứng dụng đã cài"
        case .dropZone: return "Kéo & Thả nhanh"
        case .addons: return "Tiện ích & Plugin"
        case .orphans: return "File rác mồ côi"
        case .history: return "Lịch sử & Hoàn tác"
        }
    }

    var subtitle: String {
        switch self {
        case .apps: return "Quét sâu & gỡ bỏ triệt để ứng dụng"
        case .dropZone: return "Thả ứng dụng hoặc plugin bất kỳ để gỡ"
        case .addons: return "PrefPanes, QuickLook, Screen Savers, Audio"
        case .orphans: return "Dữ liệu sót lại từ ứng dụng đã xóa trước đó"
        case .history: return "Nhật ký gỡ cài đặt, sao lưu & khôi phục 1 chạm"
        }
    }

    var symbolName: String {
        switch self {
        case .apps: return "square.grid.2x2"
        case .dropZone: return "arrow.down.app"
        case .addons: return "puzzlepiece.extension"
        case .orphans: return "tray.full"
        case .history: return "clock.arrow.circlepath"
        }
    }
}

enum AppSortOrder: String, CaseIterable, Identifiable {
    case nameAsc = "Tên (A → Z)"
    case leastUsedFirst = "Ít dùng / Lâu nhất chưa mở"
    case mostUsedFirst = "Dùng nhiều nhất"
    case sizeDesc = "Dung lượng lớn nhất"
    case vendorAsc = "Bundle ID"

    var id: String { rawValue }
}

enum AppFilterScope: String, CaseIterable, Identifiable {
    case all = "Tất cả loại"
    case userApps = "Ứng dụng bên thứ 3"
    case running = "Đang chạy"
    case large = "Dung lượng lớn (>200MB)"

    var id: String { rawValue }
}

enum AppUsageLevel: String, Codable, CaseIterable, Sendable, Identifiable {
    case neverUsed = "neverUsed"
    case dormant = "dormant"
    case rarelyUsed = "rarelyUsed"
    case frequent = "frequent"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .neverUsed: return "Chưa từng mở"
        case .dormant: return "Lâu không mở (>90 ngày)"
        case .rarelyUsed: return "Ít sử dụng"
        case .frequent: return "Dùng thường xuyên"
        }
    }

    var shortLabel: String {
        switch self {
        case .neverUsed: return "Chưa mở"
        case .dormant: return ">90 ngày"
        case .rarelyUsed: return "Ít dùng"
        case .frequent: return "Thường xuyên"
        }
    }

    var symbolName: String {
        switch self {
        case .neverUsed: return "minus.circle"
        case .dormant: return "clock"
        case .rarelyUsed: return "hourglass"
        case .frequent: return "checkmark.circle"
        }
    }

    var color: Color {
        .secondary
    }
}

enum AppUsageFilter: String, CaseIterable, Identifiable {
    case all = "all"
    case suggestedCleanup = "suggestedCleanup"
    case neverUsed = "neverUsed"
    case dormant90Days = "dormant90Days"
    case rarelyUsed = "rarelyUsed"
    case frequentlyUsed = "frequentlyUsed"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "Tất cả mức dùng"
        case .suggestedCleanup: return "Gợi ý nên dọn (Chưa mở / >90 ngày)"
        case .neverUsed: return "Chưa từng mở (0 lần)"
        case .dormant90Days: return "Lâu không mở (>90 ngày)"
        case .rarelyUsed: return "Ít sử dụng (≤5 lần / >21 ngày)"
        case .frequentlyUsed: return "Dùng thường xuyên"
        }
    }

    var pillTitle: String {
        switch self {
        case .all: return "Tất cả"
        case .suggestedCleanup: return "Ít / Không dùng"
        case .neverUsed: return "Chưa mở"
        case .dormant90Days: return ">90 ngày"
        case .rarelyUsed: return "Ít dùng"
        case .frequentlyUsed: return "Thường xuyên"
        }
    }

    var symbolName: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .suggestedCleanup: return "tray"
        case .neverUsed: return "minus.circle"
        case .dormant90Days: return "clock"
        case .rarelyUsed: return "hourglass"
        case .frequentlyUsed: return "checkmark.circle"
        }
    }
}

enum AppArchitecture: String, Codable, Sendable {
    case universal = "Universal"
    case appleSilicon = "Apple Silicon"
    case intel = "Intel"
    case unknown = "macOS"
}

enum BundleKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case application = "Ứng dụng (.app)"
    case preferencePane = "Bảng cài đặt (.prefPane)"
    case quickLook = "Xem nhanh (.qlgenerator)"
    case screenSaver = "Trình bảo vệ màn hình (.saver)"
    case internetPlugin = "Internet Plugin (.plugin)"
    case audioPlugin = "Audio Plugin (AU / VST / VST3)"
    case service = "Dịch vụ macOS (.service)"
    case widget = "Widget (.wdgt / .appex)"

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .application: return "app.fill"
        case .preferencePane: return "gearshape.2.fill"
        case .quickLook: return "eye.fill"
        case .screenSaver: return "sparkles.tv.fill"
        case .internetPlugin: return "globe"
        case .audioPlugin: return "waveform"
        case .service: return "wrench.and.screwdriver.fill"
        case .widget: return "rectangle.3.group.fill"
        }
    }
}

enum FileCategory: String, Codable, CaseIterable, Sendable, Identifiable {
    case appBundle = "appBundle"
    case applicationSupport = "applicationSupport"
    case containers = "containers"
    case caches = "caches"
    case preferences = "preferences"
    case launchDaemons = "launchDaemons"
    case savedState = "savedState"
    case webData = "webData"
    case logs = "logs"
    case receiptsAndConfig = "receiptsAndConfig"
    case addonBundle = "addonBundle"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appBundle: return "Gói ứng dụng chính (.app)"
        case .applicationSupport: return "Dữ liệu ứng dụng (Application Support)"
        case .containers: return "Sandbox & Group Containers"
        case .caches: return "Bộ nhớ đệm (Caches & Temp)"
        case .preferences: return "Thiết lập & Cấu hình (Preferences)"
        case .launchDaemons: return "Tiến trình ngầm & Helper (LaunchAgents / Daemons)"
        case .savedState: return "Trạng thái cửa sổ đã lưu (Saved State)"
        case .webData: return "Dữ liệu Web, Cookies & HTTP Storage"
        case .logs: return "Nhật ký & Báo cáo lỗi (Logs / Crash)"
        case .receiptsAndConfig: return "Biên lai cài đặt & Dotfiles cấu hình"
        case .addonBundle: return "Tiện ích mở rộng & Plugin liên quan"
        }
    }

    var shortBadge: String {
        switch self {
        case .appBundle: return "Ứng dụng"
        case .applicationSupport: return "App Support"
        case .containers: return "Container"
        case .caches: return "Cache"
        case .preferences: return "Preferences"
        case .launchDaemons: return "LaunchAgent"
        case .savedState: return "Saved State"
        case .webData: return "Web / Cookie"
        case .logs: return "Logs"
        case .receiptsAndConfig: return "Receipt / Config"
        case .addonBundle: return "Plugin"
        }
    }

    var symbolName: String {
        switch self {
        case .appBundle: return "app"
        case .applicationSupport: return "folder"
        case .containers: return "shippingbox"
        case .caches: return "internaldrive"
        case .preferences: return "slider.horizontal.3"
        case .launchDaemons: return "gearshape"
        case .savedState: return "macwindow"
        case .webData: return "globe"
        case .logs: return "doc.text"
        case .receiptsAndConfig: return "doc.badge.gearshape"
        case .addonBundle: return "puzzlepiece.extension"
        }
    }

    var sortPriority: Int {
        switch self {
        case .appBundle: return 0
        case .addonBundle: return 1
        case .applicationSupport: return 2
        case .containers: return 3
        case .caches: return 4
        case .preferences: return 5
        case .launchDaemons: return 6
        case .webData: return 7
        case .savedState: return 8
        case .logs: return 9
        case .receiptsAndConfig: return 10
        }
    }

    /// Subtle tonal palette matching macOS System Settings -> Storage (follows system accent + neutral grays).
    var storageSegmentColor: Color {
        switch self {
        case .appBundle, .addonBundle:
            return Color.accentColor
        case .applicationSupport, .containers:
            return Color.accentColor.opacity(0.62)
        case .caches, .webData:
            return Color.primary.opacity(0.34)
        case .preferences, .launchDaemons, .savedState, .logs, .receiptsAndConfig:
            return Color.primary.opacity(0.18)
        }
    }
}

enum MatchConfidence: String, Codable, Sendable {
    case exact = "exact"
    case strong = "strong"
    case sharedVendor = "sharedVendor"

    var label: String {
        switch self {
        case .exact: return "Chính xác"
        case .strong: return "Liên quan cao"
        case .sharedVendor: return "Dùng chung hãng"
        }
    }
}

struct TargetBundle: Identifiable, Hashable, Sendable {
    let id: String // Canonical path
    let name: String
    let bundleName: String
    let executableName: String
    let bundleIdentifier: String
    let version: String
    let path: String
    let teamIdentifier: String?
    let childBundleIdentifiers: [String]
    let childExecutableNames: [String]
    let privilegedHelperLabels: [String]
    let architecture: AppArchitecture
    var bundleSizeBytes: Int64?
    let modifiedDate: Date?
    let lastUsedDate: Date?
    let useCount: Int
    let dateAdded: Date?
    let isSystemProtected: Bool
    let kind: BundleKind

    var url: URL { URL(fileURLWithPath: path) }

    var displayPath: String {
        PathFormatter.prettyPath(path)
    }

    func daysSinceLastUsed(now: Date = Date()) -> Int? {
        guard let lastUsedDate else { return nil }
        let diff = Calendar.current.dateComponents([.day], from: lastUsedDate, to: now).day ?? 0
        return max(0, diff)
    }

    func usageLevel(isRunning: Bool, now: Date = Date()) -> AppUsageLevel {
        if isRunning {
            return .frequent
        }
        if useCount == 0 && lastUsedDate == nil {
            return .neverUsed
        }
        let days = daysSinceLastUsed(now: now) ?? 999
        if days > 90 {
            return .dormant
        }
        if days > 21 || (useCount <= 5 && days > 7) {
            return .rarelyUsed
        }
        return .frequent
    }

    func shortUsageSummary(isRunning: Bool, now: Date = Date()) -> String {
        if isRunning {
            return useCount > 0 ? "Đang mở • \(Self.formatCount(useCount)) lần" : "Đang mở"
        }
        if useCount == 0 && lastUsedDate == nil {
            return "Chưa từng mở"
        }
        let relText = relativeLastUsedText(now: now)
        if useCount > 0 {
            return "\(relText) • \(Self.formatCount(useCount)) lần"
        }
        return relText
    }

    func detailedUsageSummary(isRunning: Bool, now: Date = Date()) -> String {
        let level = usageLevel(isRunning: isRunning, now: now)
        if level == .neverUsed {
            if let dateAdded {
                return "Chưa từng mở (Cài ngày \(Self.shortDateFormatter.string(from: dateAdded)))"
            }
            return "Chưa từng mở lần nào"
        }
        var parts: [String] = [level.title]
        if useCount > 0 {
            parts.append("Đã mở \(Self.formatCount(useCount)) lần")
        }
        if isRunning {
            parts.append("Hiện đang chạy")
        } else if let lastUsedDate {
            parts.append("Mở lần cuối: \(Self.shortDateFormatter.string(from: lastUsedDate)) (\(relativeLastUsedText(now: now)))")
        }
        return parts.joined(separator: " • ")
    }

    private func relativeLastUsedText(now: Date) -> String {
        guard let days = daysSinceLastUsed(now: now) else {
            return "Không rõ"
        }
        if days == 0 { return "Hôm nay" }
        if days == 1 { return "Hôm qua" }
        if days < 30 { return "\(days) ngày trước" }
        let months = days / 30
        if months < 12 { return "\(months) tháng trước" }
        let years = days / 365
        let remMonths = (days % 365) / 30
        return remMonths > 0 ? "\(years) năm \(remMonths) tháng trước" : "\(years) năm trước"
    }

    private static let decimalFormatter: NumberFormatter = {
        let nf = NumberFormatter()
        nf.numberStyle = .decimal
        nf.groupingSeparator = "."
        return nf
    }()

    private static func formatCount(_ n: Int) -> String {
        decimalFormatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    private static let shortDateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "dd/MM/yyyy"
        return df
    }()

    var vendorPrefix: String? {
        let parts = bundleIdentifier.lowercased().split(separator: ".").map(String.init)
        guard parts.count >= 2 else { return nil }
        let generic = Set(["com", "org", "net", "io", "app", "me", "dev", "co", "uk", "de", "jp", "vn"])
        if generic.contains(parts[0]), parts.count >= 2 {
            let vendor = parts[1]
            let ambiguousVendors = Set(["github", "gitlab", "electron", "apple", "googlecode", "sourceforge"])
            if ambiguousVendors.contains(vendor) || vendor.count < 3 {
                return nil
            }
            return "\(parts[0]).\(vendor)"
        }
        return nil
    }
}

struct AssociatedFileItem: Identifiable, Hashable, Sendable {
    let id: String // Canonical path
    let path: String
    let name: String
    let category: FileCategory
    let sizeBytes: Int64
    let confidence: MatchConfidence
    let matchReason: String
    let requiresAdmin: Bool
    let isDirectory: Bool
    var isSelected: Bool

    var url: URL { URL(fileURLWithPath: path) }

    var displayPath: String {
        PathFormatter.prettyPath(path)
    }
}

struct OrphanItem: Identifiable, Hashable, Sendable {
    let id: String
    let path: String
    let name: String
    let inferredIdentifier: String
    let category: FileCategory
    let sizeBytes: Int64
    let reason: String
    let requiresAdmin: Bool
    let modifiedDate: Date?
    var isSelected: Bool

    var url: URL { URL(fileURLWithPath: path) }

    var displayPath: String {
        PathFormatter.prettyPath(path)
    }
}

enum RemovalMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case moveToTrash = "trash"
    case permanentDelete = "permanent"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .moveToTrash:
            return "Đưa vào Thùng rác (An toàn & Hoàn tác 1 chạm)"
        case .permanentDelete:
            return "Xóa vĩnh viễn ngay lập tức"
        }
    }

    var shortTitle: String {
        switch self {
        case .moveToTrash: return "Chuyển vào Thùng rác"
        case .permanentDelete: return "Xóa vĩnh viễn"
        }
    }
}

struct RestorableFileEntry: Codable, Hashable, Sendable, Identifiable {
    var id: String { originalPath }
    let originalPath: String
    let trashedPath: String?
    let categoryRaw: String
    let sizeBytes: Int64
    var isRestored: Bool
}

struct UninstallHistoryRecord: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let timestamp: Date
    let targetName: String
    let bundleIdentifier: String
    let mode: RemovalMode
    let totalBytesFreed: Int64
    let removedCount: Int
    let failedPaths: [String]
    let trashContainerPath: String?
    let archiveZipPath: String?
    var entries: [RestorableFileEntry]
    var isFullyRestored: Bool

    var canRestore: Bool {
        guard mode == .moveToTrash, !isFullyRestored, let container = trashContainerPath else {
            return false
        }
        return FileManager.default.fileExists(atPath: container)
    }
}

enum ByteFormatter {
    static func string(_ bytes: Int64) -> String {
        if bytes <= 0 { return "0 KB" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

enum PathFormatter {
    static func prettyPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home {
            return "~"
        }
        if path.hasPrefix(home + "/") {
            return "~" + String(path.dropFirst(home.count))
        }
        return path
    }
}
