import CoreGraphics
import Foundation
import SwiftUI

enum DiskScanPreset: String, CaseIterable, Identifiable, Sendable {
    case home = "home"
    case userLibrary = "userLibrary"
    case downloads = "downloads"
    case applications = "applications"
    case mainDisk = "mainDisk"
    case custom = "custom"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Cá nhân (~)"
        case .userLibrary: return "~/Library"
        case .downloads: return "Tải về"
        case .applications: return "/Applications"
        case .mainDisk: return "Ổ đĩa chính"
        case .custom: return "Chọn thư mục..."
        }
    }

    var symbolName: String {
        switch self {
        case .home: return "house"
        case .userLibrary: return "building.columns"
        case .downloads: return "arrow.down.circle"
        case .applications: return "app.badge"
        case .mainDisk: return "internaldrive"
        case .custom: return "folder"
        }
    }

    var resolvedRootPath: String? {
        let home = NSHomeDirectory()
        switch self {
        case .home:
            return home
        case .userLibrary:
            return (home as NSString).appendingPathComponent("Library")
        case .downloads:
            return (home as NSString).appendingPathComponent("Downloads")
        case .applications:
            return "/Applications"
        case .mainDisk:
            return "/"
        case .custom:
            return nil
        }
    }
}

enum DiskAnalyzerMode: String, CaseIterable, Identifiable, Sendable {
    case mapAndExplorer = "mapAndExplorer"
    case recommendations = "recommendations"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mapAndExplorer: return "Sơ đồ & Thư mục"
        case .recommendations: return "Đề xuất dọn dẹp"
        }
    }

    var symbolName: String {
        switch self {
        case .mapAndExplorer: return "square.grid.3x1.below.line.grid.1x2"
        case .recommendations: return "sparkles"
        }
    }
}

struct VolumeSpaceMetrics: Equatable, Sendable {
    let volumeName: String
    let totalBytes: Int64
    let availableBytes: Int64

    var usedBytes: Int64 {
        max(0, totalBytes - availableBytes)
    }

    var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1.0, max(0.0, Double(usedBytes) / Double(totalBytes)))
    }
}

struct DiskSpaceNode: Identifiable, Equatable, Sendable {
    let id: String
    let path: String
    let name: String
    var sizeBytes: Int64
    let isDirectory: Bool
    let isPackageBundle: Bool
    let isSyntheticOther: Bool
    var hasUnexpandedSubtree: Bool
    var itemCount: Int
    let modifiedDate: Date?
    let requiresAdmin: Bool
    let isProtected: Bool
    var children: [DiskSpaceNode]

    var displayPath: String {
        isSyntheticOther ? path : PathFormatter.prettyPath(path)
    }

    var canDrillDown: Bool {
        isDirectory && !isSyntheticOther && sizeBytes > 0
    }

    var isAppBundle: Bool {
        isPackageBundle && path.lowercased().hasSuffix(".app")
    }
}

enum CleanupSafetyLevel: String, Codable, CaseIterable, Identifiable, Sendable {
    case safeRecreate = "safeRecreate"
    case reviewRecommended = "reviewRecommended"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .safeRecreate: return "Xóa an toàn"
        case .reviewRecommended: return "Nên xem qua"
        }
    }

    var badgeText: String {
        switch self {
        case .safeRecreate: return "An toàn — Không mất dữ liệu"
        case .reviewRecommended: return "Kiểm tra nếu bạn còn dùng"
        }
    }

    var subtitle: String {
        switch self {
        case .safeRecreate:
            return "Chỉ gồm file nháp, bộ nhớ tạm hoặc bản ứng dụng bị trùng lặp — xóa đi giúp nhẹ máy mà không mất tài liệu hay cài đặt"
        case .reviewRecommended:
            return "Gồm các bộ cài đã tải về, bản ứng dụng trong thư mục làm việc hoặc tệp rất lớn — hãy tích chọn nếu bạn không còn dùng"
        }
    }

    var symbolName: String {
        switch self {
        case .safeRecreate: return "checkmark.shield"
        case .reviewRecommended: return "eye"
        }
    }
}

