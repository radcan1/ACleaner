import Foundation

/// Keeps Homebrew's cask receipts in sync with what is actually on disk.
///
/// Deleting a brew-installed app without `brew uninstall` leaves its receipt
/// in the Caskroom, so brew keeps reporting "updates" that would reinstall
/// the deleted app. Clean Uninstall calls these helpers once a cleanup
/// commits, so the receipt disappears together with the app and the Updater
/// never sees a ghost.
enum BrewReceipts {

    /// Maps an app file name ("Telegram.app", or Finder-renamed
    /// "Telegram 2.app") to the installed cask token ("telegram"), if
    /// Homebrew installed it. Returns nil for apps brew doesn't manage.
    static func caskToken(forAppNamed appName: String) async -> String? {
        guard let brew = CommandRunner.brewPath else { return nil }
        let (status, out, _) = await CommandRunner.runOnce(
            executable: brew,
            args: ["info", "--cask", "--json=v2", "--installed"],
            timeoutSeconds: 60)
        guard status == 0, let data = out.data(using: .utf8) else { return nil }

        struct InfoJSON: Decodable {
            struct Cask: Decodable {
                let token: String
                let artifacts: [Artifact]?
            }
            // The artifacts array mixes shapes; tolerate anything that is
            // not an {app: [names]} entry.
            struct Artifact: Decodable {
                let app: [String]?
                enum CodingKeys: String, CodingKey { case app }
                init(from decoder: Decoder) {
                    let c = try? decoder.container(keyedBy: CodingKeys.self)
                    app = try? c?.decode([String].self, forKey: .app)
                }
            }
            let casks: [Cask]
        }
        guard let parsed = try? JSONDecoder().decode(InfoJSON.self, from: data) else { return nil }

        // Exact (case-insensitive) match first; fall back to a match with
        // Finder's " 2" rename counter stripped.
        let exact = appName.lowercased()
        let stripped = normalize(appName)
        var strippedHit: String?
        for cask in parsed.casks {
            for artifact in cask.artifacts ?? [] {
                for app in artifact.app ?? [] {
                    if app.lowercased() == exact { return cask.token }
                    if normalize(app) == stripped { strippedHit = strippedHit ?? cask.token }
                }
            }
        }
        return strippedHit
    }

    /// Removes the cask receipt (Caskroom entry and metadata). Safe when the
    /// app bundle is already gone — that is the expected state when this
    /// runs. Does not touch the copy sitting in the Trash.
    @discardableResult
    static func purgeReceipt(token: String) async -> Bool {
        guard let brew = CommandRunner.brewPath else { return false }
        let (status, _, _) = await CommandRunner.runOnce(
            executable: brew,
            args: ["uninstall", "--cask", "--force", token],
            timeoutSeconds: 120)
        return status == 0
    }

    /// "Telegram 2.app" → "telegram.app": Finder appends a counter when the
    /// name is already taken in the Trash.
    private static func normalize(_ name: String) -> String {
        let base = (name as NSString).deletingPathExtension
            .replacingOccurrences(of: #"\s+\d+$"#, with: "", options: .regularExpression)
        return base.lowercased() + ".app"
    }
}
