import Foundation

/// Watches ~/.Trash for newly added .app bundles.
///
/// Two complementary mechanisms run in parallel:
///   1. kqueue DispatchSource — fires a .write event whenever the directory
///      changes (O_EVTONLY, no data access, no FDA required).
///   2. Polling timer — scans every 3 seconds as a belt-and-suspenders backup
///      in case the kqueue event misfires (e.g. when the app wakes from sleep).
///
/// Both share the same knownPaths set and serial queue, so there are no races.
/// On start(), knownPaths is seeded with whatever is already in the Trash so
/// pre-existing items are never reported.
final class TrashWatcher: @unchecked Sendable {
    var onAppTrashed: (@Sendable (TrashedApp) -> Void)?

    private var watchSource: DispatchSourceFileSystemObject?
    private var pollTimer:   DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.user.acleaner.trashwatcher", qos: .utility)
    private var knownPaths: Set<String> = []
    private var dirFD: Int32 = -1

    private var trashPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".Trash").path
    }

    // MARK: - Public API

    func start() {
        guard watchSource == nil else { return }

        // Seed so anything already in the Trash is never reported.
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: trashPath)) ?? []
        knownPaths = Set(existing.map { trashPath + "/" + $0 })

        startKqueue()
        startPolling()
    }

    func stop() {
        watchSource?.cancel()
        watchSource = nil
        pollTimer?.cancel()
        pollTimer = nil
    }

    deinit { stop() }

    // MARK: - kqueue watcher

    private func startKqueue() {
        let fd = open(trashPath, O_EVTONLY)
        guard fd >= 0 else { return }
        dirFD = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: .write,      // fires whenever an item is added or removed
            queue: queue
        )

        source.setEventHandler { [weak self] in
            // Small settle delay so the bundle is fully present when we scan.
            self?.queue.asyncAfter(deadline: .now() + 0.5) {
                self?.scanForNewApps()
            }
        }

        source.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.dirFD >= 0 { close(self.dirFD); self.dirFD = -1 }
        }

        source.resume()
        watchSource = source
    }

    // MARK: - Polling fallback

    private func startPolling() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // Poll every 3 seconds; the first fire happens after 3 s so the initial
        // seed has time to complete before we start comparing.
        timer.schedule(deadline: .now() + 3, repeating: 3)
        timer.setEventHandler { [weak self] in
            self?.scanForNewApps()
        }
        timer.resume()
        pollTimer = timer
    }

    // MARK: - Scan

    /// Compares the current Trash contents with knownPaths and reports new apps.
    /// Called on the serial queue by both the kqueue handler and the poll timer.
    private func scanForNewApps() {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: trashPath)) ?? []
        for name in entries where name.hasSuffix(".app") {
            let path = trashPath + "/" + name
            guard !knownPaths.contains(path) else { continue }
            knownPaths.insert(path)

            let url = URL(fileURLWithPath: path)
            guard let trashed = TrashedApp.from(trashURL: url) else { continue }

            // Never fire for ACleaner itself.
            let bundleID = trashed.bundleIdentifier ?? ""
            guard bundleID != "com.user.ACleaner",
                  bundleID != "com.cleanuninstall.app" else { continue }

            let cb = onAppTrashed
            DispatchQueue.main.async { cb?(trashed) }
        }
    }
}
