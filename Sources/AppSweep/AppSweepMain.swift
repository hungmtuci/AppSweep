import AppKit
import SwiftUI

@main
enum AppSweepMain {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = AppSweepDelegate()
        app.delegate = delegate
        MainActor.assumeIsolated {
            delegate.installMainMenu()
        }
        app.run()
    }
}

@MainActor
final class AppSweepDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var mainWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Prevent duplicate instances
        if let bundleID = Bundle.main.bundleIdentifier {
            let ownPID = ProcessInfo.processInfo.processIdentifier
            let existing = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .first { $0.processIdentifier != ownPID }
            if let existing {
                existing.activate()
                NSApp.terminate(nil)
                return
            }
        }

        openOrFocusMainWindow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            openOrFocusMainWindow()
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Supports dragging any .app / plugin directly onto the AppSweep icon in the macOS Dock or Finder!
    func application(_ application: NSApplication, open urls: [URL]) {
        openOrFocusMainWindow()
        MainViewModel.shared.handleDroppedURLs(urls)
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let urls = filenames.map { URL(fileURLWithPath: $0) }
        openOrFocusMainWindow()
        MainViewModel.shared.handleDroppedURLs(urls)
        sender.reply(toOpenOrPrint: .success)
    }

    func openOrFocusMainWindow() {
        if let window = mainWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let contentView = MainWindowView(viewModel: MainViewModel.shared)
        let hostingController = NSHostingController(rootView: contentView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "AppSweep"
        window.toolbarStyle = .unified
        window.minSize = NSSize(width: 920, height: 600)
        window.contentViewController = hostingController
        window.center()
        window.setFrameAutosaveName("AppSweepMainWindow")
        window.isReleasedWhenClosed = false
        window.delegate = self

        self.mainWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func installMainMenu() {
        let mainMenu = NSMenu()

        // 1. App Menu
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "Giới thiệu về AppSweep",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        let checkUpdateMenuItem = appMenu.addItem(
            withTitle: "Kiểm tra cập nhật...",
            action: #selector(checkForUpdatesFromMenu),
            keyEquivalent: "u"
        )
        checkUpdateMenuItem.target = self
        let openGitHubMenuItem = appMenu.addItem(
            withTitle: "Mở trang GitHub dự án...",
            action: #selector(openGitHubRepoFromMenu),
            keyEquivalent: ""
        )
        openGitHubMenuItem.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Ẩn AppSweep",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        appMenu.addItem(
            withTitle: "Thoát AppSweep",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenuItem.submenu = appMenu

        // 2. File Menu
        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "Tệp")
        let openBundleItem = fileMenu.addItem(
            withTitle: "Chọn ứng dụng cần gỡ...",
            action: #selector(openBundlePickerFromMenu),
            keyEquivalent: "o"
        )
        openBundleItem.target = self

        let refreshItem = fileMenu.addItem(
            withTitle: "Làm mới danh sách ứng dụng",
            action: #selector(reloadCatalogFromMenu),
            keyEquivalent: "r"
        )
        refreshItem.target = self

        let orphanItem = fileMenu.addItem(
            withTitle: "Quét file rác mồ côi",
            action: #selector(scanOrphansFromMenu),
            keyEquivalent: "f"
        )
        orphanItem.keyEquivalentModifierMask = [.command, .shift]
        orphanItem.target = self
        fileMenuItem.submenu = fileMenu

        // 3. Edit Menu (enables Cmd+A / Cmd+C / Cmd+V / Cmd+X inside search TextFields)
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Chỉnh sửa")
        editMenu.addItem(withTitle: "Hoàn tác nhập", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Làm lại", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cắt", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Sao chép", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Dán", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Chọn tất cả", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu

        // 4. Window Menu
        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Cửa sổ")
        let showMainItem = windowMenu.addItem(
            withTitle: "Mở cửa sổ chính",
            action: #selector(reopenWindowFromMenu),
            keyEquivalent: "1"
        )
        showMainItem.target = self
        windowMenu.addItem(withTitle: "Đóng cửa sổ", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Thu nhỏ", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenuItem.submenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    @objc private func openBundlePickerFromMenu() {
        openOrFocusMainWindow()
        let panel = NSOpenPanel()
        panel.title = "Chọn một hoặc nhiều ứng dụng (.app) / Plugin cần gỡ triệt để"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        if panel.runModal() == .OK, !panel.urls.isEmpty {
            MainViewModel.shared.handleDroppedURLs(panel.urls)
        }
    }

    @objc private func reloadCatalogFromMenu() {
        MainViewModel.shared.reloadAllCatalogs()
    }

    @objc private func scanOrphansFromMenu() {
        openOrFocusMainWindow()
        MainViewModel.shared.activeSection = .orphans
        MainViewModel.shared.scanOrphansNow()
    }

    @objc private func reopenWindowFromMenu() {
        openOrFocusMainWindow()
    }

    @objc private func checkForUpdatesFromMenu() {
        openOrFocusMainWindow()
        UpdateCheckerService.shared.checkForUpdatesManually()
    }

    @objc private func openGitHubRepoFromMenu() {
        UpdateCheckerService.shared.openGitHubRepoPage()
    }
}