enum CleanupSafetyFilter: String, CaseIterable, Identifiable, Sendable {
    case all = "all"
    case safeOnly = "safeOnly"
    case appsAndInstallers = "appsAndInstallers"
    case reviewOnly = "reviewOnly"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "Tất cả gợi ý"
        case .safeOnly: return "An toàn 100%"
        case .appsAndInstallers: return "Bản .app & Bộ cài thừa"
        case .reviewOnly: return "Mục lớn cần xem"
        }
    }
}

enum CleanupRuleKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case builtAndDuplicateApps = "builtAndDuplicateApps"
    case developerBuild = "developerBuild"
    case appCaches = "appCaches"
    case packageCache = "packageCache"
    case oldInstallers = "oldInstallers"
    case logsAndCrash = "logsAndCrash"
    case iosBackupsAndVMs = "iosBackupsAndVMs"
    case largeFiles = "largeFiles"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .builtAndDuplicateApps:
            return "Ứng dụng (.app) bị nhân bản hoặc tạo ra khi đóng gói"
        case .developerBuild:
            return "File nháp tạo ra khi đóng gói phần mềm (.build, dist, Xcode)"
        case .appCaches:
            return "Bộ nhớ tạm của các ứng dụng (Caches)"
        case .packageCache:
            return "Gói cài đặt lưu tạm của công cụ hệ thống"
        case .oldInstallers:
            return "Bộ cài đặt cũ (.dmg, .pkg, .zip) sau khi đã cài xong"
        case .logsAndCrash:
            return "Nhật ký hoạt động & Báo cáo lỗi cũ (Logs)"
        case .iosBackupsAndVMs:
            return "Bản sao lưu điện thoại & Ổ đĩa máy ảo"
        case .largeFiles:
            return "Tệp dung lượng rất lớn (≥ 500 MB)"
        }
    }

    var plainExplanation: String {
        switch self {
        case .builtAndDuplicateApps:
            return "Các bản sao ứng dụng đánh số (2, 3...) hoặc file .app sinh ra trong thư mục dự án khi bạn đã có bản chính trong Applications."
        case .developerBuild:
            return "Thư mục trung gian (.build, dist, DerivedData) tự sinh ra lúc chạy hoặc đóng gói phần mềm — xóa đi vẫn giữ nguyên 100% mã nguồn và tài liệu."
        case .appCaches:
            return "Dữ liệu lưu tạm để mở ứng dụng nhanh hơn — ứng dụng sẽ tự tạo lại khi cần, không mất tài khoản hay thiết lập."
        case .packageCache:
            return "Các gói thư viện đã tải về trước đây nằm chờ trong bộ nhớ đệm — xóa đi giúp giải phóng ổ đĩa ngay lập tức."
        case .oldInstallers:
            return "Các file bộ cài (.dmg, .pkg, .zip) lưu trên máy sau khi bạn đã cài đặt phần mềm xong."
        case .logsAndCrash:
            return "Các tệp văn bản ghi lịch sử hoạt động cũ của hệ thống — hoàn toàn vô hại khi dọn sạch."
        case .iosBackupsAndVMs:
            return "Bản sao lưu iPhone/iPad cũ hoặc ổ đĩa máy ảo — chỉ xóa khi bạn không còn cần dùng."
        case .largeFiles:
            return "Các video hoặc tệp dữ liệu chiếm từ 500 MB trở lên — hãy xem lại trước khi xóa."
        }
    }

    var shortBadge: String {
        switch self {
        case .builtAndDuplicateApps: return "Bản .app thừa"
        case .developerBuild: return "File nháp (.build / dist)"
        case .appCaches: return "Bộ nhớ tạm"
        case .packageCache: return "Gói lưu tạm"
        case .oldInstallers: return "Bộ cài (.dmg / .zip)"
        case .logsAndCrash: return "Nhật ký lỗi"
        case .iosBackupsAndVMs: return "Sao lưu / Máy ảo"
        case .largeFiles: return "Tệp rất lớn"
        }
    }

    var symbolName: String {
        switch self {
        case .builtAndDuplicateApps: return "app.badge.checkmark"
        case .developerBuild: return "hammer"
        case .appCaches: return "internaldrive"
        case .packageCache: return "shippingbox"
        case .oldInstallers: return "arrow.down.doc"
        case .logsAndCrash: return "doc.text"
        case .iosBackupsAndVMs: return "externaldrive"
        case .largeFiles: return "doc.badge.ellipsis"
        }
    }

    var sortOrder: Int {
        switch self {
        case .builtAndDuplicateApps: return 0
        case .developerBuild: return 1
        case .appCaches: return 2
        case .packageCache: return 3
        case .oldInstallers: return 4
        case .logsAndCrash: return 5
        case .iosBackupsAndVMs: return 6
        case .largeFiles: return 7
        }
    }

    var mappedFileCategory: FileCategory {
        switch self {
        case .builtAndDuplicateApps:
            return .appBundle
        case .appCaches, .packageCache:
            return .caches
        case .logsAndCrash:
            return .logs
        case .developerBuild, .iosBackupsAndVMs:
            return .applicationSupport
        case .oldInstallers, .largeFiles:
            return .receiptsAndConfig
        }
    }
}

