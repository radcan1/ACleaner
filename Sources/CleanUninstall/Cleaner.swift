import Foundation

enum Cleaner {
    struct Outcome {
        let removed: Int
        let failed: [String]
        let trashedPairs: [TrashedRecord]
    }

    static func moveToTrash(urls: [URL]) -> Outcome {
        var removed = 0
        var failed: [String] = []
        var pairs: [TrashedRecord] = []
        let manager = FileManager.default

        for url in urls {
            guard manager.fileExists(atPath: url.path) else { continue }
            do {
                var resultURL: NSURL?
                try manager.trashItem(at: url, resultingItemURL: &resultURL)
                removed += 1
                if let trashedPath = (resultURL as URL?)?.path {
                    pairs.append(TrashedRecord(originalPath: url.path, trashPath: trashedPath))
                }
            } catch {
                // Include the full path so failure reports are actionable.
                failed.append("\(url.path)\n   Error: \(error.localizedDescription)")
            }
        }

        return Outcome(removed: removed, failed: failed, trashedPairs: pairs)
    }
}
