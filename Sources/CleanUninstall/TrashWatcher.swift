import Foundation
import CoreServices

/// Watches ~/.Trash for newly-trashed .app bundles.
///
/// Two complementary mechanisms run in parallel:
///
/// 1. FSEvents with kFSEventStreamCreateFlagFileEvents (primary) — copied from
///    Pearcleaner's open-source sentinel implementation. With FileEvents, every
///    changed item gets its own event whose `path` IS the item itself.  When
///    WhatsApp.app lands in ~/.Trash, the event path is ~/.Trash/WhatsApp.app
///    and pathExtension == "app" works directly — no directory scanning needed.
///
/// 2. Polling every 5 seconds (fallback) — catches cases where FSEvents misses
///    an event (e.g. system wake, heavy I/O load).
///
/// Both mechanisms dedupe against the shared `knownPaths` set, which tracks
/// the .app bundles currently in the Trash. AppState adds a short time-window
/// dedup on top so the UI never double-fires for the same app.
final class TrashWatcher: @unchecked Sendable {
    var onAppTrashed: (@Sendable (TrashedApp) -> Void)?

    private var streamRef: FSEventStreamRef?
    private var pollTimer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.user.acleaner.trashwatcher", qos: .utility)

    /// .app paths currently believed to be in the Trash. Entries are removed
    /// when the item leaves the Trash (restored or Trash emptied), so
    /// re-trashing the same app fires a fresh detection. A permanent set here
    /// meant the dialog only ever appeared once per app path per session.
    /// Only touched on `queue` after start() seeds it.
    private var knownPaths: Set<String> = []

    private var trashPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".Trash").path
    }

    // MARK: - Stored C callbacks (must be non-capturing so they can be @convention(c))
    // Pearcleaner stores them the same way.

    let eventCallback: FSEventStreamCallback = { _, contextInfo, _, eventPaths, _, _ in
        guard let contextInfo else { return }
        let watcher = Unmanaged<TrashWatcher>.fromOpaque(contextInfo).takeUnretainedValue()
        let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as! [String]
        for path in paths { watcher.checkPath(path) }
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

    // MARK: - Public API

    func start() {
        guard streamRef == nil else { return }

        // Seed knownPaths so neither mechanism fires for items already in the
        // Trash before this session started.  (Those are surfaced by the
        // "Apps in Trash" list in IdleView instead.)
        let trashDir = trashPath
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: trashDir)) ?? []
        knownPaths = Set(existing.map { trashDir + "/" + $0 })

        startFSEvents()
        startPolling()
    }

    func stop() {
        if let s = streamRef {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            streamRef = nil
        }
        pollTimer?.cancel()
        pollTimer = nil
    }

    deinit { stop() }

    // MARK: - FSEvents (Pearcleaner's proven approach)

    private func startFSEvents() {
        let trashDir = trashPath
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
            [trashDir] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0,      // latency 0 — deliver immediately (same as Pearcleaner)
            UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        ) else { return }

        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        streamRef = stream
    }

    // MARK: - Polling fallback

    private func startPolling() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in self?.pollScan() }
        timer.resume()
        pollTimer = timer
    }

    private func pollScan() {
        let trashDir = trashPath
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: trashDir)) ?? []
        // Forget items no longer in the Trash so a re-trash fires again.
        knownPaths.formIntersection(Set(entries.map { trashDir + "/" + $0 }))
        for name in entries where name.hasSuffix(".app") {
            checkPath(trashDir + "/" + name)
        }
    }

    // MARK: - Detection (shared by FSEvents and polling)

    private func checkPath(_ path: String) {
        let url = URL(fileURLWithPath: path)

        // Only .app bundles
        guard url.pathExtension == "app" else { return }

        // FSEvents also fires when an item is renamed OUT of the Trash
        // (restore) or deleted (empty Trash) — forget it immediately so a
        // future re-trash is detected without waiting for the next poll.
        guard FileManager.default.fileExists(atPath: path) else {
            knownPaths.remove(path)
            return
        }

        // Already known to be in the Trash — not a new arrival.
        guard !knownPaths.contains(path) else { return }

        // Confirm it's genuinely inside the Trash — guards against edge cases
        // where the path looks like a Trash item but was renamed back out.
        // Same check Pearcleaner uses.
        guard FileManager.default.isInTrash(url) else { return }

        // Must be a valid, readable app bundle
        guard let trashed = TrashedApp.from(trashURL: url) else { return }
        knownPaths.insert(path)

        // Never report ACleaner itself
        let bundleID = trashed.bundleIdentifier ?? ""
        guard bundleID != "com.user.ACleaner",
              bundleID != "com.cleanuninstall.app" else { return }

        let cb = onAppTrashed
        DispatchQueue.main.async { cb?(trashed) }
    }
}

// MARK: - FileManager + Trash relationship
// Copied from Pearcleaner — uses getRelationship(_:of:in:toItemAt:) which is
// the correct API for checking whether a URL is inside the user's Trash.

extension FileManager {
    func isInTrash(_ url: URL) -> Bool {
        var relationship: URLRelationship = .other
        do {
            try getRelationship(&relationship,
                                of: .trashDirectory,
                                in: .userDomainMask,
                                toItemAt: url)
            return relationship == .contains
        } catch {
            return false
        }
    }
}
