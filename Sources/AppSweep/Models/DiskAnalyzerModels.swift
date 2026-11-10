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
        case .safeRecreate: return "An toàn cao"
        case .reviewRecommended: return "Cần xem trước"
        }
    }

    var subtitle: String {
        switch self {
        case .safeRecreate:
            return "Bộ nhớ đệm, log hoặc dữ liệu tạm — hệ thống & ứng dụng tự tạo lại khi cần"
        case .reviewRecommended:
            return "Bộ cài cũ, thư viện build dự án hoặc tệp lớn — nên kiểm tra trước khi xóa"
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
    case reviewOnly = "reviewOnly"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "Tất cả đề xuất"
        case .safeOnly: return "An toàn cao"
        case .reviewOnly: return "Cần xem trước"
        }
    }
}

enum CleanupRuleKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case appCaches = "appCaches"
    case developerBuild = "developerBuild"
    case packageCache = "packageCache"
    case logsAndCrash = "logsAndCrash"
    case oldInstallers = "oldInstallers"
    case iosBackupsAndVMs = "iosBackupsAndVMs"
    case largeFiles = "largeFiles"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appCaches:
            return "Bộ nhớ đệm ứng dụng (Application Caches)"
        case .developerBuild:
            return "Dữ liệu biên dịch & Dự án lập trình (Xcode / node_modules / Build)"
        case .packageCache:
            return "Bộ đệm trình quản lý gói (Homebrew / npm / pip / Cargo)"
        case .logsAndCrash:
            return "Nhật ký hệ thống & Báo cáo lỗi (Logs / Crash Reports)"
        case .oldInstallers:
            return "Bộ cài đặt & Gói nén trong Tải về (.dmg / .pkg / .zip)"
        case .iosBackupsAndVMs:
            return "Sao lưu thiết bị, Simulator & Dữ liệu Container lớn"
        case .largeFiles:
            return "Tệp đơn lẻ dung lượng rất lớn (≥ 500 MB)"
        }
    }

    var shortBadge: String {
        switch self {
        case .appCaches: return "Cache ứng dụng"
        case .developerBuild: return "Build / Dev"
        case .packageCache: return "Package Cache"
        case .logsAndCrash: return "Logs"
        case .oldInstallers: return "Bộ cài cũ"
        case .iosBackupsAndVMs: return "Backup / VM"
        case .largeFiles: return "Tệp lớn"
        }
    }

    var symbolName: String {
        switch self {
        case .appCaches: return "internaldrive"
        case .developerBuild: return "hammer"
        case .packageCache: return "shippingbox"
        case .logsAndCrash: return "doc.text"
        case .oldInstallers: return "arrow.down.doc"
        case .iosBackupsAndVMs: return "externaldrive"
        case .largeFiles: return "doc.badge.ellipsis"
        }
    }

    var sortOrder: Int {
        switch self {
        case .appCaches: return 0
        case .packageCache: return 1
        case .logsAndCrash: return 2
        case .developerBuild: return 3
        case .oldInstallers: return 4
        case .iosBackupsAndVMs: return 5
        case .largeFiles: return 6
        }
    }

    var mappedFileCategory: FileCategory {
        switch self {
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
    let lastModified: Date?
    let isDirectory: Bool
    let requiresAdmin: Bool

    var displayPath: String {
        PathFormatter.prettyPath(path)
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
