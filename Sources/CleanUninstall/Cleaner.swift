import Foundation

enum Cleaner {
    struct Outcome {
        let removed: Int
        let failed: [String]
    }

    static func moveToTrash(urls: [URL]) -> Outcome {
        var removed = 0
        var failed: [String] = []
        let manager = FileManager.default

        for url in urls {
            guard manager.fileExists(atPath: url.path) else { continue }
            do {
                var resultURL: NSURL?
                try manager.trashItem(at: url, resultingItemURL: &resultURL)
                removed += 1
            } catch {
                failed.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        return Outcome(removed: removed, failed: failed)
    }
}
