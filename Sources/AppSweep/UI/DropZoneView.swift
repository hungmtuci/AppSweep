import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct DropZoneView: View {
    @ObservedObject var viewModel: MainViewModel

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            VStack(spacing: 16) {
                Image(systemName: viewModel.isDropZoneTargeted ? "arrow.down.circle" : "arrow.down.app")
                    .font(.system(size: 44, weight: .ultraLight))
                    .foregroundStyle(viewModel.isDropZoneTargeted ? Color.accentColor : Color.secondary)

                VStack(spacing: 5) {
                    Text("Kéo ứng dụng hoặc Plugin vào đây")
                        .font(.title3.weight(.semibold))

                    Text("Tự động tìm toàn bộ dữ liệu liên quan trong Library, Containers, Caches & Preferences")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                HStack(spacing: 10) {
                    Button("Chọn từ Finder...") {
                        pickBundleFromFinder()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)

                    Button("Xem danh sách đã cài (\(viewModel.installedApps.count))") {
                        viewModel.activeSection = .apps
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 44)
            .frame(maxWidth: 540)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(viewModel.isDropZoneTargeted ? Color.accentColor.opacity(0.06) : Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        viewModel.isDropZoneTargeted ? Color.accentColor : Color(nsColor: .separatorColor),
                        style: StrokeStyle(lineWidth: viewModel.isDropZoneTargeted ? 2 : 1, dash: [6, 4])
                    )
            )
            .onDrop(of: [.fileURL], isTargeted: $viewModel.isDropZoneTargeted) { providers in
                handleDropProviders(providers)
            }

            Text("Hỗ trợ .app, .prefPane, .qlgenerator, .saver, .plugin, .component, .vst3, .service · Có thể thả trực tiếp lên icon AppSweep trên Dock")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 540)

            Spacer()
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func pickBundleFromFinder() {
        let panel = NSOpenPanel()
        panel.title = "Chọn một hoặc nhiều ứng dụng / Plugin cần gỡ"
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
