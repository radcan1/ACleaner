import Foundation
import AppKit
import Combine

extension Notification.Name {
    static let acleanerShowCleanUninstall = Notification.Name("acleanerShowCleanUninstall")
    static let acleanerShowPermissions    = Notification.Name("acleanerShowPermissions")
}

@MainActor
final class AppState: ObservableObject {
    enum Phase: Equatable {
        case idle
        case trashing(String)               // displayName — shown while password dialog is open
        case detected(TrashedApp)
        case scanning(TrashedApp)
        case results(TrashedApp, [LeftoverFile])
        case cleaning
        case done(removed: Int, failed: [String])
    }

    @Published var phase: Phase = .idle
    @Published var selection: Set<URL> = []
    @Published var watchEnabled: Bool = true
    @Published var loginItemEnabled: Bool = false
    @Published var recentEvents: [String] = []
    /// Non-nil when trashAndScan fails; MainView binds an alert to this.
    @Published var trashingError: String? = nil

    private let watcher = TrashWatcher()
    private let scanner = LeftoverScanner()
    private var seenPaths: Set<String> = []

    // MARK: - Trash watcher

    func startWatching() {
        watcher.onAppTrashed = { [weak self] trashed in
            Task { @MainActor in self?.handleTrashed(trashed) }
        }
        watcher.start()
        announce("Clean Uninstall is watching the Trash for applications.")
    }

    func stopWatching() {
        watcher.stop()
    }

    func setWatch(_ on: Bool) {
        watchEnabled = on
        if on { watcher.start() } else { watcher.stop() }
    }

    private func handleTrashed(_ trashed: TrashedApp) {
        guard watchEnabled else { return }
        guard !seenPaths.contains(trashed.trashURL.path) else { return }
        seenPaths.insert(trashed.trashURL.path)

        recentEvents.insert("Detected \(trashed.displayName) in Trash", at: 0)
        if recentEvents.count > 20 { recentEvents.removeLast() }

        phase = .detected(trashed)
        bringToFront()
        NotificationCenter.default.post(name: .acleanerShowCleanUninstall, object: nil)
        SoundPlayer.playDetected()
        announce("Warning: \(trashed.displayName) was moved to the Trash. ACleaner has switched to Clean Uninstall — review and remove its leftover files.")
    }

    // MARK: - Scan / cleanup

    func startScan(_ trashed: TrashedApp) {
        phase = .scanning(trashed)
        announce("Scanning for files associated with \(trashed.displayName).")
        Task.detached(priority: .userInitiated) { [scanner] in
            let results = scanner.scan(for: trashed)
            await MainActor.run {
                self.phase = .results(trashed, results)
                self.selection = Set(results.map(\.url))
                SoundPlayer.playScanComplete()
                self.announce("Found \(results.count) item\(results.count == 1 ? "" : "s") for \(trashed.displayName). Review the list and choose what to remove.")
            }
        }
    }

    func dismissDetection() {
        phase = .idle
        selection = []
    }

    func performCleanup(_ trashed: TrashedApp, items: [LeftoverFile]) {
        phase = .cleaning
        let toRemove = items.filter { selection.contains($0.url) }.map(\.url)
        announce("Moving \(toRemove.count) item\(toRemove.count == 1 ? "" : "s") to the Trash.")
        Task.detached(priority: .userInitiated) {
            let outcome = Cleaner.moveToTrash(urls: toRemove)
            await MainActor.run {
                self.phase = .done(removed: outcome.removed, failed: outcome.failed)
                self.selection = []
                SoundPlayer.playCleanupComplete()
                let failedNote = outcome.failed.isEmpty
                    ? ""
                    : ". \(outcome.failed.count) item\(outcome.failed.count == 1 ? "" : "s") could not be removed."
                self.announce("Cleanup finished. Removed \(outcome.removed) item\(outcome.removed == 1 ? "" : "s")\(failedNote)")
            }
        }
    }

    func resetToIdle() {
        phase = .idle
        selection = []
    }

    // MARK: - Direct uninstall (user-initiated, no Trash drag needed)

