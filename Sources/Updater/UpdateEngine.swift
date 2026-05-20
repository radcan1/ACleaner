import Foundation
import AppKit

// MARK: - Models

enum UpdateKind: String, Codable {
    case formula
    case cask
    case mas

    var displayLabel: String {
        switch self {
        case .formula: return "Formula"
        case .cask:    return "Cask"
        case .mas:     return "App Store"
        }
    }
}

struct OutdatedItem: Identifiable, Equatable {
    let id = UUID()
    let kind: UpdateKind
    let name: String
    let currentVersion: String
    let newVersion: String
    let masId: String?     // mas only
    var isSelected: Bool = true
    var sizeBytes: Int64? = nil   // best-effort, fetched asynchronously after scan

    var versionString: String { "\(currentVersion) → \(newVersion)" }
}

enum EngineState: Equatable {
    case idle
    case checking
    case ready
    case upgrading
    case done(succeeded: Int, failed: Int)
}

// MARK: - Engine

@MainActor
final class UpdateEngine: ObservableObject {
    @Published var state: EngineState = .idle
    @Published var items: [OutdatedItem] = []           // visible items (skip-filtered)
    @Published var hiddenSkippedCount: Int = 0          // outdated items that were filtered out
    @Published var checkStatus: String = ""

    // Options
    @Published var includeMas: Bool = true
    @Published var includeGreedy: Bool = true

    // Upgrade progress
    @Published var upgradeLog: String = ""
    @Published var currentUpgradeName: String = ""
    @Published var upgradeIndex: Int = 0
    @Published var upgradeTotal: Int = 0
    @Published var failedItems: [String] = []
    @Published var sheetVisible: Bool = false

    private let skipList: SkipList
    private var runningProcess: Process?
    private var cancelled = false

    init(skipList: SkipList) {
        self.skipList = skipList
    }

    var brewIsAvailable: Bool { CommandRunner.brewPath != nil }
    var masIsAvailable:  Bool { CommandRunner.masPath  != nil }

    // MARK: Check for updates

    func checkForUpdates() async {
        guard let brew = CommandRunner.brewPath else {
            state = .idle
            checkStatus = "Homebrew not found at /opt/homebrew/bin or /usr/local/bin."
            return
        }

        state = .checking
        items = []
        hiddenSkippedCount = 0
        failedItems = []

        checkStatus = "Updating Homebrew catalog…"
        announce("Updating Homebrew catalog.")
        _ = await CommandRunner.runOnce(executable: brew, args: ["update"])

        checkStatus = "Checking outdated brews…"
        let brewOutdated = await readBrewOutdated(brew: brew, greedy: includeGreedy)

        var collected = brewOutdated

        if includeMas, let mas = CommandRunner.masPath {
            checkStatus = "Checking App Store updates…"
            let masOutdated = await readMasOutdated(mas: mas)
            collected += masOutdated
        }

        // Apply skip list.
        let visible = collected.filter { !skipList.contains(kind: $0.kind, name: $0.name) }
        hiddenSkippedCount = collected.count - visible.count

        items = visible
        state = .ready
        checkStatus = ""
        let skippedSuffix = hiddenSkippedCount > 0 ? " (\(hiddenSkippedCount) skipped)" : ""
        announce(visible.isEmpty
            ? "No updates available\(skippedSuffix)."
            : "\(visible.count) update\(visible.count == 1 ? "" : "s") available\(skippedSuffix).")

        // Best-effort: resolve download sizes in the background. As each
        // size arrives we update the corresponding item in-place; SwiftUI
        // re-renders the row. Failures are silent — the row just shows "—".
        Task { [weak self] in await self?.fetchSizes() }
    }

    private func fetchSizes() async {
        // Snapshot ids so out-of-order completions still find the right item
        // even if a fresh checkForUpdates rebuilds `items`.
        let snapshot = items.map { (id: $0.id, item: $0) }
        await withTaskGroup(of: (UUID, Int64?).self) { group in
            for entry in snapshot {
                group.addTask { (entry.id, await SizeFetcher.size(for: entry.item)) }
            }
            for await (id, size) in group {
                if let i = items.firstIndex(where: { $0.id == id }) {
                    items[i].sizeBytes = size
                }
            }
        }
    }

    /// Re-apply the skip list to the already-collected items (no network).
    func reapplySkipFilter() async {
        // Nothing to do if we have not checked yet.
        guard !items.isEmpty || hiddenSkippedCount > 0 else { return }
        // We do not keep the unfiltered list around, so a re-check is the
        // safest way to refresh. Cheap because HOMEBREW_NO_AUTO_UPDATE is set.
        await checkForUpdates()
    }

    // MARK: Upgrade selected

    func upgradeSelected() async {
        guard let brew = CommandRunner.brewPath else { return }
        let selected = items.filter { $0.isSelected }
        guard !selected.isEmpty else { return }

        cancelled = false
        state = .upgrading
        sheetVisible = true
        upgradeLog = ""
        upgradeTotal = selected.count
        upgradeIndex = 0
        failedItems = []

        // Sudo askpass — needed for casks that ship pkg installers. (MAS apps
        // use a different admin path via osascript; see upgradeOne below.)
        let needsSudo = selected.contains { $0.kind == .cask }
        var sudoEnv: [String: String]? = nil
        if needsSudo {
            sudoEnv = await Sudo.setupAskpass()
            if sudoEnv == nil {
                appendLog("(no sudo password — pkg-based casks will fail and be skipped)\n")
            }
        }

        var succeeded = 0
        var failed = 0

        for item in selected {
            if cancelled {
                appendLog("\n(cancelled)\n")
                break
            }
            upgradeIndex += 1
            currentUpgradeName = item.name
            let header = "\n==> [\(upgradeIndex)/\(upgradeTotal)] Upgrading \(item.kind.displayLabel.lowercased()): \(item.name)\n"
            appendLog(header)
            announce("Upgrading \(item.name), \(upgradeIndex) of \(upgradeTotal).")

            let ok = await upgradeOne(item: item, brew: brew, env: sudoEnv)
            if ok {
                succeeded += 1
            } else {
                failed += 1
                failedItems.append(item.name)
                appendLog("(\(item.name) failed)\n")
            }
        }

        Sudo.cleanup()
        currentUpgradeName = ""
        state = .done(succeeded: succeeded, failed: failed)

        let summary: String
        if cancelled {
            summary = "Update cancelled."
        } else if failed == 0 {
            summary = "All \(succeeded) update\(succeeded == 1 ? "" : "s") complete."
        } else {
            summary = "\(succeeded) succeeded, \(failed) failed."
        }
        appendLog("\n==> \(summary)\n")
        announce(summary)
    }

