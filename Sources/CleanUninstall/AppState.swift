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
        case done(app: TrashedApp, removed: Int, failed: [String])
    }

    @Published var phase: Phase = .idle
    @Published var selection: Set<URL> = []
    @Published var watchEnabled: Bool = true
    @Published var loginItemEnabled: Bool = false
    @Published var recentEvents: [String] = []
    /// Non-nil when trashAndScan fails; MainView binds an alert to this.
    @Published var trashingError: String? = nil
    /// Apps currently sitting in ~/.Trash — shown in the idle screen.
    @Published var appsInTrash: [TrashedApp] = []

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
                self.phase = .done(app: trashed, removed: outcome.removed, failed: outcome.failed)
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
        refreshTrashContents()
    }

    // MARK: - Existing-Trash support

    /// Re-reads ~/.Trash and updates `appsInTrash`. Called on appear and after cleanup.
    func refreshTrashContents() {
        let trashDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".Trash").path
        Task.detached(priority: .userInitiated) {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: trashDir)) ?? []
            let apps: [TrashedApp] = names
                .filter { $0.hasSuffix(".app") }
                .compactMap { TrashedApp.from(trashURL: URL(fileURLWithPath: trashDir + "/" + $0)) }
                .filter {
                    let id = $0.bundleIdentifier ?? ""
                    return id != "com.user.ACleaner" && id != "com.cleanuninstall.app"
                }
            await MainActor.run { self.appsInTrash = apps }
        }
    }

    /// Transitions directly to the detected phase for an app that is already in the Trash.
    func scanExistingTrashedApp(_ app: TrashedApp) {
        seenPaths.insert(app.trashURL.path)      // prevent watcher double-firing
        recentEvents.insert("Detected \(app.displayName) in Trash", at: 0)
        if recentEvents.count > 20 { recentEvents.removeLast() }
        phase = .detected(app)
        SoundPlayer.playDetected()
        announce("\(app.displayName) is in the Trash. Ready to scan for leftover files.")
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

            // ── Step 2: privileged mv via AppleScript (shows macOS password dialog,
            //            requires no Automation / Finder permission) ─────────────
            if needsElevation {
                // Compute a unique destination name inside ~/.Trash (mirrors Finder).
                let trashDir = FileManager.default
                    .homeDirectoryForCurrentUser
                    .appendingPathComponent(".Trash").path
                let base     = appURL.deletingPathExtension().lastPathComponent
                let ext      = appURL.pathExtension
                var destName = appURL.lastPathComponent       // e.g. "GarageBand.app"
                var destPath = (trashDir as NSString).appendingPathComponent(destName)
                var counter  = 2
                while FileManager.default.fileExists(atPath: destPath) {
                    destName = ext.isEmpty
                        ? "\(base) \(counter)"
                        : "\(base) \(counter).\(ext)"
                    destPath = (trashDir as NSString).appendingPathComponent(destName)
                    counter += 1
                }

                // Single-quote-escape a string for use inside a POSIX shell command.
                func q(_ s: String) -> String {
                    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
                }
                let shellCmd = "mv \(q(appURL.path)) \(q(destPath))"
                // Embed in an AppleScript double-quoted string: escape \ then ".
                let escaped  = shellCmd
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                let source   = "do shell script \"\(escaped)\" with administrator privileges"

                let shellErrMsg: String? = await Task.detached(priority: .userInitiated) {
                    var dict: NSDictionary?
                    NSAppleScript(source: source)?.executeAndReturnError(&dict)
                    return dict?["NSAppleScriptErrorMessage"] as? String
                }.value

                if let shellErrMsg {
                    phase = .idle
                    trashingError = "Could not move \"\(displayName)\" to the Trash.\n\n\(shellErrMsg)"
                    announce("Could not move \(displayName) to the Trash.")
                    return
                }
                // We know the exact destination — skip findInTrash().
                resultNSURL = NSURL(fileURLWithPath: destPath)
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
