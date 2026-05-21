import Foundation
import AppKit

/// Checks for and directs the user to grant macOS privacy permissions
/// that ACleaner needs to run without per-folder prompts.
enum PermissionsChecker {

    // MARK: - Full Disk Access

    /// Returns true if Full Disk Access has been granted.
    /// Uses a set of files that exist on every Mac but require FDA to read.
    /// Does NOT trigger a TCC prompt — purely a silent check.
    static var hasFullDiskAccess: Bool {
        let fm = FileManager.default
        // macOS setup marker — always present, always requires FDA
        if fm.isReadableFile(atPath: "/var/db/.AppleSetupDone") { return true }
        // TCC database itself
        if fm.isReadableFile(atPath: "/Library/Application Support/com.apple.TCC/TCC.db") { return true }
        // Safari history — exists once Safari has been used
        let home = fm.homeDirectoryForCurrentUser.path
        if fm.isReadableFile(atPath: home + "/Library/Safari/History.db") { return true }
        return false
    }

    /// Opens System Settings directly to the Full Disk Access pane.
    static func openFullDiskAccessSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Acknowledgment persistence

    /// True once the user has clicked Continue in the permissions sheet.
    /// Stored in UserDefaults so the sheet is never shown again automatically.
    static var hasBeenAcknowledged: Bool {
        get { UserDefaults.standard.bool(forKey: "acleanerPermissionsAcknowledged") }
        set { UserDefaults.standard.set(newValue, forKey: "acleanerPermissionsAcknowledged") }
    }

    // MARK: - Overall readiness

    /// True when every permission ACleaner needs has been granted.
    static var allGranted: Bool {
        hasFullDiskAccess
    }
}
