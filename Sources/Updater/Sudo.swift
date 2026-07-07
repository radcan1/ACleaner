import Foundation
import AppKit

// Provides SUDO_ASKPASS to brew so cask .pkg installers can run without a tty.
//
// Approach:
//   1. Show a native NSAlert with a secure text field. VoiceOver reads it.
//   2. Write a small helper script that prints the password to stdout.
//   3. Return {"SUDO_ASKPASS": helperPath} so subprocesses inherit it.
//
// On macOS sudo will invoke the SUDO_ASKPASS helper when no tty is available
// (which is the case for a Process launched from a GUI app).
//
// The helper is created with mode 0700 in a temp dir and removed on cleanup().

enum Sudo {
    nonisolated(unsafe) private static var helperURL: URL?

    /// Prompts the user for their password and writes an askpass helper.
    /// Returns the env dict to merge into a child Process, or nil if the user
    /// cancelled or the password could not be validated.
    @MainActor
    static func setupAskpass() async -> [String: String]? {
        guard let pw = promptPassword() else { return nil }
        guard let url = writeHelper(pw: pw) else { return nil }
        helperURL = url

        // Validate the password against sudo so we fail fast rather than
        // mid-upgrade.
        let env = ["SUDO_ASKPASS": url.path]
        let ok = await validateSudo(env: env)
        if !ok {
            cleanup()
            await MainActor.run {
                let alert = NSAlert()
                alert.messageText = "Password not accepted"
                alert.informativeText = "macOS rejected the password you entered. Pkg-based casks (Microsoft Office, OneDrive, etc.) will be skipped."
                alert.alertStyle = .warning
                alert.runModal()
            }
            return nil
        }
        return env
    }

    static func cleanup() {
        if let url = helperURL {
            try? FileManager.default.removeItem(at: url)
            helperURL = nil
        }
        // Invalidate cached sudo timestamp.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        p.arguments = ["-k"]
        try? p.run()
        p.waitUntilExit()
    }

    // MARK: - Internals

    @MainActor
    private static func promptPassword() -> String? {
        let alert = NSAlert()
        alert.messageText = "Mac Updater needs your password"
        alert.informativeText = "Some Homebrew casks (Microsoft Office, OneDrive, etc.) ship .pkg installers that require sudo. Your password stays local — it is written to a temporary file readable only by you and is removed when the update finishes.\n\nCancel to skip those casks."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Skip")

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "Mac login password"
        field.setAccessibilityLabel("Mac login password")
        alert.accessoryView = field

        // Move focus to the password field after the alert lays out.
        DispatchQueue.main.async {
            alert.window.initialFirstResponder = field
            field.window?.makeFirstResponder(field)
        }

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return nil }
        let pw = field.stringValue
        return pw.isEmpty ? nil : pw
    }

    private static func writeHelper(pw: String) -> URL? {
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("macupdater-askpass-\(UUID().uuidString).sh")
        // The helper just prints the password (one shell variable, escaped via single quotes).
        // Single-quote-escape: ' -> '\''
        let escaped = pw.replacingOccurrences(of: "'", with: "'\\''")
        let body = "#!/bin/bash\nprintf '%s\\n' '\(escaped)'\n"
        do {
            try body.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            return url
        } catch {
            return nil
        }
    }

    private static func validateSudo(env: [String: String]) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            p.arguments = ["-A", "true"]
            var combined = ProcessInfo.processInfo.environment
            for (k, v) in env { combined[k] = v }
            p.environment = combined
            // Only the exit status matters here; discard both streams to null
            // rather than leaving unread pipes around.
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            p.terminationHandler = { proc in
                continuation.resume(returning: proc.terminationStatus == 0)
            }
            do { try p.run() } catch { continuation.resume(returning: false) }
        }
    }
}
