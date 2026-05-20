import Foundation
import CoreServices

// Modelled on Pearcleaner's FileWatcher / PearcleanerSentinel pattern.
// Key points:
//   - eventCallback stored as a class property so the C function pointer stays valid
//   - retain/release callbacks so the stream keeps self alive
//   - latency = 0, no NoDefer flag — matches Pearcleaner exactly
//   - no flag filtering in the handler; just check pathExtension + isInTrash

final class TrashWatcher: @unchecked Sendable {
    var onAppTrashed: (@Sendable (TrashedApp) -> Void)?

    private var streamRef: FSEventStreamRef?
    private let queue = DispatchQueue.global()

    private var watchedPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".Trash").path
    }

    // MARK: - Stored C callbacks (must be properties, not locals)

    let eventCallback: FSEventStreamCallback = { _, contextInfo, numEvents, eventPaths, _, _ in
        guard let contextInfo else { return }
        let watcher = Unmanaged<TrashWatcher>.fromOpaque(contextInfo).takeUnretainedValue()
        let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as! [String]
        for index in 0..<numEvents {
            watcher.checkApp(path: paths[index])
        }
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

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: retainCallback,
            release: releaseCallback,
            copyDescription: nil
        )

        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            eventCallback,
            &context,
            [watchedPath] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0,
            UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        ) else { return }

        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)
        streamRef = created
    }

    func stop() {
        guard let current = streamRef else { return }
        FSEventStreamStop(current)
        FSEventStreamInvalidate(current)
        FSEventStreamRelease(current)
        streamRef = nil
    }

    deinit { stop() }

    // MARK: - Event handler (mirrors Pearcleaner's checkApp)

    private func checkApp(path: String) {
        let url = URL(fileURLWithPath: path)
        guard url.pathExtension == "app" else { return }
        guard let bundle = Bundle(url: url) else { return }

        let bundleID = bundle.bundleIdentifier ?? ""
        guard bundleID != "com.cleanuninstall.app" else { return }
        guard FileManager.default.isInTrash(url) else { return }
        guard let trashed = TrashedApp.from(trashURL: url) else { return }

        let callback = onAppTrashed
        DispatchQueue.main.async { callback?(trashed) }
    }
}

extension FileManager {
    func isInTrash(_ file: URL) -> Bool {
        var relationship: FileManager.URLRelationship = .other
        do {
            try getRelationship(&relationship, of: .trashDirectory, in: .userDomainMask, toItemAt: file)
            return relationship == .contains
        } catch {
            return false
        }
    }
}
