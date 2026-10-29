import AppKit
import Foundation

struct UninstallExecutionResult: Sendable {
    let record: UninstallHistoryRecord
    let dockIconRemoved: Bool
}

struct BatchTargetPayload: Sendable {
    let target: TargetBundle
    let items: [AssociatedFileItem]
}

struct BatchUninstallExecutionResult: Sendable {
    let records: [UninstallHistoryRecord]
    let totalBytesFreed: Int64
    let totalRemovedCount: Int
    let failedCount: Int
    let dockIconsRemoved: Bool
}

enum UninstallEngineError: LocalizedError {
    case nothingSelected
    case protectedTarget(String)
    case adminCancelledOrFailed(String)
    case restoreUnavailable

    var errorDescription: String? {
        switch self {
        case .nothingSelected:
            return "Chưa có mục nào được chọn để gỡ bỏ."
        case .protectedTarget(let name):
            return "\(name) là thành phần hệ thống được macOS bảo vệ và không thể xóa."
        case .adminCancelledOrFailed(let detail):
            return "Không thể cấp quyền Quản trị viên (Admin) cho các file hệ thống: \(detail)"
        case .restoreUnavailable:
            return "Thư mục lưu tạm trong Thùng rác không còn tồn tại (có thể bạn đã dọn sạch Thùng rác)."
        }
    }
}

