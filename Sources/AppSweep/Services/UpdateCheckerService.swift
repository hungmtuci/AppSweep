import AppKit
import Foundation

/// Checks `github.com/hungmtuci/AppSweep` tags & releases, compares semantic versions,
/// downloads the latest `.zip` or `.dmg` package with live progress, atomically replaces `AppSweep.app`,
/// removes Gatekeeper quarantine attributes (`xattr -cr`), and relaunches automatically.
@MainActor
final class UpdateCheckerService: ObservableObject {
    static let shared = UpdateCheckerService()

    enum AssetKind: Equatable, Sendable {
        case zip
        case dmg
    }

    struct ReleaseUpdateInfo: Equatable, Sendable {
        let rawTag: String
        let version: String
        let downloadURL: URL?
        let assetKind: AssetKind
        let releasePageURL: URL
        let releaseNotes: String?
    }

    enum UpdateState: Equatable {
        case idle
        case checking
        case upToDate(version: String)
        case available(ReleaseUpdateInfo)
        case downloading(version: String, progress: Double)
        case installing(version: String)
        case failed(message: String)
    }

    private struct GitHubReleaseDTO: Decodable, Sendable {
        let tag_name: String
        let html_url: String
        let draft: Bool?
        let body: String?
        let assets: [GitHubAssetDTO]
    }

    private struct GitHubAssetDTO: Decodable, Sendable {
        let name: String
        let browser_download_url: String
    }

    private struct GitHubTagDTO: Decodable, Sendable {
        let name: String
    }

    static let githubOwner = "hungmtuci"
    static let githubRepo = "AppSweep"
    private static let autoCheckDefaultsKey = "AppSweep.autoCheckUpdatesOnLaunch"

