import Foundation
import AppKit

/// Checks for Full Disk Access using Pearcleaner's proven approach:
/// POSIX access() syscall + contentsOfDirectory fallback on three paths
/// that are always present but gated behind FDA. Never triggers a TCC prompt.
///
/// There is no "acknowledged" flag. FDA is checked fresh on every launch.
/// If it is missing, RootView shows a non-blocking banner — the same
/// philosophy Pearcleaner uses (no modal, no gate, just an indicator).
enum PermissionsChecker {

    // MARK: - Full Disk Access

    /// Returns true if Full Disk Access has been granted.
    static var hasFullDiskAccess: Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let checkPaths = [
            home + "/Library/Containers/com.apple.stocks",
            home + "/Library/Safari",
            home + "/Library/Mail",
        ]
        for path in checkPaths {
            if let cPath = path.cString(using: .utf8), access(cPath, R_OK) == 0 {
                return true
            }
            if (try? FileManager.default.contentsOfDirectory(atPath: path)) != nil {
                return true
            }
        }
        return false
    }

    /// Opens System Settings directly to the Full Disk Access pane.
    static func openFullDiskAccessSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Async check with retry

    /// Runs the FDA check on a background thread with up to 2 attempts
    /// and a 100 ms gap between them — same as Pearcleaner's pattern.
    /// Calls completion on the main thread.
    static func checkAsync(completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            for attempt in 1...2 {
                if hasFullDiskAccess {
                    DispatchQueue.main.async { completion(true) }
                    return
                }
                if attempt < 2 { Thread.sleep(forTimeInterval: 0.1) }
            }
            DispatchQueue.main.async { completion(false) }
        }
    }

    // MARK: - Convenience

    static var allGranted: Bool { hasFullDiskAccess }
}