enum UninstallEngine {
    private static var historyFileURL: URL {
        let appSupport = (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Application Support/AppSweep")
        try? FileManager.default.createDirectory(atPath: appSupport, withIntermediateDirectories: true)
        return URL(fileURLWithPath: appSupport).appendingPathComponent("uninstall_history.json")
    }

    // MARK: - History Persistence

    static func loadHistory() -> [UninstallHistoryRecord] {
        guard let data = try? Data(contentsOf: historyFileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([UninstallHistoryRecord].self, from: data)) ?? []
    }

    static func saveHistory(_ records: [UninstallHistoryRecord]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(records) {
            try? data.write(to: historyFileURL, options: .atomic)
        }
    }

    // MARK: - Running App Detection & Termination

    static func isTargetRunning(_ target: TargetBundle) -> Bool {
        let running = NSWorkspace.shared.runningApplications
        let lowerPrimary = target.bundleIdentifier.lowercased()
        let lowerChildren = Set(target.childBundleIdentifiers.map { $0.lowercased() })
        let targetPath = target.path

        return running.contains { app in
            if let bid = app.bundleIdentifier?.lowercased() {
                if !lowerPrimary.isEmpty && bid == lowerPrimary { return true }
                if lowerChildren.contains(bid) { return true }
            }
            if let bundlePath = app.bundleURL?.standardizedFileURL.path {
                if bundlePath == targetPath || bundlePath.hasPrefix(targetPath + "/") {
                    return true
                }
            }
            if let execPath = app.executableURL?.standardizedFileURL.path {
                if execPath.hasPrefix(targetPath + "/") {
                    return true
                }
            }
            return false
        }
    }

    static func terminateTargetProcesses(_ target: TargetBundle) {
        let lowerPrimary = target.bundleIdentifier.lowercased()
        let lowerChildren = Set(target.childBundleIdentifiers.map { $0.lowercased() })
        let targetPath = target.path

        let matchedApps = NSWorkspace.shared.runningApplications.filter { app in
            if app.processIdentifier == ProcessInfo.processInfo.processIdentifier { return false }
            if let bid = app.bundleIdentifier?.lowercased() {
                if !lowerPrimary.isEmpty && bid == lowerPrimary { return true }
                if lowerChildren.contains(bid) { return true }
            }
            if let bundlePath = app.bundleURL?.standardizedFileURL.path,
               (bundlePath == targetPath || bundlePath.hasPrefix(targetPath + "/")) {
                return true
            }
            if let execPath = app.executableURL?.standardizedFileURL.path,
               execPath.hasPrefix(targetPath + "/") {
                return true
            }
            return false
        }

        guard !matchedApps.isEmpty else { return }

        for app in matchedApps {
            _ = app.terminate()
        }

        // Wait up to 900ms for graceful quit before force-terminating
        let deadline = Date().addingTimeInterval(0.9)
        while Date() < deadline {
            if matchedApps.allSatisfy({ $0.isTerminated }) { break }
            Thread.sleep(forTimeInterval: 0.1)
        }

        for app in matchedApps where !app.isTerminated {
            _ = app.forceTerminate()
        }
    }

    // MARK: - Uninstall Associated Items

    static func performUninstall(
        target: TargetBundle?,
        items: [AssociatedFileItem],
        mode: RemovalMode,
        createZipBackup: Bool,
        cleanDockIcon: Bool
    ) throws -> UninstallExecutionResult {
        let selectedItems = items.filter(\.isSelected)
        guard !selectedItems.isEmpty else {
            throw UninstallEngineError.nothingSelected
        }

        if let target, target.isSystemProtected {
            throw UninstallEngineError.protectedTarget(target.name)
        }

        // 1. Quit running target app & embedded helpers if applicable
        if let target {
            terminateTargetProcesses(target)
        }

        let targetName = target?.name ?? selectedItems.first?.name ?? " Dọn dẹp"
        let bundleID = target?.bundleIdentifier ?? ""

        // 2. Optional ZIP Backup before deleting (AppDelete Archive feature)
        var archiveZipPath: String? = nil
        if createZipBackup {
            archiveZipPath = createBackupArchive(targetName: targetName, items: selectedItems)
        }

        // 3. Bootout any user-domain LaunchAgents first so launchd stops respawning helpers
        let uid = getuid()
        for item in selectedItems where item.category == .launchDaemons && item.path.hasPrefix(NSHomeDirectory()) {
            runQuietProcess("/bin/launchctl", arguments: ["bootout", "gui/\(uid)", item.path])
        }

        // 4. Prepare Trash Package folder if mode == .moveToTrash
        let fm = FileManager.default
        let timestampStr = Self.folderTimestampFormatter.string(from: Date())
        let safeTitle = sanitizeFileName(targetName)
        let trashContainerPath: String? = {
            guard mode == .moveToTrash else { return nil }
            let trashRoot = (NSHomeDirectory() as NSString).appendingPathComponent(".Trash")
            let folderName = "AppSweep - \(safeTitle) (\(timestampStr))"
            let full = (trashRoot as NSString).appendingPathComponent(folderName)
            try? fm.createDirectory(atPath: full, withIntermediateDirectories: true)
            return full
        }()

        var entries: [RestorableFileEntry] = []
        var failedPaths: [String] = []
        var adminQueue: [(item: AssociatedFileItem, destinationTrashPath: String?)] = []
        var removedPreferencePlist = false

        for (index, item) in selectedItems.enumerated() {
            guard isSafeForDeletion(item.path) else {
                failedPaths.append(item.path)
                continue
            }
            guard fm.fileExists(atPath: item.path) else {
                continue
            }

            if item.category == .preferences {
                removedPreferencePlist = true
            }

            let prefixIndex = String(format: "%03d", index + 1)
            let destPath: String? = trashContainerPath.map {
                ($0 as NSString).appendingPathComponent("\(prefixIndex)_\(item.name)")
            }

            if item.requiresAdmin {
                adminQueue.append((item, destPath))
                continue
            }

            do {
                if mode == .moveToTrash, let destPath {
                    try fm.moveItem(atPath: item.path, toPath: destPath)
                    entries.append(RestorableFileEntry(
                        originalPath: item.path,
                        trashedPath: destPath,
                        categoryRaw: item.category.rawValue,
                        sizeBytes: item.sizeBytes,
                        isRestored: false
                    ))
                } else {
                    try fm.removeItem(atPath: item.path)
                    entries.append(RestorableFileEntry(
                        originalPath: item.path,
                        trashedPath: nil,
                        categoryRaw: item.category.rawValue,
                        sizeBytes: item.sizeBytes,
                        isRestored: false
                    ))
                }
            } catch {
                // Escalate permission failures to batched Admin queue
                adminQueue.append((item, destPath))
            }
        }

        // 5. Execute single Touch ID / Admin prompt if privileged items exist
        if !adminQueue.isEmpty {
            let gid = getgid()
            var scriptLines: [String] = ["set -e"]

            for (item, destPath) in adminQueue {
                if item.category == .launchDaemons && item.path.hasPrefix("/Library/") {
                    scriptLines.append("/bin/launchctl bootout system \(shellQuote(item.path)) 2>/dev/null || true")
                }
                if mode == .moveToTrash, let destPath {
                    scriptLines.append("/bin/mv -f \(shellQuote(item.path)) \(shellQuote(destPath))")
                    scriptLines.append("/usr/sbin/chown -R \(uid):\(gid) \(shellQuote(destPath)) 2>/dev/null || true")
                } else {
                    scriptLines.append("/bin/rm -rf \(shellQuote(item.path))")
                }
            }

            let joinedScript = scriptLines.joined(separator: " ; ")
            if runElevatedShellScript(joinedScript) {
                for (item, destPath) in adminQueue {
                    if !fm.fileExists(atPath: item.path) {
                        entries.append(RestorableFileEntry(
                            originalPath: item.path,
                            trashedPath: destPath,
                            categoryRaw: item.category.rawValue,
                            sizeBytes: item.sizeBytes,
                            isRestored: false
                        ))
                    } else {
                        failedPaths.append(item.path)
                    }
                }
            } else {
                for (item, _) in adminQueue {
                    failedPaths.append(item.path)
                }
            }
        }

        // 6. Flush cfprefsd RAM cache so removed .plist files are not rewritten from memory
        if removedPreferencePlist {
            runQuietProcess("/usr/bin/killall", arguments: ["-u", NSUserName(), "cfprefsd"])
        }

        // 7. Remove broken icon from macOS Dock if requested and app bundle was removed
        var dockCleaned = false
        if cleanDockIcon, let target, target.kind == .application, !fm.fileExists(atPath: target.path) {
            dockCleaned = removeAppFromDockIfPresent(appPath: target.path)
        }

        let freedBytes = entries.reduce(Int64(0)) { $0 + $1.sizeBytes }
        let record = UninstallHistoryRecord(
            id: UUID(),
            timestamp: Date(),
            targetName: targetName,
            bundleIdentifier: bundleID,
            mode: mode,
            totalBytesFreed: freedBytes,
            removedCount: entries.count,
            failedPaths: failedPaths,
            trashContainerPath: entries.isEmpty ? nil : trashContainerPath,
            archiveZipPath: archiveZipPath,
            entries: entries,
            isFullyRestored: false
        )

        // Write manifest inside Trash folder too for transparency
        if let trashContainerPath, !entries.isEmpty {
            let manifestURL = URL(fileURLWithPath: trashContainerPath).appendingPathComponent("restore_manifest.json")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted]
            encoder.dateEncodingStrategy = .iso8601
            if let data = try? encoder.encode(record) {
                try? data.write(to: manifestURL)
            }
        } else if let trashContainerPath, entries.isEmpty {
            try? fm.removeItem(atPath: trashContainerPath)
        }

        var history = loadHistory()
        if !entries.isEmpty {
            history.insert(record, at: 0)
            saveHistory(history)
        }

        return UninstallExecutionResult(record: record, dockIconRemoved: dockCleaned)
    }

