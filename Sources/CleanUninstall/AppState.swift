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

    private let watcher = TrashWatcher()
    private let scanner = LeftoverScanner()
    private var seenPaths: Set<String> = []

    func startWatching() {
        watcher.onAppTrashed = { [weak self] trashed in
            Task { @MainActor in self?.handleTrashed(trashed) }
        }
        watcher.start()
        announce("CleanUninstall is watching the Trash for applications.")
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
        // Switch the sidebar to the Clean Uninstall tab so the detection
        // prompt is immediately visible, regardless of which tool was active.
        NotificationCenter.default.post(name: .acleanerShowCleanUninstall, object: nil)
        SoundPlayer.playDetected()
        announce("Warning: \(trashed.displayName) was moved to the Trash. ACleaner has switched to Clean Uninstall — review and remove its leftover files.")
    }

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
                let failedNote = outcome.failed.isEmpty ? "" : ". \(outcome.failed.count) item\(outcome.failed.count == 1 ? "" : "s") could not be removed."
                self.announce("Cleanup finished. Removed \(outcome.removed) item\(outcome.removed == 1 ? "" : "s")\(failedNote)")
            }
        }
    }

    func resetToIdle() {
        phase = .idle
        selection = []
    }

    // MARK: - Direct uninstall (user-initiated, no need to drag to Trash first)

    /// Moves `appURL` to the Trash, then enters the detected phase so the user can
    /// scan for and remove leftover files.  Returns a non-nil error message if the
    /// operation fails so the caller can show it in a visible alert.
    @discardableResult
    func trashAndScan(appURL: URL) -> String? {
        let displayName = appURL.deletingPathExtension().lastPathComponent

        var resultNSURL: NSURL?
        do {
            try FileManager.default.trashItem(at: appURL, resultingItemURL: &resultNSURL)
        } catch {
            let msg = "Could not move \(displayName) to the Trash: \(error.localizedDescription)"
            announce(msg)
            return msg
        }

        // resultingItemURL may be nil on some macOS versions even on success.
        // Fall back to reconstructing the expected Trash path.
        let trashedPath: URL
        if let found = resultNSURL as URL? {
            trashedPath = found
        } else {
            let trashDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".Trash")
            trashedPath = trashDir.appendingPathComponent(appURL.lastPathComponent)
        }

        guard let trashed = TrashedApp.from(trashURL: trashedPath) else {
            let msg = "Moved \(displayName) to the Trash but could not read its bundle info."
            announce(msg)
            return msg
        }

        // Register the trashed path so TrashWatcher doesn't fire a duplicate event.
        seenPaths.insert(trashedPath.path)

        recentEvents.insert("Uninstalled \(trashed.displayName)", at: 0)
        if recentEvents.count > 20 { recentEvents.removeLast() }

        phase = .detected(trashed)
        SoundPlayer.playDetected()
        announce("Moved \(trashed.displayName) to the Trash. Press Scan for leftover files to continue.")
        return nil
    }

    func setLoginItem(_ on: Bool) {
        do {
            try LoginItem.set(enabled: on)
            loginItemEnabled = LoginItem.isEnabled
            announce(on ? "CleanUninstall will start at login." : "CleanUninstall will no longer start at login.")
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
