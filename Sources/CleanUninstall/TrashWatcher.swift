import Foundation
import CoreServices

/// Watches ~/.Trash for newly added .app bundles using directory-level FSEvents.
///
/// Design:
///   - Seeds knownPaths on start() so pre-existing Trash contents are ignored.
///   - Uses directory-level events (no kFSEventStreamCreateFlagFileEvents) to
///     avoid thousands of callbacks per large app bundle.
///   - 0.5 s coalesce window lets large bundles fully land before we read them.
///   - Runs on a dedicated serial queue — FSEvents requirement.
final class TrashWatcher: @unchecked Sendable {
    var onAppTrashed: (@Sendable (TrashedApp) -> Void)?

    private var streamRef: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.user.acleaner.trashwatcher", qos: .utility)
    /// Paths already in ~/.Trash when start() was called — not reported to the callback.
    private var knownPaths: Set<String> = []

    private var trashPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".Trash").path
    }

    // MARK: Stored C callbacks
    // Must be stored properties so the pointer remains valid for the lifetime
    // of the FSEventStream.

    let eventCallback: FSEventStreamCallback = { _, contextInfo, _, _, _, _ in
        guard let contextInfo else { return }
        let watcher = Unmanaged<TrashWatcher>.fromOpaque(contextInfo).takeUnretainedValue()
        watcher.scanForNewApps()
    }

    let retainCallback: CFAllocatorRetainCallBack = { info in
        guard let info else { return nil }
        _ = Unmanaged<TrashWatcher>.fromOpaque(info).retain()
        return info
    }

    let releaseCallback: CFAllocatorReleaseCallBack = { info in
        guard let info else { return }
        Unmanaged<TrashWatcher>.fromOpaque(info).release()
    }

    // MARK: - Start / Stop

    func start() {
        guard streamRef == nil else { return }

        // Seed before starting so anything already in the Trash is ignored.
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: trashPath)) ?? []
        knownPaths = Set(existing.map { trashPath + "/" + $0 })

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: retainCallback,
            release: releaseCallback,
            copyDescription: nil
        )

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            eventCallback,
            &context,
            [trashPath] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,   // coalesce window (seconds) — large apps need time to fully land
            UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        ) else { return }

        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        streamRef = stream
    }

    func stop() {
        guard let s = streamRef else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        streamRef = nil
    }

    deinit { stop() }

    // MARK: - Private

    /// Scans ~/.Trash for .app bundles that weren't there on start().
    /// Called on our serial FSEvents queue; safe to mutate knownPaths here.
    private func scanForNewApps() {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: trashPath)) ?? []
        for name in entries where name.hasSuffix(".app") {
            let path = trashPath + "/" + name
            guard !knownPaths.contains(path) else { continue }
            knownPaths.insert(path)

            let url = URL(fileURLWithPath: path)
            guard let trashed = TrashedApp.from(trashURL: url) else { continue }

            // Skip ACleaner itself
            let bundleID = trashed.bundleIdentifier ?? ""
            guard bundleID != "com.user.ACleaner",
                  bundleID != "com.cleanuninstall.app" else { continue }

            let cb = onAppTrashed
            DispatchQueue.main.async { cb?(trashed) }
        }
    }
}