    // MARK: - Batch Multi-App Uninstall (Single Admin Prompt for Entire Batch)

    static func performBatchUninstall(
        batches: [BatchTargetPayload],
        mode: RemovalMode,
        createZipBackup: Bool,
        cleanDockIcon: Bool
    ) throws -> BatchUninstallExecutionResult {
        let validBatches = batches.filter { payload in
            !payload.target.isSystemProtected && payload.items.contains(where: \.isSelected)
        }
        guard !validBatches.isEmpty else {
            throw UninstallEngineError.nothingSelected
        }

        let fm = FileManager.default
        let uid = getuid()
        let gid = getgid()
        let timestampStr = Self.folderTimestampFormatter.string(from: Date())

        // 1. Terminate all running processes across all selected apps first
        for payload in validBatches {
            terminateTargetProcesses(payload.target)
        }

        // Per-target mutable state before finalizing history records
        struct WorkingBatchState {
            let target: TargetBundle
            let trashContainerPath: String?
            let archiveZipPath: String?
            var entries: [RestorableFileEntry] = []
            var failedPaths: [String] = []
        }

        var states: [WorkingBatchState] = []
        var globalProcessedPaths = Set<String>()
        var globalAdminQueue: [(stateIndex: Int, item: AssociatedFileItem, destTrashPath: String?)] = []
        var removedAnyPreferencePlist = false

        // 2. Process user-writable items & stage privileged items into a single Admin queue
        for (bIdx, payload) in validBatches.enumerated() {
            let selected = payload.items.filter { item in
                guard item.isSelected else { return false }
                return globalProcessedPaths.insert(item.path).inserted
            }

            if selected.isEmpty { continue }

            var archivePath: String? = nil
            if createZipBackup {
                archivePath = createBackupArchive(targetName: payload.target.name, items: selected)
            }

            for item in selected where item.category == .launchDaemons && item.path.hasPrefix(NSHomeDirectory()) {
                runQuietProcess("/bin/launchctl", arguments: ["bootout", "gui/\(uid)", item.path])
            }

            let safeTitle = sanitizeFileName(payload.target.name)
            let trashContainerPath: String? = {
                guard mode == .moveToTrash else { return nil }
                let trashRoot = (NSHomeDirectory() as NSString).appendingPathComponent(".Trash")
                let folderName = "AppSweep - \(safeTitle) (\(timestampStr)-\(bIdx + 1))"
                let full = (trashRoot as NSString).appendingPathComponent(folderName)
                try? fm.createDirectory(atPath: full, withIntermediateDirectories: true)
                return full
            }()

            let stateIdx = states.count
            states.append(WorkingBatchState(
                target: payload.target,
                trashContainerPath: trashContainerPath,
                archiveZipPath: archivePath
            ))

            for (itemIdx, item) in selected.enumerated() {
                guard isSafeForDeletion(item.path) else {
                    states[stateIdx].failedPaths.append(item.path)
                    continue
                }
                guard fm.fileExists(atPath: item.path) else { continue }

                if item.category == .preferences {
                    removedAnyPreferencePlist = true
                }

                let prefixIndex = String(format: "%03d", itemIdx + 1)
                let destPath: String? = trashContainerPath.map {
                    ($0 as NSString).appendingPathComponent("\(prefixIndex)_\(item.name)")
                }

                if item.requiresAdmin {
                    globalAdminQueue.append((stateIdx, item, destPath))
                    continue
                }

                do {
                    if mode == .moveToTrash, let destPath {
                        try fm.moveItem(atPath: item.path, toPath: destPath)
                        states[stateIdx].entries.append(RestorableFileEntry(
                            originalPath: item.path,
                            trashedPath: destPath,
                            categoryRaw: item.category.rawValue,
                            sizeBytes: item.sizeBytes,
                            isRestored: false
                        ))
                    } else {
                        try fm.removeItem(atPath: item.path)
                        states[stateIdx].entries.append(RestorableFileEntry(
                            originalPath: item.path,
                            trashedPath: nil,
                            categoryRaw: item.category.rawValue,
                            sizeBytes: item.sizeBytes,
                            isRestored: false
                        ))
                    }
                } catch {
                    globalAdminQueue.append((stateIdx, item, destPath))
                }
            }
        }

        // 3. Single Touch ID / Admin prompt for ALL privileged files across the entire batch!
        if !globalAdminQueue.isEmpty {
            var scriptLines: [String] = []
            for (_, item, destPath) in globalAdminQueue {
                if item.category == .launchDaemons && item.path.hasPrefix("/Library/") {
                    scriptLines.append("/bin/launchctl bootout system \(shellQuote(item.path)) 2>/dev/null || true")
                }
                if mode == .moveToTrash, let destPath {
                    scriptLines.append("/bin/mv -f \(shellQuote(item.path)) \(shellQuote(destPath)) 2>/dev/null || true")
                    scriptLines.append("/usr/sbin/chown -R \(uid):\(gid) \(shellQuote(destPath)) 2>/dev/null || true")
                } else {
                    scriptLines.append("/bin/rm -rf \(shellQuote(item.path)) 2>/dev/null || true")
                }
            }

            let joined = scriptLines.joined(separator: " ; ")
            if runElevatedShellScript(joined) {
                for (stateIdx, item, destPath) in globalAdminQueue {
                    if !fm.fileExists(atPath: item.path) {
                        states[stateIdx].entries.append(RestorableFileEntry(
                            originalPath: item.path,
                            trashedPath: destPath,
                            categoryRaw: item.category.rawValue,
                            sizeBytes: item.sizeBytes,
                            isRestored: false
                        ))
                    } else {
                        states[stateIdx].failedPaths.append(item.path)
                    }
                }
            } else {
                for (stateIdx, item, _) in globalAdminQueue {
                    states[stateIdx].failedPaths.append(item.path)
                }
            }
        }

        // 4. Flush cfprefsd once if any .plist was deleted
        if removedAnyPreferencePlist {
            runQuietProcess("/usr/bin/killall", arguments: ["-u", NSUserName(), "cfprefsd"])
        }

        // 5. Remove Dock icons in a single pass so Dock restarts at most once
        var dockCleaned = false
        if cleanDockIcon {
            let removedAppPaths = states
                .filter { $0.target.kind == .application && !fm.fileExists(atPath: $0.target.path) }
                .map(\.target.path)
            if !removedAppPaths.isEmpty {
                dockCleaned = removeAppsFromDockIfPresent(appPaths: removedAppPaths)
            }
        }

        // 6. Finalize per-app UninstallHistoryRecord entries & persist
        var createdRecords: [UninstallHistoryRecord] = []
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601

        for st in states {
            if st.entries.isEmpty {
                if let emptyTrash = st.trashContainerPath {
                    try? fm.removeItem(atPath: emptyTrash)
                }
                continue
            }

            let freed = st.entries.reduce(Int64(0)) { $0 + $1.sizeBytes }
            let rec = UninstallHistoryRecord(
                id: UUID(),
                timestamp: Date(),
                targetName: st.target.name,
                bundleIdentifier: st.target.bundleIdentifier,
                mode: mode,
                totalBytesFreed: freed,
                removedCount: st.entries.count,
                failedPaths: st.failedPaths,
                trashContainerPath: st.trashContainerPath,
                archiveZipPath: st.archiveZipPath,
                entries: st.entries,
                isFullyRestored: false
            )

            if let trashDir = st.trashContainerPath, let data = try? encoder.encode(rec) {
                let manifestURL = URL(fileURLWithPath: trashDir).appendingPathComponent("restore_manifest.json")
                try? data.write(to: manifestURL)
            }
            createdRecords.append(rec)
        }

        if !createdRecords.isEmpty {
            var history = loadHistory()
            history.insert(contentsOf: createdRecords, at: 0)
            saveHistory(history)
        }

        let totalBytes = createdRecords.reduce(Int64(0)) { $0 + $1.totalBytesFreed }
        let totalRemoved = createdRecords.reduce(0) { $0 + $1.removedCount }
        let totalFailed = states.reduce(0) { $0 + $1.failedPaths.count }

        return BatchUninstallExecutionResult(
            records: createdRecords,
            totalBytesFreed: totalBytes,
            totalRemovedCount: totalRemoved,
            failedCount: totalFailed,
            dockIconsRemoved: dockCleaned
        )
    }

