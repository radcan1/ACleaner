import Foundation

/// Shared "does this name/bundle-ID belong to that app?" logic, used by both
/// the orphan-file clustering in AppCleanerView and the Clean Uninstall
/// leftover scanner. Originally built only for orphan clustering; extracted
/// here so LeftoverScanner stops using bare whole-string substring matching,
/// which produced false positives like an app named "Photo" matching a
/// "Photoshop" folder.
enum AppTokenMatcher {
    /// Words too generic to identify an app on their own — never used to
    /// match two names as the same app.
    static let genericTokens: Set<String> = [
        "app","apps","application","applications","mac","macos","osx",
        "helper","agent","agents","daemon","client","service","services",
        "plugin","plugins","extension","launcher","updater","update",
        "assistant","support","group","team","labs","studio","software",
        "framework","shared","core","main","data","text","file","files",
        "free","lite","beta","alpha","desktop","tool","tools","user",
    ]

    private static let wordSeparators = CharacterSet(charactersIn: " -_.")

    /// Identity tokens for a name or bundle ID. For reverse-DNS bundle-id
    /// strings ("com.vendor.Product", 3+ dot-separated components) only the
    /// last meaningful component counts — the product name — otherwise every
    /// vendor's apps would collide on their shared vendor token. For plain
    /// names every meaningful word counts. An empty result means the key
    /// never matches anything (all its words were short or generic).
    static func identityTokens(for key: String) -> Set<String> {
        let words = key.components(separatedBy: wordSeparators)
            .map { $0.lowercased().filter { $0.isLetter || $0.isNumber } }
            .filter { $0.count >= 4 && !genericTokens.contains($0) }
        guard !words.isEmpty else { return [] }
        if key.split(separator: ".").count >= 3, let last = words.last {
            return [last]
        }
        return Set(words)
    }

    /// Two tokens identify the same app when equal, or when one is a short
    /// version-suffix extension of the other ("sketch" / "sketch3") — NOT
    /// when one is merely a word-prefix of a longer, different product name
    /// ("photo" is not the start of a real match against "photoshop"). The
    /// shorter token must be at least 6 characters, and the length
    /// difference at most 2, so only version-suffix-sized extensions count.
    static func tokensMatch(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let (shorter, longer) = a.count <= b.count ? (a, b) : (b, a)
        guard shorter.count >= 6, longer.count - shorter.count <= 2 else { return false }
        return longer.hasPrefix(shorter)
    }

    /// True if any token in `a` matches any token in `b`.
    static func tokenSetsMatch(_ a: Set<String>, _ b: Set<String>) -> Bool {
        a.contains { x in b.contains { y in tokensMatch(x, y) } }
    }

    /// Most human-readable of a set of equivalent keys: prefer plain names
    /// over reverse-DNS bundle ids, shorter over longer.
    static func preferredKey(_ keys: [String]) -> String {
        let plain = keys.filter { !$0.contains(".") }
        let pool = plain.isEmpty ? keys : plain
        return pool.min { ($0.count, $0) < ($1.count, $1) } ?? keys[0]
    }

    /// Strips all non-alphanumeric characters and lowercases — a name or
    /// bundle ID collapsed to one unbroken blob, for the substring fallback
    /// below.
    static func pearFormat(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Fallback for names that don't tokenize cleanly — a camelCase vendor
    /// folder like "BraveSoftware" has no separator for identityTokens to
    /// split on, so it becomes one long token that word-matching can't
    /// relate to "com.brave.Browser". Comparing the fully-collapsed blobs as
    /// a substring (either direction) catches these, with a 6-character
    /// floor so short strings can't glue unrelated apps together.
    static func substringFallbackMatch(_ a: String, _ b: String) -> Bool {
        let pa = pearFormat(a), pb = pearFormat(b)
        guard pa.count >= 6, pb.count >= 6 else { return false }
        return pa.contains(pb) || pb.contains(pa)
    }
}
