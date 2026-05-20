import Foundation
import AppKit

// MARK: - Models

struct CleanupCandidate: Identifiable, Equatable {
    let id = UUID()
    let kind: Kind
    let name: String
    let detail: String      // version, size, owner, etc.
    let path: String?       // filesystem path for kinds that need one (rootOwnedApp)
    var isSelected: Bool = true

    init(kind: Kind, name: String, detail: String, path: String? = nil, isSelected: Bool = true) {
        self.kind = kind
        self.name = name
        self.detail = detail
        self.path = path
        self.isSelected = isSelected
    }

    enum Kind: String {
        case oldVersion       // brew cleanup
        case orphanedFormula  // brew autoremove
        case staleCask        // installed cask, .app missing from /Applications
    }
}

enum MaintenanceState: Equatable {
    case idle
    case scanning
    case ready
    case acting
    case done(removedCount: Int, freedBytes: Int64)
}

// MARK: - Engine

@MainActor
final class MaintenanceEngine: ObservableObject {
    @Published var state: MaintenanceState = .idle
    @Published var scanStatus: String = ""
    @Published var candidates: [CleanupCandidate] = []
    @Published var freeableBytes: Int64 = 0

    @Published var actionLog: String = ""
    @Published var sheetVisible: Bool = false

    private var runningProcess: Process?

    // MARK: Scan

    func scan() async {
        guard let brew = CommandRunner.brewPath else {
            scanStatus = "Homebrew not found."
            return
        }

        state = .scanning
        candidates = []
        freeableBytes = 0
        actionLog = ""

        scanStatus = "Checking old versions (brew cleanup --dry-run)…"
        announce("Checking old versions.")
        let cleanup = await scanCleanup(brew: brew)

        scanStatus = "Checking orphaned formulae (brew autoremove --dry-run)…"
        announce("Checking orphaned formulae.")
        let orphans = await scanAutoremove(brew: brew)

        scanStatus = "Checking for stale casks…"
        announce("Checking for stale casks.")
        let stale = await scanStaleCasks(brew: brew)

        candidates = cleanup.items + orphans + stale
        freeableBytes = cleanup.totalBytes
        state = .ready
        scanStatus = ""
        let summary: String
        if candidates.isEmpty {
            summary = "Nothing to clean up."
        } else {
            summary = "\(candidates.count) maintenance item\(candidates.count == 1 ? "" : "s") found."
        }
        announce(summary)
    }

    /// Parse `brew cleanup --dry-run` output.
    /// Returns the list of removable items and the total freeable bytes.
    private func scanCleanup(brew: String) async -> (items: [CleanupCandidate], totalBytes: Int64) {
        let (_, out) = await CommandRunner.runOnce(executable: brew,
                                                   args: ["cleanup", "--dry-run"])
        var items: [CleanupCandidate] = []
        var total: Int64 = 0

        // brew cleanup --dry-run prints lines like:
        //   Would remove: /opt/homebrew/Cellar/yt-dlp/2026.3.17_1 (4.5MB)
        //   Would remove: /opt/homebrew/Caskroom/google-chrome/147.0.7727.102 (217.5MB)
        //   ==> This operation would free approximately 1.2GB of disk space.

        for raw in out.split(separator: "\n") {
            let line = String(raw)
            if let removed = parseCleanupLine(line) {
                items.append(removed)
            } else if line.contains("would free approximately") {
                if let bytes = parseFreedBytes(line) {
                    total = bytes
                }
            }
        }
        return (items, total)
    }

    private func parseCleanupLine(_ line: String) -> CleanupCandidate? {
        let prefixes = ["Would remove:", "Removing:"]
        guard let prefix = prefixes.first(where: { line.contains($0) }) else { return nil }
        guard let range = line.range(of: prefix) else { return nil }

        let rest = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
        // rest looks like "/opt/.../foo/1.2.3 (4.5MB)" or "/opt/.../foo/1.2.3"
        var path = rest
        var detail = ""
        if let openParen = rest.lastIndex(of: "("),
           let closeParen = rest.lastIndex(of: ")"),
           openParen < closeParen {
            path = String(rest[..<openParen]).trimmingCharacters(in: .whitespaces)
            detail = String(rest[rest.index(after: openParen)..<closeParen])
        }
        let name = (path as NSString).lastPathComponent
        let parent = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
        let display = parent.isEmpty ? name : "\(parent) \(name)"
        return CleanupCandidate(
            kind: .oldVersion,
            name: display,
            detail: detail.isEmpty ? path : "\(detail) — \(path)"
        )
    }

