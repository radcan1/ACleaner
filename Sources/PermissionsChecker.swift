import Foundation
import AppKit

/// Checks for and directs the user to grant macOS privacy permissions
/// that ACleaner needs to run without per-folder prompts.
///
/// FDA detection mirrors Pearcleaner's approach: POSIX access() syscall +
/// contentsOfDirectory on three paths that are always present but gated
/// behind Full Disk Access. This never triggers a TCC prompt.
enum PermissionsChecker {

    // MARK: - Full Disk Access

    /// Returns true if Full Disk Access has been granted.
    /// Checks three paths known to require FDA on every Mac.
    static var hasFullDiskAccess: Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let checkPaths = [
            home + "/Library/Containers/com.apple.stocks",
            home + "/Library/Safari",
            home + "/Library/Mail",
        ]
        for path in checkPaths {
            // Fast POSIX syscall — no TCC prompt, no sandbox side-effects
            if let cPath = path.cString(using: .utf8), access(cPath, R_OK) == 0 {
                return true
            }
            // Fallback: directory listing via FileManager
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

    /// Runs the FDA check on a background thread.
    /// Makes up to 2 attempts with a 100 ms gap — identical to Pearcleaner's pattern.
    /// Calls `completion` on the main thread once a definitive answer is available.
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

    // MARK: - Acknowledgment persistence

    /// True once the user has clicked Continue in the permissions sheet.
    /// Stored in UserDefaults so the first-launch sheet is not shown again.
    static var hasBeenAcknowledged: Bool {
        get { UserDefaults.standard.bool(forKey: "acleanerPermissionsAcknowledged") }
        set { UserDefaults.standard.set(newValue, forKey: "acleanerPermissionsAcknowledged") }
    }

    // MARK: - Overall readiness

    static var allGranted: Bool { hasFullDiskAccess }
}