    // MARK: - Batch Clean Orphans

    static func cleanOrphans(
        orphans: [OrphanItem],
        mode: RemovalMode
    ) throws -> UninstallHistoryRecord {
        let mapped: [AssociatedFileItem] = orphans.filter(\.isSelected).map { orphan in
            AssociatedFileItem(
                id: orphan.id,
                path: orphan.path,
                name: orphan.name,
                category: orphan.category,
                sizeBytes: orphan.sizeBytes,
                confidence: .exact,
                matchReason: orphan.reason,
                requiresAdmin: orphan.requiresAdmin,
                isDirectory: true,
                isSelected: true
            )
        }

        let syntheticResult = try performUninstall(
            target: nil,
            items: mapped,
            mode: mode,
            createZipBackup: false,
            cleanDockIcon: false
        )

        // Rename synthetic targetName nicely in history
        var history = loadHistory()
        if let idx = history.firstIndex(where: { $0.id == syntheticResult.record.id }) {
            let updated = UninstallHistoryRecord(
                id: syntheticResult.record.id,
                timestamp: syntheticResult.record.timestamp,
                targetName: "Dọn \(syntheticResult.record.removedCount) file rác mồ côi",
                bundleIdentifier: "orphans.cleanup",
                mode: syntheticResult.record.mode,
                totalBytesFreed: syntheticResult.record.totalBytesFreed,
                removedCount: syntheticResult.record.removedCount,
                failedPaths: syntheticResult.record.failedPaths,
                trashContainerPath: syntheticResult.record.trashContainerPath,
                archiveZipPath: nil,
                entries: syntheticResult.record.entries,
                isFullyRestored: false
            )
            history[idx] = updated
            saveHistory(history)
            return updated
        }
        return syntheticResult.record
    }

