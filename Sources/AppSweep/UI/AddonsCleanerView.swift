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
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Tìm plugin, prefPane, QuickLook...", text: $viewModel.searchQuery)
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
                            systemImage: "puzzlepiece.extension"
                        )
                        .font(.caption)
                    }
                    .controlSize(.small)

                    Spacer()

                    if viewModel.isMultiSelectMode || checkedCount > 0 {
                        Button("Chọn hết") {
                            viewModel.selectAllVisibleTargets(viewModel.filteredAddons)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)

                        Button("Bỏ chọn (\(checkedCount))") {
                            viewModel.exitMultiSelectMode()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    } else {
                        Button {
                            viewModel.toggleMultiSelectMode()
                        } label: {
                            Label("Chọn nhiều", systemImage: "checklist")
                                .font(.caption2.weight(.medium))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                }
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))

            Divider()

            if viewModel.filteredAddons.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "puzzlepiece.extension")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("Không có tiện ích mở rộng nào")
                        .font(.subheadline.weight(.medium))
                    Text("Các PreferencePanes, QuickLook, Screen Savers, Audio VST/AU và Internet Plugins của bên thứ ba sẽ hiển thị tại đây.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 18)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(viewModel.filteredAddons) { addon in
                            addonRow(addon)
                        }
                    }
                    .padding(8)
                }
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.35))
    }

    private func addonRow(_ addon: TargetBundle) -> some View {
        let isChecked = viewModel.isTargetChecked(addon)
        let isFocusedSingle = !viewModel.isMultiSelectMode && checkedCount == 0 && (viewModel.selectedTarget?.path == addon.path)

        return HStack(spacing: 9) {
            Button {
                viewModel.toggleCheckForTarget(addon)
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

            Image(nsImage: viewModel.icon(for: addon.path))
                .resizable()
                .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(addon.name)
                    .font(.system(size: 13, weight: (isFocusedSingle || isChecked) ? .semibold : .medium))
                    .foregroundStyle(isFocusedSingle ? .white : .primary)
                    .lineLimit(1)

                Text(addon.kind.rawValue)
                    .font(.system(size: 10.5))
                    .foregroundStyle(isFocusedSingle ? .white.opacity(0.85) : .secondary)
                    .lineLimit(1)
            }

            Spacer()

            if let size = addon.bundleSizeBytes {
                Text(ByteFormatter.string(size))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(isFocusedSingle ? .white.opacity(0.9) : .secondary)
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
            VStack(spacing: 12) {
                Image(systemName: "puzzlepiece.extension.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                Text("Chọn một hoặc nhiều Plugin bên trái")
                    .font(.title3.weight(.semibold))
                Text("Tích chọn các ô vuông để gỡ nhiều tiện ích PreferencePanes, QuickLook, Screen Savers hoặc Audio VST/AU cùng lúc.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 430)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
