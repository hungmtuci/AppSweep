import AppKit
import SwiftUI

struct InstalledAppsView: View {
    @ObservedObject var viewModel: MainViewModel

    private var checkedCount: Int {
        viewModel.activeCheckedTargets.count
    }

    var body: some View {
        HSplitView {
            leftAppCatalogPane
                .frame(minWidth: 310, idealWidth: 345, maxWidth: 420)

            rightDetailPane
                .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Left App Catalog Pane

    private var leftAppCatalogPane: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                // 1. Native macOS Search Field
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    TextField("Tìm ứng dụng hoặc Bundle ID", text: $viewModel.searchQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                    if !viewModel.searchQuery.isEmpty {
                        Button {
                            viewModel.searchQuery = ""
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

                // 2. macOS Scope Bar for Usage Level (Monochrome, non-gaudy)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(AppUsageFilter.allCases) { uFilter in
                            usageScopeTab(uFilter)
                        }
                    }
                    .padding(.vertical, 1)
                }

                // 3. Filter & Sort Menus
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
                        Label(activeFilterMenuLabel, systemImage: "line.3.horizontal.decrease")
                            .font(.system(size: 11.5))
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
                            .font(.system(size: 11.5))
                            .lineLimit(1)
                    }
                    .controlSize(.small)

                    Spacer(minLength: 2)

                    Button {
                        viewModel.reloadAllCatalogs()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11.5))
                    }
                    .buttonStyle(.borderless)
                    .help("Làm mới danh sách ứng dụng (⌘R)")
                }

                // 4. Summary & Multi-Selection Strip
                HStack(spacing: 6) {
                    if viewModel.isMultiSelectMode || checkedCount > 0 {
                        Text("Đã chọn \(checkedCount) ứng dụng")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.primary)

                        Spacer()

                        Button("Chọn hết") {
                            viewModel.selectAllVisibleTargets(viewModel.filteredApps)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)

                        Button("Xong") {
                            viewModel.exitMultiSelectMode()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    } else {
                        let totalBytes = viewModel.filteredAppsTotalBytes
                        Text(totalBytes > 0
                             ? "\(viewModel.filteredApps.count) ứng dụng · \(ByteFormatter.string(totalBytes))"
                             : "\(viewModel.filteredApps.count) ứng dụng")
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)

                        if viewModel.isCalculatingAppSizes {
                            ProgressView()
                                .controlSize(.mini)
                        }

                        Spacer()

                        Button("Chọn nhiều") {
                            viewModel.toggleMultiSelectMode()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .help("Chọn nhiều ứng dụng cùng lúc (hoặc giữ phím ⌘ / ⇧ khi nhấp vào dòng)")
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            if viewModel.isLoadingCatalog {
                VStack(spacing: 8) {
                    Spacer()
                    ProgressView()
                        .controlSize(.regular)
                    Text("Đang tải danh sách ứng dụng...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.filteredApps.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: viewModel.usageFilter.symbolName)
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("Không có ứng dụng phù hợp")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                    if viewModel.usageFilter != .all || viewModel.filterScope != .all || !viewModel.searchQuery.isEmpty {
                        Button("Xóa bộ lọc") {
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
                    LazyVStack(spacing: 1) {
                        ForEach(viewModel.filteredApps) { app in
                            appRow(app)
                        }
                    }
                    .padding(6)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var activeFilterMenuLabel: String {
        if viewModel.usageFilter != .all && viewModel.filterScope != .all {
            return "\(viewModel.usageFilter.pillTitle) · \(viewModel.filterScope.rawValue)"
        }
        if viewModel.usageFilter != .all {
            return viewModel.usageFilter.pillTitle
        }
        return viewModel.filterScope.rawValue
    }

    private func usageScopeTab(_ uFilter: AppUsageFilter) -> some View {
        let isActive = (viewModel.usageFilter == uFilter)
        let count = viewModel.countForUsageFilter(uFilter)

        return Button {
            viewModel.usageFilter = uFilter
            if (uFilter == .suggestedCleanup || uFilter == .dormant90Days || uFilter == .rarelyUsed) && viewModel.sortOrder == .nameAsc {
                viewModel.sortOrder = .leastUsedFirst
            }
        } label: {
            HStack(spacing: 4) {
                Text(uFilter.pillTitle)
                    .font(.system(size: 11, weight: isActive ? .semibold : .regular))
                Text("\(count)")
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(isActive ? Color.primary.opacity(0.75) : Color(nsColor: .tertiaryLabelColor))
            }
            .foregroundStyle(isActive ? Color.primary : Color.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3.5)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isActive ? Color.primary.opacity(0.09) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(isActive ? Color(nsColor: .separatorColor) : Color.clear, lineWidth: 0.75)
            )
        }
        .buttonStyle(.plain)
        .help(uFilter.title)
    }

    private func appRow(_ app: TargetBundle) -> some View {
        let isChecked = viewModel.isTargetChecked(app)
        let isFocusedSingle = !viewModel.isMultiSelectMode && checkedCount == 0 && (viewModel.selectedTarget?.path == app.path)
        let running = viewModel.isRunning(app)
        let usageText = app.shortUsageSummary(isRunning: running)

        return HStack(spacing: 8) {
            if app.isSystemProtected {
                Image(systemName: "lock")
                    .font(.system(size: 10.5))
                    .foregroundStyle(isFocusedSingle ? Color.white.opacity(0.7) : Color(nsColor: .tertiaryLabelColor))
                    .frame(width: 16)
                    .help("Ứng dụng được bảo vệ")
            } else {
                Toggle(
                    "",
                    isOn: Binding(
                        get: { isChecked },
                        set: { _ in viewModel.toggleCheckForTarget(app) }
                    )
                )
                .toggleStyle(.checkbox)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 16)
            }

            Image(nsImage: viewModel.icon(for: app.path))
                .resizable()
                .interpolation(.high)
                .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 1.5) {
                HStack(spacing: 5) {
                    Text(app.name)
                        .font(.system(size: 12.5, weight: isFocusedSingle ? .semibold : .regular))
                        .foregroundStyle(isFocusedSingle ? .white : .primary)
                        .lineLimit(1)

                    if running {
                        Circle()
                            .fill(isFocusedSingle ? Color.white.opacity(0.85) : Color.secondary.opacity(0.55))
                            .frame(width: 5, height: 5)
                            .help("Đang mở")
                    }
                }

                Text(app.bundleIdentifier.isEmpty ? app.displayPath : app.bundleIdentifier)
                    .font(.system(size: 10.5))
                    .foregroundStyle(isFocusedSingle ? .white.opacity(0.75) : .secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 1.5) {
                if let size = app.bundleSizeBytes {
                    Text(ByteFormatter.string(size))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(isFocusedSingle ? .white.opacity(0.92) : .secondary)
                }

                Text(usageText)
                    .font(.system(size: 10))
                    .foregroundStyle(isFocusedSingle ? Color.white.opacity(0.72) : Color(nsColor: .tertiaryLabelColor))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(
                    isFocusedSingle
                    ? Color(nsColor: .selectedContentBackgroundColor)
                    : (isChecked ? Color.accentColor.opacity(0.11) : Color.clear)
                )
        )
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.handleTargetRowClick(app, in: viewModel.filteredApps)
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
            VStack(spacing: 10) {
                Image(systemName: "macwindow")
                    .font(.system(size: 36, weight: .ultraLight))
                    .foregroundStyle(.tertiary)
                Text("Chưa chọn ứng dụng")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text("Chọn một ứng dụng ở danh sách bên trái để xem chi tiết dung lượng, hoặc tích ô vuông để gỡ nhiều ứng dụng cùng lúc.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }
}
