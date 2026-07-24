import Foundation
import AppKit

// Provides SUDO_ASKPASS to brew so cask .pkg installers can run without a tty.
//
// Approach (Applite-style): the askpass helper shows the NATIVE macOS
// password dialog via osascript whenever sudo needs a password. Native
// dialogs are always frontmost and fully VoiceOver-accessible — unlike the
// previous custom NSAlert with an embedded secure field, which could sit
// behind the upgrade sheet and never receive VoiceOver focus.
//
// Security: the password is never stored anywhere. It flows dialog → stdout
// → sudo and exists nowhere else. (The old approach wrote it to a temp
// file; this one writes only the dialog script.)
//
// sudo re-invokes the helper up to 3 times on a wrong password, so typos
// self-recover without any custom retry UI.

enum Sudo {
    nonisolated(unsafe) private static var helperURL: URL?

    /// Writes the askpass helper and validates it once up-front (`sudo -A
    /// true`), so the password dialog appears immediately — not mid-upgrade —
    /// and sudo's timestamp is warmed for the casks that follow. Returns the
    /// env dict to merge into child Processes, or nil if the user cancelled.
    @MainActor
    static func setupAskpass() async -> [String: String]? {
        guard let url = writeHelper() else { return nil }
        helperURL = url
        let env = ["SUDO_ASKPASS": url.path]

        Announcer.announce(
            "macOS will now ask for your Mac login password to allow installer-based updates. Press Cancel in the dialog to skip them.")

        let ok = await validateSudo(env: env)
        if !ok {
            cleanup()
            Announcer.announce("No password provided. Installer-based updates will be skipped.")
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

    /// The helper contains no secrets — just the script that shows the
    /// native dialog and prints what the user typed.
    private static func writeHelper() -> URL? {
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("acleaner-askpass-\(UUID().uuidString).sh")
        let body = """
        #!/bin/bash
        exec /usr/bin/osascript \\
          -e 'set d to display dialog "ACleaner needs your Mac login password to install an update that uses a pkg installer (Microsoft Office, OneDrive, and similar). Press Cancel to skip those updates." default answer "" with title "ACleaner" with hidden answer' \\
          -e 'text returned of d' 2>/dev/null
        """
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
