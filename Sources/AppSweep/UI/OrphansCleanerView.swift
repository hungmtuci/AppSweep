import SwiftUI

struct OrphansCleanerView: View {
    @ObservedObject var viewModel: MainViewModel

    var body: some View {
        VStack(spacing: 0) {
            topBanner
            Divider()

            if viewModel.isScanningOrphans {
                VStack(spacing: 14) {
                    Spacer()
                    ProgressView()
                        .controlSize(.large)
                    Text("Đang rà soát file rác mồ côi trên toàn bộ thư mục Library...")
                        .font(.headline)
                    Text("Đối chiếu LaunchServices, Bundle ID ứng dụng đang cài và các LaunchAgents gãy đường dẫn")
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
        .confirmationDialog(
            "Xác nhận dọn \(viewModel.selectedOrphansCount) file rác mồ côi?",
            isPresented: $viewModel.showOrphanConfirmation,
            titleVisibility: .visible
        ) {
            Button(
                "\(viewModel.removalMode.shortTitle) (\(ByteFormatter.string(viewModel.selectedOrphansBytes)))",
                role: .destructive
            ) {
                viewModel.executeOrphanCleanup()
            }
            Button("Hủy bỏ", role: .cancel) {}
        } message: {
            Text(viewModel.removalMode == .moveToTrash
                 ? "Tất cả mục đã chọn sẽ được chuyển gọn vào Thùng rác và có thể Hoàn tác trong tab Lịch sử."
                 : "Cảnh báo: File xóa vĩnh viễn sẽ không thể khôi phục.")
        }
    }

    private var topBanner: some View {
        HStack(spacing: 14) {
            Image(systemName: "sparkles.rectangle.stack.fill")
                .font(.system(size: 30))
                .foregroundStyle(.purple)

            VStack(alignment: .leading, spacing: 3) {
                Text("Dọn file rác mồ côi (Orphans Scanner)")
                    .font(.title3.weight(.bold))
                Text("Tìm dữ liệu Caches, Containers, Saved State, Preferences và LaunchAgents sót lại từ những ứng dụng bạn từng kéo thẳng vào Trash trước đây.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                viewModel.scanOrphansNow()
            } label: {
                Label(
                    viewModel.orphans.isEmpty ? "Bắt đầu quét hệ thống" : "Quét lại",
                    systemImage: "magnifyingglass"
                )
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.isScanningOrphans)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
    }

    private var emptyOrReadyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 52))
                .foregroundStyle(.green)
            Text("Nhấn 'Bắt đầu quét hệ thống' hoặc hệ thống của bạn đang rất sạch!")
                .font(.headline)
            Text("AppSweep chỉ liệt kê các mục có Bundle ID hoặc đường dẫn tiến trình chắc chắn không còn thuộc về bất kỳ ứng dụng nào trên máy.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)

            Button {
                viewModel.scanOrphansNow()
            } label: {
                Label("Quét tìm file mồ côi ngay", systemImage: "sparkle.magnifyingglass")
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var orphanListContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Lọc theo tên file hoặc Bundle ID...", text: $viewModel.orphanSearchQuery)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .frame(width: 280)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.1)))

                Button("Chọn tất cả") {
                    viewModel.setAllOrphansSelection(true)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Bỏ chọn tất cả") {
                    viewModel.setAllOrphansSelection(false)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                Text("Phát hiện \(viewModel.orphans.count) mục mồ côi")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)

            Divider()

            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(viewModel.filteredOrphans) { item in
                        orphanRow(item)
                    }
                }
                .padding(16)
            }
        }
    }

    private func orphanRow(_ item: OrphanItem) -> some View {
        HStack(spacing: 12) {
            Button {
                viewModel.toggleOrphanSelection(item.id)
            } label: {
                Image(systemName: item.isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(item.isSelected ? Color.accentColor : Color.secondary)
                    .font(.system(size: 16))
            }
            .buttonStyle(.plain)

            Image(nsImage: viewModel.icon(for: item.path))
                .resizable()
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)

                    Text(item.category.shortBadge)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(item.category.accentColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(item.category.accentColor.opacity(0.13), in: Capsule())

                    if item.requiresAdmin {
                        Label("Admin", systemImage: "lock.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                    }
                }

                Text("\(item.displayPath)  •  \(item.reason)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Text(ByteFormatter.string(item.sizeBytes))
                .font(.system(size: 12, design: .monospaced).weight(.medium))

            Button {
                viewModel.revealInFinder(item.path)
            } label: {
                Image(systemName: "magnifyingglass.circle")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Hiển thị trong Finder")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        )
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
            .frame(width: 300)

            Spacer()

            Text("Đã chọn \(viewModel.selectedOrphansCount) mục • \(ByteFormatter.string(viewModel.selectedOrphansBytes))")
                .font(.subheadline.weight(.medium))
                .padding(.trailing, 10)

            Button {
                viewModel.showOrphanConfirmation = true
            } label: {
                Label(
                    "Dọn sạch (\(ByteFormatter.string(viewModel.selectedOrphansBytes)))",
                    systemImage: "trash.fill"
                )
                .fontWeight(.semibold)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)
            .disabled(viewModel.selectedOrphansCount == 0 || viewModel.isExecutingAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}
