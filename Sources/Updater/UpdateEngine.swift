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
    @Published var warningNote: String = ""             // non-fatal problems from the last check

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
        warningNote = ""
        var warnings: [String] = []

        checkStatus = "Updating Homebrew catalog…"
        announce("Updating Homebrew catalog.")
        let (updateStatus, _, _) = await CommandRunner.runOnce(
            executable: brew, args: ["update"], timeoutSeconds: 300)
        if updateStatus != 0 {
            // Stale catalog still yields useful results; warn, don't abort.
            warnings.append("Catalog refresh failed — results may be stale.")
        }

        checkStatus = "Checking outdated brews…"
        var collected: [OutdatedItem]
        switch await readBrewOutdated(brew: brew, greedy: includeGreedy) {
        case .success(let list):
            collected = list
        case .failure(let failure):
            // A failed check must never look like "everything is up to date".
            state = .idle
            checkStatus = "Update check failed: \(failure.message)"
            announce("Update check failed.")
            return
        }

        checkStatus = "Verifying installed versions…"
        let verified = await verifyCasksOnDisk(brew: brew, items: collected)
        collected = verified.items
        if !verified.removedApps.isEmpty {
            let n = verified.removedApps.count
            warnings.append("\(n) deleted app\(n == 1 ? "" : "s") ignored — clean up in Maintenance.")
        }

        if includeMas {
            if let mas = CommandRunner.masPath {
                checkStatus = "Checking App Store updates…"
                switch await readMasOutdated(mas: mas) {
                case .success(let list):
                    collected += list
                case .failure:
                    warnings.append("App Store check failed.")
                }
            } else {
                warnings.append("mas not installed — App Store apps not checked.")
            }
        }

        // Apply skip list.
        let visible = collected.filter { !skipList.contains(kind: $0.kind, name: $0.name) }
        hiddenSkippedCount = collected.count - visible.count

        items = visible
        state = .ready
        checkStatus = ""
        warningNote = warnings.joined(separator: " ")
        let skippedSuffix = hiddenSkippedCount > 0 ? " (\(hiddenSkippedCount) skipped)" : ""
        let warningSuffix = warnings.isEmpty ? "" : " Warning: \(warningNote)"
        announce((visible.isEmpty
            ? "No updates available\(skippedSuffix)."
            : "\(visible.count) update\(visible.count == 1 ? "" : "s") available\(skippedSuffix).")
            + warningSuffix)

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

    struct CheckFailure: Error {
        let message: String
    }

    /// Last few stderr lines, flattened for a one-line status message.
    private func errTail(_ err: String, lines: Int = 3) -> String {
        let all = err.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        return all.suffix(lines).joined(separator: " ")
    }

    private func readBrewOutdated(brew: String, greedy: Bool) async -> Result<[OutdatedItem], CheckFailure> {
        var args = ["outdated", "--json=v2"]
        if greedy { args.append("--greedy") }
        let (status, out, err) = await CommandRunner.runOnce(
            executable: brew, args: args, timeoutSeconds: 120)
        guard status == 0 else {
            let detail = errTail(err)
            return .failure(CheckFailure(message: detail.isEmpty
                ? "brew outdated exited with status \(status)."
                : detail))
        }
        guard let data = out.data(using: .utf8) else {
            return .failure(CheckFailure(message: "brew produced unreadable output."))
        }

        struct OutdatedJSON: Decodable {
            // brew has shipped installed_versions as both a bare string
            // (casks, pre-6.x) and an array (6.x unified both kinds). Accept
            // either so the next Homebrew schema tweak cannot silently break
            // update detection again.
            struct VersionList: Decodable {
                let versions: [String]
                init(from decoder: Decoder) throws {
                    let c = try decoder.singleValueContainer()
                    if let arr = try? c.decode([String].self) {
                        versions = arr
                    } else if let s = try? c.decode(String.self) {
                        versions = [s]
                    } else {
                        versions = []
                    }
                }
            }
            struct Entry: Decodable {
                let name: String
                let installed_versions: VersionList?
                let current_version: String?
                let pinned: Bool?
            }
            let formulae: [Entry]
            let casks: [Entry]
        }

        let parsed: OutdatedJSON
        do {
            parsed = try JSONDecoder().decode(OutdatedJSON.self, from: data)
        } catch {
            return .failure(CheckFailure(message: "could not parse brew's JSON output."))
        }

        var out_items: [OutdatedItem] = []
        for (kind, entries) in [(UpdateKind.formula, parsed.formulae), (.cask, parsed.casks)] {
            for e in entries {
                // Pinned entries are excluded: brew upgrade refuses to touch
                // them, so listing them would only produce failed rows.
                if e.pinned == true { continue }
                out_items.append(OutdatedItem(
                    kind: kind,
                    name: e.name,
                    currentVersion: e.installed_versions?.versions.last ?? "?",
                    newVersion: e.current_version ?? "?",
                    masId: nil
                ))
            }
        }
        return .success(out_items)
    }

    /// brew compares against its own install receipt, which goes stale for
    /// casks that update themselves (auto_updates apps like browsers). Check
    /// the app bundle actually on disk: rows already at the catalog version
    /// are dropped, and stale "current version" labels are corrected.
    ///
    /// Casks that declare an .app artifact which is missing from disk are
    /// apps the user has deleted outside brew — the receipt survives in the
    /// Caskroom, so brew keeps offering "updates" that would actually
    /// reinstall the app. Those are excluded and counted in `removedAppsSkipped`
    /// so the exclusion stays visible.
    private func verifyCasksOnDisk(brew: String,
                                   items: [OutdatedItem]) async -> (items: [OutdatedItem], removedApps: [String]) {
        let caskNames = items.filter { $0.kind == .cask }.map { $0.name }
        guard !caskNames.isEmpty else { return (items, []) }

        let (status, out, _) = await CommandRunner.runOnce(
            executable: brew,
            args: ["info", "--cask", "--json=v2"] + caskNames,
            timeoutSeconds: 120)
        // Verification is an accuracy refinement; if it fails, keep brew's view.
        guard status == 0, let data = out.data(using: .utf8) else { return (items, []) }

        struct InfoJSON: Decodable {
            struct Cask: Decodable {
                let token: String
                let artifacts: [Artifact]?
            }
            // The artifacts array mixes shapes (strings, dicts of several
            // kinds); tolerate anything that is not an {app: [names]} entry.
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
        guard let parsed = try? JSONDecoder().decode(InfoJSON.self, from: data) else { return (items, []) }

        var appNameByCask: [String: String] = [:]
        for cask in parsed.casks {
            if let appName = cask.artifacts?.compactMap({ $0.app }).flatMap({ $0 }).first {
                appNameByCask[cask.token] = appName
            }
        }

        func appBundlePath(appName: String) -> String? {
            for dir in ["/Applications", NSHomeDirectory() + "/Applications"] {
                let path = "\(dir)/\(appName)"
                if FileManager.default.fileExists(atPath: path) { return path }
            }
            return nil
        }

        func diskVersion(appPath: String) -> String? {
            let plist = "\(appPath)/Contents/Info.plist"
            guard let d = NSDictionary(contentsOfFile: plist) else { return nil }
            return d["CFBundleShortVersionString"] as? String
        }

        // Cask versions may carry a build suffix ("1.2.3,4567"); the app's
        // CFBundleShortVersionString only ever holds the marketing part.
        func marketing(_ v: String) -> String {
            v.split(separator: ",").first.map(String.init) ?? v
        }

        var result: [OutdatedItem] = []
        var removedApps: [String] = []
        for item in items {
            // Non-casks, and pkg/CLI casks with no .app artifact: keep brew's view.
            guard item.kind == .cask, let appName = appNameByCask[item.name] else {
                result.append(item)
                continue
            }
            guard let appPath = appBundlePath(appName: appName) else {
                // Declared .app is gone from disk — the user deleted this app.
                // "Updating" it would reinstall it, so exclude it.
                removedApps.append(item.name)
                continue
            }
            guard let disk = diskVersion(appPath: appPath) else {
                result.append(item)   // present but unreadable: keep brew's view
                continue
            }
            if marketing(item.newVersion) == disk {
                continue  // app self-updated; only brew's receipt is behind
            }
            if marketing(item.currentVersion) != disk {
                result.append(OutdatedItem(
                    kind: .cask,
                    name: item.name,
                    currentVersion: disk,
                    newVersion: item.newVersion,
                    masId: nil
                ))
            } else {
                result.append(item)
            }
        }
        return (result, removedApps)
    }

    private func readMasOutdated(mas: String) async -> Result<[OutdatedItem], CheckFailure> {
        let (status, out, err) = await CommandRunner.runOnce(
            executable: mas, args: ["outdated"], timeoutSeconds: 60)
        guard status == 0 else {
            return .failure(CheckFailure(message: errTail(err)))
        }

        // Lines look like: "1435957248  Drafts  (53.0 -> 53.1)".
        // Anchor on the trailing "(x -> y)" so hyphenated versions and app
        // names containing parentheses parse correctly.
        let pattern = #"^\s*(\d+)\s+(.+?)\s+\((.+) -> (.+)\)\s*$"#
        guard let re = try? NSRegularExpression(pattern: pattern) else {
            return .success([])
        }

        var items: [OutdatedItem] = []
        for line in out.split(separator: "\n") {
            let s = String(line)
            let range = NSRange(s.startIndex..., in: s)
            guard let m = re.firstMatch(in: s, range: range),
                  let idR = Range(m.range(at: 1), in: s),
                  let nameR = Range(m.range(at: 2), in: s),
                  let curR = Range(m.range(at: 3), in: s),
                  let newR = Range(m.range(at: 4), in: s) else { continue }
            items.append(OutdatedItem(
                kind: .mas,
                name: String(s[nameR]).trimmingCharacters(in: .whitespaces),
                currentVersion: String(s[curR]),
                newVersion: String(s[newR]),
                masId: String(s[idR])
            ))
        }
        return .success(items)
    }

    // MARK: Log + accessibility

    func appendLog(_ s: String) {
        upgradeLog += s
        if upgradeLog.count > 200_000 {
            upgradeLog = String(upgradeLog.suffix(150_000))
        }
    }

    func announce(_ text: String) {
        Announcer.announce(text)
    }
}