struct DiskCleanupSuggestion: Identifiable, Equatable, Sendable {
    let id: String // Canonical path
    let path: String
    let title: String
    let sizeBytes: Int64
    let safety: CleanupSafetyLevel
    let ruleKind: CleanupRuleKind
    let reason: String
    let impactIfDeleted: String
    let lastModified: Date?
    let isDirectory: Bool
    let requiresAdmin: Bool

    init(
        id: String,
        path: String,
        title: String,
        sizeBytes: Int64,
        safety: CleanupSafetyLevel,
        ruleKind: CleanupRuleKind,
        reason: String,
        impactIfDeleted: String? = nil,
        lastModified: Date?,
        isDirectory: Bool,
        requiresAdmin: Bool
    ) {
        self.id = id
        self.path = path
        self.title = title
        self.sizeBytes = sizeBytes
        self.safety = safety
        self.ruleKind = ruleKind
        self.reason = reason
        self.impactIfDeleted = impactIfDeleted ?? (
            safety == .safeRecreate
            ? "Xóa hoàn toàn an toàn — Không làm mất tài liệu, mã nguồn hay ứng dụng chính."
            : "Nên kiểm tra nhanh — Chỉ giữ lại nếu bạn vẫn đang dùng trực tiếp tệp này."
        )
        self.lastModified = lastModified
        self.isDirectory = isDirectory
        self.requiresAdmin = requiresAdmin
    }

    var displayPath: String {
        PathFormatter.prettyPath(path)
    }

    var parentFolderPath: String {
        (path as NSString).deletingLastPathComponent
    }

    var parentFolderName: String {
        let p = parentFolderPath
        let last = (p as NSString).lastPathComponent
        return last.isEmpty ? p : last
    }

    func ageDescription(now: Date = Date()) -> String? {
        guard let lastModified else { return nil }
        let days = max(0, Calendar.current.dateComponents([.day], from: lastModified, to: now).day ?? 0)
        if days == 0 { return "Hôm nay" }
        if days < 30 { return "\(days) ngày trước" }
        if days < 365 { return "\(days / 30) tháng trước" }
        return "\(days / 365) năm trước"
    }
}

struct FolderCleanupScopeOption: Identifiable, Equatable, Sendable {
    let id: String
    let folderPath: String
    let displayName: String
    let reclaimableBytes: Int64
    let itemCount: Int
}

struct FolderRuleBreakdownSlice: Identifiable, Equatable, Sendable {
    var id: String { kind.rawValue }
    let kind: CleanupRuleKind
    let totalBytes: Int64
    let itemCount: Int
    let selectedCount: Int

    var isAllSelected: Bool {
        itemCount > 0 && selectedCount == itemCount
    }

    var isPartiallySelected: Bool {
        selectedCount > 0 && selectedCount < itemCount
    }
}

struct DiskAnalysisSnapshot: Sendable {
    let rootNode: DiskSpaceNode
    let recommendations: [DiskCleanupSuggestion]
    let volumeMetrics: VolumeSpaceMetrics?
    let elapsedSeconds: Double
}

struct DiskScanProgress: Sendable {
    let currentPath: String
    let scannedBytes: Int64
    let completedUnits: Int
    let totalUnits: Int

    var fraction: Double {
        guard totalUnits > 0 else { return 0 }
        return min(0.98, max(0.03, Double(completedUnits) / Double(totalUnits)))
    }
}

