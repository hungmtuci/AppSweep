import AppKit
import SwiftUI

struct DiskSpaceAnalyzerView: View {
    @ObservedObject var viewModel: MainViewModel
    @ObservedObject var analyzer: DiskAnalyzerViewModel

    private static let modifiedFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .none
        df.locale = Locale(identifier: "vi_VN")
        return df
    }()

    var body: some View {
        VStack(spacing: 0) {
            topScopeAndVolumeHeader
            Divider()

            if analyzer.isScanning {
                scanningProgressView
            } else if let current = analyzer.currentNode {
                navigationAndModeBar(current: current)
                Divider()

                switch analyzer.activeMode {
                case .mapAndExplorer:
                    mapAndExplorerSplitView(current: current)
                case .recommendations:
                    recommendationsAdvisorView
                }

                if analyzer.selectedCleanupCount > 0 || analyzer.activeMode == .recommendations {
                    Divider()
                    bottomCleanupActionBar
                }
            } else {
                emptyInitialView
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            analyzer.startScanIfNeeded()
        }
        .confirmationDialog(
            "Dọn dẹp \(analyzer.selectedCleanupCount) mục đã chọn trên ổ đĩa?",
            isPresented: $analyzer.showCleanupConfirmation,
            titleVisibility: .visible
        ) {
            Button(
                "\(viewModel.removalMode == .moveToTrash ? "Chuyển vào Thùng rác" : "Xóa vĩnh viễn") (\(ByteFormatter.string(analyzer.selectedCleanupBytes)))",
                role: .destructive
            ) {
                analyzer.executeCleanup(mainViewModel: viewModel)
            }
            Button("Hủy", role: .cancel) {}
        } message: {
            Text(cleanupConfirmationMessage)
        }
    }

    // MARK: - 1. Top Scope Presets & Volume Capacity Header

    private var topScopeAndVolumeHeader: some View {
        VStack(spacing: 9) {
            HStack(alignment: .center, spacing: 12) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(DiskScanPreset.allCases) { preset in
                            presetPill(preset)
                        }
                    }
                }

                Spacer(minLength: 8)

                Button {
                    analyzer.rescanCurrentRoot()
                } label: {
                    Label("Quét lại", systemImage: "arrow.clockwise")
                        .font(.system(size: 11.5))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(analyzer.isScanning)
            }

            if let vol = analyzer.volumeMetrics {
                HStack(spacing: 12) {
                    Image(systemName: "internaldrive")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    Text(vol.volumeName)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.primary)

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.primary.opacity(0.08))
                            RoundedRectangle(cornerRadius: 3)
                                .fill(vol.usedFraction > 0.88 ? Color.orange.opacity(0.85) : Color.accentColor.opacity(0.75))
                                .frame(width: max(4, geo.size.width * CGFloat(vol.usedFraction)))
                        }
                    }
                    .frame(maxWidth: 200, maxHeight: 6)

                    Text("Đã dùng \(ByteFormatter.string(vol.usedBytes)) / \(ByteFormatter.string(vol.totalBytes))")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)

                    Text("· Còn trống \(ByteFormatter.string(vol.availableBytes))")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(.primary)

                    Spacer()

                    if let root = analyzer.rootNode, !analyzer.isScanning {
                        Text("Phạm vi quét: \(ByteFormatter.string(root.sizeBytes)) (\(String(format: "%.1f", analyzer.lastElapsedSeconds))s)")
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func presetPill(_ preset: DiskScanPreset) -> some View {
        let isActive = (analyzer.selectedPreset == preset)
        let labelTitle: String = {
            if preset == .custom, isActive, let custom = analyzer.customRootPath {
                let name = (custom as NSString).lastPathComponent
                return name.isEmpty ? custom : name
            }
            return preset.title
        }()

        return Button {
            analyzer.selectPreset(preset)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: preset.symbolName)
                    .font(.system(size: 11))
                Text(labelTitle)
                    .font(.system(size: 11.5, weight: isActive ? .semibold : .regular))
                    .lineLimit(1)
            }
            .foregroundStyle(isActive ? Color.primary : Color.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 4.5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isActive ? Color.primary.opacity(0.09) : Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isActive ? Color.accentColor.opacity(0.55) : Color(nsColor: .separatorColor), lineWidth: 0.85)
            )
        }
        .buttonStyle(.plain)
        .disabled(analyzer.isScanning)
    }

    // MARK: - 2. Scanning & Empty States

    private var scanningProgressView: some View {
        VStack(spacing: 14) {
            Spacer()
            ProgressView(value: analyzer.scanProgressFraction, total: 1.0)
                .progressViewStyle(.linear)
                .frame(width: 300)

            Text("Đang phân tích cấu trúc dung lượng thư mục...")
                .font(.headline)
                .foregroundStyle(.primary)

            Text("Đã đo \(ByteFormatter.string(analyzer.scannedBytesLive))  ·  \(analyzer.scanCurrentPath)")
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 520)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyInitialView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "internaldrive")
                .font(.system(size: 38, weight: .ultraLight))
                .foregroundStyle(.tertiary)
            Text("Phân tích không gian ổ đĩa")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Chọn một phạm vi ở thanh trên để dựng sơ đồ Treemap tỷ lệ thực và nhận danh sách các thư mục rác có thể dọn dẹp an toàn.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button("Bắt đầu phân tích") {
                analyzer.rescanCurrentRoot()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 3. Breadcrumb & Mode Bar

    private func navigationAndModeBar(current: DiskSpaceNode) -> some View {
        HStack(spacing: 10) {
            if analyzer.activeMode == .mapAndExplorer {
                Button {
                    analyzer.navigateUp()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11.5, weight: .semibold))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!analyzer.canNavigateUp)
                .help("Quay lại thư mục cha")

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(Array(analyzer.breadcrumbNodes.enumerated()), id: \.element.id) { idx, crumb in
                            if idx > 0 {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            let isLast = (idx == analyzer.breadcrumbNodes.count - 1)
                            Button {
                                analyzer.navigateToBreadcrumb(at: idx)
                            } label: {
                                HStack(spacing: 4) {
                                    if idx == 0 {
                                        Image(systemName: "folder")
                                            .font(.system(size: 10.5))
                                    }
                                    Text(crumb.name)
                                        .font(.system(size: 11.5, weight: isLast ? .semibold : .regular))
                                        .lineLimit(1)
                                }
                                .foregroundStyle(isLast ? Color.primary : Color.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(isLast ? Color.primary.opacity(0.07) : Color.clear)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if analyzer.isDrillingDown {
                    ProgressView()
                        .controlSize(.mini)
                }
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text("Phát hiện \(analyzer.recommendations.count) mục đề xuất dọn dẹp · Tổng cộng \(ByteFormatter.string(analyzer.totalRecommendedBytes))")
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            // Mode Switcher (Map vs Recommendations)
            HStack(spacing: 4) {
                modeTabButton(.mapAndExplorer, badge: nil)
                modeTabButton(
                    .recommendations,
                    badge: analyzer.recommendations.isEmpty
                        ? nil
                        : "\(analyzer.recommendations.count) · \(ByteFormatter.string(analyzer.totalRecommendedBytes))"
                )
            }
            .padding(2)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 7)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func modeTabButton(_ mode: DiskAnalyzerMode, badge: String?) -> some View {
        let isSelected = (analyzer.activeMode == mode)
        return Button {
            analyzer.activeMode = mode
        } label: {
            HStack(spacing: 5) {
                Image(systemName: mode.symbolName)
                    .font(.system(size: 11))
                Text(mode.title)
                    .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
                if let badge {
                    Text(badge)
                        .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
                }
            }
            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isSelected ? Color(nsColor: .controlBackgroundColor) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(isSelected ? Color(nsColor: .separatorColor) : Color.clear, lineWidth: 0.75)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - 4. Mode A: Interactive Treemap + Synchronized Folder Explorer

    private func mapAndExplorerSplitView(current: DiskSpaceNode) -> some View {
        HSplitView {
            treemapVisualPane(current: current)
                .frame(minWidth: 400, idealWidth: 490, maxWidth: .infinity, maxHeight: .infinity)

            folderExplorerListPane(current: current)
                .frame(minWidth: 320, idealWidth: 380, maxWidth: 480, maxHeight: .infinity)
        }
    }

    private func treemapVisualPane(current: DiskSpaceNode) -> some View {
        let highlightedNode: DiskSpaceNode? = current.children.first(where: { $0.id == analyzer.highlightedNodeID })
            ?? current.children.first

        return VStack(alignment: .leading, spacing: 10) {
            // Current Folder Header + Legend
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(current.name)
                            .font(.system(size: 15, weight: .semibold))
                            .lineLimit(1)
                        Text(ByteFormatter.string(current.sizeBytes))
                            .font(.system(size: 14, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Text("\(current.displayPath) · \(current.children.count) mục trực tiếp")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                HStack(spacing: 10) {
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.accentColor.opacity(0.26))
                            .frame(width: 9, height: 9)
                        Text("Thư mục / Tệp")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.orange.opacity(0.32))
                            .frame(width: 9, height: 9)
                        Text("Có mục đề xuất dọn")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Squarified Treemap Canvas
            if current.children.isEmpty || current.sizeBytes == 0 {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "folder")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("Thư mục trống hoặc không thể đọc quyền truy cập")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            } else {
                GeometryReader { geo in
                    let tiles = SquarifiedTreemapLayout.compute(
                        children: current.children,
                        in: CGRect(origin: .zero, size: geo.size),
                        parentPath: current.path,
                        cleanablePathPrefixes: analyzer.cleanablePathPrefixes
                    )
                    ZStack(alignment: .topLeading) {
                        ForEach(tiles) { tile in
                            treemapTileView(tile)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(3)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )
            }

            // Highlighted Node Inspector Card
            if let inspected = highlightedNode {
                selectedTileInspectorCard(node: inspected, parentBytes: max(1, current.sizeBytes))
            }
        }
        .padding(14)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func treemapTileView(_ tile: TreemapTile) -> some View {
        let insetRect = tile.rect.insetBy(dx: 1.2, dy: 1.2)
        let w = max(0, insetRect.width)
        let h = max(0, insetRect.height)
        let isSelected = (analyzer.highlightedNodeID == tile.node.id)
        let isMarkedCleanup = !tile.node.isSyntheticOther && analyzer.isPathSelectedForCleanup(tile.node.path)
        let pctString = String(format: "%.1f%%", tile.fractionOfParent * 100.0)

        let baseFill: Color = {
            if tile.node.isSyntheticOther {
                return Color.primary.opacity(0.055)
            }
            if isMarkedCleanup {
                return Color.accentColor.opacity(0.32)
            }
            if tile.hasCleanableContent {
                return Color.orange.opacity(isSelected ? 0.24 : 0.14)
            }
            let tierOpacity = max(0.08, 0.24 - Double(min(tile.rankIndex, 10)) * 0.014)
            return tile.node.isDirectory
                ? Color.accentColor.opacity(isSelected ? tierOpacity + 0.08 : tierOpacity)
                : Color.primary.opacity(isSelected ? 0.14 : 0.08)
        }()

        let borderColor: Color = {
            if isSelected {
                return Color.accentColor
            }
            if tile.hasCleanableContent {
                return Color.orange.opacity(0.45)
            }
            return Color(nsColor: .separatorColor).opacity(0.85)
        }()

        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4)
                .fill(baseFill)

            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(borderColor, lineWidth: isSelected ? 1.8 : 0.8)

            if w >= 52 && h >= 28 {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        if w >= 78 {
                            Image(systemName: tile.node.isSyntheticOther
                                  ? "ellipsis.circle"
                                  : (tile.node.isAppBundle ? "app" : (tile.node.isDirectory ? "folder" : "doc")))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Text(tile.node.name)
                            .font(.system(size: w >= 110 && h >= 54 ? 11.5 : 10.5, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if tile.hasCleanableContent && w >= 86 {
                            Image(systemName: "sparkles")
                                .font(.system(size: 9.5))
                                .foregroundStyle(Color.orange.opacity(0.9))
                        }
                    }

                    if h >= 44 {
                        Text(w >= 115
                             ? "\(ByteFormatter.string(tile.node.sizeBytes)) · \(pctString)"
                             : ByteFormatter.string(tile.node.sizeBytes))
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
            }
        }
        .frame(width: w, height: h)
        .position(x: tile.rect.midX, y: tile.rect.midY)
        .contentShape(Rectangle())
        .help("\(tile.node.name) — \(ByteFormatter.string(tile.node.sizeBytes)) (\(pctString))\(tile.node.canDrillDown ? " · Nhấp đúp để mở thư mục con" : "")")
        .onTapGesture(count: 2) {
            analyzer.selectNodeOnMap(tile.node)
            if tile.node.canDrillDown {
                analyzer.drillDown(into: tile.node)
            }
        }
        .onTapGesture {
            analyzer.selectNodeOnMap(tile.node)
        }
    }

    private func selectedTileInspectorCard(node: DiskSpaceNode, parentBytes: Int64) -> some View {
        let pct = Double(node.sizeBytes) / Double(max(1, parentBytes)) * 100.0
        let directSuggestion = node.isSyntheticOther ? nil : analyzer.suggestion(forPath: node.path)
        let isTrashFolder = (node.path == NSHomeDirectory() + "/.Trash")

        return HStack(spacing: 10) {
            if node.isSyntheticOther {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
            } else {
                Image(nsImage: viewModel.icon(for: node.path))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 30, height: 30)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(node.name)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)

                    Text("\(ByteFormatter.string(node.sizeBytes)) (\(String(format: "%.1f%%", pct)))")
                        .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)

                    if let sug = directSuggestion {
                        Text(sug.safety.title)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color.orange)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                    }
                }

                if let sug = directSuggestion {
                    Text(sug.reason)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    let modStr = node.modifiedDate.map { " · Sửa đổi \(Self.modifiedFormatter.string(from: $0))" } ?? ""
                    Text("\(node.displayPath)\(modStr)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 6)

            if !node.isSyntheticOther {
                if node.isAppBundle {
                    Button("Gỡ triệt để (.app)") {
                        viewModel.handleDroppedURLs([URL(fileURLWithPath: node.path)])
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Chuyển sang trình quét gỡ cài đặt 11 tầng của AppSweep")
                } else if isTrashFolder {
                    Button("Mở Thùng rác") {
                        viewModel.revealInFinder(node.path)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else if !node.isProtected {
                    let checked = analyzer.isPathSelectedForCleanup(node.path)
                    Button(checked ? "Bỏ chọn dọn" : "Chọn để dọn") {
                        analyzer.toggleNodeCleanupSelection(node)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if node.canDrillDown {
                    Button {
                        analyzer.drillDown(into: node)
                    } label: {
                        Label("Mở bên trong", systemImage: "arrow.turn.down.right")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }

                Button {
                    viewModel.revealInFinder(node.path)
                } label: {
                    Image(systemName: "arrow.forward.circle")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Hiện trong Finder")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }

    // MARK: - Right Folder Breakdown Pane

    private func folderExplorerListPane(current: DiskSpaceNode) -> some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    TextField("Lọc thư mục / tệp trong cấp này...", text: $analyzer.explorerSearchQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                    if !analyzer.explorerSearchQuery.isEmpty {
                        Button {
                            analyzer.explorerSearchQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )

                // Quick Advisor Callout Banner
                if analyzer.totalRecommendedBytes > 0 {
                    Button {
                        analyzer.activeMode = .recommendations
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 11.5))
                                .foregroundStyle(Color.orange)
                            Text("Đề xuất dọn \(ByteFormatter.string(analyzer.totalRecommendedBytes)) (\(analyzer.recommendations.count) mục)")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Spacer()
                            Text("Xem chi tiết")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.accentColor)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.orange.opacity(0.28), lineWidth: 0.8)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(analyzer.visibleExplorerChildren) { item in
                        explorerItemRow(item, parentBytes: max(1, current.sizeBytes))
                    }
                }
                .padding(6)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
    }

    private func explorerItemRow(_ item: DiskSpaceNode, parentBytes: Int64) -> some View {
        let isHighlighted = (analyzer.highlightedNodeID == item.id)
        let isChecked = !item.isSyntheticOther && analyzer.isPathSelectedForCleanup(item.path)
        let directSuggestion = item.isSyntheticOther ? nil : analyzer.suggestion(forPath: item.path)
        let hasNestedCleanable = directSuggestion == nil && analyzer.hasCleanableDescendant(for: item)
        let ratio = min(1.0, max(0.015, Double(item.sizeBytes) / Double(parentBytes)))

        return HStack(spacing: 8) {
            if item.isProtected || item.isSyntheticOther {
                Image(systemName: item.isSyntheticOther ? "ellipsis" : "lock")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .frame(width: 16)
                    .help(item.isSyntheticOther ? "Nhóm mục nhỏ" : "Thư mục gốc được hệ thống bảo vệ")
            } else {
                Toggle(
                    "",
                    isOn: Binding(
                        get: { isChecked },
                        set: { _ in analyzer.toggleNodeCleanupSelection(item) }
                    )
                )
                .toggleStyle(.checkbox)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 16)
            }

            if item.isSyntheticOther {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
            } else {
                Image(nsImage: viewModel.icon(for: item.path))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 22, height: 22)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(item.name)
                        .font(.system(size: 12, weight: isHighlighted ? .semibold : .regular))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if directSuggestion != nil {
                        Text("Nên dọn")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(Color.orange)
                            .padding(.horizontal, 4.5)
                            .padding(.vertical, 0.5)
                            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
                    } else if hasNestedCleanable {
                        Image(systemName: "sparkles")
                            .font(.system(size: 9.5))
                            .foregroundStyle(Color.orange.opacity(0.85))
                            .help("Bên trong thư mục này có mục đề xuất dọn dẹp")
                    }

                    Spacer(minLength: 4)

                    Text(ByteFormatter.string(item.sizeBytes))
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 6) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.primary.opacity(0.07))
                            RoundedRectangle(cornerRadius: 2)
                                .fill(directSuggestion != nil ? Color.orange.opacity(0.7) : Color.accentColor.opacity(0.62))
                                .frame(width: max(3, geo.size.width * CGFloat(ratio)))
                        }
                    }
                    .frame(height: 4)

                    Text(String(format: "%.1f%%", ratio * 100.0))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .frame(width: 36, alignment: .trailing)
                }
            }

            if item.canDrillDown {
                Button {
                    analyzer.selectNodeOnMap(item)
                    analyzer.drillDown(into: item)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 22)
                }
                .buttonStyle(.plain)
                .help("Đi vào bên trong \(item.name)")
            } else {
                Spacer()
                    .frame(width: 18)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5.5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(
                    isHighlighted
                    ? Color.accentColor.opacity(0.12)
                    : (isChecked ? Color.accentColor.opacity(0.07) : Color.clear)
                )
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            analyzer.selectNodeOnMap(item)
            if item.canDrillDown {
                analyzer.drillDown(into: item)
            }
        }
        .onTapGesture {
            analyzer.selectNodeOnMap(item)
        }
    }

    // MARK: - 5. Mode B: Smart Cleanup Recommendations View

    private var recommendationsAdvisorView: some View {
        VStack(spacing: 0) {
            recommendationsSummaryBanner
            Divider()
            recommendationsFilterToolbar
            Divider()

            if analyzer.filteredRecommendations.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 34, weight: .ultraLight))
                        .foregroundStyle(.tertiary)
                    Text("Không phát hiện mục cần dọn trong bộ lọc hiện tại")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("Ổ đĩa hoặc phạm vi thư mục đang chọn đã khá gọn gàng, hoặc bạn có thể chuyển sang quét toàn bộ Thư mục cá nhân (~).")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(analyzer.groupedRecommendations, id: \.kind) { group in
                            recommendationGroupSection(
                                kind: group.kind,
                                items: group.items,
                                subtotalBytes: group.totalBytes
                            )
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                }
            }
        }
    }

    private var recommendationsSummaryBanner: some View {
        HStack(spacing: 24) {
            metricBlock(
                title: "Tổng dung lượng đề xuất",
                value: ByteFormatter.string(analyzer.totalRecommendedBytes),
                note: "\(analyzer.recommendations.count) thư mục & tệp"
            )

            Divider()
                .frame(height: 32)

            metricBlock(
                title: "An toàn cao (Tự tạo lại)",
                value: ByteFormatter.string(analyzer.safeRecommendedBytes),
                note: "Cache, Logs, Xcode DerivedData, pip/npm..."
            )

            Divider()
                .frame(height: 32)

            metricBlock(
                title: "Cần xem trước",
                value: ByteFormatter.string(analyzer.reviewRecommendedBytes),
                note: "Bộ cài cũ (.dmg/.pkg), node_modules, tệp ≥500MB"
            )

            Spacer()

            if analyzer.safeRecommendedBytes > 0 {
                Button("Chọn nhanh mục An toàn cao (\(ByteFormatter.string(analyzer.safeRecommendedBytes)))") {
                    analyzer.selectSafeRecommendations()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 11)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func metricBlock(title: String, value: String, note: String) -> some View {
        VStack(alignment: .leading, spacing: 1.5) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 15, weight: .semibold).monospacedDigit())
                .foregroundStyle(.primary)
            Text(note)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    private var recommendationsFilterToolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                TextField("Tìm theo tên thư mục, đường dẫn hoặc loại dữ liệu...", text: $analyzer.recommendationSearchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !analyzer.recommendationSearchQuery.isEmpty {
                    Button {
                        analyzer.recommendationSearchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(width: 290)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor), lineWidth: 1))

            Picker("", selection: $analyzer.recommendationSafetyFilter) {
                ForEach(CleanupSafetyFilter.allCases) { f in
                    Text(f.title).tag(f)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 285)

            Spacer()

            Button("Chọn tất cả đang lọc") {
                analyzer.selectAllFilteredRecommendations()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            if analyzer.selectedCleanupCount > 0 {
                Button("Bỏ chọn") {
                    analyzer.clearCleanupSelection()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    private func recommendationGroupSection(
        kind: CleanupRuleKind,
        items: [DiskCleanupSuggestion],
        subtotalBytes: Int64
    ) -> some View {
        let allSelected = items.allSatisfy { analyzer.isPathSelectedForCleanup($0.path) }

        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Toggle(
                    "",
                    isOn: Binding(
                        get: { allSelected },
                        set: { newValue in analyzer.setCategorySelection(kind, selected: newValue) }
                    )
                )
                .toggleStyle(.checkbox)
                .labelsHidden()
                .controlSize(.small)

                Image(systemName: kind.symbolName)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                Text(kind.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)

                Text("(\(items.count))")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.tertiary)

                Spacer()

                Text(ByteFormatter.string(subtotalBytes))
                    .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)

            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                    recommendationRow(item)
                    if idx < items.count - 1 {
                        Divider()
                            .padding(.leading, 40)
                    }
                }
            }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            )
        }
    }

    private func recommendationRow(_ item: DiskCleanupSuggestion) -> some View {
        let isSelected = analyzer.isPathSelectedForCleanup(item.path)

        return HStack(spacing: 10) {
            Toggle(
                "",
                isOn: Binding(
                    get: { isSelected },
                    set: { _ in analyzer.toggleSuggestionSelection(item) }
                )
            )
            .toggleStyle(.checkbox)
            .labelsHidden()
            .controlSize(.small)

            Image(nsImage: viewModel.icon(for: item.path))
                .resizable()
                .interpolation(.high)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(isSelected ? .primary : .secondary)
                        .lineLimit(1)

                    HStack(spacing: 3) {
                        Image(systemName: item.safety.symbolName)
                            .font(.system(size: 9))
                        Text(item.safety.title)
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(item.safety == .safeRecreate ? Color.secondary : Color.orange)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        (item.safety == .safeRecreate ? Color.primary.opacity(0.06) : Color.orange.opacity(0.11)),
                        in: RoundedRectangle(cornerRadius: 4)
                    )

                    if let age = item.ageDescription() {
                        Text("· \(age)")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                    }

                    if item.requiresAdmin {
                        Image(systemName: "lock")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .help("Cần quyền Quản trị viên khi dọn dẹp")
                    }
                }

                Text("\(item.displayPath)  —  \(item.reason)")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            Text(ByteFormatter.string(item.sizeBytes))
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.primary)

            Button {
                analyzer.revealSuggestionOnMap(item)
            } label: {
                Image(systemName: "square.grid.3x1.below.line.grid.1x2")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Định vị trên Sơ đồ Treemap")

            Button {
                viewModel.revealInFinder(item.path)
            } label: {
                Image(systemName: "arrow.forward.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Hiện trong Finder")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7.5)
        .contentShape(Rectangle())
        .onTapGesture {
            analyzer.toggleSuggestionSelection(item)
        }
    }

    // MARK: - 6. Bottom Unified Cleanup Bar

    private var bottomCleanupActionBar: some View {
        let count = analyzer.selectedCleanupCount
        let bytes = analyzer.selectedCleanupBytes
        let isDisabled = count == 0 || viewModel.isExecutingAction

        return HStack(spacing: 14) {
            Picker("Chế độ:", selection: $viewModel.removalMode) {
                ForEach(RemovalMode.allCases) { mode in
                    Text(mode.shortTitle).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .frame(width: 270)

            Toggle("Sao lưu .zip", isOn: $viewModel.createZipBackup)
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .font(.system(size: 11.5))

            Spacer()

            VStack(alignment: .trailing, spacing: 1) {
                HStack(spacing: 5) {
                    Text("Đã chọn \(count) mục · \(ByteFormatter.string(bytes))")
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                    if analyzer.selectedCleanupRequiresAdmin {
                        Image(systemName: "lock")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .help("Yêu cầu xác thực Touch ID / Quản trị viên")
                    }
                }
                Text(viewModel.removalMode == .moveToTrash
                     ? "Hỗ trợ Hoàn tác 1 chạm trong mục Lịch sử & Hoàn tác"
                     : "Xóa trực tiếp không qua Thùng rác")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }

            if viewModel.removalMode == .permanentDelete {
                Button(role: .destructive) {
                    analyzer.showCleanupConfirmation = true
                } label: {
                    Text("Xóa vĩnh viễn (\(ByteFormatter.string(bytes)))")
                        .font(.system(size: 12.5, weight: .medium).monospacedDigit())
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(isDisabled)
            } else {
                Button {
                    analyzer.showCleanupConfirmation = true
                } label: {
                    Text("Chuyển vào Thùng rác (\(ByteFormatter.string(bytes)))")
                        .font(.system(size: 12.5, weight: .medium).monospacedDigit())
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isDisabled)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var cleanupConfirmationMessage: String {
        let items = analyzer.resolvedSelectedCleanupItems
        let previewNames = items.prefix(5).map(\.title).joined(separator: ", ")
        var lines: [String] = [
            "Mục đã chọn (\(items.count)): \(previewNames)\(items.count > 5 ? "..." : "")",
            "Tổng dung lượng giải phóng: \(ByteFormatter.string(analyzer.selectedCleanupBytes))."
        ]
        if viewModel.removalMode == .moveToTrash {
            lines.append("Tất cả tệp được đóng gói an toàn trong Thùng rác và có thể khôi phục về vị trí gốc bằng 1 cú nhấp chuột.")
        } else {
            lines.append("Cảnh báo: Xóa vĩnh viễn không thể khôi phục lại.")
        }
        return lines.joined(separator: "\n")
    }
}