    // MARK: - 1-Click Undo / Restore from Trash (AppDelete Undo feature)

    static func restoreUninstallRecord(_ recordID: UUID) throws -> UninstallHistoryRecord {
        var history = loadHistory()
        guard let recIdx = history.firstIndex(where: { $0.id == recordID }) else {
            throw UninstallEngineError.restoreUnavailable
        }
        var record = history[recIdx]
        guard record.canRestore else {
            throw UninstallEngineError.restoreUnavailable
        }

        let fm = FileManager.default
        var adminRestoreCommands: [String] = []
        var pendingAdminIndices: [Int] = []

        for idx in record.entries.indices {
            if record.entries[idx].isRestored { continue }
            guard let trashed = record.entries[idx].trashedPath, fm.fileExists(atPath: trashed) else { continue }
            let orig = record.entries[idx].originalPath
            let origParent = (orig as NSString).deletingLastPathComponent

            do {
                if !fm.fileExists(atPath: origParent) {
                    try fm.createDirectory(atPath: origParent, withIntermediateDirectories: true)
                }
                if fm.fileExists(atPath: orig) {
                    try fm.removeItem(atPath: orig)
                }
                try fm.moveItem(atPath: trashed, toPath: orig)
                record.entries[idx].isRestored = true
            } catch {
                adminRestoreCommands.append("/bin/mkdir -p \(shellQuote(origParent))")
                adminRestoreCommands.append("/bin/rm -rf \(shellQuote(orig))")
                adminRestoreCommands.append("/bin/mv -f \(shellQuote(trashed)) \(shellQuote(orig))")
                pendingAdminIndices.append(idx)
            }
        }

        if !adminRestoreCommands.isEmpty {
            let script = adminRestoreCommands.joined(separator: " ; ")
            if runElevatedShellScript(script) {
                for idx in pendingAdminIndices {
                    if fm.fileExists(atPath: record.entries[idx].originalPath) {
                        record.entries[idx].isRestored = true
                    }
                }
            }
        }

        let allDone = record.entries.allSatisfy(\.isRestored)
        record.isFullyRestored = allDone

        if allDone, let container = record.trashContainerPath {
            try? fm.removeItem(atPath: container)
        }

        history[recIdx] = record
        saveHistory(history)
        return record
    }

