import AppKit
import SwiftUI

struct OrphansCleanerView: View {
    @ObservedObject var viewModel: MainViewModel

    var body: some View {
        VStack(spacing: 0) {
            topHeaderBar
            Divider()

            if viewModel.isScanningOrphans {
                VStack(spacing: 10) {
                    Spacer()
                    ProgressView()
                        .controlSize(.regular)
                    Text("Đang rà soát dữ liệu mồ côi trong Library...")
                        .font(.subheadline.weight(.medium))
                    Text("Đối chiếu LaunchServices, Bundle ID ứng dụng hiện có và các LaunchAgents gãy đường dẫn")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.orphans.isEmpty {
                emptyOrReadyState
            } else {
                orphanListContent
                Divider()
                bottomCleanFooter
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .confirmationDialog(
            "Dọn \(viewModel.selectedOrphansCount) mục rác mồ côi?",
            isPresented: $viewModel.showOrphanConfirmation,
            titleVisibility: .visible
        ) {
            Button(
                "\(viewModel.removalMode.shortTitle) (\(ByteFormatter.string(viewModel.selectedOrphansBytes)))",
                role: .destructive
            ) {
                viewModel.executeOrphanCleanup()
            }
            Button("Hủy", role: .cancel) {}
        } message: {
            Text(viewModel.removalMode == .moveToTrash
                 ? "Các mục đã chọn sẽ chuyển vào Thùng rác và có thể khôi phục trong mục Lịch sử & Hoàn tác."
                 : "Thao tác xóa vĩnh viễn không thể khôi phục.")
        }
    }

    private var topHeaderBar: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("File rác mồ côi")
                    .font(.headline)
                Text("Tìm Caches, Containers, Preferences và LaunchAgents còn sót lại từ các ứng dụng đã xóa thủ công trước đây.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                viewModel.scanOrphansNow()
            } label: {
                Label(
                    viewModel.orphans.isEmpty ? "Quét hệ thống" : "Quét lại",
                    systemImage: "arrow.clockwise"
                )
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .disabled(viewModel.isScanningOrphans)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 13)
    }

    private var emptyOrReadyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "tray")
                .font(.system(size: 38, weight: .ultraLight))
                .foregroundStyle(.tertiary)
            Text("Chưa có mục rác mồ côi nào được liệt kê")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Nhấn 'Quét hệ thống' để kiểm tra các thư mục dữ liệu không còn thuộc về bất kỳ ứng dụng nào trên máy.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            Button("Quét hệ thống") {
                viewModel.scanOrphansNow()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var orphanListContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    TextField("Lọc theo tên hoặc Bundle ID", text: $viewModel.orphanSearchQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4.5)
                .frame(width: 250)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor), lineWidth: 1))

                Button("Chọn tất cả") {
                    viewModel.setAllOrphansSelection(true)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Bỏ chọn") {
                    viewModel.setAllOrphansSelection(false)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                Text("\(viewModel.filteredOrphans.count) mục")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 9)

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(viewModel.filteredOrphans.enumerated()), id: \.element.id) { idx, item in
                        orphanRow(item)
                        if idx < viewModel.filteredOrphans.count - 1 {
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
                .padding(20)
            }
        }
    }

    private func orphanRow(_ item: OrphanItem) -> some View {
        HStack(spacing: 10) {
            Toggle(
                "",
                isOn: Binding(
                    get: { item.isSelected },
                    set: { _ in viewModel.toggleOrphanSelection(item.id) }
                )
            )
            .toggleStyle(.checkbox)
            .labelsHidden()
            .controlSize(.small)

            Image(nsImage: viewModel.icon(for: item.path))
                .resizable()
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 1.5) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(item.isSelected ? .primary : .secondary)
                        .lineLimit(1)

                    Text("· \(item.category.shortBadge)")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)

                    if item.requiresAdmin {
                        Image(systemName: "lock")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }

                Text("\(item.displayPath)  ·  \(item.reason)")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Text(ByteFormatter.string(item.sizeBytes))
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(.secondary)

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
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.toggleOrphanSelection(item.id)
        }
    }

    private var bottomCleanFooter: some View {
        HStack {
            Picker("Chế độ:", selection: $viewModel.removalMode) {
                ForEach(RemovalMode.allCases) { mode in
                    Text(mode.shortTitle).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .frame(width: 280)

            Spacer()

            Text("Đã chọn \(viewModel.selectedOrphansCount) mục · \(ByteFormatter.string(viewModel.selectedOrphansBytes))")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.trailing, 8)

            if viewModel.removalMode == .permanentDelete {
                Button(role: .destructive) {
                    viewModel.showOrphanConfirmation = true
                } label: {
                    Text("Xóa vĩnh viễn (\(ByteFormatter.string(viewModel.selectedOrphansBytes)))")
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.regular)
                .disabled(viewModel.selectedOrphansCount == 0 || viewModel.isExecutingAction)
            } else {
                Button {
                    viewModel.showOrphanConfirmation = true
                } label: {
                    Text("Chuyển vào Thùng rác (\(ByteFormatter.string(viewModel.selectedOrphansBytes)))")
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(viewModel.selectedOrphansCount == 0 || viewModel.isExecutingAction)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 11)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
