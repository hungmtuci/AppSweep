import AppKit
import SwiftUI

struct AddonsCleanerView: View {
    @ObservedObject var viewModel: MainViewModel

    private var checkedCount: Int {
        viewModel.activeCheckedTargets.count
    }

    var body: some View {
        HSplitView {
            leftAddonsListPane
                .frame(minWidth: 300, idealWidth: 340, maxWidth: 410)

            rightDetailPane
                .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var leftAddonsListPane: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    TextField("Tìm plugin, prefPane, QuickLook...", text: $viewModel.searchQuery)
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

                HStack {
                    Menu {
                        Button("Tất cả tiện ích (\(viewModel.addons.count))") {
                            viewModel.addonFilterKind = nil
                        }
                        Divider()
                        ForEach(BundleKind.allCases.filter { $0 != .application }) { kind in
                            Button(kind.rawValue) {
                                viewModel.addonFilterKind = kind
                            }
                        }
                    } label: {
                        Label(
                            viewModel.addonFilterKind?.rawValue ?? "Tất cả loại Plugin",
                            systemImage: "line.3.horizontal.decrease"
                        )
                        .font(.system(size: 11.5))
                        .lineLimit(1)
                    }
                    .controlSize(.small)

                    Spacer()

                    if viewModel.isMultiSelectMode || checkedCount > 0 {
                        Button("Chọn hết") {
                            viewModel.selectAllVisibleTargets(viewModel.filteredAddons)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)

                        Button("Xong") {
                            viewModel.exitMultiSelectMode()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    } else {
                        Button("Chọn nhiều") {
                            viewModel.toggleMultiSelectMode()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            if viewModel.filteredAddons.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "puzzlepiece.extension")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("Không có tiện ích mở rộng")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text("PreferencePanes, QuickLook, Screen Savers, Audio VST/AU và Internet Plugins của bên thứ ba sẽ hiển thị tại đây.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(viewModel.filteredAddons) { addon in
                            addonRow(addon)
                        }
                    }
                    .padding(6)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func addonRow(_ addon: TargetBundle) -> some View {
        let isChecked = viewModel.isTargetChecked(addon)
        let isFocusedSingle = !viewModel.isMultiSelectMode && checkedCount == 0 && (viewModel.selectedTarget?.path == addon.path)

        return HStack(spacing: 8) {
            Toggle(
                "",
                isOn: Binding(
                    get: { isChecked },
                    set: { _ in viewModel.toggleCheckForTarget(addon) }
                )
            )
            .toggleStyle(.checkbox)
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 16)

            Image(nsImage: viewModel.icon(for: addon.path))
                .resizable()
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 1.5) {
                Text(addon.name)
                    .font(.system(size: 12.5, weight: isFocusedSingle ? .semibold : .regular))
                    .foregroundStyle(isFocusedSingle ? .white : .primary)
                    .lineLimit(1)

                Text(addon.kind.rawValue)
                    .font(.system(size: 10.5))
                    .foregroundStyle(isFocusedSingle ? .white.opacity(0.75) : .secondary)
                    .lineLimit(1)
            }

            Spacer()

            if let size = addon.bundleSizeBytes {
                Text(ByteFormatter.string(size))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(isFocusedSingle ? .white.opacity(0.9) : .secondary)
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
            viewModel.handleTargetRowClick(addon, in: viewModel.filteredAddons)
        }
    }

    @ViewBuilder
    private var rightDetailPane: some View {
        if viewModel.isMultiSelectMode || checkedCount > 0 {
            BatchUninstallDetailView(viewModel: viewModel)
        } else if let selected = viewModel.selectedTarget, selected.kind != .application {
            TargetDeepScanDetailView(viewModel: viewModel, target: selected)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "puzzlepiece.extension")
                    .font(.system(size: 36, weight: .ultraLight))
                    .foregroundStyle(.tertiary)
                Text("Chưa chọn Plugin")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text("Chọn một Plugin ở danh sách bên trái để xem tệp cấu hình liên quan, hoặc tích ô vuông để gỡ hàng loạt.")
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
