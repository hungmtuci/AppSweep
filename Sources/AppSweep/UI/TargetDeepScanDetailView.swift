import AppKit
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
            headerSummarySection
            Divider()

            if viewModel.isScanningTarget {
                VStack(spacing: 10) {
                    Spacer()
                    ProgressView()
                        .controlSize(.regular)
                    Text("Đang phân tích dữ liệu của \(target.name)...")
                        .font(.subheadline.weight(.medium))
                    Text("Kiểm tra Application Support, Containers, Caches, Preferences & LaunchAgents")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                presetAndStorageBar
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
            Button("Hủy", role: .cancel) {}
        } message: {
            Text(confirmDialogMessage)
        }
    }

    // MARK: - Top Inspector Header

    private var headerSummarySection: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(nsImage: viewModel.icon(for: target.path))
                .resizable()
                .interpolation(.high)
                .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(target.name)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)

                    Text(metadataInlineLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 8) {
                    if !target.bundleIdentifier.isEmpty {
                        Text(target.bundleIdentifier)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    if let team = target.teamIdentifier {
                        Text("· Team \(team)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }

                if target.kind == .application {
                    let running = viewModel.isRunning(target)
                    Text(target.detailedUsageSummary(isRunning: running))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 6) {
                    Text(target.displayPath)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Button("Hiện trong Finder") {
                        viewModel.revealInFinder(target.path)
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
                }
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 2) {
                Text(ByteFormatter.string(viewModel.totalDiscoveredBytes))
                    .font(.system(size: 20, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.primary)
                Text("\(viewModel.associatedItems.count) mục liên quan")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var metadataInlineLabel: String {
        var parts: [String] = ["v\(target.version)"]
        if target.architecture != .unknown {
            parts.append(target.architecture.rawValue)
        }
        if viewModel.isRunning(target) {
            parts.append("Đang mở")
        }
        if target.isSystemProtected {
            parts.append("Hệ thống bảo vệ")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Calm Tonal Storage Bar & Presets

    private var presetAndStorageBar: some View {
        VStack(alignment: .leading, spacing: 9) {
            if viewModel.totalDiscoveredBytes > 0 {
                GeometryReader { geo in
                    HStack(spacing: 1.5) {
                        ForEach(groupedCategories, id: \.category) { group in
                            let ratio = max(0.012, CGFloat(group.totalBytes) / CGFloat(max(1, viewModel.totalDiscoveredBytes)))
                            Rectangle()
                                .fill(group.category.storageSegmentColor)
                                .frame(width: max(3, (geo.size.width - CGFloat(groupedCategories.count) * 1.5) * ratio))
                                .help("\(group.category.title): \(ByteFormatter.string(group.totalBytes))")
                        }
                    }
                }
                .frame(height: 6)
                .background(Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 3))

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(groupedCategories, id: \.category) { group in
                            HStack(spacing: 5) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(group.category.storageSegmentColor)
                                    .frame(width: 7, height: 7)
                                Text("\(group.category.shortBadge) \(ByteFormatter.string(group.totalBytes))")
                                    .font(.system(size: 11).monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            HStack(spacing: 6) {
                Text("Chọn nhanh:")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)

                Button("Gỡ bỏ hoàn toàn") {
                    viewModel.applyPresetCompleteUninstall()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(target.isSystemProtected)

                Button("Chỉ xóa dữ liệu") {
                    viewModel.applyPresetResetAppDataOnly()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Chỉ dọn Cache & Logs") {
                    viewModel.applyPresetCachesAndLogsOnly()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                Button {
                    viewModel.rescanSelectedTarget()
                } label: {
                    Label("Quét lại", systemImage: "arrow.clockwise")
                        .font(.system(size: 11.5))
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    // MARK: - Native Inset Grouped File Sections

    private var associatedFilesScrollList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(groupedCategories, id: \.category) { group in
                    categorySection(category: group.category, items: group.items, categoryBytes: group.totalBytes)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
    }

    private func categorySection(
        category: FileCategory,
        items: [AssociatedFileItem],
        categoryBytes: Int64
    ) -> some View {
        let allSelected = items.allSatisfy(\.isSelected)

        return VStack(alignment: .leading, spacing: 5) {
            // Quiet macOS Group Header
            HStack(spacing: 7) {
                Toggle(
                    "",
                    isOn: Binding(
                        get: { allSelected },
                        set: { newValue in viewModel.setCategorySelection(category, selected: newValue) }
                    )
                )
                .toggleStyle(.checkbox)
                .labelsHidden()
                .controlSize(.small)

                Image(systemName: category.symbolName)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                Text(category.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)

                Text("(\(items.count))")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.tertiary)

                Spacer()

                Text(ByteFormatter.string(categoryBytes))
                    .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)

            // Inset Grouped Rows
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                    associatedFileRow(item)
                    if idx < items.count - 1 {
                        Divider()
                            .padding(.leading, 38)
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

    private func associatedFileRow(_ item: AssociatedFileItem) -> some View {
        let isLockedRootApp = target.isSystemProtected && item.path == target.path

        return HStack(spacing: 9) {
            Toggle(
                "",
                isOn: Binding(
                    get: { item.isSelected },
                    set: { _ in
                        if !isLockedRootApp {
                            viewModel.toggleItemSelection(item.id)
                        }
                    }
                )
            )
            .toggleStyle(.checkbox)
            .labelsHidden()
            .controlSize(.small)
            .disabled(isLockedRootApp)

            Image(nsImage: viewModel.icon(for: item.path))
                .resizable()
                .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 1.5) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .font(.system(size: 12.5))
                        .foregroundStyle(item.isSelected ? .primary : .secondary)
                        .lineLimit(1)

                    if item.confidence == .sharedVendor {
                        Text("Dùng chung")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
                    }

                    if item.requiresAdmin {
                        Image(systemName: "lock")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .help("Nằm trong thư mục hệ thống — cần xác thực Touch ID / Mật khẩu khi xóa")
                    }
                }

                Text(item.displayPath)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            Text(ByteFormatter.string(item.sizeBytes))
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(item.isSelected ? Color.secondary : Color(nsColor: .tertiaryLabelColor))

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
        .padding(.vertical, 6.5)
        .contentShape(Rectangle())
        .onTapGesture {
            if !isLockedRootApp {
                viewModel.toggleItemSelection(item.id)
            }
        }
    }

    // MARK: - Native Bottom Action Bar

    private var bottomActionFooter: some View {
        VStack(spacing: 8) {
            HStack(spacing: 14) {
                Picker("Chế độ:", selection: $viewModel.removalMode) {
                    ForEach(RemovalMode.allCases) { mode in
                        Text(mode.shortTitle).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .frame(width: 280)

                Toggle("Sao lưu .zip", isOn: $viewModel.createZipBackup)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .font(.system(size: 11.5))
                    .help("Lưu bản nén dự phòng vào ~/Downloads/AppSweep Backups trước khi xóa")

                if target.kind == .application {
                    Toggle("Gỡ khỏi Dock", isOn: $viewModel.cleanDockIcon)
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                        .font(.system(size: 11.5))
                }

                Spacer()
            }

            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 1.5) {
                    HStack(spacing: 6) {
                        Text("Đã chọn \(viewModel.selectedAssociatedItems.count)/\(viewModel.associatedItems.count) mục")
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                        if viewModel.selectedRequiresAdmin {
                            Text("· Cần xác thực quản trị viên")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(viewModel.removalMode == .moveToTrash
                         ? "Chuyển gọn vào Thùng rác, hỗ trợ Hoàn tác 1 chạm."
                         : "Xóa vĩnh viễn khỏi ổ đĩa và không thể hoàn tác.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if viewModel.removalMode == .permanentDelete {
                    Button(role: .destructive) {
                        viewModel.showUninstallConfirmation = true
                    } label: {
                        actionButtonLabel
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.regular)
                    .disabled(viewModel.selectedAssociatedItems.isEmpty || viewModel.isExecutingAction)
                } else {
                    Button {
                        viewModel.showUninstallConfirmation = true
                    } label: {
                        actionButtonLabel
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .disabled(viewModel.selectedAssociatedItems.isEmpty || viewModel.isExecutingAction)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 11)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var actionButtonLabel: some View {
        HStack(spacing: 6) {
            if viewModel.isExecutingAction {
                ProgressView()
                    .controlSize(.small)
            }
            Text("\(viewModel.removalMode == .moveToTrash ? "Chuyển vào Thùng rác" : "Xóa vĩnh viễn") (\(ByteFormatter.string(viewModel.selectedBytesToRemove)))")
                .font(.system(size: 12.5, weight: .medium).monospacedDigit())
        }
        .padding(.horizontal, 6)
    }

    // MARK: - Confirmation Dialog Copy

    private var confirmDialogTitle: String {
        let removingApp = viewModel.selectedAssociatedItems.contains { $0.path == target.path }
        return removingApp
            ? "Gỡ cài đặt \(target.name)?"
            : "Xóa dữ liệu đã chọn của \(target.name)?"
    }

    private var confirmPrimaryButtonLabel: String {
        let sizeText = ByteFormatter.string(viewModel.selectedBytesToRemove)
        return viewModel.removalMode == .moveToTrash
            ? "Chuyển vào Thùng rác (\(sizeText))"
            : "Xóa vĩnh viễn (\(sizeText))"
    }

    private var confirmDialogMessage: String {
        var parts: [String] = []
        if viewModel.isRunning(target) {
            parts.append("\(target.name) đang mở và sẽ được đóng trước khi gỡ.")
        }
        parts.append("Tổng cộng \(viewModel.selectedAssociatedItems.count) mục (\(ByteFormatter.string(viewModel.selectedBytesToRemove))).")
        if viewModel.createZipBackup {
            parts.append("Tự động tạo bản sao lưu .zip trong ~/Downloads/AppSweep Backups.")
        }
        if viewModel.removalMode == .moveToTrash {
            parts.append("Bạn có thể khôi phục lại từ mục Lịch sử & Hoàn tác.")
        } else {
            parts.append("Thao tác xóa vĩnh viễn không thể khôi phục.")
        }
        return parts.joined(separator: "\n")
    }
}