    /// Moves `appURL` to the Trash, showing a progress screen while any macOS
    /// password dialog is open.
    ///
    /// Strategy:
    ///   1. Try `FileManager.trashItem` — fast, silent, works for user-owned apps.
    ///   2. On permission failure, delegate to Finder via AppleScript.
    ///      Finder holds the elevated rights and will show macOS's own
    ///      authentication dialog if needed (same dialog you see in Finder).
    func trashAndScan(appURL: URL) {
        let displayName = appURL.deletingPathExtension().lastPathComponent
        phase = .trashing(displayName)
        announce("Moving \(displayName) to the Trash.")

        Task {
            // ── Step 1: fast FileManager path ───────────────────────────────
            var resultNSURL: NSURL?
            var needsElevation = false
            do {
                try FileManager.default.trashItem(at: appURL, resultingItemURL: &resultNSURL)
            } catch {
                needsElevation = true
            }

            // ── Step 2: Finder fallback (shows macOS password dialog) ────────
            if needsElevation {
                let path   = appURL.path
                // Raw-string literal keeps the double quotes literal inside AppleScript
                let source = #"tell application "Finder" to move POSIX file "\#(path)" to trash"#

                let finderErrMsg: String? = await Task.detached(priority: .userInitiated) {
                    var dict: NSDictionary?
                    NSAppleScript(source: source)?.executeAndReturnError(&dict)
                    return dict?["NSAppleScriptErrorMessage"] as? String
                }.value

                if let errMsg = finderErrMsg {
                    phase = .idle
                    trashingError = "Could not move \"\(displayName)\" to the Trash.\n\n\(errMsg)"
                    announce("Could not move \(displayName) to the Trash.")
                    return
                }
                // Finder succeeded but gives us no resulting URL — use findInTrash.
                resultNSURL = nil
            }

            // ── Step 3: resolve the resulting Trash URL ──────────────────────
            let trashedURL: URL
            if let found = resultNSURL as URL? {
                trashedURL = found
            } else {
                guard let found = findInTrash(originalURL: appURL) else {
                    phase = .idle
                    trashingError = "Moved \"\(displayName)\" to the Trash but could not locate it there."
                    return
                }
                trashedURL = found
            }

            // ── Step 4: build TrashedApp and enter the detection workflow ─────
            guard let trashed = TrashedApp.from(trashURL: trashedURL) else {
                phase = .idle
                trashingError = "Moved \"\(displayName)\" to the Trash but could not read its bundle info."
                return
            }

            // Prevent TrashWatcher from firing a duplicate event for the same path.
            seenPaths.insert(trashedURL.path)

            recentEvents.insert("Uninstalled \(trashed.displayName)", at: 0)
            if recentEvents.count > 20 { recentEvents.removeLast() }

            phase = .detected(trashed)
            SoundPlayer.playDetected()
            announce("Moved \(trashed.displayName) to the Trash. Press Scan for leftover files to continue.")
        }
    }

    // MARK: - Helpers

    /// Finds `originalURL.lastPathComponent` in ~/.Trash, including Finder's
    /// numeric rename ("GarageBand 2.app") if the name was already taken.
    private func findInTrash(originalURL: URL) -> URL? {
        let fm       = FileManager.default
        let trashDir = fm.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
        let appName  = originalURL.deletingPathExtension().lastPathComponent

        // Exact name first
        let exact = trashDir.appendingPathComponent(originalURL.lastPathComponent)
        if fm.fileExists(atPath: exact.path) { return exact }

        // Finder may have renamed it ("GarageBand 2.app")
        let contents = (try? fm.contentsOfDirectory(
            at: trashDir, includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles)) ?? []
        return contents.first {
            $0.pathExtension == "app" &&
            $0.deletingPathExtension().lastPathComponent.hasPrefix(appName)
        }
    }

    func setLoginItem(_ on: Bool) {
        do {
            try LoginItem.set(enabled: on)
            loginItemEnabled = LoginItem.isEnabled
            announce(on ? "Clean Uninstall will start at login." : "Clean Uninstall will no longer start at login.")
        } catch {
            announce("Could not change login-item setting: \(error.localizedDescription)")
        }
    }

    private func bringToFront() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.canBecomeMain {
            window.makeKeyAndOrderFront(nil)
        }
    }

    private func announce(_ message: String) {
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue
            ]
        )
    }
}
