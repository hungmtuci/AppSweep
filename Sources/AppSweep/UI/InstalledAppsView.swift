import SwiftUI

struct InstalledAppsView: View {
    @ObservedObject var viewModel: MainViewModel

    private var checkedCount: Int {
        viewModel.activeCheckedTargets.count
    }

    var body: some View {
        HSplitView {
            leftAppCatalogPane
                .frame(minWidth: 315, idealWidth: 355, maxWidth: 430)

            rightDetailPane
                .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Left App List

    private var leftAppCatalogPane: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                // 1. Search Bar
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Tìm tên ứng dụng hoặc Bundle ID...", text: $viewModel.searchQuery)
                        .textFieldStyle(.plain)
                    if !viewModel.searchQuery.isEmpty {
                        Button {
                            viewModel.searchQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                )

                // 2. 1-Click Usage Level Quick Pills
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(AppUsageFilter.allCases) { uFilter in
                            usageFilterPill(uFilter)
                        }
                    }
                    .padding(.vertical, 1)
                }

                // 3. Flat Filter & Sort Menus (no nested submenus!)
                HStack(spacing: 6) {
                    Menu {
                        Section("Mức độ sử dụng") {
                            ForEach(AppUsageFilter.allCases) { uFilter in
                                Button {
                                    viewModel.usageFilter = uFilter
                                } label: {
                                    HStack {
                                        if viewModel.usageFilter == uFilter {
                                            Image(systemName: "checkmark")
                                        }
                                        Text("\(uFilter.title) (\(viewModel.countForUsageFilter(uFilter)))")
                                    }
                                }
                            }
                        }

                        Divider()

                        Section("Phạm vi ứng dụng") {
                            ForEach(AppFilterScope.allCases) { scope in
                                Button {
                                    viewModel.filterScope = scope
                                } label: {
                                    HStack {
                                        if viewModel.filterScope == scope {
                                            Image(systemName: "checkmark")
                                        }
                                        Text(scope.rawValue)
                                    }
                                }
                            }
                        }
                    } label: {
                        Label(activeFilterMenuLabel, systemImage: "line.3.horizontal.decrease.circle")
                            .font(.caption)
                            .lineLimit(1)
                    }
                    .controlSize(.small)

                    Menu {
                        ForEach(AppSortOrder.allCases) { order in
                            Button {
                                viewModel.sortOrder = order
                            } label: {
                                HStack {
                                    if viewModel.sortOrder == order {
                                        Image(systemName: "checkmark")
                                    }
                                    Text(order.rawValue)
                                }
                            }
                        }
                    } label: {
                        Label(viewModel.sortOrder.rawValue, systemImage: "arrow.up.arrow.down")
                            .font(.caption)
                            .lineLimit(1)
                    }
                    .controlSize(.small)

                    Spacer()

                    Button {
                        viewModel.reloadAllCatalogs()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .help("Làm mới danh sách ứng dụng & thống kê sử dụng")
                }

                // 4. Count + Multi-Selection Control Strip
                HStack(spacing: 6) {
                    if viewModel.isMultiSelectMode || checkedCount > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color.accentColor)
                            Text("Đã chọn \(checkedCount)")
                                .fontWeight(.semibold)
                        }
                        .font(.caption2)

                        Spacer()

                        Button("Chọn hết (\(viewModel.filteredApps.filter { !$0.isSystemProtected }.count))") {
                            viewModel.selectAllVisibleTargets(viewModel.filteredApps)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)

                        Button("Bỏ chọn") {
                            viewModel.exitMultiSelectMode()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    } else {
                        let totalBytes = viewModel.filteredAppsTotalBytes
                        Text(totalBytes > 0
                             ? "\(viewModel.filteredApps.count) ứng dụng • \(ByteFormatter.string(totalBytes))"
                             : "\(viewModel.filteredApps.count) ứng dụng")
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        if viewModel.isCalculatingAppSizes {
                            ProgressView()
                                .controlSize(.mini)
                        }

                        Spacer()

                        Button {
                            viewModel.toggleMultiSelectMode()
                        } label: {
                            Label("Chọn nhiều", systemImage: "checklist")
                                .font(.caption2.weight(.medium))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .help("Tích chọn nhiều ứng dụng cùng lúc (hoặc giữ phím ⌘ / ⇧ khi bấm vào dòng)")
                    }
                }
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))

            Divider()

            if viewModel.isLoadingCatalog {
                VStack(spacing: 10) {
                    Spacer()
                    ProgressView()
                    Text("Đang quét ứng dụng & lịch sử sử dụng...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.filteredApps.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: viewModel.usageFilter.symbolName)
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("Không có ứng dụng nào ở nhóm này")
                        .font(.subheadline.weight(.medium))
                    if viewModel.usageFilter != .all || viewModel.filterScope != .all || !viewModel.searchQuery.isEmpty {
                        Button("Đặt lại bộ lọc về Tất cả") {
                            viewModel.usageFilter = .all
                            viewModel.filterScope = .all
                            viewModel.searchQuery = ""
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(viewModel.filteredApps) { app in
                            appRow(app)
                        }
                    }
                    .padding(8)
                }
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.35))
    }

    private var activeFilterMenuLabel: String {
        if viewModel.usageFilter != .all && viewModel.filterScope != .all {
            return "\(viewModel.usageFilter.pillTitle) • \(viewModel.filterScope.rawValue)"
        }
        if viewModel.usageFilter != .all {
            return viewModel.usageFilter.pillTitle
        }
        return viewModel.filterScope.rawValue
    }

    private func usageFilterPill(_ uFilter: AppUsageFilter) -> some View {
        let isActive = (viewModel.usageFilter == uFilter)
        let count = viewModel.countForUsageFilter(uFilter)

        return Button {
            viewModel.usageFilter = uFilter
            // Auto-switch to "Ít dùng / Lâu nhất chưa mở" when user picks cleanup/unused filters if still on default A->Z
            if (uFilter == .suggestedCleanup || uFilter == .dormant90Days || uFilter == .rarelyUsed) && viewModel.sortOrder == .nameAsc {
                viewModel.sortOrder = .leastUsedFirst
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: uFilter.symbolName)
                    .font(.system(size: 9.5, weight: .semibold))
                Text("\(uFilter.pillTitle) \(count)")
                    .font(.system(size: 11, weight: isActive ? .semibold : .medium))
            }
            .foregroundStyle(isActive ? Color.white : Color.primary.opacity(0.82))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(isActive ? uFilter.tintColor : Color.secondary.opacity(0.12))
            )
        }
        .buttonStyle(.plain)
        .help(uFilter.title)
    }

    private func appRow(_ app: TargetBundle) -> some View {
        let isChecked = viewModel.isTargetChecked(app)
        let isFocusedSingle = !viewModel.isMultiSelectMode && checkedCount == 0 && (viewModel.selectedTarget?.path == app.path)
        let running = viewModel.isRunning(app)
        let level = app.usageLevel(isRunning: running)
        let usageText = app.shortUsageSummary(isRunning: running)

        return HStack(spacing: 9) {
            if app.isSystemProtected {
                Image(systemName: "lock.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(isFocusedSingle ? .white.opacity(0.75) : .secondary.opacity(0.5))
                    .frame(width: 16)
                    .help("Ứng dụng được bảo vệ")
            } else {
                Button {
                    viewModel.toggleCheckForTarget(app)
                } label: {
                    Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(
                            isChecked
                            ? Color.accentColor
                            : (isFocusedSingle ? Color.white.opacity(0.85) : Color.secondary.opacity(0.65))
                        )
                        .frame(width: 16)
                }
                .buttonStyle(.plain)
                .help("Tích để đưa \(app.name) vào danh sách xóa hàng loạt")
            }

            ZStack(alignment: .bottomTrailing) {
                Image(nsImage: viewModel.icon(for: app.path))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 34, height: 34)

                if running {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 8, height: 8)
                        .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                    .font(.system(size: 13, weight: (isFocusedSingle || isChecked) ? .semibold : .medium))
                    .foregroundStyle(isFocusedSingle ? .white : .primary)
                    .lineLimit(1)

                Text(app.bundleIdentifier.isEmpty ? app.displayPath : app.bundleIdentifier)
                    .font(.system(size: 10.5))
                    .foregroundStyle(isFocusedSingle ? .white.opacity(0.8) : .secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 2) {
                if let size = app.bundleSizeBytes {
                    Text(ByteFormatter.string(size))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(isFocusedSingle ? .white.opacity(0.95) : .primary.opacity(0.85))
                }

                Text(usageText)
                    .font(.system(size: 9.5, weight: (level == .neverUsed || level == .dormant) ? .semibold : .regular))
                    .foregroundStyle(usageLabelColor(level: level, isFocusedSingle: isFocusedSingle))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(
                    isFocusedSingle
                    ? Color.accentColor
                    : (isChecked ? Color.accentColor.opacity(0.14) : Color.clear)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isChecked ? Color.accentColor.opacity(0.45) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.handleTargetRowClick(app, in: viewModel.filteredApps)
        }
    }

    private func usageLabelColor(level: AppUsageLevel, isFocusedSingle: Bool) -> Color {
        if isFocusedSingle {
            return .white.opacity(0.88)
        }
        switch level {
        case .neverUsed:
            return .red.opacity(0.88)
        case .dormant:
            return .orange
        case .rarelyUsed:
            return .secondary
        case .frequent:
            return .green.opacity(0.85)
        }
    }

    // MARK: - Right Detail Pane

    @ViewBuilder
    private var rightDetailPane: some View {
        if viewModel.isMultiSelectMode || checkedCount > 0 {
            BatchUninstallDetailView(viewModel: viewModel)
        } else if let selected = viewModel.selectedTarget, selected.kind == .application {
            TargetDeepScanDetailView(viewModel: viewModel, target: selected)
        } else {
            VStack(spacing: 14) {
                Image(systemName: "app.dashed")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("Chọn một hoặc nhiều ứng dụng ở cột bên trái")
                    .font(.title3.weight(.semibold))
                Text("Dùng các thẻ lọc Mức độ sử dụng (Gợi ý dọn, Chưa mở, >90 ngày) ở trên để nhanh chóng tìm ứng dụng không còn dùng tới.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 430)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
