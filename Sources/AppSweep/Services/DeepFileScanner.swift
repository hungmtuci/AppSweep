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

    static func scanAssociatedFiles(
        for target: TargetBundle,
        systemIndex: InstalledSystemIndex
    ) -> [AssociatedFileItem] {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        var discovered: [String: AssociatedFileItem] = [:]

        func addCandidate(
            url: URL,
            category: FileCategory,
            confidence: MatchConfidence,
            reason: String,
            autoSelect: Bool? = nil
        ) {
            let standardized = url.standardizedFileURL.path
            guard !isBlockedSystemOrProtectedPath(standardized, target: target) else { return }
            guard fm.fileExists(atPath: standardized) else { return }

            // If an ancestor directory is already added (e.g. target.app itself), skip child paths inside target.app
            if standardized != target.path && standardized.hasPrefix(target.path + "/") {
                return
            }

            if let existing = discovered[standardized] {
                // Keep higher confidence if already discovered
                if existing.confidence == .exact || confidence != .exact {
                    return
                }
            }

            var isDir: ObjCBool = false
            _ = fm.fileExists(atPath: standardized, isDirectory: &isDir)
            let size = DiskSizeCalculator.allocatedSize(at: URL(fileURLWithPath: standardized))
            let needsAdmin = DiskSizeCalculator.requiresAdminToModify(path: standardized)
            let defaultSelected: Bool = {
                if target.isSystemProtected { return false }
                if let autoSelect { return autoSelect }
                return confidence != .sharedVendor
            }()

            discovered[standardized] = AssociatedFileItem(
                id: standardized,
                path: standardized,
                name: URL(fileURLWithPath: standardized).lastPathComponent,
                category: category,
                sizeBytes: size,
                confidence: confidence,
                matchReason: reason,
                requiresAdmin: needsAdmin,
                isDirectory: isDir.boolValue,
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
        if !primaryID.isEmpty, !primaryID.hasPrefix("com.apple.") || !target.isSystemProtected {
            if !primaryID.isEmpty {
                exactBundleIDs.insert(primaryID)
            }
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

        // Strong normalized name tokens (e.g., "spotify", "visualstudiocode", "googlechrome")
        let nameCandidates = buildSafeNameVariants(for: target)
        let vendorFolderToken = extractVendorNameToken(from: primaryID)

        // Check whether other installed apps share the same TeamID or Vendor Prefix
        let hasSiblingTeamApps: Bool = {
            guard let team = target.teamIdentifier, !team.isEmpty else { return false }
            let paths = systemIndex.teamIDToAppPaths[team] ?? []
            return paths.subtracting([target.path]).isEmpty == false
        }()

        // 2. Scan Standard Directory Locations
        var scanSpecs: [(String, FileCategory, Bool)] = [
            // (Directory Path, Category, AllowNameMatching)
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

        if let darwinCache = darwinUserDir(_CS_DARWIN_USER_CACHE_DIR) {
            scanSpecs.append((darwinCache, .caches, false))
        }
        if let darwinTemp = darwinUserDir(_CS_DARWIN_USER_TEMP_DIR) {
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

        // 3. Scan ~/Library/Containers (handles both Bundle-ID folders and macOS UUID container metadata!)
        scanSandboxContainers(
            at: "\(home)/Library/Containers",
            exactBundleIDs: exactBundleIDs,
            addCandidate: addCandidate
        )

        // 4. Scan ~/Library/Group Containers (handles group.<bundleID> AND <TeamID>.* with Sibling-App Guard!)
        scanGroupContainers(
            at: "\(home)/Library/Group Containers",
            exactBundleIDs: exactBundleIDs,
            nameVariants: nameCandidates,
            teamID: target.teamIdentifier,
            hasSiblingTeamApps: hasSiblingTeamApps,
            addCandidate: addCandidate
        )

        // 5. Scan LaunchAgents & LaunchDaemons (matches filename AND inspects plist Program/Label/AssociatedBundleIdentifiers!)
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

        // 9. Scan Companion Plugins / QuickLook / PreferencePanes / Services (if target is an .app)
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

        // Sort cleanly: Primary bundle first, then by category priority, then largest size first
        return discovered.values.sorted { lhs, rhs in
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
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for entry in entries {
            let itemName = entry.lastPathComponent
            let lowerName = itemName.lowercased()

            // A. Match against exact Bundle IDs & Child Bundle IDs
            if let matchedID = matchBundleID(itemName: lowerName, exactBundleIDs: exactBundleIDs) {
                addCandidate(entry, category, .exact, "Khớp Bundle ID (\(matchedID))", nil)
                continue
            }

            // B. Match against App Name Variants (when safe for this directory)
            if allowNameMatch, let matchedVariant = matchAppNameVariant(
                itemName: itemName,
                variants: nameVariants,
                target: target,
                systemIndex: systemIndex
            ) {
                addCandidate(entry, category, .strong, "Khớp tên ứng dụng (\(matchedVariant))", nil)
                continue
            }

            // C. Check 1-level nested Vendor Folder (e.g., ~/Library/Application Support/Google/Chrome)
            if allowNameMatch, let vendor = vendorToken,
               AppCatalogService.normalizeToken(itemName) == vendor {
                if let subEntries = try? fm.contentsOfDirectory(
                    at: entry,
                    includingPropertiesForKeys: [.isDirectoryKey],
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
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for entry in entries {
            let folderName = entry.lastPathComponent.lowercased()
            if let matchedID = matchBundleID(itemName: folderName, exactBundleIDs: exactBundleIDs) {
                addCandidate(entry, .containers, .exact, "Sandbox Container (\(matchedID))", nil)
                continue
            }

            // macOS Sonoma / Sequoia / Tahoe UUID container metadata check
            let metaURL = entry.appendingPathComponent(".com.apple.containermanagerd.metadata.plist")
            if fm.fileExists(atPath: metaURL.path),
               let dict = NSDictionary(contentsOf: metaURL) as? [String: Any],
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
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let lowerTeam = teamID?.lowercased()

        for entry in entries {
            let name = entry.lastPathComponent
            let lower = name.lowercased()

            // Direct bundleID match inside Group Container name (e.g. group.com.spotify.client or 2FNC3A47ZF.com.spotify.client)
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

            // TeamID prefix match (e.g. UBF8T346G9.ms or 2FNC3A47ZF.group...)
            if let lowerTeam, !lowerTeam.isEmpty, lower.hasPrefix(lowerTeam + ".") {
                let suffix = String(lower.dropFirst(lowerTeam.count + 1))
                let mentionsThisApp = nameVariants.contains { variant in
                    variant.normalized.count >= 4 && AppCatalogService.normalizeToken(suffix).contains(variant.normalized)
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
                inspectHelperBinaryInLaunchPlist(entry, target: target, addCandidate: addCandidate)
                continue
            }

            // Parse plist content to catch non-standard plist names pointing inside target.app or AssociatedBundleIdentifiers
            guard let dict = NSDictionary(contentsOf: entry) as? [String: Any] else { continue }

            if let label = (dict["Label"] as? String)?.lowercased(),
               let matchedID = matchBundleID(itemName: label, exactBundleIDs: exactBundleIDs) {
                addCandidate(entry, .launchDaemons, .exact, "Launch Label (\(matchedID))", nil)
                inspectHelperBinaryInLaunchPlist(entry, target: target, addCandidate: addCandidate)
                continue
            }

            // AssociatedBundleIdentifiers check (macOS 13+ Ventura/Sonoma/Tahoe background items)
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
                inspectHelperBinaryInLaunchPlist(entry, target: target, addCandidate: addCandidate)
                continue
            }

            // Program / ProgramArguments check pointing directly into target.path
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
                // Check if stem strongly matches uncommon app name AND program path mentions app name
                if nameVariants.contains(where: { v in
                    v.normalized.count >= 5 && AppCatalogService.normalizeToken(stem).contains(v.normalized)
                    && AppCatalogService.normalizeToken(programPath).contains(v.normalized)
                }) {
                    addCandidate(entry, .launchDaemons, .strong, "LaunchAgent thực thi tiến trình của \(target.name)", nil)
                }
            }
        }
    }

    private static func inspectHelperBinaryInLaunchPlist(
        _ plistURL: URL,
        target: TargetBundle,
        addCandidate: (URL, FileCategory, MatchConfidence, String, Bool?) -> Void
    ) {
        guard let dict = NSDictionary(contentsOf: plistURL) as? [String: Any] else { return }
        let programPath: String? = {
            if let prog = dict["Program"] as? String { return prog }
            if let args = dict["ProgramArguments"] as? [String], let first = args.first { return first }
            return nil
        }()
        guard let programPath else { return }
        if programPath.hasPrefix("/Library/PrivilegedHelperTools/") {
            addCandidate(
                URL(fileURLWithPath: programPath),
                .launchDaemons,
                .exact,
                "Privileged Helper được khai báo trong \(plistURL.lastPathComponent)",
                nil
            )
        }
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
            if !execLower.isEmpty, execLower.count >= 3,
               (lower.hasPrefix(execLower + "-") || lower.hasPrefix(execLower + "_")) {
                addCandidate(entry, .logs, .exact, "Báo cáo lỗi Crash/IPS (\(target.executableName))", nil)
            } else if !appLower.isEmpty, appLower.count >= 4,
                      (lower.hasPrefix(appLower + "-") || lower.hasPrefix(appLower + "_")) {
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

        // Exact ~/.<appname> dot-directory in Home (only for distinct names >= 4 chars, e.g. ~/.vscode, ~/.cursor, ~/.zed)
        var exactDotTokens = Set<String>()
        for v in nameVariants where v.normalized.count >= 4 {
            exactDotTokens.insert(v.normalized)
            exactDotTokens.insert(v.hyphenated)
        }
        // Special well-known mappings (e.g. Visual Studio Code -> .vscode)
        if target.bundleIdentifier.lowercased() == "com.microsoft.vscode" {
            exactDotTokens.insert("vscode")
        } else if target.bundleIdentifier.lowercased().hasPrefix("com.todesktop.") && target.name.lowercased() == "cursor" {
            exactDotTokens.insert("cursor")
        }

        for token in exactDotTokens where token.count >= 4 && !genericTokens.contains(token) {
            let dotPath = "\(home)/.\(token)"
            if !protectedExactPaths.contains(dotPath), fm.fileExists(atPath: dotPath) {
                addCandidate(
                    URL(fileURLWithPath: dotPath),
                    .receiptsAndConfig,
                    .strong,
                    "Thư mục cấu hình ẩn tại Home (~/. \(token))".replacingOccurrences(of: "~/. ", with: "~/."),
                    nil
                )
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

        // If app name starts with vendor name (e.g., "Google Chrome" -> also consider "Chrome" inside vendor contexts,
        // or "Microsoft Edge" -> consider full name; keep single word only if distinct!)
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

    private static func matchBundleID(itemName: String, exactBundleIDs: Set<String>) -> String? {
        // Strip common plist/savedState/bom suffixes for cleaner exact matching
        let suffixes = [
            ".savedstate", ".binarycookies", ".plist", ".bom",
            ".sfl2", ".sfl3", ".lockfile"
        ]
        var base = itemName.lowercased()
        for suffix in suffixes where base.hasSuffix(suffix) {
            base = String(base.dropLast(suffix.count))
            break
        }

        for id in exactBundleIDs {
            if base == id || base.hasPrefix(id + ".") || base == "group.\(id)" || base.hasPrefix("group.\(id).") {
                return id
            }
        }
        return nil
    }

    private static func matchAppNameVariant(
        itemName: String,
        variants: [NameVariant],
        target: TargetBundle,
        systemIndex: InstalledSystemIndex,
        requireExactOnly: Bool = false
    ) -> String? {
        // Never treat reverse-DNS strings belonging to ANOTHER vendor/bundleID as a loose name match
        let lowerItem = itemName.lowercased()
        if lowerItem.hasPrefix("com.apple.") {
            return nil
        }
        if looksLikeBundleID(lowerItem) {
            // If it looks like com.something.else, only match if its last segment equals a distinct >=5 char variant
            // AND it is NOT a known installed bundle ID of another app!
            if systemIndex.allKnownBundleIDs.contains(lowerItem),
               lowerItem != target.bundleIdentifier.lowercased() {
                return nil
            }
        }

        let cleanStem: String = {
            let url = URL(fileURLWithPath: itemName)
            let knownExts: Set<String> = ["plist", "savedstate", "caches", "log", "out", "err", "prefpane", "qlgenerator", "saver", "plugin", "service"]
            if knownExts.contains(url.pathExtension.lowercased()) {
                return url.deletingPathExtension().lastPathComponent
            }
            return itemName
        }()

        let itemNorm = AppCatalogService.normalizeToken(cleanStem)
        guard itemNorm.count >= 3 else { return nil }
        let itemWords = splitIntoWords(cleanStem)

        for variant in variants {
            // 1. Exact normalized match (works safely even for 3-letter apps like VLC, Arc, OBS, Zed!)
            if itemNorm == variant.normalized {
                return variant.raw
            }

            if requireExactOnly || variant.normalized.count < 5 {
                continue
            }

            // 2. Word-boundary prefix match (e.g., variant = ["visual", "studio", "code"] or ["spotify"],
            //    itemWords = ["spotify", "client"] or ["spotify", "updater"])
            //    Guard: Ensure `itemNorm` is NOT the exact name of ANOTHER installed app (e.g., "Telegram Lite" vs "Telegram"!)
            if itemWords.count > variant.words.count,
               !variant.words.isEmpty,
               Array(itemWords.prefix(variant.words.count)) == variant.words {
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

    private static func looksLikeBundleID(_ str: String) -> Bool {
        let parts = str.split(separator: ".")
        guard parts.count >= 3 else { return false }
        let prefixes: Set<Substring> = ["com", "org", "net", "io", "app", "dev", "me", "edu", "gov", "group"]
        return prefixes.contains(parts[0])
    }

    /// Splits camelCase, spaces, dots, hyphens, and underscores into lowercase alphanumeric tokens.
    static func splitIntoWords(_ text: String) -> [String] {
        // Insert space between lowercase->Uppercase transitions (e.g. "BarFlow" -> "Bar Flow", "VSCode" -> "VS Code")
        var separated = ""
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
            .map { $0.lowercased() }
            .filter { !$0.isEmpty }
    }

    private static func isBlockedSystemOrProtectedPath(_ path: String, target: TargetBundle) -> Bool {
        if protectedExactPaths.contains(path) {
            return true
        }
        if path != target.path {
            if path.hasPrefix("/System/") || path.hasPrefix("/usr/") || path.hasPrefix("/bin/") || path.hasPrefix("/sbin/") {
                return true
            }
            let lowerName = URL(fileURLWithPath: path).lastPathComponent.lowercased()
            if lowerName.hasPrefix("com.apple.") && !target.bundleIdentifier.lowercased().hasPrefix("com.apple.") {
                return true
            }
        }
        return false
    }

    private static func darwinUserDir(_ name: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let len = confstr(name, &buffer, buffer.count)
        guard len > 0 else { return nil }
        let raw = String(cString: buffer)
        return URL(fileURLWithPath: raw).standardizedFileURL.path
    }
}
