import Foundation
import AppKit
import Combine

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
        SoundPlayer.playDetected()
        announce("Warning: \(trashed.displayName) was moved to the Trash. Open CleanUninstall to remove its leftover files.")
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
