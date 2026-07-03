import Foundation
import AppKit

final class LeftoverScanner: Sendable {
    func scan(for app: TrashedApp) async -> [LeftoverFile] {
        var matches: [URL: LeftoverFile.Kind] = [:]

        // An app on the shared exclusion list (set from the Orphaned Files
        // scan) is never searched for leftovers here either — one "always
        // skip" preference covers both flows. The trashed app bundle itself
        // still appears below since that's the literal item just trashed,
        // not a discovered match.
        let isExcluded = await ExclusionStore.shared.isExcluded(app.displayName)
        if !isExcluded {
            let needleTokens = makeIdentityTokens(for: app)
            let bundleIDBlob = app.bundleIdentifier.map(AppTokenMatcher.pearFormat)
                .flatMap { $0.count >= 6 ? $0 : nil }

            if !needleTokens.isEmpty || bundleIDBlob != nil {
                let manager = FileManager.default

                for entry in ScanLocations.all {
                    guard manager.fileExists(atPath: entry.path) else { continue }
                    walk(root: URL(fileURLWithPath: entry.path), depth: 0, maxDepth: entry.depth) { url in
                        let name = url.lastPathComponent
                        let base = stripExtensionIfFile(name, isDirectory: isDirectory(url))
                        let entryTokens = AppTokenMatcher.identityTokens(for: base)

                        let matchesTokens = !entryTokens.isEmpty
                            && AppTokenMatcher.tokenSetsMatch(entryTokens, needleTokens)
                        let matchesBundleIDBlob = bundleIDBlob.map { blob in
                            let entryBlob = AppTokenMatcher.pearFormat(base)
                            return entryBlob.count >= 6 && entryBlob.contains(blob)
                        } ?? false

                        if matchesTokens || matchesBundleIDBlob {
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
            }
        }

        let collapsed = collapseChildren(of: matches)

        // Size the app bundle plus every leftover in one bounded batch instead
        // of sequentially, one item at a time.
        let allURLs = [app.trashURL] + collapsed.keys
        let sizes = await FileSize.allocatedSizes(of: allURLs)

        let trashed = LeftoverFile(
            url: app.trashURL,
            sizeBytes: sizes[app.trashURL] ?? 0,
            kind: .appBundle
        )

        let leftovers = collapsed
            .map { url, kind in
                LeftoverFile(url: url, sizeBytes: sizes[url] ?? 0, kind: kind)
            }
            .sorted { lhs, rhs in
                if lhs.kind.rawValue == rhs.kind.rawValue {
                    return lhs.url.path < rhs.url.path
                }
                return lhs.kind.rawValue < rhs.kind.rawValue
            }

        return [trashed] + leftovers
    }

    /// Identity tokens covering the app's display name, original bundle
    /// name, and bundle identifier. Matching leftover files against these
    /// via AppTokenMatcher.tokenSetsMatch (word-boundary tokens, not raw
    /// substring containment) is what stops an app like "Photo" from
    /// matching an unrelated "Photoshop" folder — the previous whole-string
    /// `normalized.contains(needle)` check had no word-boundary awareness.
    private func makeIdentityTokens(for app: TrashedApp) -> Set<String> {
        var tokens: Set<String> = []
        tokens.formUnion(AppTokenMatcher.identityTokens(for: app.displayName))
        tokens.formUnion(AppTokenMatcher.identityTokens(for: app.originalName))
        if let bundleID = app.bundleIdentifier, !bundleID.isEmpty {
            tokens.formUnion(AppTokenMatcher.identityTokens(for: bundleID))
        }
        return tokens
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

}
