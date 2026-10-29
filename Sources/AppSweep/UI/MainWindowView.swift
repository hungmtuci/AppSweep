import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MainWindowView: View {
    @ObservedObject var viewModel: MainViewModel
    @ObservedObject var updateService: UpdateCheckerService = .shared

    var body: some View {
        NavigationSplitView {
            sidebarContent
                .navigationSplitViewColumnWidth(min: 195, ideal: 215, max: 245)
        } detail: {
            ZStack(alignment: .top) {
                detailSectionView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if let toast = viewModel.bannerToast {
                    floatingToastView(toast)
                        .padding(.top, 12)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .zIndex(20)
                }

                if viewModel.isGlobalDropTargeted && viewModel.activeSection != .dropZone {
                    globalDropOverlay
                        .zIndex(30)
                }
            }
            .onDrop(of: [.fileURL], isTargeted: $viewModel.isGlobalDropTargeted) { providers in
                handleGlobalDrop(providers)
            }
            .navigationTitle(viewModel.activeSection.title)
            .toolbar {
                ToolbarItemGroup(placement: .automatic) {
                    toolbarUpdateControl
                }
            }
        }
        .onAppear {
            viewModel.initialLoadIfNeeded()
            updateService.checkSilentlyOnLaunchIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            viewModel.refreshPermissions()
        }
        .alert(
            updateAlertTitle,
            isPresented: $updateService.showUpdatePromptDialog
        ) {
            if case let .available(info) = updateService.state {
                Button("Tải & Cập nhật tự động (v\(info.version))") {
                    updateService.installAvailableUpdate()
                }
                Button("Xem trên GitHub") {
                    NSWorkspace.shared.open(info.releasePageURL)
                }
            }
            Button("Để sau", role: .cancel) {}
        } message: {
            Text(updateAlertMessage)
        }
    }

    // MARK: - Native macOS Sidebar

    private var sidebarContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            List(selection: $viewModel.activeSection) {
                Section("Danh mục") {
                    ForEach(NavigationSection.allCases) { section in
                        sidebarRow(section)
                            .tag(section)
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()

            sidebarStatusFooter
        }
    }

    private func sidebarRow(_ section: NavigationSection) -> some View {
        HStack(spacing: 6) {
            Label(section.title, systemImage: section.symbolName)
            Spacer(minLength: 4)
            if let badge = badgeText(for: section) {
                Text(badge)
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func badgeText(for section: NavigationSection) -> String? {
        switch section {
        case .apps:
            return viewModel.installedApps.isEmpty ? nil : "\(viewModel.installedApps.count)"
        case .dropZone:
            return nil
        case .addons:
            return viewModel.addons.isEmpty ? nil : "\(viewModel.addons.count)"
        case .orphans:
            return viewModel.orphans.isEmpty ? nil : "\(viewModel.orphans.count)"
        case .history:
            return viewModel.historyRecords.isEmpty ? nil : "\(viewModel.historyRecords.count)"
        }
    }

    // MARK: - Quiet Native Sidebar Footer & Toolbar Controls

    @ViewBuilder
    private var toolbarUpdateControl: some View {
        switch updateService.state {
        case .checking:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Đang kiểm tra...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)

        case let .downloading(ver, progress):
            HStack(spacing: 6) {
                ProgressView(value: progress, total: 1.0)
                    .progressViewStyle(.linear)
                    .frame(width: 64)
                Text("v\(ver) (\(Int(progress * 100))%)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)

        case let .installing(ver):
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Đang cài v\(ver)...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)

        case let .available(info):
            Button {
                updateService.installAvailableUpdate()
            } label: {
                Label("Cập nhật v\(info.version)", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .help("Tự động tải và cài đặt AppSweep v\(info.version) từ GitHub")

        case .idle, .upToDate, .failed:
            Button {
                updateService.checkForUpdatesManually()
            } label: {
                Label("Kiểm tra cập nhật", systemImage: "arrow.triangle.2.circlepath")
            }
            .help("Kiểm tra phiên bản mới từ github.com/hungmtuci/AppSweep (⌘U)")
        }
    }

    private var sidebarStatusFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Version & Update status row
            switch updateService.state {
            case .checking:
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Đang kiểm tra cập nhật...")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

            case let .downloading(ver, progress):
                VStack(alignment: .leading, spacing: 4) {
                    Text("Đang tải v\(ver) (\(Int(progress * 100))%)")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                    ProgressView(value: progress, total: 1.0)
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                }

            case let .installing(ver):
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Đang cài v\(ver)...")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

            case let .available(info):
                HStack {
                    Text("Có bản mới v\(info.version)")
                        .font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Button("Cập nhật") {
                        updateService.installAvailableUpdate()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
                }

            case .idle, .upToDate, .failed:
                HStack(spacing: 6) {
                    Text("Phiên bản \(updateService.currentVersion)")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button {
                        updateService.checkForUpdatesManually()
                    } label: {
                        Text("Kiểm tra")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.link)
                    .help("Kiểm tra bản cập nhật mới trên GitHub")

                    Text("·")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)

                    Button {
                        updateService.openGitHubRepoPage()
                    } label: {
                        Text("GitHub")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.link)
                    .help("Mở trang mã nguồn github.com/hungmtuci/AppSweep")
                }
            }

            Toggle("Tự kiểm tra khi mở ứng dụng", isOn: $updateService.autoCheckOnLaunch)
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Divider()

            // Full Disk Access subtle row
            if viewModel.hasFullDiskAccess {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.shield")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text("Quyền truy cập đĩa: Đầy đủ")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        Image(systemName: "lock.shield")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text("Chưa cấp Full Disk Access")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    Button("Mở Cài đặt Quyền...") {
                        PermissionService.openFullDiskAccessSettings()
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var updateAlertTitle: String {
        if case let .available(info) = updateService.state {
            return "Đã có bản cập nhật AppSweep v\(info.version)"
        }
        return "Cập nhật AppSweep"
    }

    private var updateAlertMessage: String {
        guard case let .available(info) = updateService.state else {
            return ""
        }
        var lines: [String] = [
            "Phát hiện phiên bản mới \(info.rawTag) trên github.com/\(UpdateCheckerService.githubOwner)/\(UpdateCheckerService.githubRepo) (hiện tại: v\(updateService.currentVersion))."
        ]
        if let notes = info.releaseNotes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
            let trimmedNotes = notes.count > 260 ? String(notes.prefix(260)) + "..." : notes
            lines.append("\nNội dung cập nhật:\n\(trimmedNotes)")
        }
        lines.append("\nNhấn 'Tải & Cập nhật tự động' để tải gói cài đặt mới, thay thế ứng dụng và tự khởi động lại.")
        return lines.joined(separator: "\n")
    }

    // MARK: - Detail Router

    @ViewBuilder
    private var detailSectionView: some View {
        switch viewModel.activeSection {
        case .apps:
            InstalledAppsView(viewModel: viewModel)
        case .dropZone:
            DropZoneView(viewModel: viewModel)
        case .addons:
            AddonsCleanerView(viewModel: viewModel)
        case .orphans:
            OrphansCleanerView(viewModel: viewModel)
        case .history:
            HistoryRestoreView(viewModel: viewModel)
        }
    }

    // MARK: - Subtle macOS Toast & Drop Overlay

    private func floatingToastView(_ toast: BannerToast) -> some View {
        HStack(spacing: 10) {
            Image(systemName: toast.isError ? "exclamationmark.circle" : "checkmark.circle")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(toast.isError ? .primary : .secondary)

            VStack(alignment: .leading, spacing: 1) {
                Text(toast.title)
                    .font(.system(size: 12.5, weight: .semibold))
                if let sub = toast.subtitle {
                    Text(sub)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            if let undoID = toast.restorableRecordID {
                Button("Hoàn tác") {
                    viewModel.bannerToast = nil
                    viewModel.restoreFromHistory(undoID)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Button {
                withAnimation {
                    viewModel.bannerToast = nil
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
    }

    private var globalDropOverlay: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor).opacity(0.75)
                .ignoresSafeArea()

            VStack(spacing: 10) {
                Image(systemName: "arrow.down.app")
                    .font(.system(size: 42, weight: .light))
                    .foregroundStyle(.secondary)
                Text("Thả ứng dụng hoặc Plugin để quét dữ liệu liên quan")
                    .font(.headline)
                Text("Hỗ trợ chọn một hoặc nhiều mục cùng lúc")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(32)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color(nsColor: .separatorColor), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            )
        }
    }

    private func handleGlobalDrop(_ providers: [NSItemProvider]) -> Bool {
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