    /// Parse "approximately 1.2GB" into raw bytes.
    private func parseFreedBytes(_ line: String) -> Int64? {
        // Capture last number+unit before "of disk space"
        let lower = line.lowercased()
        let units: [(String, Double)] = [
            ("kb", 1_024),
            ("mb", 1_048_576),
            ("gb", 1_073_741_824),
            ("tb", 1_099_511_627_776),
            ("b",  1)
        ]
        // very forgiving: scan for "<number><unit>"
        for (unit, factor) in units {
            if let unitRange = lower.range(of: unit, options: .backwards) {
                // walk back to grab the digits/decimal
                var idx = unitRange.lowerBound
                while idx > lower.startIndex {
                    let prev = lower.index(before: idx)
                    let ch = lower[prev]
                    if ch.isNumber || ch == "." || ch == "," {
                        idx = prev
                    } else {
                        break
                    }
                }
                let numStr = String(lower[idx..<unitRange.lowerBound])
                    .replacingOccurrences(of: ",", with: "")
                if let value = Double(numStr.trimmingCharacters(in: .whitespaces)) {
                    return Int64(value * factor)
                }
            }
        }
        return nil
    }

    private func scanAutoremove(brew: String) async -> [CleanupCandidate] {
        let (_, out) = await CommandRunner.runOnce(executable: brew,
                                                   args: ["autoremove", "--dry-run"])
        // brew autoremove --dry-run output formats vary across versions. Two
        // shapes we handle:
        //
        //   Would autoremove:
        //   glib gnupg libusb
        //
        //   ==> Would autoremove 3 unneeded formulae:
        //   glib
        //   gnupg
        //   libusb
        //
        var names: [String] = []
        var inAutoremoveBlock = false
        for raw in out.split(separator: "\n") {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.contains("autoremove") {
                inAutoremoveBlock = true
                // Same-line form ("Would autoremove: a b c")
                if let colon = line.range(of: ":") {
                    let rest = String(line[colon.upperBound...]).trimmingCharacters(in: .whitespaces)
                    if !rest.isEmpty {
                        names.append(contentsOf: rest.split(separator: " ").map { String($0) })
                    }
                }
                continue
            }
            if inAutoremoveBlock {
                if line.hasPrefix("==>") { continue }
                // single-name-per-line form
                names.append(contentsOf: line.split(separator: " ").map { String($0) })
            }
        }
        return names.compactMap { n in
            let trimmed = n.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            return CleanupCandidate(
                kind: .orphanedFormula,
                name: trimmed,
                detail: "unused dependency"
            )
        }
    }

    /// Stale casks: installed casks whose .app artifact is no longer at the
    /// expected place. Uses `brew info --json=v2 --installed --cask` once,
    /// then file-system-checks each artifact.
    private func scanStaleCasks(brew: String) async -> [CleanupCandidate] {
        let (_, out) = await CommandRunner.runOnce(
            executable: brew,
            args: ["info", "--json=v2", "--installed", "--cask"]
        )
        guard let data = out.data(using: .utf8) else { return [] }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        guard let casks = root["casks"] as? [[String: Any]] else { return [] }

        var stale: [CleanupCandidate] = []
        for cask in casks {
            guard let token = cask["token"] as? String else { continue }
            let artifacts = cask["artifacts"] as? [Any] ?? []
            let appNames = appArtifactNames(artifacts: artifacts)
            guard !appNames.isEmpty else { continue }

            let anyExists = appNames.contains { name in
                let paths = [
                    "/Applications/\(name)",
                    "\(NSHomeDirectory())/Applications/\(name)"
                ]
                return paths.contains { FileManager.default.fileExists(atPath: $0) }
            }
            if !anyExists {
                stale.append(CleanupCandidate(
                    kind: .staleCask,
                    name: token,
                    detail: "expected app missing: \(appNames.joined(separator: ", "))"
                ))
            }
        }
        return stale
    }

