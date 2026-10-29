import AppKit
import SwiftUI

struct BatchUninstallDetailView: View {
    @ObservedObject var viewModel: MainViewModel

    private var targets: [TargetBundle] {
        viewModel.activeCheckedTargets
    }

    private var combinedCategories: [(category: FileCategory, totalBytes: Int64)] {
        var seen = Set<String>()
        var sums: [FileCategory: Int64] = [:]
        for bundle in targets {
            for item in (viewModel.batchItemsByAppPath[bundle.path] ?? []) where item.isSelected {
                if seen.insert(item.path).inserted {
                    sums[item.category, default: 0] += item.sizeBytes
                }
            }
        }
        return sums.keys
            .sorted { $0.sortPriority < $1.sortPriority }
            .compactMap { cat in
                let val = sums[cat] ?? 0
                return val > 0 ? (cat, val) : nil
            }
    }

    var body: some View {
        if targets.isEmpty {
            emptySelectionPrompt
        } else {
            VStack(spacing: 0) {
                batchHeaderSection
                Divider()
                batchPresetAndStorageBar
                Divider()
                batchAppsScrollList
                Divider()
                batchBottomFooter
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .confirmationDialog(
                "Gỡ cài đặt \(targets.count) mục đã chọn?",
                isPresented: $viewModel.showBatchUninstallConfirmation,
                titleVisibility: .visible
            ) {
                Button(
                    "\(viewModel.removalMode == .moveToTrash ? "Chuyển vào Thùng rác" : "Xóa vĩnh viễn") (\(targets.count) mục · \(ByteFormatter.string(viewModel.batchSelectedBytesToRemove)))",
                    role: .destructive
                ) {
                    viewModel.executeBatchUninstall()
                }
                Button("Hủy", role: .cancel) {}
            } message: {
                Text(batchConfirmMessage)
            }
        }
    }

    // MARK: - Empty Multi-Select Prompt

    private var emptySelectionPrompt: some View {
        VStack(spacing: 10) {
            Image(systemName: "checklist")
                .font(.system(size: 36, weight: .ultraLight))
                .foregroundStyle(.tertiary)
            Text("Chế độ chọn nhiều")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Tích chọn các ứng dụng ở danh sách bên trái (hoặc giữ phím ⌘ / ⇧ khi nhấp) để xem dung lượng và gỡ hàng loạt.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            Button("Thoát chọn nhiều") {
                viewModel.exitMultiSelectMode()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Header Summary

    private var batchHeaderSection: some View {
        let runningCount = targets.filter { viewModel.isRunning($0) }.count
        let selectedItemCount = viewModel.batchAllSelectedItemsDeduplicated.count

        return HStack(alignment: .center, spacing: 14) {
            HStack(spacing: -12) {
                ForEach(Array(targets.prefix(4).enumerated()), id: \.element.id) { idx, bundle in
                    Image(nsImage: viewModel.icon(for: bundle.path))
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 42, height: 42)
                        .zIndex(Double(10 - idx))
                }

                if targets.count > 4 {
                    Text("+\(targets.count - 4)")
                        .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 34, height: 34)
                        .background(Color(nsColor: .controlBackgroundColor), in: Circle())
                        .overlay(Circle().stroke(Color(nsColor: .separatorColor), lineWidth: 1))
                        .padding(.leading, 6)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("Đã chọn \(targets.count) ứng dụng")
                        .font(.title3.weight(.semibold))

                    if viewModel.isScanningAnyCheckedTarget {
                        HStack(spacing: 4) {
                            ProgressView()
                                .controlSize(.mini)
                            Text("Đang quét...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if runningCount > 0 {
                        Text("· \(runningCount) đang mở")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Text(targets.map(\.name).joined(separator: ", "))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                HStack(spacing: 10) {
                    Text("\(selectedItemCount) tệp & thư mục liên quan")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)

                    Button("Bỏ chọn tất cả") {
                        viewModel.exitMultiSelectMode()
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
                }
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 2) {
                Text(ByteFormatter.string(viewModel.batchSelectedBytesToRemove))
                    .font(.system(size: 20, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.primary)
                Text("trên tổng \(ByteFormatter.string(viewModel.batchTotalDiscoveredBytes))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Tonal Breakdown & Presets

    private var batchPresetAndStorageBar: some View {
        let totalSelectedBytes = max(1, viewModel.batchSelectedBytesToRemove)

        return VStack(alignment: .leading, spacing: 9) {
            if !combinedCategories.isEmpty {
                GeometryReader { geo in
                    HStack(spacing: 1.5) {
                        ForEach(combinedCategories, id: \.category) { group in
                            let ratio = max(0.012, CGFloat(group.totalBytes) / CGFloat(totalSelectedBytes))
                            Rectangle()
                                .fill(group.category.storageSegmentColor)
                                .frame(width: max(3, (geo.size.width - CGFloat(combinedCategories.count) * 1.5) * ratio))
                                .help("\(group.category.title): \(ByteFormatter.string(group.totalBytes))")
                        }
                    }
                }
                .frame(height: 6)
                .background(Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 3))

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(combinedCategories, id: \.category) { group in
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
                    viewModel.applyBatchPresetComplete()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Chỉ xóa dữ liệu") {
                    viewModel.applyBatchPresetResetDataOnly()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Chỉ dọn Cache & Logs") {
                    viewModel.applyBatchPresetCachesOnly()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                Button {
                    viewModel.rescanAllCheckedTargets()
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

    // MARK: - Per-App Disclosure Cards

    private var batchAppsScrollList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(targets) { bundle in
                    batchAppCard(bundle)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
    }

    private func batchAppCard(_ bundle: TargetBundle) -> some View {
        let items = viewModel.batchItemsByAppPath[bundle.path] ?? []
        let isScanning = viewModel.scanningBatchPaths.contains(bundle.path)
        let isExpanded = viewModel.expandedBatchAppPaths.contains(bundle.path)
        let selectedItems = items.filter(\.isSelected)
        let selectedBytes = selectedItems.reduce(Int64(0)) { $0 + $1.sizeBytes }
        let needsAdmin = selectedItems.contains(where: \.requiresAdmin)

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 12)

                Image(nsImage: viewModel.icon(for: bundle.path))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(bundle.name)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)

                        Text("v\(bundle.version)")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)

                        if viewModel.isRunning(bundle) {
                            Text("· Đang mở")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }

                        if needsAdmin {
                            Image(systemName: "lock")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                                .help("Có mục nằm trong thư mục hệ thống")
                        }
                    }

                    if isScanning {
                        HStack(spacing: 5) {
                            ProgressView()
                                .controlSize(.mini)
                            Text("Đang tìm tệp liên quan...")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Đã chọn \(selectedItems.count)/\(items.count) mục · \(bundle.bundleIdentifier.isEmpty ? bundle.displayPath : bundle.bundleIdentifier)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                if !isScanning {
                    Text(ByteFormatter.string(selectedBytes))
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Button {
                    viewModel.toggleCheckForTarget(bundle)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .help("Bỏ \(bundle.name) khỏi danh sách chọn")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
            .onTapGesture {
                if !isScanning {
                    viewModel.toggleBatchExpand(appPath: bundle.path)
                }
            }

            if isExpanded && !items.isEmpty {
                Divider()
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                        batchSubItemRow(appPath: bundle.path, item: item)
                        if idx < items.count - 1 {
                            Divider()
                                .padding(.leading, 42)
                        }
                    }
                }
                .background(Color(nsColor: .windowBackgroundColor).opacity(0.4))
            }
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }

    private func batchSubItemRow(appPath: String, item: AssociatedFileItem) -> some View {
        HStack(spacing: 9) {
            Toggle(
                "",
                isOn: Binding(
                    get: { item.isSelected },
                    set: { _ in viewModel.toggleBatchAssociatedItem(appPath: appPath, itemID: item.id) }
                )
            )
            .toggleStyle(.checkbox)
            .labelsHidden()
            .controlSize(.small)

            Image(nsImage: viewModel.icon(for: item.path))
                .resizable()
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .font(.system(size: 12))
                        .foregroundStyle(item.isSelected ? .primary : .secondary)
                        .lineLimit(1)

                    Text(item.category.shortBadge)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)

                    if item.requiresAdmin {
                        Image(systemName: "lock")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                    }
                }

                Text(item.displayPath)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Text(ByteFormatter.string(item.sizeBytes))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)

            Button {
                viewModel.revealInFinder(item.path)
            } label: {
                Image(systemName: "arrow.forward.circle")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Hiện trong Finder")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5.5)
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.toggleBatchAssociatedItem(appPath: appPath, itemID: item.id)
        }
    }

    // MARK: - Bottom Action Bar

    private var batchBottomFooter: some View {
        let totalSelectedItems = viewModel.batchAllSelectedItemsDeduplicated.count
        let isDisabled = totalSelectedItems == 0 || viewModel.isExecutingAction || viewModel.isScanningAnyCheckedTarget

        return VStack(spacing: 8) {
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

                Toggle("Gỡ khỏi Dock", isOn: $viewModel.cleanDockIcon)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .font(.system(size: 11.5))

                Spacer()
            }

            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 1.5) {
                    HStack(spacing: 6) {
                        Text("\(targets.count) ứng dụng (\(totalSelectedItems) mục)")
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                        if viewModel.batchRequiresAdmin {
                            Text("· Xác thực quản trị gộp 1 lần")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(viewModel.removalMode == .moveToTrash
                         ? "Lưu thành từng gói riêng trong Thùng rác để có thể hoàn tác lẻ."
                         : "Xóa vĩnh viễn khỏi ổ đĩa và không thể hoàn tác.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if viewModel.removalMode == .permanentDelete {
                    Button(role: .destructive) {
                        viewModel.showBatchUninstallConfirmation = true
                    } label: {
                        batchActionLabel
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.regular)
                    .disabled(isDisabled)
                } else {
                    Button {
                        viewModel.showBatchUninstallConfirmation = true
                    } label: {
                        batchActionLabel
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .disabled(isDisabled)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 11)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var batchActionLabel: some View {
        HStack(spacing: 6) {
            if viewModel.isExecutingAction {
                ProgressView()
                    .controlSize(.small)
            }
            Text("\(viewModel.removalMode == .moveToTrash ? "Chuyển \(targets.count) ứng dụng vào Thùng rác" : "Xóa vĩnh viễn \(targets.count) mục") (\(ByteFormatter.string(viewModel.batchSelectedBytesToRemove)))")
                .font(.system(size: 12.5, weight: .medium).monospacedDigit())
        }
        .padding(.horizontal, 6)
    }

    private var batchConfirmMessage: String {
        var lines: [String] = [
            "Ứng dụng (\(targets.count)): \(targets.prefix(6).map(\.name).joined(separator: ", "))\(targets.count > 6 ? "..." : "")",
            "Tổng cộng \(viewModel.batchAllSelectedItemsDeduplicated.count) tệp & thư mục (\(ByteFormatter.string(viewModel.batchSelectedBytesToRemove)))."
        ]
        if viewModel.batchRequiresAdmin {
            lines.append("Chỉ yêu cầu xác thực Touch ID / Mật khẩu Quản trị viên 1 lần duy nhất.")
        }
        if viewModel.removalMode == .moveToTrash {
            lines.append("Có thể khôi phục từng ứng dụng riêng lẻ trong mục Lịch sử & Hoàn tác.")
        } else {
            lines.append("Thao tác xóa vĩnh viễn không thể khôi phục.")
        }
        return lines.joined(separator: "\n")
    }
}