    @Published private(set) var state: UpdateState = .idle
    @Published var showUpdatePromptDialog: Bool = false
    @Published var autoCheckOnLaunch: Bool = {
        if UserDefaults.standard.object(forKey: "AppSweep.autoCheckUpdatesOnLaunch") == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: "AppSweep.autoCheckUpdatesOnLaunch")
    }() {
        didSet {
            UserDefaults.standard.set(autoCheckOnLaunch, forKey: Self.autoCheckDefaultsKey)
        }
    }

    var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.3.1"
    }

    private var lastSilentCheckTime: CFAbsoluteTime = 0

    private var releasesListAPI: URL {
        URL(string: "https://api.github.com/repos/\(Self.githubOwner)/\(Self.githubRepo)/releases?per_page=10")!
    }

    private var tagsListAPI: URL {
        URL(string: "https://api.github.com/repos/\(Self.githubOwner)/\(Self.githubRepo)/tags?per_page=20")!
    }

    private var htmlLatestReleaseURL: URL {
        URL(string: "https://github.com/\(Self.githubOwner)/\(Self.githubRepo)/releases/latest")!
    }

    private var repoHomeURL: URL {
        URL(string: "https://github.com/\(Self.githubOwner)/\(Self.githubRepo)")!
    }

    private init() {}

    // MARK: - Public Actions

    /// Quietly checks for a newer tag on launch (at most once every 6 hours).
    func checkSilentlyOnLaunchIfNeeded() {
        guard autoCheckOnLaunch else { return }
        let now = CFAbsoluteTimeGetCurrent()
        guard (now - lastSilentCheckTime) >= 21_600 else { return }
        lastSilentCheckTime = now
        Task { @MainActor in
            await performCheck(manual: false)
        }
    }

    func openGitHubRepoPage() {
        NSWorkspace.shared.open(repoHomeURL)
    }

    /// Triggered when the user clicks "Kiểm tra cập nhật".
    func checkForUpdatesManually() {
        Task { @MainActor in
            await performCheck(manual: true)
        }
    }

    // MARK: - Core Tag & Release Discovery

    private func performCheck(manual: Bool) async {
        switch state {
        case .checking, .downloading, .installing:
            return
        default:
            break
        }

        if manual {
            state = .checking
        }

        let localVersion = currentVersion

        do {
            let discovered = try await fetchNewestRemoteReleaseOrTag()

            guard let latest = discovered else {
                // Repository exists or hasn't published any tags/releases yet -> current local build is latest
                state = .upToDate(version: localVersion)
                if manual {
                    MainViewModel.shared.showToast(
                        title: "Đang sử dụng phiên bản mới nhất (v\(localVersion))",
                        subtitle: "Chưa có tag nào mới hơn trên github.com/\(Self.githubOwner)/\(Self.githubRepo)."
                    )
                }
                return
            }

            if Self.isVersion(latest.version, newerThan: localVersion) {
                state = .available(latest)
                if manual {
                    showUpdatePromptDialog = true
                } else {
                    MainViewModel.shared.showToast(
                        title: "Đã có phiên bản mới AppSweep v\(latest.version)!",
                        subtitle: "Nhấn 'Cập nhật v\(latest.version)' ở thanh công cụ hoặc thanh bên trái để nâng cấp tự động."
                    )
                }
            } else {
                state = .upToDate(version: localVersion)
                if manual {
                    MainViewModel.shared.showToast(
                        title: "Bạn đang dùng bản mới nhất (v\(localVersion))",
                        subtitle: "Đã đối chiếu tag mới nhất (\(latest.rawTag)) từ github.com/\(Self.githubOwner)/\(Self.githubRepo)."
                    )
                }
            }
        } catch {
            if manual {
                let message = "Không thể kiểm tra cập nhật: \(error.localizedDescription)"
                state = .failed(message: message)
                MainViewModel.shared.showToast(
                    title: "Kiểm tra cập nhật thất bại",
                    subtitle: error.localizedDescription,
                    isError: true
                )
            }
        }
    }

    /// Queries both GitHub Releases and GitHub Tags on `hungmtuci/AppSweep` (with HTML redirect fallback if API is rate-limited)
    /// so the highest semantic tag is always detected accurately.
    private func fetchNewestRemoteReleaseOrTag() async throws -> ReleaseUpdateInfo? {
        let ua = "AppSweep/\(currentVersion)"

        // 1. Fetch Releases list & Tags list
        async let releasesResp = fetchGitHubData(url: releasesListAPI, userAgent: ua)
        async let tagsResp = fetchGitHubData(url: tagsListAPI, userAgent: ua)

        let (relResult, tagResult) = try await (releasesResp, tagsResp)

        // Handle GitHub API rate limiting (403 / 429) gracefully via web redirect fallback
        if relResult.statusCode == 403 || relResult.statusCode == 429 || tagResult.statusCode == 403 || tagResult.statusCode == 429 {
            return await fetchViaHTMLRedirectFallback()
        }

        // If repository does not exist yet on GitHub (404) or is empty
        if relResult.statusCode == 404 && tagResult.statusCode == 404 {
            return nil
        }

        var releases: [GitHubReleaseDTO] = []
        if (200...299).contains(relResult.statusCode), let data = relResult.data {
            releases = ((try? JSONDecoder().decode([GitHubReleaseDTO].self, from: data)) ?? [])
                .filter { $0.draft != true }
        }

        var tags: [GitHubTagDTO] = []
        if (200...299).contains(tagResult.statusCode), let data = tagResult.data {
            tags = (try? JSONDecoder().decode([GitHubTagDTO].self, from: data)) ?? []
        }

        // Find highest version across all published releases and git tags
        var bestRelease: GitHubReleaseDTO? = nil
        for rel in releases {
            let v = Self.cleanVersionString(rel.tag_name)
            guard !v.isEmpty else { continue }
            if let currentBest = bestRelease {
                if Self.isVersion(v, newerThan: Self.cleanVersionString(currentBest.tag_name)) {
                    bestRelease = rel
                }
            } else {
                bestRelease = rel
            }
        }

        var bestTagName: String? = nil
        for t in tags {
            let v = Self.cleanVersionString(t.name)
            guard !v.isEmpty else { continue }
            if let currentBestTag = bestTagName {
                if Self.isVersion(v, newerThan: Self.cleanVersionString(currentBestTag)) {
                    bestTagName = t.name
                }
            } else {
                bestTagName = t.name
            }
        }

        // Case A: Highest release is >= highest tag (or no separate newer tag exists)
        if let rel = bestRelease {
            let relVer = Self.cleanVersionString(rel.tag_name)
            let tagVer = bestTagName.map { Self.cleanVersionString($0) } ?? ""
            if tagVer.isEmpty || !Self.isVersion(tagVer, newerThan: relVer) {
                let (assetURL, kind) = await resolveDownloadAsset(from: rel.assets, rawTag: rel.tag_name, cleanVersion: relVer)
                let page = URL(string: rel.html_url) ?? htmlLatestReleaseURL
                return ReleaseUpdateInfo(
                    rawTag: rel.tag_name,
                    version: relVer,
                    downloadURL: assetURL,
                    assetKind: kind,
                    releasePageURL: page,
                    releaseNotes: rel.body
                )
            }
        }

        // Case B: A newer git tag exists in /tags (probe standard release download URLs for that tag)
        if let rawTag = bestTagName {
            let cleanVer = Self.cleanVersionString(rawTag)
            let matchingRel = releases.first { Self.cleanVersionString($0.tag_name) == cleanVer }
            let (assetURL, kind) = await resolveDownloadAsset(
                from: matchingRel?.assets ?? [],
                rawTag: rawTag,
                cleanVersion: cleanVer
            )
            let page = URL(string: "https://github.com/\(Self.githubOwner)/\(Self.githubRepo)/releases/tag/\(rawTag)") ?? repoHomeURL
            return ReleaseUpdateInfo(
                rawTag: rawTag,
                version: cleanVer,
                downloadURL: assetURL,
                assetKind: kind,
                releasePageURL: page,
                releaseNotes: matchingRel?.body
            )
        }

        return nil
    }

    private func fetchGitHubData(url: URL, userAgent: String) async throws -> (statusCode: Int, data: Data?) {
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (code, data)
    }

    /// Fallback when GitHub REST API hits unauthenticated IP rate limit: resolves `/releases/latest` redirect URL.
    private func fetchViaHTMLRedirectFallback() async -> ReleaseUpdateInfo? {
        var req = URLRequest(url: htmlLatestReleaseURL)
        req.httpMethod = "HEAD"
        req.timeoutInterval = 12
        req.cachePolicy = .reloadIgnoringLocalCacheData

        guard let (_, response) = try? await URLSession.shared.data(for: req),
              let finalURL = response.url else {
            return nil
        }

        // Expected finalURL: https://github.com/hungmtuci/AppSweep/releases/tag/v1.2.0
        let parts = finalURL.pathComponents
        guard let tagIdx = parts.firstIndex(of: "tag"), tagIdx + 1 < parts.count else {
            return nil
        }
        let rawTag = parts[tagIdx + 1]
        let cleanVer = Self.cleanVersionString(rawTag)
        guard !cleanVer.isEmpty else { return nil }

        let (assetURL, kind) = await resolveDownloadAsset(from: [], rawTag: rawTag, cleanVersion: cleanVer)
        return ReleaseUpdateInfo(
            rawTag: rawTag,
            version: cleanVer,
            downloadURL: assetURL,
            assetKind: kind,
            releasePageURL: finalURL,
            releaseNotes: nil
        )
    }

    /// Resolves `.zip` (preferred) or `.dmg` download URL from Release assets, or probes standard naming convention.
    private func resolveDownloadAsset(
        from assets: [GitHubAssetDTO],
        rawTag: String,
        cleanVersion: String
    ) async -> (URL?, AssetKind) {
        if let zipAsset = assets.first(where: { $0.name.lowercased().hasSuffix(".zip") }),
           let url = URL(string: zipAsset.browser_download_url) {
            return (url, .zip)
        }
        if let dmgAsset = assets.first(where: { $0.name.lowercased().hasSuffix(".dmg") }),
           let url = URL(string: dmgAsset.browser_download_url) {
            return (url, .dmg)
        }

        // Probe standard build_appsweep.sh release asset URLs if assets list wasn't populated
        let candidates: [(String, AssetKind)] = [
            ("https://github.com/\(Self.githubOwner)/\(Self.githubRepo)/releases/download/\(rawTag)/AppSweep-v\(cleanVersion)-macOS.zip", .zip),
            ("https://github.com/\(Self.githubOwner)/\(Self.githubRepo)/releases/download/\(rawTag)/AppSweep.zip", .zip),
            ("https://github.com/\(Self.githubOwner)/\(Self.githubRepo)/releases/download/\(rawTag)/AppSweep-Installer-v\(cleanVersion).dmg", .dmg)
        ]

        for (urlStr, kind) in candidates {
            guard let probeURL = URL(string: urlStr) else { continue }
            var headReq = URLRequest(url: probeURL)
            headReq.httpMethod = "HEAD"
            headReq.timeoutInterval = 6
            if let (_, resp) = try? await URLSession.shared.data(for: headReq),
               let http = resp as? HTTPURLResponse,
               (200...399).contains(http.statusCode) {
                return (probeURL, kind)
            }
        }

        return (nil, .zip)
    }

    // MARK: - Download, Atomic Install & Relaunch

    func installAvailableUpdate() {
        guard case let .available(info) = state else { return }

        guard let downloadURL = info.downloadURL else {
            NSWorkspace.shared.open(info.releasePageURL)
            return
        }

        state = .downloading(version: info.version, progress: 0.0)

        Task { @MainActor in
            let stageDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("AppSweepAutoUpdate-\(UUID().uuidString)", isDirectory: true)
            let archiveExt = (info.assetKind == .dmg) ? "dmg" : "zip"
            let archiveDest = stageDir.appendingPathComponent("AppSweep-update.\(archiveExt)")
            let extractDir = stageDir.appendingPathComponent("extracted", isDirectory: true)

            do {
                try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)

                try await downloadFileWithProgress(
                    from: downloadURL,
                    to: archiveDest,
                    version: info.version
                )

                state = .installing(version: info.version)

                let extractedAppURL: URL
                switch info.assetKind {
                case .zip:
                    extractedAppURL = try await Self.extractAndValidateZipOffMain(
                        zipPath: archiveDest.path,
                        extractDirPath: extractDir.path
                    )
                case .dmg:
                    extractedAppURL = try await Self.extractAndValidateDmgOffMain(
                        dmgPath: archiveDest.path,
                        extractDirPath: extractDir.path,
                        stageDirPath: stageDir.path
                    )
                }

                // Update the currently running AppSweep.app bundle (and /Applications/AppSweep.app if also installed)
                let runningBundlePath = Bundle.main.bundleURL.standardizedFileURL.path
                let primaryTargetPath: String = {
                    if runningBundlePath.hasSuffix(".app") {
                        return runningBundlePath
                    }
                    return "/Applications/AppSweep.app"
                }()

                let secondaryApplicationsPath: String? = {
                    let stdApps = "/Applications/AppSweep.app"
                    if primaryTargetPath != stdApps && FileManager.default.fileExists(atPath: stdApps) {
                        return stdApps
                    }
                    return nil
                }()

                let currentPID = ProcessInfo.processInfo.processIdentifier
                try Self.spawnDetachedSwapAndRelaunch(
                    oldPID: currentPID,
                    extractedAppPath: extractedAppURL.path,
                    primaryTargetPath: primaryTargetPath,
                    secondaryTargetPath: secondaryApplicationsPath,
                    stageDirPath: stageDir.path
                )

                NSApp.terminate(nil)
            } catch {
                try? FileManager.default.removeItem(at: stageDir)
                let msg = "Cập nhật tự động thất bại (\(error.localizedDescription)). Đang mở trang GitHub Releases..."
                state = .failed(message: msg)
                MainViewModel.shared.showToast(
                    title: "Cập nhật tự động không thành công",
                    subtitle: error.localizedDescription,
                    isError: true
                )
                NSWorkspace.shared.open(info.releasePageURL)
            }
        }
    }

    private func downloadFileWithProgress(from url: URL, to destination: URL, version: String) async throws {
        var req = URLRequest(url: url)
        req.timeoutInterval = 120
        req.setValue("AppSweep/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        let tempFileURL = try await NativeChunkedDownloader.download(request: req) { [weak self] pct in
            Task { @MainActor in
                guard let self else { return }
                if case .downloading = self.state {
                    self.state = .downloading(version: version, progress: pct)
                }
            }
        }

        if FileManager.default.fileExists(atPath: destination.path) {
            try? FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: tempFileURL, to: destination)
        state = .downloading(version: version, progress: 1.0)
    }

    // MARK: - Archive Extraction & Validation Helpers

    nonisolated private static func extractAndValidateZipOffMain(
        zipPath: String,
        extractDirPath: String
    ) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                proc.arguments = ["-x", "-k", zipPath, extractDirPath]
                do {
                    try proc.run()
                    proc.waitUntilExit()
                    guard proc.terminationStatus == 0 else {
                        throw NSError(domain: "AppSweepUpdate", code: Int(proc.terminationStatus), userInfo: [
                            NSLocalizedDescriptionKey: "Giải nén gói .zip thất bại (mã \(proc.terminationStatus))"
                        ])
                    }
                    guard let validApp = locateValidAppBundle(in: URL(fileURLWithPath: extractDirPath)) else {
                        throw NSError(domain: "AppSweepUpdate", code: -2, userInfo: [
                            NSLocalizedDescriptionKey: "Không tìm thấy AppSweep.app hợp lệ bên trong gói tải về"
                        ])
                    }
                    continuation.resume(returning: validApp)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    nonisolated private static func extractAndValidateDmgOffMain(
        dmgPath: String,
        extractDirPath: String,
        stageDirPath: String
    ) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let mountPoint = (stageDirPath as NSString).appendingPathComponent("dmg_mount")
                try? FileManager.default.createDirectory(atPath: mountPoint, withIntermediateDirectories: true)

                let attach = Process()
                attach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
                attach.arguments = ["attach", dmgPath, "-mountpoint", mountPoint, "-nobrowse", "-readonly", "-quiet"]

                defer {
                    let detach = Process()
                    detach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
                    detach.arguments = ["detach", mountPoint, "-force", "-quiet"]
                    try? detach.run()
                    detach.waitUntilExit()
                }

                do {
                    try attach.run()
                    attach.waitUntilExit()
                    guard attach.terminationStatus == 0 else {
                        throw NSError(domain: "AppSweepUpdate", code: Int(attach.terminationStatus), userInfo: [
                            NSLocalizedDescriptionKey: "Không thể mở bộ cài .dmg (mã \(attach.terminationStatus))"
                        ])
                    }

                    guard let mountedApp = locateValidAppBundle(in: URL(fileURLWithPath: mountPoint)) else {
                        throw NSError(domain: "AppSweepUpdate", code: -3, userInfo: [
                            NSLocalizedDescriptionKey: "Không tìm thấy AppSweep.app bên trong file .dmg"
                        ])
                    }

                    let copiedApp = URL(fileURLWithPath: extractDirPath).appendingPathComponent("AppSweep.app")
                    let copyProc = Process()
                    copyProc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                    copyProc.arguments = ["--noextattr", mountedApp.path, copiedApp.path]
                    try copyProc.run()
                    copyProc.waitUntilExit()

                    guard copyProc.terminationStatus == 0,
                          let validated = locateValidAppBundle(in: URL(fileURLWithPath: extractDirPath)) else {
                        throw NSError(domain: "AppSweepUpdate", code: -4, userInfo: [
                            NSLocalizedDescriptionKey: "Sao chép AppSweep.app từ .dmg thất bại"
                        ])
                    }
                    continuation.resume(returning: validated)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    nonisolated private static func isValidExtractedAppBundle(_ appURL: URL) -> Bool {
        let fm = FileManager.default
        let execPath = appURL.appendingPathComponent("Contents/MacOS/AppSweep").path
        guard fm.isExecutableFile(atPath: execPath) else { return false }

        let infoURL = appURL.appendingPathComponent("Contents/Info.plist")
        if let dict = NSDictionary(contentsOf: infoURL) as? [String: Any],
           let bid = dict["CFBundleIdentifier"] as? String {
            return bid == "com.hunglx.AppSweep"
        }
        return false
    }

    nonisolated private static func locateValidAppBundle(in rootDir: URL, maxDepth: Int = 2) -> URL? {
        let fm = FileManager.default
        let directCandidate = rootDir.appendingPathComponent("AppSweep.app")
        if isValidExtractedAppBundle(directCandidate) {
            return directCandidate
        }

        guard maxDepth > 0,
              let entries = try? fm.contentsOfDirectory(
                  at: rootDir,
                  includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                  options: [.skipsHiddenFiles]
              ) else {
            return nil
        }

        for entry in entries {
            let vals = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if vals?.isSymbolicLink == true { continue }
            if entry.pathExtension.lowercased() == "app" {
                if isValidExtractedAppBundle(entry) {
                    return entry
                }
            } else if vals?.isDirectory == true {
                if let nested = locateValidAppBundle(in: entry, maxDepth: maxDepth - 1) {
                    return nested
                }
            }
        }
        return nil
    }

    nonisolated private static func spawnDetachedSwapAndRelaunch(
        oldPID: pid_t,
        extractedAppPath: String,
        primaryTargetPath: String,
        secondaryTargetPath: String?,
        stageDirPath: String
    ) throws {
        // Waits for old AppSweep PID to exit, swaps bundle(s) cleanly (elevating via AppleScript only if permission denied),
        // strips Gatekeeper quarantine, relaunches AppSweep, and deletes temporary staging files.
        let script = """
        OLD_PID="$1"
        SRC_APP="$2"
        DST_APP="$3"
        DST_SECONDARY="$4"
        STAGE_DIR="$5"

        for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
            kill -0 "$OLD_PID" 2>/dev/null || break
            sleep 0.2
        done

        DST_PARENT="$(dirname "$DST_APP")"
        if [ -w "$DST_PARENT" ] && { [ ! -e "$DST_APP" ] || [ -w "$DST_APP" ]; } && rm -rf "$DST_APP" 2>/dev/null && /usr/bin/ditto --noextattr "$SRC_APP" "$DST_APP" 2>/dev/null; then
            /usr/bin/xattr -cr "$DST_APP" 2>/dev/null || true
        else
            /usr/bin/osascript -e "do shell script \\"rm -rf '$DST_APP' && /usr/bin/ditto --noextattr '$SRC_APP' '$DST_APP' && /usr/bin/xattr -cr '$DST_APP'\\" with administrator privileges" 2>/dev/null || true
        fi

        if [ -n "$DST_SECONDARY" ] && [ -d "$DST_SECONDARY" ]; then
            rm -rf "$DST_SECONDARY" 2>/dev/null && /usr/bin/ditto --noextattr "$SRC_APP" "$DST_SECONDARY" 2>/dev/null || true
            /usr/bin/xattr -cr "$DST_SECONDARY" 2>/dev/null || true
        fi

        /usr/bin/open "$DST_APP"
        rm -rf "$STAGE_DIR"
        """

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/nohup")
        proc.arguments = [
            "/bin/sh",
            "-c",
            script,
            "appsweep-updater",
            "\(oldPID)",
            extractedAppPath,
            primaryTargetPath,
            secondaryTargetPath ?? "",
            stageDirPath
        ]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
    }

    // MARK: - Semantic Version Comparison

    nonisolated static func cleanVersionString(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix("v") || s.hasPrefix("V") {
            s.removeFirst()
        }
        // Strip optional build/prerelease suffix after '-' if comparing numeric core
        if let dashIndex = s.firstIndex(of: "-") {
            s = String(s[..<dashIndex])
        }
        return s
    }

    nonisolated static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        let lhs = cleanVersionString(candidate).split(separator: ".").map { Int($0) ?? 0 }
        let rhs = cleanVersionString(current).split(separator: ".").map { Int($0) ?? 0 }
        guard !lhs.isEmpty else { return false }
        let count = max(lhs.count, rhs.count)
        for i in 0..<count {
            let a = i < lhs.count ? lhs[i] : 0
            let b = i < rhs.count ? rhs[i] : 0
            if a != b {
                return a > b
            }
        }
        return false
    }
}

