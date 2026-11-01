import Darwin
import Foundation

enum DeepFileScanner {
    /// Protected system & user directories that must NEVER be offered for deletion.
    private static let protectedExactPaths: Set<String> = {
        let home = NSHomeDirectory()
        return Set([
            "/",
            "/System",
            "/Applications",
            "/Library",
            "/Users",
            "/bin",
            "/sbin",
            "/usr",
            "/var",
            "/private",
            "/private/var",
            home,
            "\(home)/Desktop",
            "\(home)/Documents",
            "\(home)/Downloads",
            "\(home)/Movies",
            "\(home)/Music",
            "\(home)/Pictures",
            "\(home)/Public",
            "\(home)/Library",
            "\(home)/Library/Application Support",
            "\(home)/Library/Caches",
            "\(home)/Library/Containers",
            "\(home)/Library/Group Containers",
            "\(home)/Library/Preferences",
            "\(home)/Library/LaunchAgents",
            "\(home)/.Trash",
            "\(home)/.config",
            "\(home)/.cache",
            "\(home)/.local",
            "\(home)/.local/share",
            "\(home)/.ssh",
            "\(home)/.gnupg",
            "\(home)/.zshrc",
            "\(home)/.zprofile",
            "\(home)/.bashrc",
            "\(home)/.gitconfig",
            "\(home)/.npm",
            "\(home)/.nvm",
            "\(home)/.cargo",
            "\(home)/.rustup"
        ])
    }()

    /// Generic words that must never be used alone as loose name tokens.
    private static let genericTokens: Set<String> = [
        "app", "mac", "macos", "osx", "helper", "agent", "daemon", "client",
        "desktop", "updater", "update", "installer", "uninstaller", "launcher",
        "viewer", "player", "editor", "studio", "pro", "free", "lite", "plus",
        "server", "service", "browser", "system", "apple", "common", "shared",
        "default", "main", "core", "data", "cache", "config", "preferences",
        "support", "manager", "tool", "tools", "utility", "utilities"
    ]

    private static let cachedDarwinCacheDir: String? = resolveDarwinUserDir(_CS_DARWIN_USER_CACHE_DIR)
    private static let cachedDarwinTempDir: String? = resolveDarwinUserDir(_CS_DARWIN_USER_TEMP_DIR)

    private struct PendingCandidate {
        let path: String
        let name: String
        let category: FileCategory
        let confidence: MatchConfidence
        let matchReason: String
        let isDirectory: Bool
        let isSelected: Bool
    }

