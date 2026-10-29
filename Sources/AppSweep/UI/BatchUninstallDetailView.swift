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
                batchHeaderCard
                Divider()
                batchPresetAndBreakdownBar
                Divider()
                batchAppsScrollList
                Divider()
                batchBottomFooter
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .confirmationDialog(
                "Xác nhận gỡ hàng loạt \(targets.count) mục đã chọn?",
                isPresented: $viewModel.showBatchUninstallConfirmation,
                titleVisibility: .visible
            ) {
                Button(
                    "\(viewModel.removalMode == .moveToTrash ? "Chuyển vào Thùng rác" : "Xóa vĩnh viễn") (\(targets.count) mục • \(ByteFormatter.string(viewModel.batchSelectedBytesToRemove)))",
                    role: .destructive
                ) {
                    viewModel.executeBatchUninstall()
                }
                Button("Hủy bỏ", role: .cancel) {}
            } message: {
                Text(batchConfirmMessage)
            }
        }
    }

    // MARK: - Empty Multi-Select Prompt

    private var emptySelectionPrompt: some View {
        VStack(spacing: 14) {
            Image(systemName: "checklist.checked")
                .font(.system(size: 50))
                .foregroundStyle(Color.accentColor)
            Text("Chế độ chọn nhiều đang bật")
                .font(.title3.weight(.bold))
            Text("Tích vào ô vuông cạnh các ứng dụng ở cột bên trái (hoặc giữ phím ⌘ Command / ⇧ Shift khi nhấp chuột) để gom và gỡ sạch nhiều ứng dụng cùng lúc.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)

            Button {
                viewModel.exitMultiSelectMode()
            } label: {
                Label("Quay lại chế độ chọn đơn", systemImage: "xmark.circle")
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Top Summary Card

    private var batchHeaderCard: some View {
        let runningCount = targets.filter { viewModel.isRunning($0) }.count
        let selectedItemCount = viewModel.batchAllSelectedItemsDeduplicated.count

        return HStack(alignment: .center, spacing: 16) {
            // Overlapping App Icon Cluster
            HStack(spacing: -14) {
                ForEach(Array(targets.prefix(5).enumerated()), id: \.element.id) { idx, bundle in
                    Image(nsImage: viewModel.icon(for: bundle.path))
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 48, height: 48)
                        .background(
                            RoundedRectangle(cornerRadius: 11)
                                .fill(Color(nsColor: .windowBackgroundColor))
                        )
                        .shadow(color: .black.opacity(0.16), radius: 3, y: 1)
                        .zIndex(Double(10 - idx))
                }

                if targets.count > 5 {
                    ZStack {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 40, height: 40)
                        Text("+\(targets.count - 5)")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                    }
                    .padding(.leading, 6)
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text("Đã chọn \(targets.count) mục để gỡ hàng loạt")
                        .font(.title3.weight(.bold))

                    if viewModel.isScanningAnyCheckedTarget {
                        HStack(spacing: 5) {
                            ProgressView()
                                .controlSize(.mini)
                            Text("Đang quét...")
                        }
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.blue)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.12), in: Capsule())
                    }

                    if runningCount > 0 {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 6, height: 6)
                            Text("\(runningCount) đang chạy")
                        }
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.green)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.12), in: Capsule())
                    }
                }

                Text(targets.map(\.name).joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                HStack(spacing: 12) {
                    Text("Tổng cộng \(selectedItemCount) file & thư mục liên quan được chọn")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button {
                        viewModel.exitMultiSelectMode()
                    } label: {
                        Text("Bỏ chọn tất cả")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.link)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text("Tổng dung lượng sẽ giải phóng")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(ByteFormatter.string(viewModel.batchSelectedBytesToRemove))
                    .font(.system(size: 23, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                Text("trên tổng \(ByteFormatter.string(viewModel.batchTotalDiscoveredBytes)) phát hiện")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 15)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
    }

    // MARK: - Combined Breakdown & Batch Presets

    private var batchPresetAndBreakdownBar: some View {
        let totalSelectedBytes = max(1, viewModel.batchSelectedBytesToRemove)

        return VStack(alignment: .leading, spacing: 10) {
            if !combinedCategories.isEmpty {
                GeometryReader { geo in
                    HStack(spacing: 2) {
                        ForEach(combinedCategories, id: \.category) { group in
                            let ratio = max(0.015, CGFloat(group.totalBytes) / CGFloat(totalSelectedBytes))
                            RoundedRectangle(cornerRadius: 3)
                                .fill(group.category.accentColor.gradient)
                                .frame(width: max(4, (geo.size.width - CGFloat(combinedCategories.count * 2)) * ratio))
                                .help("\(group.category.title): \(ByteFormatter.string(group.totalBytes))")
                        }
                    }
                }
                .frame(height: 8)
                .clipShape(Capsule())

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(combinedCategories, id: \.category) { group in
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

            HStack(spacing: 8) {
                Text("Áp dụng cho cả loạt:")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

                Button {
                    viewModel.applyBatchPresetComplete()
                } label: {
                    Label("Gỡ bỏ hoàn toàn", systemImage: "trash.circle")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    viewModel.applyBatchPresetResetDataOnly()
                } label: {
                    Label("Chỉ xóa dữ liệu (Reset các App)", systemImage: "arrow.counterclockwise.circle")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    viewModel.applyBatchPresetCachesOnly()
                } label: {
                    Label("Chỉ dọn Cache & Logs", systemImage: "bolt.circle")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                Button {
                    viewModel.rescanAllCheckedTargets()
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

    // MARK: - Per-App Expandable Cards

    private var batchAppsScrollList: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(targets) { bundle in
                    batchAppCard(bundle)
                }
            }
            .padding(18)
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
            // Card Header
            HStack(spacing: 12) {
                Image(nsImage: viewModel.icon(for: bundle.path))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(bundle.name)
                            .font(.system(size: 14, weight: .bold))
                            .lineLimit(1)

                        Text("v\(bundle.version)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.13), in: Capsule())

                        if viewModel.isRunning(bundle) {
                            Text("Đang chạy")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.green)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Color.green.opacity(0.12), in: Capsule())
                        }

                        if needsAdmin {
                            HStack(spacing: 3) {
                                Image(systemName: "lock.fill")
                                Text("Admin")
                            }
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                        }
                    }

                    if isScanning {
                        HStack(spacing: 5) {
                            ProgressView()
                                .controlSize(.mini)
                            Text("Đang dò tìm các file liên quan...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("\(bundle.bundleIdentifier.isEmpty ? bundle.displayPath : bundle.bundleIdentifier)  •  Đã chọn \(selectedItems.count) / \(items.count) mục")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                if !isScanning {
                    Text(ByteFormatter.string(selectedBytes))
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(.primary)

                    Button {
                        viewModel.toggleBatchExpand(appPath: bundle.path)
                    } label: {
                        HStack(spacing: 4) {
                            Text(isExpanded ? "Thu gọn" : "Chi tiết")
                                .font(.caption.weight(.medium))
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.caption2.weight(.semibold))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    viewModel.toggleCheckForTarget(bundle)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Bỏ \(bundle.name) khỏi danh sách chọn nhiều")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
            .onTapGesture {
                if !isScanning {
                    viewModel.toggleBatchExpand(appPath: bundle.path)
                }
            }

            // Expanded Sub-items
            if isExpanded && !items.isEmpty {
                Divider()
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                        batchSubItemRow(appPath: bundle.path, item: item)
                        if idx < items.count - 1 {
                            Divider()
                                .padding(.leading, 40)
                        }
                    }
                }
                .background(Color(nsColor: .windowBackgroundColor).opacity(0.45))
            }
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 11))
        .overlay(
            RoundedRectangle(cornerRadius: 11)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private func batchSubItemRow(appPath: String, item: AssociatedFileItem) -> some View {
        HStack(spacing: 10) {
            Button {
                viewModel.toggleBatchAssociatedItem(appPath: appPath, itemID: item.id)
            } label: {
                Image(systemName: item.isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(item.isSelected ? Color.accentColor : Color.secondary)
                    .font(.system(size: 14))
            }
            .buttonStyle(.plain)

            Image(nsImage: viewModel.icon(for: item.path))
                .resizable()
                .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)

                    Text(item.category.shortBadge)
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(item.category.accentColor)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(item.category.accentColor.opacity(0.12), in: Capsule())

                    if item.requiresAdmin {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                    }
                }

                Text(item.displayPath)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Text(ByteFormatter.string(item.sizeBytes))
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(item.isSelected ? .primary : .secondary)

            Button {
                viewModel.revealInFinder(item.path)
            } label: {
                Image(systemName: "magnifyingglass.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Hiển thị trong Finder")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.toggleBatchAssociatedItem(appPath: appPath, itemID: item.id)
        }
    }

    // MARK: - Bottom Action Bar

    private var batchBottomFooter: some View {
        let totalSelectedItems = viewModel.batchAllSelectedItemsDeduplicated.count

        return VStack(spacing: 10) {
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

                Toggle("Sao lưu .zip từng ứng dụng", isOn: $viewModel.createZipBackup)
                    .toggleStyle(.checkbox)
                    .font(.caption)

                Toggle("Gỡ icon khỏi Dock", isOn: $viewModel.cleanDockIcon)
                    .toggleStyle(.checkbox)
                    .font(.caption)

                Spacer()
            }

            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("Sẵn sàng gỡ \(targets.count) ứng dụng (\(totalSelectedItems) mục)")
                            .font(.subheadline.weight(.semibold))
                        if viewModel.batchRequiresAdmin {
                            Label("Xác thực Touch ID / Admin gộp 1 lần duy nhất", systemImage: "touchid")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    Text(viewModel.removalMode == .moveToTrash
                         ? "Mỗi ứng dụng được lưu thành gói riêng trong Trash — bạn có thể Hoàn tác lẻ từng ứng dụng bất kỳ."
                         : "Cảnh báo: File xóa vĩnh viễn sẽ không đi qua Thùng rác và không thể khôi phục.")
                        .font(.caption)
                        .foregroundStyle(viewModel.removalMode == .moveToTrash ? Color.secondary : Color.red)
                }

                Spacer()

                Button {
                    viewModel.showBatchUninstallConfirmation = true
                } label: {
                    HStack(spacing: 8) {
                        if viewModel.isExecutingAction {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: viewModel.removalMode == .moveToTrash ? "trash.fill" : "xmark.bin.fill")
                        }
                        Text("\(viewModel.removalMode == .moveToTrash ? "Gỡ \(targets.count) ứng dụng" : "Xóa vĩnh viễn \(targets.count) mục") (\(ByteFormatter.string(viewModel.batchSelectedBytesToRemove)))")
                            .fontWeight(.semibold)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(viewModel.removalMode == .moveToTrash ? .red : .pink)
                .controlSize(.large)
                .disabled(totalSelectedItems == 0 || viewModel.isExecutingAction || viewModel.isScanningAnyCheckedTarget)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var batchConfirmMessage: String {
        var lines: [String] = [
            "• Ứng dụng đã chọn (\(targets.count)): \(targets.prefix(6).map(\.name).joined(separator: ", "))\(targets.count > 6 ? "..." : "")",
            "• Tổng cộng \(viewModel.batchAllSelectedItemsDeduplicated.count) file & thư mục (\(ByteFormatter.string(viewModel.batchSelectedBytesToRemove)))."
        ]
        if viewModel.batchRequiresAdmin {
            lines.append("• Chỉ cần xác thực Touch ID / Mật khẩu Quản trị viên 1 lần duy nhất cho toàn bộ danh sách.")
        }
        if viewModel.removalMode == .moveToTrash {
            lines.append("• Có thể Hoàn tác khôi phục từng ứng dụng riêng lẻ trong tab Lịch sử & Hoàn tác.")
        } else {
            lines.append("• Hành động xóa vĩnh viễn KHÔNG THỂ khôi phục.")
        }
        return lines.joined(separator: "\n")
    }
}