    func cancelUpgrade() {
        cancelled = true
        if let p = runningProcess, p.isRunning {
            p.terminate()
        }
    }

    // MARK: Subprocess wrappers

    private func upgradeOne(item: OutdatedItem, brew: String, env: [String: String]?) async -> Bool {
        let extra = env ?? [:]
        switch item.kind {
        case .formula:
            return await streamWithCapture(executable: brew, args: ["upgrade", item.name], extra: extra)
        case .cask:
            var args = ["upgrade", "--cask"]
            if includeGreedy { args.append("--greedy") }
            args.append(item.name)
            return await streamWithCapture(executable: brew, args: args, extra: extra)
        case .mas:
            guard let mas = CommandRunner.masPath, let id = item.masId else { return false }
            // mas upgrades for some App Store apps fail with the no-tty sudo
            // problem because mas's internal sudo call cannot read
            // SUDO_ASKPASS. Run the whole mas invocation with admin rights
            // via the native authorization dialog instead. The dialog appears
            // once per batch (macOS caches the rights for ~5 minutes).
            return await CommandRunner.streamAsAdmin(
                executable: mas,
                args: ["upgrade", id],
                prompt: "Mac Updater is installing the App Store update for \(item.name).",
                onLine: { [weak self] line in
                    Task { @MainActor in self?.appendLog(line + "\n") }
                }
            )
        }
    }

    private func streamWithCapture(executable: String,
                                   args: [String],
                                   extra: [String: String]) async -> Bool {
        await CommandRunner.stream(
            executable: executable,
            args: args,
            extraEnv: extra,
            onLine: { [weak self] line in
                guard let self else { return }
                Task { @MainActor in self.appendLog(line + "\n") }
            },
            processStarted: { [weak self] proc in
                self?.runningProcess = proc
            }
        )
    }

    // MARK: Parsers

    private func readBrewOutdated(brew: String, greedy: Bool) async -> [OutdatedItem] {
        var args = ["outdated", "--json=v2"]
        if greedy { args.append("--greedy") }
        let (_, out) = await CommandRunner.runOnce(executable: brew, args: args)
        guard let data = out.data(using: .utf8) else { return [] }

        struct OutdatedJSON: Decodable {
            struct Formula: Decodable {
                let name: String
                let installed_versions: [String]?
                let current_version: String?
            }
            struct Cask: Decodable {
                let name: String
                let installed_versions: String?
                let current_version: String?
            }
            let formulae: [Formula]
            let casks: [Cask]
        }

        guard let parsed = try? JSONDecoder().decode(OutdatedJSON.self, from: data) else {
            return []
        }

        var out_items: [OutdatedItem] = []
        for f in parsed.formulae {
            out_items.append(OutdatedItem(
                kind: .formula,
                name: f.name,
                currentVersion: f.installed_versions?.last ?? "?",
                newVersion: f.current_version ?? "?",
                masId: nil
            ))
        }
        for c in parsed.casks {
            out_items.append(OutdatedItem(
                kind: .cask,
                name: c.name,
                currentVersion: c.installed_versions ?? "?",
                newVersion: c.current_version ?? "?",
                masId: nil
            ))
        }
        return out_items
    }

    private func readMasOutdated(mas: String) async -> [OutdatedItem] {
        let (_, out) = await CommandRunner.runOnce(executable: mas, args: ["outdated"])
        var items: [OutdatedItem] = []
        out.split(separator: "\n").forEach { line in
            let trimmed = String(line).trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return }

            let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2, let _ = Int(parts[0]) else { return }
            let id = String(parts[0])
            let rest = String(parts[1])

            var name = rest
            var current = "?"
            var newVer = "?"
            if let openParen = rest.lastIndex(of: "("),
               let closeParen = rest.lastIndex(of: ")"),
               openParen < closeParen {
                name = String(rest[..<openParen]).trimmingCharacters(in: .whitespaces)
                let inside = String(rest[rest.index(after: openParen)..<closeParen])
                let arrow = inside.split(separator: "-", maxSplits: 1)
                    .map { $0.replacingOccurrences(of: ">", with: "").trimmingCharacters(in: .whitespaces) }
                if arrow.count == 2 {
                    current = arrow[0]
                    newVer = arrow[1]
                }
            }
            items.append(OutdatedItem(
                kind: .mas,
                name: name,
                currentVersion: current,
                newVersion: newVer,
                masId: id
            ))
        }
        return items
    }

    // MARK: Log + accessibility

    func appendLog(_ s: String) {
        upgradeLog += s
        if upgradeLog.count > 200_000 {
            upgradeLog = String(upgradeLog.suffix(150_000))
        }
    }

    func announce(_ text: String) {
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
}
