import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MainWindowView: View {
    @ObservedObject var viewModel: MainViewModel
    @ObservedObject var updateService: UpdateCheckerService = .shared

    var body: some View {
        NavigationSplitView {
            sidebarContent
                .navigationSplitViewColumnWidth(min: 205, ideal: 225, max: 255)
        } detail: {
            ZStack(alignment: .top) {
                detailSectionView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if let toast = viewModel.bannerToast {
                    floatingToastView(toast)
                        .padding(.top, 14)
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
            .toolbar {
                ToolbarItem(placement: .automatic) {
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

    // MARK: - Sidebar

    private var sidebarContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            // App Brand Header
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.95, green: 0.24, blue: 0.32),
                                    Color(red: 0.98, green: 0.50, blue: 0.18)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 32, height: 32)
                    Image(systemName: "trash.slash.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text("AppSweep")
                            .font(.system(size: 15, weight: .bold))
                        Text("v\(updateService.currentVersion)")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.14), in: Capsule())
                    }
                    Text("Gỡ ứng dụng triệt để")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 12)

            List(selection: $viewModel.activeSection) {
                Section("Chức năng chính") {
                    ForEach(NavigationSection.allCases) { section in
                        sidebarRow(section)
                            .tag(section)
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()

            VStack(spacing: 8) {
                sidebarUpdateCard
                fdaFooterCard
            }
            .padding(10)
        }
    }

    private func sidebarRow(_ section: NavigationSection) -> some View {
        HStack(spacing: 8) {
            Label(section.title, systemImage: section.symbolName)
                .font(.system(size: 13, weight: .medium))
            Spacer()
            if let badge = badgeText(for: section) {
                Text(badge)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.14), in: Capsule())
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

    // MARK: - Auto-Update Controls (Toolbar & Sidebar)

    @ViewBuilder
    private var toolbarUpdateControl: some View {
        switch updateService.state {
        case .checking:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Đang kiểm tra tag...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)

        case let .downloading(ver, progress):
            HStack(spacing: 6) {
                ProgressView(value: progress, total: 1.0)
                    .progressViewStyle(.linear)
                    .frame(width: 70)
                Text("Tải v\(ver) (\(Int(progress * 100))%)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)

        case let .installing(ver):
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Đang cài v\(ver)...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)

        case let .available(info):
            Button {
                updateService.installAvailableUpdate()
            } label: {
                Label("Cập nhật v\(info.version)", systemImage: "arrow.down.circle.fill")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .help("Tự động tải và cài đặt AppSweep v\(info.version) từ github.com/hungmtuci/AppSweep")

        case .idle, .upToDate, .failed:
            Button {
                updateService.checkForUpdatesManually()
            } label: {
                Label("Kiểm tra cập nhật", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption)
            }
            .help("Đối chiếu tag mới nhất trên github.com/hungmtuci/AppSweep để tải và cập nhật tự động")
        }
    }

    private var sidebarUpdateCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch updateService.state {
            case .checking:
                HStack(spacing: 7) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Đang đối chiếu tag GitHub...")
                        .font(.caption.weight(.medium))
                }

            case let .downloading(ver, progress):
                Text("Đang tải AppSweep v\(ver) (\(Int(progress * 100))%)...")
                    .font(.caption.weight(.semibold))
                ProgressView(value: progress, total: 1.0)
                    .progressViewStyle(.linear)

            case let .installing(ver):
                HStack(spacing: 7) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Đang cài đặt v\(ver) & khởi động lại...")
                        .font(.caption.weight(.semibold))
                }

            case let .available(info):
                HStack(spacing: 5) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(.green)
                    Text("Có phiên bản mới v\(info.version)")
                        .font(.caption.weight(.bold))
                }
                Button {
                    updateService.installAvailableUpdate()
                } label: {
                    Label("Tải & Cập nhật ngay", systemImage: "arrow.down.circle.fill")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .controlSize(.small)

            case let .upToDate(ver):
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                    Text("Bản mới nhất (v\(ver))")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Button {
                    updateService.checkForUpdatesManually()
                } label: {
                    Label("Kiểm tra cập nhật", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption.weight(.medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

            case .idle, .failed:
                Button {
                    updateService.checkForUpdatesManually()
                } label: {
                    Label("Kiểm tra cập nhật", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption.weight(.medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            HStack(spacing: 4) {
                Toggle("Tự kiểm tra", isOn: $updateService.autoCheckOnLaunch)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .help("Tự động kiểm tra bản mới trên GitHub khi mở ứng dụng")

                Spacer()

                Button {
                    updateService.openGitHubRepoPage()
                } label: {
                    HStack(spacing: 2) {
                        Text("GitHub")
                        Image(systemName: "arrow.up.right.square")
                    }
                    .font(.system(size: 10.5))
                }
                .buttonStyle(.link)
                .help("Mở kho mã nguồn github.com/hungmtuci/AppSweep")
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private var updateAlertTitle: String {
        if case let .available(info) = updateService.state {
            return "Đã có bản cập nhật AppSweep v\(info.version)!"
        }
        return "Cập nhật AppSweep"
    }

    private var updateAlertMessage: String {
        guard case let .available(info) = updateService.state else {
            return ""
        }
        var lines: [String] = [
            "Phát hiện tag mới \(info.rawTag) trên github.com/\(UpdateCheckerService.githubOwner)/\(UpdateCheckerService.githubRepo) (phiên bản hiện tại: v\(updateService.currentVersion))."
        ]
        if let notes = info.releaseNotes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
            let trimmedNotes = notes.count > 260 ? String(notes.prefix(260)) + "..." : notes
            lines.append("\nNội dung cập nhật:\n\(trimmedNotes)")
        }
        lines.append("\nNhấn 'Tải & Cập nhật tự động' để tải gói cài đặt mới, thay thế ứng dụng, gỡ cờ Gatekeeper và tự khởi động lại.")
        return lines.joined(separator: "\n")
    }

    private var fdaFooterCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            if viewModel.hasFullDiskAccess {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.shield.fill")
                        .foregroundStyle(.green)
                    Text("Quét sâu toàn bộ đĩa: Đã bật")
                        .font(.caption.weight(.semibold))
                }
                Text("AppSweep có toàn quyền quét sạch Sandbox Containers & Caches ẩn.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.shield.fill")
                        .foregroundStyle(.orange)
                    Text("Khuyên bật Full Disk Access")
                        .font(.caption.weight(.semibold))
                }
                Text("Giúp quét 100% thư mục Sandbox Containers được macOS bảo vệ.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)

                Button {
                    PermissionService.openFullDiskAccessSettings()
                } label: {
                    Text("Mở Cài đặt Quyền...")
                        .font(.caption.weight(.medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
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

    // MARK: - Toast & Global Drop Overlay

    private func floatingToastView(_ toast: BannerToast) -> some View {
        HStack(spacing: 12) {
            Image(systemName: toast.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(toast.isError ? .orange : .green)

            VStack(alignment: .leading, spacing: 2) {
                Text(toast.title)
                    .font(.subheadline.weight(.semibold))
                if let sub = toast.subtitle {
                    Text(sub)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let undoID = toast.restorableRecordID {
                Button {
                    viewModel.bannerToast = nil
                    viewModel.restoreFromHistory(undoID)
                } label: {
                    Label("Hoàn tác ngay", systemImage: "arrow.uturn.backward")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            Button {
                withAnimation {
                    viewModel.bannerToast = nil
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
    }

    private var globalDropOverlay: some View {
        ZStack {
            Color.accentColor.opacity(0.14)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                Image(systemName: "arrow.down.app.fill")
                    .font(.system(size: 54))
                    .foregroundStyle(Color.accentColor)
                Text("Thả ứng dụng hoặc Plugin vào đây để quét sâu")
                    .font(.title2.weight(.bold))
                Text("AppSweep sẽ tự động dò toàn bộ file liên quan trước khi gỡ bỏ")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(36)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, dash: [8, 6]))
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
