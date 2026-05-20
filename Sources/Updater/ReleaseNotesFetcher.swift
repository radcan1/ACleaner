import Foundation

// Release-notes lookup for outdated items.
//
//   MAS apps : iTunes Lookup API exposes `releaseNotes` directly.
//   Casks    : formulae.brew.sh JSON gives homepage + download URL. If the
//              project is on GitHub we fetch the latest release body.
//   Formulae : same as cask, via the formula endpoint.
//
// Results are cached for the lifetime of the app launch so re-opening the
// same sheet is instant.

struct ReleaseNotes: Equatable {
    let title: String           // e.g. "Version 12.7"
    let body: String            // plain text or light markdown
    let source: String          // "Mac App Store", "GitHub releases", "Homebrew"
    let homepage: String?       // shown as selectable text in the sheet
}

private actor ReleaseNotesCache {
    var entries: [String: ReleaseNotes] = [:]
    func get(_ key: String) -> ReleaseNotes? { entries[key] }
    func set(_ key: String, _ value: ReleaseNotes) { entries[key] = value }
}

enum ReleaseNotesFetcher {

    private static let cache = ReleaseNotesCache()

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 10
        c.timeoutIntervalForResource = 15
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    static func notes(for item: OutdatedItem) async -> ReleaseNotes? {
        let key = "\(item.kind.rawValue):\(item.name)"
        if let cached = await cache.get(key) { return cached }

        let fresh: ReleaseNotes?
        switch item.kind {
        case .mas:     fresh = await masNotes(id: item.masId)
        case .cask:    fresh = await brewNotes(name: item.name, kind: "cask")
        case .formula: fresh = await brewNotes(name: item.name, kind: "formula")
        }
        if let fresh { await cache.set(key, fresh) }
        return fresh
    }

    // MARK: - Sources

    private static func masNotes(id: String?) async -> ReleaseNotes? {
        guard let id = id,
              let url = URL(string: "https://itunes.apple.com/lookup?id=\(id)"),
              let json = try? await fetchJSON(url),
              let results = json["results"] as? [[String: Any]],
              let first = results.first else { return nil }

        let version = (first["version"] as? String).map { "Version \($0)" } ?? "What's New"
        let raw = (first["releaseNotes"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let body = raw.isEmpty
            ? "Apple does not publish release notes for this app."
            : raw
        let homepage = first["trackViewUrl"] as? String
        return ReleaseNotes(
            title: version,
            body: body,
            source: "Mac App Store",
            homepage: homepage
        )
    }

    private static func brewNotes(name: String, kind: String) async -> ReleaseNotes? {
        let safe = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        guard let metaURL = URL(string: "https://formulae.brew.sh/api/\(kind)/\(safe).json"),
              let json = try? await fetchJSON(metaURL) else { return nil }

        let homepage = json["homepage"] as? String
        let desc     = (json["desc"] as? String) ?? ""
        let caveats  = (json["caveats"] as? String) ?? ""
        let version  = brewVersion(from: json, kind: kind)

        // Best case: project is on GitHub → fetch the latest release notes.
        if let gh = detectGitHub(in: json),
           let release = await githubLatestReleaseBody(owner: gh.owner, repo: gh.repo) {
            var body = release.body
            if !desc.isEmpty { body = "_\(desc)_\n\n" + body }
            if !caveats.isEmpty { body += "\n\n---\n\n**Homebrew caveats:**\n\n" + caveats }
            return ReleaseNotes(
                title: release.title ?? version ?? "Latest release",
                body: body,
                source: "GitHub releases",
                homepage: homepage
            )
        }

        // Fallback: Homebrew metadata only.
        var fallbackBody = ""
        if !desc.isEmpty { fallbackBody += desc + "\n\n" }
        fallbackBody += "Homebrew does not host structured release notes for this package, and the project does not appear to publish them on GitHub.\n\nCheck the homepage listed below for changelog details."
        if !caveats.isEmpty { fallbackBody += "\n\n---\n\n**Homebrew caveats:**\n\n" + caveats }
        return ReleaseNotes(
            title: version ?? "Update available",
            body: fallbackBody,
            source: "Homebrew",
            homepage: homepage
        )
    }

    // MARK: - Helpers

    private static func brewVersion(from json: [String: Any], kind: String) -> String? {
        if kind == "formula",
           let v = json["versions"] as? [String: Any],
           let stable = v["stable"] as? String {
            return "Version \(stable)"
        }
        if kind == "cask", let v = json["version"] as? String {
            return "Version \(v)"
        }
        return nil
    }

    private static func detectGitHub(in json: [String: Any]) -> (owner: String, repo: String)? {
        var candidates: [String] = []
        candidates.append(json["homepage"] as? String ?? "")
        candidates.append(json["url"]      as? String ?? "")
        if let head = json["head"] as? [String: Any],
           let u = head["url"] as? String {
            candidates.append(u)
        }
        if let urls = json["urls"] as? [String: Any] {
            if let stable = urls["stable"] as? [String: Any],
               let u = stable["url"] as? String {
                candidates.append(u)
            }
        }
        for c in candidates {
            if let parsed = parseGitHub(c) { return parsed }
        }
        return nil
    }

    private static func parseGitHub(_ raw: String) -> (owner: String, repo: String)? {
        guard !raw.isEmpty, raw.contains("github.com") else { return nil }
        guard let url = URL(string: raw) else { return nil }
        let comps = url.path.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        guard comps.count >= 2 else { return nil }
        var repo = comps[1]
        if repo.hasSuffix(".git") { repo = String(repo.dropLast(4)) }
        return (owner: comps[0], repo: repo)
    }

    private struct GitHubRelease {
        let title: String?
        let body: String
    }

    private static func githubLatestReleaseBody(owner: String, repo: String) async -> GitHubRelease? {
        guard let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest") else {
            return nil
        }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await session.data(for: req),
              let http = resp as? HTTPURLResponse,
              http.statusCode < 400,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let title = (json["name"] as? String) ?? (json["tag_name"] as? String)
        let body = ((json["body"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if body.isEmpty { return nil }
        return GitHubRelease(title: title, body: body)
    }

    private static func fetchJSON(_ url: URL) async throws -> [String: Any]? {
        let (data, _) = try await session.data(from: url)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