    static func scanAssociatedFiles(
        for target: TargetBundle,
        systemIndex: InstalledSystemIndex
    ) -> [AssociatedFileItem] {
        let home = NSHomeDirectory()
        var pendingByPath: [String: PendingCandidate] = [:]

        func addCandidate(
            url: URL,
            category: FileCategory,
            confidence: MatchConfidence,
            reason: String,
            autoSelect: Bool? = nil
        ) {
            let standardized = url.standardizedFileURL.path
            guard !isBlockedSystemOrProtectedPath(standardized, target: target) else { return }

            var st = stat()
            guard lstat(standardized, &st) == 0 else { return }

            // Skip child paths inside target.app itself
            if standardized != target.path && standardized.hasPrefix(target.path + "/") {
                return
            }

            if let existing = pendingByPath[standardized] {
                if existing.confidence == .exact || confidence != .exact {
                    return
                }
            }

            let isDir = (st.st_mode & S_IFMT) == S_IFDIR
            let defaultSelected: Bool = {
                if target.isSystemProtected { return false }
                if let autoSelect { return autoSelect }
                return confidence != .sharedVendor
            }()

            pendingByPath[standardized] = PendingCandidate(
                path: standardized,
                name: (standardized as NSString).lastPathComponent,
                category: category,
                confidence: confidence,
                matchReason: reason,
                isDirectory: isDir,
                isSelected: defaultSelected
            )
        }

        // 1. Primary Bundle (.app or addon)
        let rootCategory: FileCategory = (target.kind == .application) ? .appBundle : .addonBundle
        addCandidate(
            url: target.url,
            category: rootCategory,
            confidence: .exact,
            reason: target.isSystemProtected ? "Ứng dụng hệ thống macOS (Được bảo vệ)" : "Gói cài đặt gốc",
            autoSelect: !target.isSystemProtected
        )

        // Build identity signals
        let primaryID = target.bundleIdentifier.lowercased()
        var exactBundleIDs = Set<String>()
        if !primaryID.isEmpty, (!primaryID.hasPrefix("com.apple.") || !target.isSystemProtected) {
            exactBundleIDs.insert(primaryID)
        }
        for child in target.childBundleIdentifiers {
            let lower = child.lowercased()
            if !lower.isEmpty {
                exactBundleIDs.insert(lower)
            }
        }
        for helperLabel in target.privilegedHelperLabels {
            let lower = helperLabel.lowercased()
            if !lower.isEmpty {
                exactBundleIDs.insert(lower)
            }
        }

        let nameCandidates = buildSafeNameVariants(for: target)
        let vendorFolderToken = extractVendorNameToken(from: primaryID)

        let hasSiblingTeamApps: Bool = {
            guard let team = target.teamIdentifier, !team.isEmpty else { return false }
            let paths = systemIndex.teamIDToAppPaths[team] ?? []
            return !paths.subtracting([target.path]).isEmpty
        }()

        // 2. Scan Standard Directory Locations
        var scanSpecs: [(String, FileCategory, Bool)] = [
            ("\(home)/Library/Application Support", .applicationSupport, true),
            ("/Library/Application Support", .applicationSupport, true),
            ("/Users/Shared", .applicationSupport, false),
            ("\(home)/Library/Caches", .caches, true),
            ("/Library/Caches", .caches, true),
            ("\(home)/Library/Preferences", .preferences, false),
            ("\(home)/Library/Preferences/ByHost", .preferences, false),
            ("/Library/Preferences", .preferences, false),
            ("\(home)/Library/Saved Application State", .savedState, false),
            ("\(home)/Library/Autosave Information", .savedState, false),
            ("\(home)/Library/HTTPStorages", .webData, false),
            ("\(home)/Library/WebKit", .webData, true),
            ("\(home)/Library/Cookies", .webData, false),
            ("\(home)/Library/Logs", .logs, true),
            ("/Library/Logs", .logs, true),
            ("\(home)/Library/Application Scripts", .containers, false),
            ("/Library/PrivilegedHelperTools", .launchDaemons, false)
        ]

        if let darwinCache = cachedDarwinCacheDir {
            scanSpecs.append((darwinCache, .caches, false))
        }
        if let darwinTemp = cachedDarwinTempDir {
            scanSpecs.append((darwinTemp, .caches, false))
        }

        for (dirPath, category, allowNameMatch) in scanSpecs {
            if Task.isCancelled { break }
            scanDirectoryEntries(
                at: dirPath,
                category: category,
                allowNameMatch: allowNameMatch,
                exactBundleIDs: exactBundleIDs,
                nameVariants: nameCandidates,
                vendorToken: vendorFolderToken,
                target: target,
                systemIndex: systemIndex,
                addCandidate: addCandidate
            )
        }

        // 3. Scan ~/Library/Containers
        scanSandboxContainers(
            at: "\(home)/Library/Containers",
            exactBundleIDs: exactBundleIDs,
            addCandidate: addCandidate
        )

        // 4. Scan ~/Library/Group Containers
        scanGroupContainers(
            at: "\(home)/Library/Group Containers",
            exactBundleIDs: exactBundleIDs,
            nameVariants: nameCandidates,
            teamID: target.teamIdentifier,
            hasSiblingTeamApps: hasSiblingTeamApps,
            addCandidate: addCandidate
        )

        // 5. Scan LaunchAgents & LaunchDaemons
        let launchDirs = [
            "\(home)/Library/LaunchAgents",
            "/Library/LaunchAgents",
            "/Library/LaunchDaemons"
        ]
        for ldir in launchDirs {
            scanLaunchDirectory(
                at: ldir,
                exactBundleIDs: exactBundleIDs,
                nameVariants: nameCandidates,
                target: target,
                addCandidate: addCandidate
            )
        }

        // 6. Scan Crash & Diagnostic Reports
        let diagDirs = [
            "\(home)/Library/Logs/DiagnosticReports",
            "/Library/Logs/DiagnosticReports",
            "\(home)/Library/Application Support/CrashReporter"
        ]
        for ddir in diagDirs {
            scanDiagnosticReports(
                at: ddir,
                target: target,
                exactBundleIDs: exactBundleIDs,
                addCandidate: addCandidate
            )
        }

        // 7. Scan Installer Receipts (/private/var/db/receipts)
        scanInstallerReceipts(
            at: "/private/var/db/receipts",
            exactBundleIDs: exactBundleIDs,
            addCandidate: addCandidate
        )

        // 8. Scan Developer & CLI Configs (~/.config, ~/.cache, ~/.local/share, exact ~/.<app>)
        scanDotConfigLocations(
            home: home,
            exactBundleIDs: exactBundleIDs,
            nameVariants: nameCandidates,
            target: target,
            systemIndex: systemIndex,
            addCandidate: addCandidate
        )

        // 9. Scan Companion Plugins / QuickLook / PreferencePanes / Services
        if target.kind == .application {
            let companionDirs = [
                "\(home)/Library/PreferencePanes",
                "/Library/PreferencePanes",
                "\(home)/Library/QuickLook",
                "/Library/QuickLook",
                "\(home)/Library/Screen Savers",
                "\(home)/Library/Services",
                "\(home)/Library/Internet Plug-Ins"
            ]
            for cdir in companionDirs {
                scanDirectoryEntries(
                    at: cdir,
                    category: .addonBundle,
                    allowNameMatch: true,
                    exactBundleIDs: exactBundleIDs,
                    nameVariants: nameCandidates,
                    vendorToken: nil,
                    target: target,
                    systemIndex: systemIndex,
                    addCandidate: addCandidate
                )
            }
        }

        // Prune nested child candidates if an ancestor directory is already matched (prevents double-counting bytes!)
        let allPaths = Set(pendingByPath.keys)
        let dedupedPending: [PendingCandidate] = pendingByPath.values.filter { candidate in
            var parent = (candidate.path as NSString).deletingLastPathComponent
            while parent.count > 1 && parent != "/" {
                if allPaths.contains(parent) {
                    return false
                }
                parent = (parent as NSString).deletingLastPathComponent
            }
            return true
        }

        guard !dedupedPending.isEmpty else { return [] }

        // Compute allocated disk sizes & privilege requirements concurrently across CPU cores!
        let lock = NSLock()
        var finalized: [AssociatedFileItem] = []
        finalized.reserveCapacity(dedupedPending.count)

        DispatchQueue.concurrentPerform(iterations: dedupedPending.count) { idx in
            if Task.isCancelled { return }
            let item = dedupedPending[idx]
            let size = DiskSizeCalculator.allocatedSize(atPath: item.path)
            let needsAdmin = DiskSizeCalculator.requiresAdminToModify(path: item.path)

            let built = AssociatedFileItem(
                id: item.path,
                path: item.path,
                name: item.name,
                category: item.category,
                sizeBytes: size,
                confidence: item.confidence,
                matchReason: item.matchReason,
                requiresAdmin: needsAdmin,
                isDirectory: item.isDirectory,
                isSelected: item.isSelected
            )

            lock.lock()
            finalized.append(built)
            lock.unlock()
        }

        return finalized.sorted { lhs, rhs in
            if lhs.category.sortPriority != rhs.category.sortPriority {
                return lhs.category.sortPriority < rhs.category.sortPriority
            }
            if lhs.sizeBytes != rhs.sizeBytes {
                return lhs.sizeBytes > rhs.sizeBytes
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    // MARK: - Specialized Scanners

    private static func scanDirectoryEntries(
        at dirPath: String,
        category: FileCategory,
        allowNameMatch: Bool,
        exactBundleIDs: Set<String>,
        nameVariants: [NameVariant],
        vendorToken: String?,
        target: TargetBundle,
        systemIndex: InstalledSystemIndex,
        addCandidate: (URL, FileCategory, MatchConfidence, String, Bool?) -> Void
    ) {
        let fm = FileManager.default
        let dirURL = URL(fileURLWithPath: dirPath)
        guard let entries = try? fm.contentsOfDirectory(
            at: dirURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for entry in entries {
            let itemName = entry.lastPathComponent
            let lowerName = itemName.lowercased()

            if let matchedID = matchBundleID(itemName: lowerName, exactBundleIDs: exactBundleIDs) {
                addCandidate(entry, category, .exact, "Khớp Bundle ID (\(matchedID))", nil)
                continue
            }

            if allowNameMatch, let matchedVariant = matchAppNameVariant(
                itemName: itemName,
                variants: nameVariants,
                target: target,
                systemIndex: systemIndex
            ) {
                addCandidate(entry, category, .strong, "Khớp tên ứng dụng (\(matchedVariant))", nil)
                continue
            }

            if allowNameMatch, let vendor = vendorToken,
               AppCatalogService.normalizeToken(itemName) == vendor {
                if let subEntries = try? fm.contentsOfDirectory(
                    at: entry,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                ) {
                    for sub in subEntries {
                        let subName = sub.lastPathComponent
                        if let matchedID = matchBundleID(itemName: subName.lowercased(), exactBundleIDs: exactBundleIDs) {
                            addCandidate(sub, category, .exact, "Thư mục hãng → Bundle ID (\(matchedID))", nil)
                        } else if let matchedVar = matchAppNameVariant(
                            itemName: subName,
                            variants: nameVariants,
                            target: target,
                            systemIndex: systemIndex
                        ) {
                            addCandidate(sub, category, .strong, "Thư mục hãng (\(itemName)/\(matchedVar))", nil)
                        }
                    }
                }
            }
        }
    }

    private static func scanSandboxContainers(
        at containersPath: String,
        exactBundleIDs: Set<String>,
        addCandidate: (URL, FileCategory, MatchConfidence, String, Bool?) -> Void
    ) {
        guard !exactBundleIDs.isEmpty else { return }
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: URL(fileURLWithPath: containersPath),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        for entry in entries {
            let folderName = entry.lastPathComponent.lowercased()
            if let matchedID = matchBundleID(itemName: folderName, exactBundleIDs: exactBundleIDs) {
                addCandidate(entry, .containers, .exact, "Sandbox Container (\(matchedID))", nil)
                continue
            }

            let metaURL = entry.appendingPathComponent(".com.apple.containermanagerd.metadata.plist")
            if let dict = NSDictionary(contentsOf: metaURL) as? [String: Any],
               let metaID = (dict["MCMMetadataIdentifier"] as? String)?.lowercased() {
                if exactBundleIDs.contains(metaID) || exactBundleIDs.contains(where: { metaID.hasPrefix($0 + ".") }) {
                    addCandidate(entry, .containers, .exact, "Sandbox Container Metadata (\(metaID))", nil)
                }
            }
        }
    }

    private static func scanGroupContainers(
        at groupContainersPath: String,
        exactBundleIDs: Set<String>,
        nameVariants: [NameVariant],
        teamID: String?,
        hasSiblingTeamApps: Bool,
        addCandidate: (URL, FileCategory, MatchConfidence, String, Bool?) -> Void
    ) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: URL(fileURLWithPath: groupContainersPath),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        let lowerTeam = teamID?.lowercased()

        for entry in entries {
            let name = entry.lastPathComponent
            let lower = name.lowercased()

            if let matchedID = exactBundleIDs.first(where: { id in
                lower == id
                || lower.hasPrefix(id + ".")
                || lower == "group.\(id)"
                || lower.hasPrefix("group.\(id).")
                || lower.hasSuffix(".\(id)")
                || lower.contains(".\(id).")
            }) {
                addCandidate(entry, .containers, .exact, "Group Container (\(matchedID))", nil)
                continue
            }

            if let lowerTeam, !lowerTeam.isEmpty, lower.hasPrefix(lowerTeam + ".") {
                let suffix = String(lower.dropFirst(lowerTeam.count + 1))
                let normSuffix = AppCatalogService.normalizeToken(suffix)
                let mentionsThisApp = nameVariants.contains { variant in
                    variant.normalized.count >= 4 && normSuffix.contains(variant.normalized)
                }
                if mentionsThisApp || !hasSiblingTeamApps {
                    addCandidate(entry, .containers, .exact, "Team Group Container (\(teamID!))", true)
                } else {
                    addCandidate(
                        entry,
                        .containers,
                        .sharedVendor,
                        "Dùng chung Team ID (\(teamID!)) với ứng dụng cùng hãng",
                        false
                    )
                }
            }
        }
    }

    private static func scanLaunchDirectory(
        at dirPath: String,
        exactBundleIDs: Set<String>,
        nameVariants: [NameVariant],
        target: TargetBundle,
        addCandidate: (URL, FileCategory, MatchConfidence, String, Bool?) -> Void
    ) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: URL(fileURLWithPath: dirPath),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        for entry in entries where entry.pathExtension.lowercased() == "plist" {
            let stem = entry.deletingPathExtension().lastPathComponent.lowercased()

            if let matchedID = matchBundleID(itemName: stem, exactBundleIDs: exactBundleIDs) {
                addCandidate(entry, .launchDaemons, .exact, "Launch plist (\(matchedID))", nil)
                if let dict = NSDictionary(contentsOf: entry) as? [String: Any] {
                    inspectHelperBinaryInLaunchDict(dict, plistName: entry.lastPathComponent, addCandidate: addCandidate)
                }
                continue
            }

            // Parse plist content once
            guard let dict = NSDictionary(contentsOf: entry) as? [String: Any] else { continue }

            if let label = (dict["Label"] as? String)?.lowercased(),
               let matchedID = matchBundleID(itemName: label, exactBundleIDs: exactBundleIDs) {
                addCandidate(entry, .launchDaemons, .exact, "Launch Label (\(matchedID))", nil)
                inspectHelperBinaryInLaunchDict(dict, plistName: entry.lastPathComponent, addCandidate: addCandidate)
                continue
            }

            var assocIDs: [String] = []
            if let single = dict["AssociatedBundleIdentifiers"] as? String {
                assocIDs.append(single.lowercased())
            } else if let array = dict["AssociatedBundleIdentifiers"] as? [String] {
                assocIDs.append(contentsOf: array.map { $0.lowercased() })
            }
            if let matchedAssoc = assocIDs.first(where: { assoc in
                exactBundleIDs.contains(assoc) || exactBundleIDs.contains(where: { assoc.hasPrefix($0 + ".") })
            }) {
                addCandidate(entry, .launchDaemons, .exact, "AssociatedBundleIdentifier (\(matchedAssoc))", nil)
                inspectHelperBinaryInLaunchDict(dict, plistName: entry.lastPathComponent, addCandidate: addCandidate)
                continue
            }

            let programPath: String? = {
                if let prog = dict["Program"] as? String { return prog }
                if let args = dict["ProgramArguments"] as? [String], let first = args.first { return first }
                return nil
            }()

            if let programPath {
                if programPath == target.path || programPath.hasPrefix(target.path + "/") {
                    addCandidate(entry, .launchDaemons, .exact, "Trỏ trực tiếp tới \(target.name)", nil)
                    continue
                }
                let normStem = AppCatalogService.normalizeToken(stem)
                let normProgram = AppCatalogService.normalizeToken(programPath)
                if nameVariants.contains(where: { v in
                    v.normalized.count >= 5 && normStem.contains(v.normalized) && normProgram.contains(v.normalized)
                }) {
                    addCandidate(entry, .launchDaemons, .strong, "LaunchAgent thực thi tiến trình của \(target.name)", nil)
                }
            }
        }
    }

    private static func inspectHelperBinaryInLaunchDict(
        _ dict: [String: Any],
        plistName: String,
        addCandidate: (URL, FileCategory, MatchConfidence, String, Bool?) -> Void
    ) {
        let programPath: String? = {
            if let prog = dict["Program"] as? String { return prog }
            if let args = dict["ProgramArguments"] as? [String], let first = args.first { return first }
            return nil
        }()
        guard let programPath, programPath.hasPrefix("/Library/PrivilegedHelperTools/") else { return }
        addCandidate(
            URL(fileURLWithPath: programPath),
            .launchDaemons,
            .exact,
            "Privileged Helper được khai báo trong \(plistName)",
            nil
        )
    }

    private static func scanDiagnosticReports(
        at dirPath: String,
        target: TargetBundle,
        exactBundleIDs: Set<String>,
        addCandidate: (URL, FileCategory, MatchConfidence, String, Bool?) -> Void
    ) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: URL(fileURLWithPath: dirPath),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        let execLower = target.executableName.lowercased()
        let appLower = target.name.lowercased()

        for entry in entries {
            let lower = entry.lastPathComponent.lowercased()
            if execLower.count >= 3, (lower.hasPrefix(execLower + "-") || lower.hasPrefix(execLower + "_")) {
                addCandidate(entry, .logs, .exact, "Báo cáo lỗi Crash/IPS (\(target.executableName))", nil)
            } else if appLower.count >= 4, (lower.hasPrefix(appLower + "-") || lower.hasPrefix(appLower + "_")) {
                addCandidate(entry, .logs, .strong, "Báo cáo lỗi Crash/IPS (\(target.name))", nil)
            } else if let matchedID = matchBundleID(itemName: lower, exactBundleIDs: exactBundleIDs) {
                addCandidate(entry, .logs, .exact, "Báo cáo lỗi (\(matchedID))", nil)
            }
        }
    }

    private static func scanInstallerReceipts(
        at receiptsDir: String,
        exactBundleIDs: Set<String>,
        addCandidate: (URL, FileCategory, MatchConfidence, String, Bool?) -> Void
    ) {
        guard !exactBundleIDs.isEmpty else { return }
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: URL(fileURLWithPath: receiptsDir),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        for entry in entries {
            let ext = entry.pathExtension.lowercased()
            guard ext == "bom" || ext == "plist" else { continue }
            let stem = entry.deletingPathExtension().lastPathComponent.lowercased()
            if let matchedID = matchBundleID(itemName: stem, exactBundleIDs: exactBundleIDs) {
                addCandidate(entry, .receiptsAndConfig, .exact, "Biên lai gói cài đặt .pkg (\(matchedID))", nil)
            }
        }
    }

    private static func scanDotConfigLocations(
        home: String,
        exactBundleIDs: Set<String>,
        nameVariants: [NameVariant],
        target: TargetBundle,
        systemIndex: InstalledSystemIndex,
        addCandidate: (URL, FileCategory, MatchConfidence, String, Bool?) -> Void
    ) {
        let fm = FileManager.default
        let xdgDirs = [
            "\(home)/.config",
            "\(home)/.cache",
            "\(home)/.local/share"
        ]

        for xdg in xdgDirs {
            guard let entries = try? fm.contentsOfDirectory(
                at: URL(fileURLWithPath: xdg),
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }

            for entry in entries {
                let name = entry.lastPathComponent
                if let matchedID = matchBundleID(itemName: name.lowercased(), exactBundleIDs: exactBundleIDs) {
                    addCandidate(entry, .receiptsAndConfig, .exact, "Cấu hình XDG (\(matchedID))", nil)
                } else if let matchedVar = matchAppNameVariant(
                    itemName: name,
                    variants: nameVariants,
                    target: target,
                    systemIndex: systemIndex,
                    requireExactOnly: true
                ) {
                    addCandidate(entry, .receiptsAndConfig, .strong, "Thư mục cấu hình ẩn (\(matchedVar))", nil)
                }
            }
        }

        var exactDotTokens = Set<String>()
        for v in nameVariants where v.normalized.count >= 4 {
            exactDotTokens.insert(v.normalized)
            exactDotTokens.insert(v.hyphenated)
        }
        let lowerBID = target.bundleIdentifier.lowercased()
        if lowerBID == "com.microsoft.vscode" {
            exactDotTokens.insert("vscode")
        } else if lowerBID.hasPrefix("com.todesktop.") && target.name.lowercased() == "cursor" {
            exactDotTokens.insert("cursor")
        }

        for token in exactDotTokens where token.count >= 4 && !genericTokens.contains(token) {
            let dotPath = "\(home)/.\(token)"
            if !protectedExactPaths.contains(dotPath) {
                var st = stat()
                if lstat(dotPath, &st) == 0 {
                    addCandidate(
                        URL(fileURLWithPath: dotPath),
                        .receiptsAndConfig,
                        .strong,
                        "Thư mục cấu hình ẩn tại Home (~/.@)".replacingOccurrences(of: "@", with: token),
                        nil
                    )
                }
            }
        }
    }

    // MARK: - Matching Helpers & Guards

    private struct NameVariant {
        let raw: String
        let normalized: String
        let hyphenated: String
        let words: [String]
    }

    private static func buildSafeNameVariants(for target: TargetBundle) -> [NameVariant] {
        var rawCandidates: [String] = [target.name, target.bundleName]
        let fileStem = URL(fileURLWithPath: target.path).deletingPathExtension().lastPathComponent
        rawCandidates.append(fileStem)
        if target.executableName.count >= 4 {
            rawCandidates.append(target.executableName)
        }

        var seen = Set<String>()
        var variants: [NameVariant] = []

        for raw in rawCandidates {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let norm = AppCatalogService.normalizeToken(trimmed)
            guard norm.count >= 3, !genericTokens.contains(norm) else { continue }
            guard seen.insert(norm).inserted else { continue }

            let words = splitIntoWords(trimmed)
            let hyphenated = words.joined(separator: "-")
            variants.append(NameVariant(raw: trimmed, normalized: norm, hyphenated: hyphenated, words: words))
        }
        return variants
    }

    private static let removableFileSuffixes = [
        ".savedstate", ".binarycookies", ".plist", ".bom",
        ".sfl2", ".sfl3", ".lockfile"
    ]

    private static func matchBundleID(itemName: String, exactBundleIDs: Set<String>) -> String? {
        guard !exactBundleIDs.isEmpty else { return nil }
        var base = itemName
        for suffix in removableFileSuffixes where base.hasSuffix(suffix) {
            base = String(base.dropLast(suffix.count))
            break
        }

        if exactBundleIDs.contains(base) {
            return base
        }
        for id in exactBundleIDs {
            if base.hasPrefix(id + ".") || base == "group.\(id)" || base.hasPrefix("group.\(id).") {
                return id
            }
        }
        return nil
    }

    private static let knownStemExtensions: Set<String> = [
        "plist", "savedstate", "caches", "log", "out", "err",
        "prefpane", "qlgenerator", "saver", "plugin", "service"
    ]

    private static func matchAppNameVariant(
        itemName: String,
        variants: [NameVariant],
        target: TargetBundle,
        systemIndex: InstalledSystemIndex,
        requireExactOnly: Bool = false
    ) -> String? {
        guard !variants.isEmpty else { return nil }
        let lowerItem = itemName.lowercased()
        if lowerItem.hasPrefix("com.apple.") {
            return nil
        }
        if looksLikeBundleID(lowerItem) {
            if systemIndex.allKnownBundleIDs.contains(lowerItem),
               lowerItem != target.bundleIdentifier.lowercased() {
                return nil
            }
        }

        let cleanStem: String = {
            let ext = (itemName as NSString).pathExtension.lowercased()
            if !ext.isEmpty && knownStemExtensions.contains(ext) {
                return (itemName as NSString).deletingPathExtension
            }
            return itemName
        }()

        let itemNorm = AppCatalogService.normalizeToken(cleanStem)
        guard itemNorm.count >= 3 else { return nil }
        let itemWords = splitIntoWords(cleanStem)

        for variant in variants {
            if itemNorm == variant.normalized {
                return variant.raw
            }

            if requireExactOnly || variant.normalized.count < 5 {
                continue
            }

            if itemWords.count > variant.words.count,
               !variant.words.isEmpty,
               itemWords.starts(with: variant.words) {
                if systemIndex.allKnownAppNamesNormalized.contains(itemNorm) && itemNorm != variant.normalized {
                    continue
                }
                return variant.raw
            }
        }
        return nil
    }

    private static func extractVendorNameToken(from lowerBundleID: String) -> String? {
        let parts = lowerBundleID.split(separator: ".").map(String.init)
        guard parts.count >= 3 else { return nil }
        let tlds: Set<String> = ["com", "org", "net", "io", "app", "dev", "me", "co"]
        guard tlds.contains(parts[0]) else { return nil }
        let vendor = AppCatalogService.normalizeToken(parts[1])
        let ignored: Set<String> = ["apple", "github", "gitlab", "electron", "todesktop", "googlecode", "sourceforge"]
        guard vendor.count >= 3, !ignored.contains(vendor) else { return nil }
        return vendor
    }

    private static let reverseDNSTokens: Set<Substring> = [
        "com", "org", "net", "io", "app", "dev", "me", "edu", "gov", "group"
    ]

    private static func looksLikeBundleID(_ str: String) -> Bool {
        let parts = str.split(separator: ".")
        guard parts.count >= 3 else { return false }
        return reverseDNSTokens.contains(parts[0])
    }

    /// Splits camelCase, spaces, dots, hyphens, and underscores into lowercase alphanumeric tokens.
    static func splitIntoWords(_ text: String) -> [String] {
        var separated = ""
        separated.reserveCapacity(text.count + 4)
        let chars = Array(text)
        for i in chars.indices {
            let c = chars[i]
            if i > 0 {
                let prev = chars[i - 1]
                if prev.isLowercase && c.isUppercase {
                    separated.append(" ")
                } else if i + 1 < chars.count, prev.isUppercase && c.isUppercase && chars[i + 1].isLowercase {
                    separated.append(" ")
                }
            }
            separated.append(c)
        }

        let folded = separated.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        return folded
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .compactMap { $0.isEmpty ? nil : $0.lowercased() }
    }

    private static func isBlockedSystemOrProtectedPath(_ path: String, target: TargetBundle) -> Bool {
        if protectedExactPaths.contains(path) {
            return true
        }
        if path != target.path {
            if path.hasPrefix("/System/") || path.hasPrefix("/usr/") || path.hasPrefix("/bin/") || path.hasPrefix("/sbin/") {
                return true
            }
            let lowerName = (path as NSString).lastPathComponent.lowercased()
            if lowerName.hasPrefix("com.apple.") && !target.bundleIdentifier.lowercased().hasPrefix("com.apple.") {
                return true
            }
        }
        return false
    }

    private static func resolveDarwinUserDir(_ name: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let len = confstr(name, &buffer, buffer.count)
        guard len > 0 else { return nil }
        let raw = String(cString: buffer)
        return URL(fileURLWithPath: raw).standardizedFileURL.path
    }
}
