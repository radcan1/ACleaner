import Foundation

/// Generic disk cache for scan results, so switching tools or relaunching
/// the app doesn't throw away a completed scan. Stored as JSON under
/// ~/Library/Application Support/ACleaner/cache/<key>.json.
enum ScanCache {
    private static var cacheDir: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ACleaner/cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private struct Envelope<T: Codable>: Codable {
        let savedAt: Date
        let payload: T
    }

    static func save<T: Codable>(_ payload: T, key: String) {
        let url = cacheDir.appendingPathComponent("\(key).json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(Envelope(savedAt: Date(), payload: payload)) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Returns the cached payload and when it was saved, or nil if there is
    /// no cache or it fails to decode (e.g. the model shape changed).
    static func load<T: Codable>(_ type: T.Type, key: String) -> (payload: T, savedAt: Date)? {
        let url = cacheDir.appendingPathComponent("\(key).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let envelope = try? decoder.decode(Envelope<T>.self, from: data) else { return nil }
        return (envelope.payload, envelope.savedAt)
    }

    static func clear(key: String) {
        try? FileManager.default.removeItem(at: cacheDir.appendingPathComponent("\(key).json"))
    }

    /// Human-friendly "X ago" label for a cache header, e.g. "2 hours ago".
    static func ageLabel(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
