import Foundation

// Best-effort download-size lookup for outdated items.
//
//   formulae  -> formulae.brew.sh JSON gives bottle URL; HEAD that URL.
//   casks     -> formulae.brew.sh JSON gives download URL; HEAD that URL.
//   mas apps  -> iTunes Lookup API returns fileSizeBytes directly.
//
// Returns nil when the size can't be determined (network failure, server
// doesn't expose Content-Length on HEAD, etc). Callers display "—" or hide
// the size in that case.

enum SizeFetcher {

    // Short timeouts — we don't want size lookups to hold up the UI long if
    // the network is slow or a remote is misbehaving.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    static func size(for item: OutdatedItem) async -> Int64? {
        switch item.kind {
        case .formula: return await formulaBottleSize(name: item.name)
        case .cask:    return await caskDownloadSize(name: item.name)
        case .mas:     return await masDownloadSize(id: item.masId)
        }
    }

    // MARK: - Per-kind lookups

    private static func formulaBottleSize(name: String) async -> Int64? {
        guard let url = brewAPI(kind: "formula", name: name),
              let json = try? await fetchJSON(url) else { return nil }

        // bottle.stable.files is a dict keyed by platform tag. Prefer
        // arm64_* tags for Apple Silicon, then anything else.
        guard let bottle = json["bottle"] as? [String: Any],
              let stable = bottle["stable"] as? [String: Any],
              let files  = stable["files"]  as? [String: [String: Any]] else { return nil }

        let preferred = [
            "arm64_sequoia", "arm64_sonoma", "arm64_ventura",
            "arm64_monterey", "arm64_big_sur",
            "sequoia", "sonoma", "ventura", "monterey", "big_sur",
            "all"
        ]
        for tag in preferred {
            if let entry = files[tag], let urlStr = entry["url"] as? String,
               let bottleURL = URL(string: urlStr) {
                if let s = await contentLength(of: bottleURL) { return s }
            }
        }
        // Last-ditch: take any entry.
        for (_, entry) in files {
            if let urlStr = entry["url"] as? String, let bottleURL = URL(string: urlStr) {
                if let s = await contentLength(of: bottleURL) { return s }
            }
        }
        return nil
    }

    private static func caskDownloadSize(name: String) async -> Int64? {
        guard let url = brewAPI(kind: "cask", name: name),
              let json = try? await fetchJSON(url) else { return nil }
        guard let urlStr = json["url"] as? String,
              let dlURL = URL(string: urlStr) else { return nil }
        return await contentLength(of: dlURL)
    }

    private static func masDownloadSize(id: String?) async -> Int64? {
        guard let id = id,
              let url = URL(string: "https://itunes.apple.com/lookup?id=\(id)"),
              let json = try? await fetchJSON(url),
              let results = json["results"] as? [[String: Any]],
              let first = results.first else { return nil }
        if let n = first["fileSizeBytes"] as? NSNumber { return n.int64Value }
        if let s = first["fileSizeBytes"] as? String, let n = Int64(s) { return n }
        return nil
    }

    // MARK: - HTTP helpers

    private static func brewAPI(kind: String, name: String) -> URL? {
        let safe = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        return URL(string: "https://formulae.brew.sh/api/\(kind)/\(safe).json")
    }

    private static func fetchJSON(_ url: URL) async throws -> [String: Any]? {
        let (data, _) = try await session.data(from: url)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Best-effort Content-Length via HEAD. Some CDNs don't answer HEAD;
    /// returns nil in that case.
    private static func contentLength(of url: URL) async -> Int64? {
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        guard let (_, resp) = try? await session.data(for: req),
              let http = resp as? HTTPURLResponse,
              http.statusCode < 400 else { return nil }
        if let lenStr = http.value(forHTTPHeaderField: "Content-Length"),
           let n = Int64(lenStr), n > 0 {
            return n
        }
        return nil
    }
}

// MARK: - Formatting helper used across views

enum SizeFormat {
    static func bytes(_ b: Int64?) -> String {
        guard let b = b, b > 0 else { return "—" }
        let gb = Double(b) / 1_073_741_824
        let mb = Double(b) / 1_048_576
        let kb = Double(b) / 1_024
        if gb >= 1.0 { return String(format: "%.2f GB", gb) }
        if mb >= 1.0 { return String(format: "%.0f MB", mb) }
        if kb >= 1.0 { return String(format: "%.0f KB", kb) }
        return "\(b) B"
    }

    /// Spoken form, e.g. "380 megabytes". Used in VoiceOver labels.
    static func spoken(_ b: Int64?) -> String {
        guard let b = b, b > 0 else { return "size unknown" }
        let gb = Double(b) / 1_073_741_824
        let mb = Double(b) / 1_048_576
        if gb >= 1.0 { return String(format: "%.1f gigabytes", gb) }
        if mb >= 1.0 { return String(format: "%.0f megabytes", mb) }
        return "less than 1 megabyte"
    }
}