// MARK: - Squarified Treemap Layout Engine (Bruls–Huizing–van Wijk)

struct TreemapTile: Identifiable, Equatable {
    let id: String
    let node: DiskSpaceNode
    let rect: CGRect
    let fractionOfParent: Double
    let rankIndex: Int
    let hasCleanableContent: Bool
    let cleanableBytesInside: Int64
}

enum SquarifiedTreemapLayout {
    private struct WeightedItem {
        let node: DiskSpaceNode
        let area: Double
        let fraction: Double
        let rankIndex: Int
        let hasCleanableContent: Bool
        let cleanableBytesInside: Int64
    }

    static func compute(
        children: [DiskSpaceNode],
        in bounds: CGRect,
        parentPath: String,
        recommendations: [DiskCleanupSuggestion],
        maxVisibleTiles: Int = 24
    ) -> [TreemapTile] {
        guard bounds.width > 8, bounds.height > 8 else { return [] }

        let positive = children.filter { $0.sizeBytes > 0 }
        guard !positive.isEmpty else { return [] }

        let totalBytes = positive.reduce(Int64(0)) { $0 + $1.sizeBytes }
        guard totalBytes > 0 else { return [] }

        // Group tiny tail items into a single synthetic tile so every block remains legible
        var preparedNodes: [DiskSpaceNode] = []
        var tailBytes: Int64 = 0
        var tailDirectCount: Int = 0

        for (idx, child) in positive.enumerated() {
            let share = Double(child.sizeBytes) / Double(totalBytes)
            let minShareThreshold = maxVisibleTiles > 24 ? 0.0012 : 0.0040
            if idx < maxVisibleTiles && (idx < 8 || share >= minShareThreshold) {
                preparedNodes.append(child)
            } else {
                tailBytes += child.sizeBytes
                tailDirectCount += 1
            }
        }

        if tailBytes > 0 {
            if preparedNodes.isEmpty, let first = positive.first {
                preparedNodes.append(first)
            } else {
                preparedNodes.append(
                    DiskSpaceNode(
                        id: "__treemap_other__:\(parentPath)",
                        path: "Nhấp để bung thêm \(tailDirectCount) mục nhỏ đang gộp trên sơ đồ",
                        name: "Mục nhỏ khác (\(tailDirectCount))",
                        sizeBytes: tailBytes,
                        isDirectory: false,
                        isPackageBundle: false,
                        isSyntheticOther: true,
                        hasUnexpandedSubtree: false,
                        itemCount: tailDirectCount,
                        modifiedDate: nil,
                        requiresAdmin: false,
                        isProtected: true,
                        children: []
                    )
                )
            }
        }

        let preparedSum = Double(preparedNodes.reduce(Int64(0)) { $0 + $1.sizeBytes })
        guard preparedSum > 0 else { return [] }

        let canvasArea = Double(bounds.width * bounds.height)
        let items: [WeightedItem] = preparedNodes.enumerated().map { idx, node in
            let frac = Double(node.sizeBytes) / preparedSum
            let area = max(0.0001, frac * canvasArea)
            let cleanBytes = node.isSyntheticOther ? 0 : cleanableBytes(under: node.path, in: recommendations)
            return WeightedItem(
                node: node,
                area: area,
                fraction: Double(node.sizeBytes) / Double(totalBytes),
                rankIndex: idx,
                hasCleanableContent: cleanBytes > 0,
                cleanableBytesInside: cleanBytes
            )
        }

        var remainingRect = bounds
        var currentRow: [WeightedItem] = []
        var output: [TreemapTile] = []
        output.reserveCapacity(items.count)

        for item in items {
            if currentRow.isEmpty {
                currentRow.append(item)
                continue
            }

            let shortSide = Double(min(remainingRect.width, remainingRect.height))
            guard shortSide > 0.5 else {
                currentRow.append(item)
                continue
            }

            let currentWorst = worstAspectRatio(row: currentRow, sideLength: shortSide)
            var candidateRow = currentRow
            candidateRow.append(item)
            let candidateWorst = worstAspectRatio(row: candidateRow, sideLength: shortSide)

            if candidateWorst <= currentWorst {
                currentRow = candidateRow
            } else {
                layoutRow(currentRow, in: &remainingRect, into: &output)
                currentRow = [item]
            }
        }

        if !currentRow.isEmpty {
            layoutRow(currentRow, in: &remainingRect, into: &output, fillRemainder: true)
        }

        return output
    }

