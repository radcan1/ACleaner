import Foundation

/// Size measurement helpers.
///
/// Directory sizes are measured by shelling out to `du`, called as a direct
/// executable with the path passed as a plain argument — NOT via
/// `/bin/bash -c "du ... \(path) ..."`. That distinction is the whole point:
/// passing the path as an argv element means no shell ever parses it, so
/// backticks, `$(...)`, quotes etc. in a file name can never be interpreted
/// as shell syntax. `du` itself is what makes this fast even for huge trees
/// (Xcode's DerivedData, ~/Library/Caches, Photos/Mail libraries) — an
/// earlier version of this file replaced `du` entirely with a native
/// FileManager walk to fix the injection risk, but that made scans of large
/// folders dramatically slower (a Disk Detective scan that used to take
/// under a minute could take 30+ minutes). `du` was never the problem; the
/// shell string interpolation was.
enum FileSize {
    /// Allocated size in bytes of a single file, or the recursive allocated
    /// size of a directory tree. Cancellable — if the calling Task is
    /// cancelled while a `du` process is running, it is terminated instead
    /// of being left to run to completion.
    static func allocatedSize(of url: URL) async -> Int64 {
        let manager = FileManager.default
        var isDir: ObjCBool = false
        guard manager.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }

        if !isDir.boolValue {
            let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
            return Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }

        guard !Task.isCancelled else { return 0 }
        return await duSizeInKB(of: url.path) * 1_024
    }

    /// Sizes many items concurrently. Bounded to 8 in flight so a batch of
    /// hundreds of candidates doesn't spawn hundreds of `du` processes at once.
    static func allocatedSizes(of urls: [URL]) async -> [URL: Int64] {
        guard !urls.isEmpty else { return [:] }
        var results: [URL: Int64] = [:]
        results.reserveCapacity(urls.count)
        let maxConcurrent = 16

        await withTaskGroup(of: (URL, Int64).self) { group in
            var iterator = urls.makeIterator()

            func addNext() {
                guard let url = iterator.next() else { return }
                group.addTask(priority: .utility) {
                    await (url, allocatedSize(of: url))
                }
            }
            for _ in 0..<maxConcurrent { addNext() }

            while let (url, size) = await group.next() {
                results[url] = size
                addNext()
            }
        }
        return results
    }

    /// Convenience overload for callers working with path strings.
    static func allocatedSizes(ofPaths paths: [String]) async -> [String: Int64] {
        let byURL = await allocatedSizes(of: paths.map { URL(fileURLWithPath: $0) })
        var byPath: [String: Int64] = [:]
        byPath.reserveCapacity(byURL.count)
        for (url, size) in byURL { byPath[url.path] = size }
        return byPath
    }

    /// Runs `du -sk <path>` as a direct process (no shell) and terminates it
    /// if the calling Task is cancelled, so a Stop button actually stops
    /// in-flight measurements rather than waiting for them to finish.
    private static func duSizeInKB(of path: String) async -> Int64 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        process.arguments = ["-sk", path]
        let pipe = Pipe()
        process.standardOutput = pipe
        // Discard stderr to a null sink, NOT an unread Pipe. du emits one
        // "Permission denied" line per blocked subfolder, and with Full Disk
        // Access revoked (which happens on every rebuild) that is thousands of
        // lines. An unread stderr Pipe fills its ~64KB buffer, du blocks
        // forever on the write, its terminationHandler never fires, and the
        // measurement hangs — freezing the whole scan. This one line is the
        // difference between a fast scan and a scan that never finishes.
        process.standardError = FileHandle.nullDevice

        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                process.terminationHandler = { _ in
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8) ?? ""
                    let firstField = output.split(whereSeparator: { $0 == "\t" || $0 == " " }).first ?? ""
                    continuation.resume(returning: Int64(firstField) ?? 0)
                }
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: 0)
                }
            }
        }, onCancel: {
            process.terminate()
        })
    }

    // MARK: - Size + last-modified, in one pass

    private static let sizeAndDateKeys: Set<URLResourceKey> = [
        .isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .contentModificationDateKey
    ]
    private static let sizeAndDateKeysArray = Array(sizeAndDateKeys)

    /// Allocated size and most-recent modification date of a file or
    /// directory tree, fetched in the same native enumeration pass so a
    /// directory isn't walked twice. For a directory, `modified` is the
    /// newest modification date among its regular files.
    ///
    /// Unlike `allocatedSize`, this stays on a native FileManager walk
    /// rather than `du` — `du` has no notion of modification dates, and the
    /// callers of this function (orphan-scan candidates: one app's leftover
    /// folder) are per-app leftovers rather than whole Library directories,
    /// so the size difference is much less likely to matter in practice.
    static func allocatedSizeAndModified(of url: URL) -> (size: Int64, modified: Date?) {
        let manager = FileManager.default
        var isDir: ObjCBool = false
        guard manager.fileExists(atPath: url.path, isDirectory: &isDir) else { return (0, nil) }

        if !isDir.boolValue {
            let values = try? url.resourceValues(forKeys: sizeAndDateKeys)
            let size = Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
            return (size, values?.contentModificationDate)
        }

        guard let enumerator = manager.enumerator(
            at: url,
            includingPropertiesForKeys: sizeAndDateKeysArray,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return (0, nil) }

        var total: Int64 = 0
        var newest: Date?
        for case let child as URL in enumerator {
            guard let values = try? child.resourceValues(forKeys: sizeAndDateKeys),
                  values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
            if let d = values.contentModificationDate, newest == nil || d > newest! { newest = d }
        }
        return (total, newest)
    }

    static func allocatedSizesAndDates(of urls: [URL]) async -> [URL: (size: Int64, modified: Date?)] {
        guard !urls.isEmpty else { return [:] }
        var results: [URL: (size: Int64, modified: Date?)] = [:]
        results.reserveCapacity(urls.count)
        let maxConcurrent = 16

        await withTaskGroup(of: (URL, Int64, Date?).self) { group in
            var iterator = urls.makeIterator()

            func addNext() {
                guard let url = iterator.next() else { return }
                group.addTask(priority: .utility) {
                    let r = allocatedSizeAndModified(of: url)
                    return (url, r.size, r.modified)
                }
            }
            for _ in 0..<maxConcurrent { addNext() }

            while let (url, size, modified) = await group.next() {
                results[url] = (size, modified)
                addNext()
            }
        }
        return results
    }
}
