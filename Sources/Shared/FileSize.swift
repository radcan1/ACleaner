import Foundation

/// Native, non-shelling replacements for `du`-based size measurement.
/// Spawning `/bin/bash` + `du` per item was the slowest code in the app and
/// interpolated discovered file paths into shell strings — a real injection
/// risk for names containing backticks or `$(...)`.
enum FileSize {
    private static let resourceKeys: Set<URLResourceKey> = [
        .isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey
    ]
    private static let resourceKeysArray = Array(resourceKeys)

    /// Allocated size in bytes of a single file, or the recursive allocated
    /// size of a directory tree. Synchronous — call off the main thread for
    /// large directories (this type does not hop threads itself).
    static func allocatedSize(of url: URL) -> Int64 {
        let manager = FileManager.default
        var isDir: ObjCBool = false
        guard manager.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }

        if !isDir.boolValue {
            let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
            return Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }

        guard let enumerator = manager.enumerator(
            at: url,
            includingPropertiesForKeys: resourceKeysArray,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return 0 }

        var total: Int64 = 0
        for case let child as URL in enumerator {
            guard let values = try? child.resourceValues(forKeys: resourceKeys),
                  values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }

    /// Sizes many items concurrently. Bounded to 8 in flight so a batch of
    /// hundreds of candidates doesn't spawn hundreds of enumerators at once.
    static func allocatedSizes(of urls: [URL]) async -> [URL: Int64] {
        guard !urls.isEmpty else { return [:] }
        var results: [URL: Int64] = [:]
        results.reserveCapacity(urls.count)
        let maxConcurrent = 8

        await withTaskGroup(of: (URL, Int64).self) { group in
            var iterator = urls.makeIterator()

            func addNext() {
                guard let url = iterator.next() else { return }
                group.addTask(priority: .utility) {
                    (url, allocatedSize(of: url))
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

    // MARK: - Size + last-modified, in one pass

    private static let sizeAndDateKeys: Set<URLResourceKey> = [
        .isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .contentModificationDateKey
    ]
    private static let sizeAndDateKeysArray = Array(sizeAndDateKeys)

    /// Allocated size and most-recent modification date of a file or
    /// directory tree, fetched in the same enumeration pass so a directory
    /// isn't walked twice. For a directory, `modified` is the newest
    /// modification date among its regular files.
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
        let maxConcurrent = 8

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