/// High-speed off-main-thread downloader using `URLSessionDownloadDelegate` with throttled progress callbacks.
private final class NativeChunkedDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Double) -> Void
    private var continuation: CheckedContinuation<URL, Error>?
    private var savedTempURL: URL?
    private var lastReportTime: CFAbsoluteTime = 0
    private let lock = NSLock()

    private init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    static func download(
        request: URLRequest,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        try await withCheckedThrowingContinuation { cont in
            let delegate = NativeChunkedDownloader(onProgress: onProgress)
            delegate.continuation = cont
            let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
            let task = session.downloadTask(with: request)
            task.resume()
            session.finishTasksAndInvalidate()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        let shouldUpdate = (now - lastReportTime) >= 0.06
        if shouldUpdate { lastReportTime = now }
        lock.unlock()

        if shouldUpdate {
            let pct = min(0.99, max(0.01, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
            onProgress(pct)
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            finishOnce(with: .failure(NSError(
                domain: "AppSweepUpdate",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Máy chủ GitHub trả về mã HTTP \(http.statusCode)"]
            )))
            return
        }

        let preserved = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AppSweepDL-\(UUID().uuidString).tmp")
        do {
            try FileManager.default.moveItem(at: location, to: preserved)
            lock.lock()
            savedTempURL = preserved
            lock.unlock()
        } catch {
            finishOnce(with: .failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finishOnce(with: .failure(error))
            return
        }
        lock.lock()
        let url = savedTempURL
        lock.unlock()
        if let url {
            finishOnce(with: .success(url))
        } else {
            finishOnce(with: .failure(NSError(
                domain: "AppSweepUpdate",
                code: -10,
                userInfo: [NSLocalizedDescriptionKey: "Không nhận được tệp tải về từ GitHub"]
            )))
        }
    }

    private func finishOnce(with result: Result<URL, Error>) {
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume(with: result)
    }
}