    // MARK: - Backup Archive (.zip)

    private static func createBackupArchive(targetName: String, items: [AssociatedFileItem]) -> String? {
        let fm = FileManager.default
        let backupsDir = (NSHomeDirectory() as NSString).appendingPathComponent("Downloads/AppSweep Backups")
        try? fm.createDirectory(atPath: backupsDir, withIntermediateDirectories: true)

        let stamp = folderTimestampFormatter.string(from: Date())
        let safe = sanitizeFileName(targetName)
        let stagingRoot = (NSTemporaryDirectory() as NSString).appendingPathComponent("AppSweepArchive-\(UUID().uuidString)")
        let bundleStage = (stagingRoot as NSString).appendingPathComponent("\(safe)-Backup-\(stamp)")

        defer { try? fm.removeItem(atPath: stagingRoot) }

        do {
            try fm.createDirectory(atPath: bundleStage, withIntermediateDirectories: true)
            var manifestLines: [String] = [
                "AppSweep Backup Archive - \(targetName)",
                "Created: \(ISO8601DateFormatter().string(from: Date()))",
                ""
            ]

            for (i, item) in items.enumerated() where fm.isReadableFile(atPath: item.path) {
                let subFolder = (bundleStage as NSString).appendingPathComponent(item.category.shortBadge.replacingOccurrences(of: "/", with: "-"))
                try? fm.createDirectory(atPath: subFolder, withIntermediateDirectories: true)
                let dst = (subFolder as NSString).appendingPathComponent(item.name)
                let finalDst = fm.fileExists(atPath: dst)
                    ? (subFolder as NSString).appendingPathComponent("\(i)_\(item.name)")
                    : dst
                runQuietProcess("/usr/bin/ditto", arguments: [item.path, finalDst])
                manifestLines.append("[\(item.category.shortBadge)] \(item.path)")
            }

            let notesPath = (bundleStage as NSString).appendingPathComponent("DANH_SACH_FILE_GOC.txt")
            try? manifestLines.joined(separator: "\n").write(toFile: notesPath, atomically: true, encoding: .utf8)

            let zipOut = (backupsDir as NSString).appendingPathComponent("\(safe)-Backup-\(stamp).zip")
            let status = runQuietProcess("/usr/bin/ditto", arguments: ["-c", "-k", "--sequesterRsrc", "--keepParent", bundleStage, zipOut])
            return (status == 0 && fm.fileExists(atPath: zipOut)) ? zipOut : nil
        } catch {
            return nil
        }
    }

