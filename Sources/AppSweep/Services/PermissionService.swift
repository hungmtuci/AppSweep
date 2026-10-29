import AppKit
import Foundation

enum PermissionService {
    /// Checks whether Full Disk Access is granted so protected ~/Library containers and Safari/TCC folders can be scanned completely.
    static func hasFullDiskAccess() -> Bool {
        let fm = FileManager.default
        let tccDir = "/Library/Application Support/com.apple.TCC"
        if (try? fm.contentsOfDirectory(atPath: tccDir)) != nil {
            return true
        }
        let safariDir = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Safari")
        if fm.fileExists(atPath: safariDir), (try? fm.contentsOfDirectory(atPath: safariDir)) != nil {
            return true
        }
        return false
    }

    @MainActor
    static func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}
