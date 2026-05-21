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
    // FSEvents requires a serial queue; DispatchQueue.global() is concurrent and
    // can cause out-of-order delivery or subtle race conditions.
    private let queue = DispatchQueue(label: "com.user.acleaner.trashwatcher", qos: .utility)

    private var watchedPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".Trash").path
    }

    // MARK: - Stored C callbacks (must be properties, not locals)

    let eventCallback: FSEventStreamCallback = { _, contextInfo, numEvents, eventPaths, _, _ in
        guard let contextInfo else { return }
        let watcher = Unmanaged<TrashWatcher>.fromOpaque(contextInfo).takeUnretainedValue()
        // With kFSEventStreamCreateFlagUseCFTypes the paths parameter is a CFArray of CFStrings.
        // unsafeBitCast is the standard Swift idiom for this; as! would crash on mismatch.
        let pathsArray = unsafeBitCast(eventPaths, to: NSArray.self)
        for index in 0..<numEvents {
            guard let path = pathsArray[index] as? String else { continue }
            watcher.checkApp(path: path)
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

    // MARK: - Event handler

    private func checkApp(path: String) {
        // FSEvents with FileEvents flag fires for every file inside an .app
        // bundle, not just the bundle root — so we must walk up the path to
        // find the enclosing .app directory rather than checking pathExtension
        // on the raw event path.
        guard let appURL = appBundleURL(from: path) else { return }

        let bundleID = Bundle(url: appURL)?.bundleIdentifier ?? ""
        // Ignore our own bundle and the standalone CleanUninstall app
        guard bundleID != "com.user.ACleaner",
              bundleID != "com.cleanuninstall.app" else { return }
        guard FileManager.default.isInTrash(appURL) else { return }
        guard let trashed = TrashedApp.from(trashURL: appURL) else { return }

        let callback = onAppTrashed
        DispatchQueue.main.async { callback?(trashed) }
    }

    /// Extracts the .app bundle URL from an FSEvent path.
    /// Handles both direct .app paths and paths to files inside a bundle.
    private func appBundleURL(from path: String) -> URL? {
        let url = URL(fileURLWithPath: path)
        if url.pathExtension == "app" { return url }
        // Walk up ancestors looking for a .app bundle
        var candidate = url.deletingLastPathComponent()
        while candidate.path != "/" {
            if candidate.pathExtension == "app" { return candidate }
            candidate = candidate.deletingLastPathComponent()
        }
        return nil
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