    // MARK: - Dock Cleanup

    private static func removeAppFromDockIfPresent(appPath: String) -> Bool {
        removeAppsFromDockIfPresent(appPaths: [appPath])
    }

    private static func removeAppsFromDockIfPresent(appPaths: [String]) -> Bool {
        let dockPlistPath = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Preferences/com.apple.dock.plist")
        guard let dict = NSMutableDictionary(contentsOfFile: dockPlistPath),
              let persistentApps = dict["persistent-apps"] as? [[String: Any]] else {
            return false
        }

        let targetStandards = Set(appPaths.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        var removedAny = false

        let filtered = persistentApps.filter { entry in
            guard let tileData = entry["tile-data"] as? [String: Any],
                  let fileData = tileData["file-data"] as? [String: Any],
                  let urlStr = fileData["_CFURLString"] as? String else {
                return true
            }
            if let url = URL(string: urlStr) {
                let entryPath = url.standardizedFileURL.path
                if targetStandards.contains(entryPath) {
                    removedAny = true
                    return false
                }
            } else if let decoded = urlStr.removingPercentEncoding,
                      targetStandards.contains(where: { decoded.contains($0) }) {
                removedAny = true
                return false
            }
            return true
        }

        guard removedAny else { return false }
        dict["persistent-apps"] = filtered
        if dict.write(toFile: dockPlistPath, atomically: true) {
            runQuietProcess("/usr/bin/killall", arguments: ["Dock"])
            return true
        }
        return false
    }

    // MARK: - Utilities & Security Guards

    private static func isSafeForDeletion(_ path: String) -> Bool {
        let std = URL(fileURLWithPath: path).standardizedFileURL.path
        let home = NSHomeDirectory()
        let forbiddenExact: Set<String> = [
            "/", "/System", "/Applications", "/Library", "/Users",
            "/bin", "/sbin", "/usr", "/var", "/private", home,
            "\(home)/Library", "\(home)/Desktop", "\(home)/Documents", "\(home)/Downloads"
        ]
        if forbiddenExact.contains(std) { return false }
        if std.hasPrefix("/System/") || std.hasPrefix("/bin/") || std.hasPrefix("/sbin/") || std.hasPrefix("/usr/bin/") || std.hasPrefix("/usr/lib/") {
            return false
        }
        let components = std.split(separator: "/")
        return components.count >= 2
    }

    private static func shellQuote(_ raw: String) -> String {
        return "'" + raw.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func runElevatedShellScript(_ shellCommand: String) -> Bool {
        let escapedForAppleScript = shellCommand
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let appleScriptSource = "do shell script \"\(escapedForAppleScript)\" with administrator privileges"

        var errorDict: NSDictionary?
        if let script = NSAppleScript(source: appleScriptSource) {
            _ = script.executeAndReturnError(&errorDict)
            return errorDict == nil
        }
        return false
    }

    @discardableResult
    private static func runQuietProcess(_ launchPath: String, arguments: [String]) -> Int32 {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launchPath)
        proc.arguments = arguments
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus
        } catch {
            return -1
        }
    }

    private static func sanitizeFileName(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = name.components(separatedBy: invalid).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "App" : cleaned
    }

    private static let folderTimestampFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return df
    }()
}
