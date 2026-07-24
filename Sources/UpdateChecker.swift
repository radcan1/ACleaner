import Foundation
import AppKit

/// Checks GitHub releases for a newer version of ACleaner.
/// Runs once on launch (with a short delay so it doesn't slow startup).
/// Completely silent on network failure — update checking is best-effort.
@MainActor
final class UpdateChecker: ObservableObject {
    @Published var availableVersion: String? = nil

    private let repo = "radcan1/ACleaner"

    private var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    var releasePageURL: URL {
        URL(string: "https://github.com/\(repo)/releases/latest")!
    }

    // MARK: - Check

    func check() async {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return }

        do {
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

            let (data, _) = try await URLSession.shared.data(for: request)

            guard
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let tagName = json["tag_name"] as? String
            else { return }

            // Strip leading "v" from tag (e.g. "v1.2.0" → "1.2.0")
            let latest = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName

            guard isNewer(latest, than: currentVersion) else { return }

            availableVersion = latest

            // Announce via VoiceOver so the user hears it even without looking at the banner
            NSAccessibility.post(
                element: NSApp as Any,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: "ACleaner \(latest) is available. An Update Now button has appeared at the top of the window. It installs the update without opening a browser.",
                    .priority: NSAccessibilityPriorityLevel.high.rawValue
                ]
            )
        } catch {
            // Network errors are silently ignored — update check is non-critical
        }
    }

    func dismiss() {
        availableVersion = nil
    }

    // MARK: - Version comparison

    /// Returns true if `latest` is a higher semantic version than `current`.
    private func isNewer(_ latest: String, than current: String) -> Bool {
        let l = parts(latest)
        let c = parts(current)
        let count = max(l.count, c.count)
        for i in 0..<count {
            let lv = i < l.count ? l[i] : 0
            let cv = i < c.count ? c[i] : 0
            if lv > cv { return true }
            if lv < cv { return false }
        }
        return false
    }

    private func parts(_ version: String) -> [Int] {
        version.split(separator: ".").compactMap { Int($0) }
    }
}