    /// Pull .app filenames out of the loose JSON artifacts blob.
    /// Each artifact group is itself an array; entries are either strings or
    /// dicts like {"app": ["Foo.app"]}.
    private func appArtifactNames(artifacts: [Any]) -> [String] {
        var out: [String] = []
        for group in artifacts {
            // A group can be either an array of entries (typical) or a dict.
            let entries: [Any]
            if let arr = group as? [Any] {
                entries = arr
            } else {
                entries = [group]
            }
            for entry in entries {
                if let dict = entry as? [String: Any], let appList = dict["app"] as? [Any] {
                    for a in appList {
                        if let s = a as? String, s.hasSuffix(".app") {
                            out.append(s)
                        }
                    }
                } else if let s = entry as? String, s.hasSuffix(".app") {
                    out.append(s)
                }
            }
        }
        return out
    }

    // MARK: Act

    func performSelected() async {
        let selected = candidates.filter { $0.isSelected }
        guard !selected.isEmpty else { return }
        guard let brew = CommandRunner.brewPath else { return }

        state = .acting
        sheetVisible = true
        actionLog = ""
        announce("Starting cleanup.")

        // Group by kind so we can do each in one brew call where possible.
        let oldVersions = selected.filter { $0.kind == .oldVersion }
        let orphans     = selected.filter { $0.kind == .orphanedFormula }
        let staleCasks  = selected.filter { $0.kind == .staleCask }

        var removed = 0
        var freed: Int64 = 0

        if !oldVersions.isEmpty {
            appendLog("\n==> brew cleanup\n")
            let ok = await stream(brew: brew, args: ["cleanup"])
            if ok {
                removed += oldVersions.count
                freed += freeableBytes
            }
        }

        // brew autoremove for orphaned formulae (always operates as a group)
        if !orphans.isEmpty {
            appendLog("\n==> brew autoremove\n")
            let ok = await stream(brew: brew, args: ["autoremove"])
            if ok { removed += orphans.count }
        }

        // Stale cask uninstalls may need sudo (kexts, system extensions).
        if !staleCasks.isEmpty {
            let sudoEnv = await Sudo.setupAskpass()
            for c in staleCasks {
                appendLog("\n==> brew uninstall --cask --force \(c.name)\n")
                let ok = await stream(brew: brew,
                                      args: ["uninstall", "--cask", "--force", c.name],
                                      extra: sudoEnv ?? [:])
                if ok { removed += 1 }
            }
            Sudo.cleanup()
        }

        state = .done(removedCount: removed, freedBytes: freed)
        appendLog("\n==> Cleanup complete: \(removed) item\(removed == 1 ? "" : "s") removed.\n")
        announce("Cleanup complete. \(removed) item\(removed == 1 ? "" : "s") removed.")
    }

    private func stream(brew: String, args: [String], extra: [String: String] = [:]) async -> Bool {
        await stream(executable: brew, args: args, extra: extra)
    }

    private func stream(executable: String, args: [String], extra: [String: String] = [:]) async -> Bool {
        await CommandRunner.stream(
            executable: executable,
            args: args,
            extraEnv: extra,
            onLine: { [weak self] line in
                Task { @MainActor in self?.appendLog(line + "\n") }
            },
            processStarted: { [weak self] proc in
                self?.runningProcess = proc
            }
        )
    }

    private func appendLog(_ s: String) {
        actionLog += s
        if actionLog.count > 200_000 {
            actionLog = String(actionLog.suffix(150_000))
        }
    }

    private func announce(_ text: String) {
        guard let win = NSApp.mainWindow ?? NSApp.windows.first else { return }
        NSAccessibility.post(
            element: win,
            notification: .announcementRequested,
            userInfo: [
                .announcement: text,
                .priority: NSAccessibilityPriorityLevel.high.rawValue
            ]
        )
    }

    // MARK: Formatting

    static func formatBytes(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        let mb = Double(bytes) / 1_048_576
        if gb >= 1.0 { return String(format: "%.2f GB", gb) }
        if mb >= 1.0 { return String(format: "%.0f MB", mb) }
        if bytes > 0 { return "< 1 MB" }
        return "—"
    }
}
