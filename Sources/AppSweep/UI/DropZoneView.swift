import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct DropZoneView: View {
    @ObservedObject var viewModel: MainViewModel

    var body: some View {
        VStack(spacing: 26) {
            Spacer()

            // Classic AppDelete Drag-and-Drop Hero Box
            VStack(spacing: 18) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color.accentColor.opacity(0.18), Color.red.opacity(0.14)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 96, height: 96)

                    Image(systemName: viewModel.isDropZoneTargeted ? "arrow.down.circle.fill" : "trash.slash.circle.fill")
                        .font(.system(size: 50))
                        .foregroundStyle(viewModel.isDropZoneTargeted ? Color.accentColor : Color.red)
                        .symbolEffect(.bounce, value: viewModel.isDropZoneTargeted)
                }

                VStack(spacing: 6) {
                    Text("Kéo & Thả ứng dụng vào đây để gỡ triệt để")
                        .font(.title2.weight(.bold))

                    Text("Hỗ trợ .app, .prefPane, .qlgenerator, .saver, .plugin, .component, .vst3, .service")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 12) {
                    Button {
                        pickBundleFromFinder()
                    } label: {
                        Label("Chọn ứng dụng từ Finder...", systemImage: "folder.badge.plus")
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Button {
                        viewModel.activeSection = .apps
                    } label: {
                        Label("Duyệt danh sách đã cài (\(viewModel.installedApps.count))", systemImage: "square.grid.2x2")
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
            }
            .padding(42)
            .frame(maxWidth: 640)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(viewModel.isDropZoneTargeted ? Color.accentColor.opacity(0.09) : Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .strokeBorder(
                        viewModel.isDropZoneTargeted ? Color.accentColor : Color.secondary.opacity(0.32),
                        style: StrokeStyle(lineWidth: viewModel.isDropZoneTargeted ? 2.5 : 1.5, dash: [8, 6])
                    )
            )
            .onDrop(of: [.fileURL], isTargeted: $viewModel.isDropZoneTargeted) { providers in
                handleDropProviders(providers)
            }

            // Feature Highlights inspired by AppDelete
            HStack(alignment: .top, spacing: 18) {
                featureHighlight(
                    icon: "magnifyingglass.circle.fill",
                    color: .blue,
                    title: "Quét sâu 11 tầng hệ thống",
                    desc: "Tự động dò Bundle ID, Team ID, Sandbox Containers, LaunchDaemons, Receipts & Dotfiles ẩn."
                )
                featureHighlight(
                    icon: "archivebox.circle.fill",
                    color: .orange,
                    title: "Đóng gói Thùng rác & Sao lưu .ZIP",
                    desc: "Gom gọn các file xóa vào 1 thư mục ngăn nắp trong Trash và tùy chọn nén .zip dự phòng."
                )
                featureHighlight(
                    icon: "arrow.uturn.backward.circle.fill",
                    color: .green,
                    title: "Hoàn tác 1 chạm (Undo)",
                    desc: "Đặt trả toàn bộ ứng dụng & từng file Preferences, App Support về đúng thư mục gốc ban đầu."
                )
            }
            .frame(maxWidth: 780)

            Spacer()
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func featureHighlight(icon: String, color: Color, title: String, desc: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(desc)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
    }

    private func pickBundleFromFinder() {
        let panel = NSOpenPanel()
        panel.title = "Chọn một hoặc nhiều ứng dụng / Plugin cần gỡ triệt để"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")

        if panel.runModal() == .OK, !panel.urls.isEmpty {
            viewModel.handleDroppedURLs(panel.urls)
        }
    }

    private func handleDropProviders(_ providers: [NSItemProvider]) -> Bool {
        let matching = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !matching.isEmpty else { return false }

        let group = DispatchGroup()
        let lock = NSLock()
        var collected: [URL] = []

        for provider in matching {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                let resolvedURL: URL? = {
                    if let data = item as? Data {
                        return URL(dataRepresentation: data, relativeTo: nil)
                    }
                    if let url = item as? URL {
                        return url
                    }
                    return nil
                }()
                if let url = resolvedURL {
                    lock.lock()
                    collected.append(url)
                    lock.unlock()
                }
            }
        }

        group.notify(queue: .main) {
            if !collected.isEmpty {
                viewModel.handleDroppedURLs(collected)
            }
        }
        return true
    }
}
