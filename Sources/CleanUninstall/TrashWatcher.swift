import Foundation

/// Watches ~/.Trash for newly added .app bundles using a kqueue DispatchSource.
///
/// Design:
///   - Opens ~/.Trash with O_EVTONLY (no data access, no FDA required).
///   - DispatchSource.write fires once per directory modification — no per-file
///     callback storms like FSEvents with kFSEventStreamCreateFlagFileEvents.
///   - Seeds knownPaths on start() so pre-existing Trash contents are ignored.
///   - Short settle delay (0.4 s) lets the bundle fully land before we read it.
final class TrashWatcher: @unchecked Sendable {
    var onAppTrashed: (@Sendable (TrashedApp) -> Void)?

    private var watchSource: DispatchSourceFileSystemObject?
    private let queue = DispatchQueue(label: "com.user.acleaner.trashwatcher", qos: .utility)
    private var knownPaths: Set<String> = []
    private var dirFD: Int32 = -1

    private var trashPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".Trash").path
    }

    // MARK: - Start / Stop

    func start() {
        guard watchSource == nil else { return }

        // Seed so anything already in the Trash is never reported.
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: trashPath)) ?? []
        knownPaths = Set(existing.map { trashPath + "/" + $0 })

        // O_EVTONLY: open for event notification only — no data access, no prompts.
        let fd = open(trashPath, O_EVTONLY)
        guard fd >= 0 else { return }
        dirFD = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: .write,   // fires whenever an item is added or removed
            queue: queue
        )

        source.setEventHandler { [weak self] in
            // Brief settle: let the bundle fully appear in the directory listing.
            self?.queue.asyncAfter(deadline: .now() + 0.4) {
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

    func stop() {
        watchSource?.cancel()
        watchSource = nil
    }

    deinit { stop() }

    // MARK: - Scan

    /// Called on our serial queue after the settle delay.
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
