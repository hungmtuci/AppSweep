import SwiftUI

struct TargetDeepScanDetailView: View {
    @ObservedObject var viewModel: MainViewModel
    let target: TargetBundle

    private var groupedCategories: [(category: FileCategory, items: [AssociatedFileItem], totalBytes: Int64)] {
        let grouped = Dictionary(grouping: viewModel.associatedItems, by: \.category)
        return grouped.keys
            .sorted { $0.sortPriority < $1.sortPriority }
            .compactMap { cat in
                guard let items = grouped[cat], !items.isEmpty else { return nil }
                let sum = items.reduce(Int64(0)) { $0 + $1.sizeBytes }
                return (cat, items, sum)
            }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerSummaryCard
            Divider()

            if viewModel.isScanningTarget {
                VStack(spacing: 14) {
                    Spacer()
                    ProgressView()
                        .controlSize(.large)
                    Text("Đang quét sâu toàn bộ dữ liệu liên quan của \(target.name)...")
                        .font(.headline)
                    Text("Đang kiểm tra Containers, Group Containers, LaunchAgents, Caches, Preferences & Receipts")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                presetAndBreakdownBar
                Divider()
                associatedFilesScrollList
            }

            Divider()
            bottomActionFooter
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .confirmationDialog(
            confirmDialogTitle,
            isPresented: $viewModel.showUninstallConfirmation,
            titleVisibility: .visible
        ) {
            Button(confirmPrimaryButtonLabel, role: .destructive) {
                viewModel.executeSelectedUninstall()
            }
            Button("Hủy bỏ", role: .cancel) {}
        } message: {
            Text(confirmDialogMessage)
        }
    }

    // MARK: - Top Header Card

    private var headerSummaryCard: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(nsImage: viewModel.icon(for: target.path))
                .resizable()
                .interpolation(.high)
                .frame(width: 64, height: 64)
                .shadow(color: .black.opacity(0.12), radius: 4, y: 2)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(target.name)
                        .font(.title2.weight(.bold))
                        .lineLimit(1)

                    Text("v\(target.version)")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.14), in: Capsule())

                    if target.architecture != .unknown {
                        Text(target.architecture.rawValue)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.blue)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Color.blue.opacity(0.12), in: Capsule())
                    }

                    if viewModel.isRunning(target) {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 6, height: 6)
                            Text("Đang chạy")
                        }
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.green)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.12), in: Capsule())
                    }

                    if target.isSystemProtected {
                        Label("Hệ thống bảo vệ", systemImage: "lock.shield.fill")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.14), in: Capsule())
                    }
                }

                HStack(spacing: 10) {
                    if !target.bundleIdentifier.isEmpty {
                        Text(target.bundleIdentifier)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    if let team = target.teamIdentifier {
                        Text("• Team ID: \(team)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }

                if target.kind == .application {
                    let running = viewModel.isRunning(target)
                    let level = target.usageLevel(isRunning: running)
                    HStack(spacing: 5) {
                        Image(systemName: level.symbolName)
                            .font(.caption2)
                            .foregroundStyle(level.color)
                        Text(target.detailedUsageSummary(isRunning: running))
                            .font(.caption)
                            .foregroundStyle(level == .neverUsed ? Color.red : (level == .dormant ? Color.orange : Color.secondary))
                            .lineLimit(1)
                    }
                }

                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(target.displayPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Button {
                        viewModel.revealInFinder(target.path)
                    } label: {
                        Label("Mở trong Finder", systemImage: "arrow.up.forward.square")
                            .font(.caption2)
                    }
                    .buttonStyle(.link)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text("Tổng dung lượng phát hiện")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(ByteFormatter.string(viewModel.totalDiscoveredBytes))
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                Text("\(viewModel.associatedItems.count) mục liên quan")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
    }

    // MARK: - Storage Breakdown & Quick Presets

    private var presetAndBreakdownBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Proportional Segmented Bar
            if viewModel.totalDiscoveredBytes > 0 {
                GeometryReader { geo in
                    HStack(spacing: 2) {
                        ForEach(groupedCategories, id: \.category) { group in
                            let ratio = max(0.015, CGFloat(group.totalBytes) / CGFloat(max(1, viewModel.totalDiscoveredBytes)))
                            RoundedRectangle(cornerRadius: 3)
                                .fill(group.category.accentColor.gradient)
                                .frame(width: max(4, (geo.size.width - CGFloat(groupedCategories.count * 2)) * ratio))
                                .help("\(group.category.title): \(ByteFormatter.string(group.totalBytes))")
                        }
                    }
                }
                .frame(height: 8)
                .clipShape(Capsule())

                // Legend chips
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(groupedCategories, id: \.category) { group in
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(group.category.accentColor)
                                    .frame(width: 7, height: 7)
                                Text("\(group.category.shortBadge): \(ByteFormatter.string(group.totalBytes))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            // Quick Selection Mode Presets
            HStack(spacing: 8) {
                Text("Chế độ chọn nhanh:")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

                Button {
                    viewModel.applyPresetCompleteUninstall()
                } label: {
                    Label("Gỡ bỏ hoàn toàn", systemImage: "trash.circle")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(target.isSystemProtected)

                Button {
                    viewModel.applyPresetResetAppDataOnly()
                } label: {
                    Label("Chỉ xóa dữ liệu (Reset App)", systemImage: "arrow.counterclockwise.circle")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    viewModel.applyPresetCachesAndLogsOnly()
                } label: {
                    Label("Chỉ dọn Cache & Logs", systemImage: "bolt.circle")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                Button {
                    viewModel.rescanSelectedTarget()
                } label: {
                    Label("Quét lại", systemImage: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    // MARK: - Categorized Associated File List

    private var associatedFilesScrollList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(groupedCategories, id: \.category) { group in
                    categoryCard(category: group.category, items: group.items, categoryBytes: group.totalBytes)
                }
            }
            .padding(18)
        }
    }

    private func categoryCard(
        category: FileCategory,
        items: [AssociatedFileItem],
        categoryBytes: Int64
    ) -> some View {
        let allSelected = items.allSatisfy(\.isSelected)

        return VStack(alignment: .leading, spacing: 0) {
            // Category Header
            HStack(spacing: 10) {
                Button {
                    viewModel.setCategorySelection(category, selected: !allSelected)
                } label: {
                    Image(systemName: allSelected ? "checkmark.square.fill" : "square")
                        .foregroundStyle(allSelected ? Color.accentColor : Color.secondary)
                        .font(.system(size: 14, weight: .semibold))
                }
                .buttonStyle(.plain)

                Image(systemName: category.symbolName)
                    .foregroundStyle(category.accentColor)
                    .font(.system(size: 14, weight: .semibold))

                Text(category.title)
                    .font(.subheadline.weight(.semibold))

                Text("\(items.count)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.14), in: Capsule())

                Spacer()

                Text(ByteFormatter.string(categoryBytes))
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(category.accentColor.opacity(0.07))

            Divider()

            // File Rows
            ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                associatedFileRow(item)
                if idx < items.count - 1 {
                    Divider()
                        .padding(.leading, 40)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private func associatedFileRow(_ item: AssociatedFileItem) -> some View {
        let isLockedRootApp = target.isSystemProtected && item.path == target.path

        return HStack(spacing: 10) {
            Button {
                viewModel.toggleItemSelection(item.id)
            } label: {
                Image(systemName: item.isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isLockedRootApp ? Color.secondary.opacity(0.4) : (item.isSelected ? Color.accentColor : Color.secondary))
                    .font(.system(size: 15))
            }
            .buttonStyle(.plain)
            .disabled(isLockedRootApp)

            Image(nsImage: viewModel.icon(for: item.path))
                .resizable()
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)

                    if item.confidence == .sharedVendor {
                        Text("Dùng chung hãng")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.14), in: Capsule())
                    }

                    if item.requiresAdmin {
                        HStack(spacing: 3) {
                            Image(systemName: "lock.fill")
                            Text("Admin")
                        }
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                        .help("Mục nằm trong thư mục hệ thống, macOS sẽ hỏi xác thực Touch ID / Mật khẩu khi gỡ")
                    }
                }

                Text("\(item.displayPath)  •  \(item.matchReason)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Text(ByteFormatter.string(item.sizeBytes))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(item.isSelected ? .primary : .secondary)

            Button {
                viewModel.revealInFinder(item.path)
            } label: {
                Image(systemName: "magnifyingglass.circle")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Hiển thị trong Finder")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .onTapGesture {
            if !isLockedRootApp {
                viewModel.toggleItemSelection(item.id)
            }
        }
    }

    // MARK: - Sticky Action Footer

    private var bottomActionFooter: some View {
        VStack(spacing: 10) {
            HStack(spacing: 14) {
                Text("Chế độ xóa:")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .fixedSize()

                Picker("", selection: $viewModel.removalMode) {
                    ForEach(RemovalMode.allCases) { mode in
                        Text(mode.shortTitle).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 260)

                Toggle("Sao lưu .zip trước khi xóa", isOn: $viewModel.createZipBackup)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .help("Nén toàn bộ các mục đã chọn thành 1 file .zip trong ~/Downloads/AppSweep Backups trước khi xóa")

                if target.kind == .application {
                    Toggle("Gỡ icon khỏi Dock", isOn: $viewModel.cleanDockIcon)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                }

                Spacer()
            }

            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("Đã chọn \(viewModel.selectedAssociatedItems.count) / \(viewModel.associatedItems.count) mục")
                            .font(.subheadline.weight(.semibold))
                        if viewModel.selectedRequiresAdmin {
                            Label("Cần xác thực Touch ID / Admin", systemImage: "touchid")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    Text(viewModel.removalMode == .moveToTrash
                         ? "Mọi file sẽ được đóng gói gọn vào Thùng rác và có thể Hoàn tác 1 chạm."
                         : "Cảnh báo: File xóa vĩnh viễn sẽ không đi qua Thùng rác và không thể khôi phục.")
                        .font(.caption)
                        .foregroundStyle(viewModel.removalMode == .moveToTrash ? Color.secondary : Color.red)
                }

                Spacer()

                Button {
                    viewModel.showUninstallConfirmation = true
                } label: {
                    HStack(spacing: 8) {
                        if viewModel.isExecutingAction {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: viewModel.removalMode == .moveToTrash ? "trash.fill" : "xmark.bin.fill")
                        }
                        Text("\(viewModel.removalMode == .moveToTrash ? "Gỡ cài đặt" : "Xóa vĩnh viễn") (\(ByteFormatter.string(viewModel.selectedBytesToRemove)))")
                            .fontWeight(.semibold)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(viewModel.removalMode == .moveToTrash ? .red : .pink)
                .controlSize(.large)
                .disabled(viewModel.selectedAssociatedItems.isEmpty || viewModel.isExecutingAction)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Confirmation Dialog Copy

    private var confirmDialogTitle: String {
        let removingApp = viewModel.selectedAssociatedItems.contains { $0.path == target.path }
        if removingApp {
            return "Xác nhận gỡ bỏ triệt để \(target.name)?"
        } else {
            return "Xác nhận dọn dữ liệu đã chọn của \(target.name)?"
        }
    }

    private var confirmPrimaryButtonLabel: String {
        let sizeText = ByteFormatter.string(viewModel.selectedBytesToRemove)
        return viewModel.removalMode == .moveToTrash
            ? "Chuyển vào Thùng rác (\(sizeText))"
            : "Xóa vĩnh viễn ngay (\(sizeText))"
    }

    private var confirmDialogMessage: String {
        var parts: [String] = []
        if viewModel.isRunning(target) {
            parts.append("• \(target.name) đang chạy và sẽ được đóng tự động trước khi gỡ.")
        }
        parts.append("• Sẽ xử lý \(viewModel.selectedAssociatedItems.count) mục (\(ByteFormatter.string(viewModel.selectedBytesToRemove))).")
        if viewModel.createZipBackup {
            parts.append("• Tự động nén bản sao lưu .zip vào ~/Downloads/AppSweep Backups.")
        }
        if viewModel.removalMode == .moveToTrash {
            parts.append("• Có thể nhấn 'Hoàn tác' trong tab Lịch sử để khôi phục nguyên trạng về đúng thư mục gốc.")
        } else {
            parts.append("• Hành động xóa vĩnh viễn KHÔNG THỂ hoàn tác.")
        }
        return parts.joined(separator: "\n")
    }
}
