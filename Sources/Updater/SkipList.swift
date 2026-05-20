import Foundation

// Per-app skip list backed by UserDefaults.
//
// Items are keyed by "<kind>:<name>" to avoid collisions between, say, a
// formula and a cask sharing a name.

@MainActor
final class SkipList: ObservableObject {
    @Published private(set) var entries: Set<String> = []

    private let defaultsKey = "MacUpdater.SkippedApps"

    init() {
        if let arr = UserDefaults.standard.array(forKey: defaultsKey) as? [String] {
            entries = Set(arr)
        }
    }

    static func key(kind: UpdateKind, name: String) -> String {
        "\(kind.rawValue):\(name)"
    }

    func contains(_ key: String) -> Bool { entries.contains(key) }
    func contains(kind: UpdateKind, name: String) -> Bool {
        entries.contains(Self.key(kind: kind, name: name))
    }

    func add(kind: UpdateKind, name: String) {
        entries.insert(Self.key(kind: kind, name: name))
        persist()
    }

    func remove(_ key: String) {
        entries.remove(key)
        persist()
    }

    func clear() {
        entries.removeAll()
        persist()
    }

    /// Split a key back into (kind, name) for display.
    static func decompose(_ key: String) -> (kind: UpdateKind, name: String)? {
        guard let colon = key.firstIndex(of: ":") else { return nil }
        let kindRaw = String(key[..<colon])
        let name = String(key[key.index(after: colon)...])
        guard let kind = UpdateKind(rawValue: kindRaw) else { return nil }
        return (kind, name)
    }

    private func persist() {
        UserDefaults.standard.set(Array(entries), forKey: defaultsKey)
    }
}
