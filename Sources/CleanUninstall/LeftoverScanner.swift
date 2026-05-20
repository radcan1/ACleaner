import Foundation
import AppKit

final class LeftoverScanner: Sendable {
    func scan(for app: TrashedApp) -> [LeftoverFile] {
        let needles = makeNeedles(for: app)
        guard !needles.isEmpty else { return [] }

        var matches: [URL: LeftoverFile.Kind] = [:]
        let manager = FileManager.default

        for entry in ScanLocations.all {
            guard manager.fileExists(atPath: entry.path) else { continue }
            walk(root: URL(fileURLWithPath: entry.path), depth: 0, maxDepth: entry.depth) { url in
                let name = url.lastPathComponent
                let normalized = normalize(stripExtensionIfFile(name, isDirectory: isDirectory(url)))
                if matchesAny(normalized: normalized, needles: needles) {
                    matches[url] = entry.kind
                }
            }
        }

        let containerMatches = findContainers(for: app)
        for url in containerMatches {
            matches[url] = .containers
        }

        if let bundleID = app.bundleIdentifier,
           let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: bundleID),
           FileManager.default.fileExists(atPath: group.path) {
            matches[group] = .groupContainers
        }

        let collapsed = collapseChildren(of: matches)
        let trashed = LeftoverFile(
            url: app.trashURL,
            sizeBytes: size(of: app.trashURL),
            kind: .appBundle
        )

        let leftovers = collapsed
            .map { url, kind in
                LeftoverFile(url: url, sizeBytes: size(of: url), kind: kind)
            }
            .sorted { lhs, rhs in
                if lhs.kind.rawValue == rhs.kind.rawValue {
                    return lhs.url.path < rhs.url.path
                }
                return lhs.kind.rawValue < rhs.kind.rawValue
            }

        return [trashed] + leftovers
    }

    private func makeNeedles(for app: TrashedApp) -> [String] {
        var set: Set<String> = []

        let names = [app.displayName, app.originalName]
        for name in names {
            let normalized = normalize(name)
            if normalized.count >= 4 { set.insert(normalized) }
        }

        if let bundleID = app.bundleIdentifier, !bundleID.isEmpty {
            set.insert(normalize(bundleID))

            let components = bundleID.split(separator: ".").map(String.init)
            if components.count >= 2 {
                let lastTwo = components.suffix(2).joined()
                set.insert(normalize(lastTwo))
            }
            if let last = components.last {
                let normalizedLast = normalize(last)
                if normalizedLast.count >= 4 { set.insert(normalizedLast) }
            }
        }

        return Array(set)
    }

    private func matchesAny(normalized: String, needles: [String]) -> Bool {
        guard !normalized.isEmpty else { return false }
        for needle in needles where !needle.isEmpty {
            if normalized == needle { return true }
            if normalized.contains(needle) { return true }
        }
        return false
    }

    private func normalize(_ input: String) -> String {
        let lowered = input.lowercased()
        return lowered.unicodeScalars.filter { scalar in
            CharacterSet.alphanumerics.contains(scalar)
        }.reduce(into: "") { $0.unicodeScalars.append($1) }
    }

    private func stripExtensionIfFile(_ name: String, isDirectory: Bool) -> String {
        if isDirectory { return name }
        return (name as NSString).deletingPathExtension
    }

    private func isDirectory(_ url: URL) -> Bool {
        var flag: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &flag)
        return flag.boolValue
    }

    private func walk(root: URL, depth: Int, maxDepth: Int, visit: (URL) -> Void) {
        guard depth <= maxDepth else { return }
        let manager = FileManager.default
        guard let contents = try? manager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for child in contents {
            visit(child)
            if depth < maxDepth, isDirectory(child) {
                walk(root: child, depth: depth + 1, maxDepth: maxDepth, visit: visit)
            }
        }
    }

    private func findContainers(for app: TrashedApp) -> [URL] {
        guard let bundleID = app.bundleIdentifier else { return [] }
        let manager = FileManager.default
        let containers = manager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers")

        guard let entries = try? manager.contentsOfDirectory(
            at: containers,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var matches: [URL] = []
        for entry in entries {
            let metadata = entry.appendingPathComponent(".com.apple.containermanagerd.metadata.plist")
            if let dict = NSDictionary(contentsOf: metadata),
               let identifier = dict["MCMMetadataIdentifier"] as? String,
               identifier == bundleID {
                matches.append(entry)
                continue
            }
            if entry.lastPathComponent == bundleID {
                matches.append(entry)
            }
        }
        return matches
    }

    private func collapseChildren(of matches: [URL: LeftoverFile.Kind]) -> [URL: LeftoverFile.Kind] {
        let sortedPaths = matches.keys.sorted { $0.path < $1.path }
        var result: [URL: LeftoverFile.Kind] = [:]
        var kept: [URL] = []
        for url in sortedPaths {
            if kept.contains(where: { url.path.hasPrefix($0.path + "/") }) { continue }
            kept.append(url)
            result[url] = matches[url]
        }
        return result
    }

    private func size(of url: URL) -> Int64 {
        let manager = FileManager.default
        var isDir: ObjCBool = false
        guard manager.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }

        if !isDir.boolValue {
            let attr = try? manager.attributesOfItem(atPath: url.path)
            return (attr?[.size] as? Int64) ?? 0
        }

        var total: Int64 = 0
        if let enumerator = manager.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) {
            for case let child as URL in enumerator {
                let values = try? child.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey])
                if values?.isRegularFile == true {
                    total += Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
                }
            }
        }
        return total
    }
}
