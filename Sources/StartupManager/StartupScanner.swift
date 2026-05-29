import Foundation
import AppKit

@MainActor
final class StartupScanner: ObservableObject {
    @Published var items: [StartupItem] = []
    @Published var isScanning = false
    @Published var errorMessage: String? = nil

    func scan() {
        isScanning = true
        errorMessage = nil
        Task.detached(priority: .userInitiated) { [weak self] in
            var found: [StartupItem] = []

            // ── Login Items via SMAppService query ────────────────────────────
            // We enumerate all registered background tasks visible to the user.
            // This surfaces helpers registered with SMAppService (macOS 13+).
            let loginItems = Self.scanLoginItems()
            found.append(contentsOf: loginItems)

            // ── User Launch Agents  ~/Library/LaunchAgents ────────────────────
            let userAgents = Self.scanPlistDirectory(
                url: URL(fileURLWithPath: NSHomeDirectory())
                    .appendingPathComponent("Library/LaunchAgents"),
                kind: .userAgent
            )
            found.append(contentsOf: userAgents)

            // ── System Launch Agents  /Library/LaunchAgents ───────────────────
            let sysAgents = Self.scanPlistDirectory(
                url: URL(fileURLWithPath: "/Library/LaunchAgents"),
                kind: .systemAgent
            )
            found.append(contentsOf: sysAgents)

            // ── System Launch Daemons  /Library/LaunchDaemons ─────────────────
            let sysDaemons = Self.scanPlistDirectory(
                url: URL(fileURLWithPath: "/Library/LaunchDaemons"),
                kind: .systemDaemon
            )
            found.append(contentsOf: sysDaemons)

            // Sort: enabled first, then alphabetically within each kind
            let sorted = found.sorted {
                if $0.kind.rawValue != $1.kind.rawValue {
                    let order: [StartupItemKind] = [.loginItem, .userAgent, .systemAgent, .systemDaemon]
                    let li = order.firstIndex(of: $0.kind) ?? 99
                    let ri = order.firstIndex(of: $1.kind) ?? 99
                    return li < ri
                }
                if $0.isEnabled != $1.isEnabled { return $0.isEnabled && !$1.isEnabled }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }

            await MainActor.run { [weak self] in
                self?.items = sorted
                self?.isScanning = false
            }
        }
    }

    // MARK: - SMAppService login items

    private nonisolated static func scanLoginItems() -> [StartupItem] {
        // Background task items registered with SMAppService appear in
        // /var/db/com.apple.backgroundtaskmanagement/ but the public API
        // for enumerating *other* apps' registrations is private.
        // We instead read the managed-agents directory that macOS 13+ creates
        // for the current user, which lists all app-registered helpers.
        var results: [StartupItem] = []

        let mgmtDir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/com.apple.backgroundtaskmanagementd/agents")

        if let urls = try? FileManager.default.contentsOfDirectory(
            at: mgmtDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: .skipsHiddenFiles
        ) {
            for url in urls where url.pathExtension == "plist" {
                if let item = parseLoginItemPlist(url: url) {
                    results.append(item)
                }
            }
        }

        // Also check the legacy location used before macOS 13
        let legacyDir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/com.apple.backgroundtaskmanagement")
        if let urls = try? FileManager.default.contentsOfDirectory(
            at: legacyDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: .skipsHiddenFiles
        ) {
            for url in urls where url.pathExtension == "plist" {
                if let item = parseLoginItemPlist(url: url) {
                    // Deduplicate against already-found items
                    if !results.contains(where: { $0.detail == item.detail }) {
                        results.append(item)
                    }
                }
            }
        }

        return results
    }

    private nonisolated static func parseLoginItemPlist(url: URL) -> StartupItem? {
        guard let dict = NSDictionary(contentsOf: url) as? [String: Any] else { return nil }
        let label = dict["Label"] as? String ?? url.deletingPathExtension().lastPathComponent
        let disabled = dict["Disabled"] as? Bool ?? false

        // Try to resolve a friendly app name from the bundle ID
        let name = friendlyName(for: label) ?? label

        return StartupItem(
            id: UUID(),
            kind: .loginItem,
            name: name,
            detail: label,
            plistURL: url,
            isEnabled: !disabled
        )
    }

    // MARK: - Plist directory scan

    private nonisolated static func scanPlistDirectory(url: URL, kind: StartupItemKind) -> [StartupItem] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: .skipsHiddenFiles
        ) else { return [] }

        return urls.compactMap { plist -> StartupItem? in
            guard plist.pathExtension == "plist",
                  let dict = NSDictionary(contentsOf: plist) as? [String: Any]
            else { return nil }

            let label = dict["Label"] as? String ?? plist.deletingPathExtension().lastPathComponent
            let disabled = dict["Disabled"] as? Bool ?? false
            let name = friendlyName(for: label) ?? label

            return StartupItem(
                id: UUID(),
                kind: kind,
                name: name,
                detail: label,
                plistURL: plist,
                isEnabled: !disabled
            )
        }
    }

    // MARK: - Helpers

    private nonisolated static func friendlyName(for bundleIDOrLabel: String) -> String? {
        // Strip common reverse-DNS prefixes to get a readable name (e.g. com.company.MyHelper → My Helper)
        let parts = bundleIDOrLabel.split(separator: ".").map(String.init)
        if parts.count >= 3 {
            return parts.dropFirst(2).joined(separator: " ").capitalized
        }
        return nil
    }

    // MARK: - Mutations

    func toggle(item: StartupItem) {
        guard item.canToggle, let plistURL = item.plistURL else { return }

        guard let dict = NSMutableDictionary(contentsOf: plistURL) else {
            errorMessage = "Could not read \(item.name)."
            return
        }

        let nowDisabled = item.isEnabled   // toggling: if currently enabled → set disabled
        dict["Disabled"] = nowDisabled ? true : false
        // Remove the key entirely when enabling (cleaner plist)
        if !nowDisabled { dict.removeObject(forKey: "Disabled") }

        do {
            let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
            try data.write(to: plistURL, options: .atomic)
            // Reflect the change immediately in the list
            if let idx = items.firstIndex(where: { $0.id == item.id }) {
                items[idx].isEnabled = !item.isEnabled
            }
        } catch {
            errorMessage = "Could not save changes to \(item.name): \(error.localizedDescription)"
        }
    }

    func delete(item: StartupItem) {
        guard item.canDelete, let plistURL = item.plistURL else { return }
        do {
            try FileManager.default.trashItem(at: plistURL, resultingItemURL: nil)
            items.removeAll { $0.id == item.id }
        } catch {
            errorMessage = "Could not remove \(item.name): \(error.localizedDescription)"
        }
    }
}