    private static func cleanableBytes(under nodePath: String, in recommendations: [DiskCleanupSuggestion]) -> Int64 {
        guard !recommendations.isEmpty else { return 0 }
        let prefix = nodePath.hasSuffix("/") ? nodePath : (nodePath + "/")
        var sum: Int64 = 0
        for rec in recommendations {
            if rec.path == nodePath || rec.path.hasPrefix(prefix) {
                sum += rec.sizeBytes
            }
        }
        return sum
    }

    private static func worstAspectRatio(row: [WeightedItem], sideLength: Double) -> Double {
        guard !row.isEmpty, sideLength > 0 else { return .greatestFiniteMagnitude }
        var sum = 0.0
        var minA = Double.greatestFiniteMagnitude
        var maxA = 0.0
        for item in row {
            sum += item.area
            if item.area < minA { minA = item.area }
            if item.area > maxA { maxA = item.area }
        }
        guard sum > 0, minA > 0 else { return .greatestFiniteMagnitude }
        let s2 = sideLength * sideLength
        let r2 = sum * sum
        return max((s2 * maxA) / r2, r2 / (s2 * minA))
    }

    private static func layoutRow(
        _ row: [WeightedItem],
        in rect: inout CGRect,
        into output: inout [TreemapTile],
        fillRemainder: Bool = false
    ) {
        guard !row.isEmpty, rect.width > 0.5, rect.height > 0.5 else { return }
        let rowArea = row.reduce(0.0) { $0 + $1.area }
        guard rowArea > 0 else { return }

        let splitHorizontally = rect.width >= rect.height
        if splitHorizontally {
            let rawWidth = CGFloat(rowArea / Double(rect.height))
            let stripWidth = fillRemainder ? rect.width : min(rect.width, max(1.0, rawWidth))
            var cursorY = rect.minY
            for (idx, item) in row.enumerated() {
                let isLast = (idx == row.count - 1)
                let itemHeight = isLast
                    ? max(0, rect.maxY - cursorY)
                    : min(rect.maxY - cursorY, CGFloat((item.area / rowArea) * Double(rect.height)))
                let tileRect = CGRect(x: rect.minX, y: cursorY, width: stripWidth, height: max(0, itemHeight))
                output.append(TreemapTile(
                    id: item.node.id,
                    node: item.node,
                    rect: tileRect,
                    fractionOfParent: item.fraction,
                    rankIndex: item.rankIndex,
                    hasCleanableContent: item.hasCleanableContent,
                    cleanableBytesInside: item.cleanableBytesInside
                ))
                cursorY += itemHeight
            }
            rect = CGRect(
                x: rect.minX + stripWidth,
                y: rect.minY,
                width: max(0, rect.width - stripWidth),
                height: rect.height
            )
        } else {
            let rawHeight = CGFloat(rowArea / Double(rect.width))
            let stripHeight = fillRemainder ? rect.height : min(rect.height, max(1.0, rawHeight))
            var cursorX = rect.minX
            for (idx, item) in row.enumerated() {
                let isLast = (idx == row.count - 1)
                let itemWidth = isLast
                    ? max(0, rect.maxX - cursorX)
                    : min(rect.maxX - cursorX, CGFloat((item.area / rowArea) * Double(rect.width)))
                let tileRect = CGRect(x: cursorX, y: rect.minY, width: max(0, itemWidth), height: stripHeight)
                output.append(TreemapTile(
                    id: item.node.id,
                    node: item.node,
                    rect: tileRect,
                    fractionOfParent: item.fraction,
                    rankIndex: item.rankIndex,
                    hasCleanableContent: item.hasCleanableContent,
                    cleanableBytesInside: item.cleanableBytesInside
                ))
                cursorX += itemWidth
            }
            rect = CGRect(
                x: rect.minX,
                y: rect.minY + stripHeight,
                width: rect.width,
                height: max(0, rect.height - stripHeight)
            )
        }
    }
}
