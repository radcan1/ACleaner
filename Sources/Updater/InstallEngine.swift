import Foundation
import AppKit

// MARK: - Models

struct SearchResult: Identifiable, Equatable {
    let id = UUID()
    let kind: UpdateKind
    let name: String
    let masId: String?
    let isInstalled: Bool
}

enum InstallState: Equatable {
    case idle
    case searching
    case ready
    case installing(String)
    case done(success: Bool)
}

// MARK: - Engine

@MainActor
final class InstallEngine: ObservableObject {
    @Published var state: InstallState = .idle
    @Published var query: String = ""
    @Published var results: [SearchResult] = []
    @Published var searchMessage: String = ""

    // Install progress
    @Published var installLog: String = ""
    @Published var currentInstallName: String = ""
    @Published var sheetVisible: Bool = false

    // Search options
    @Published var includeCasks: Bool = true
    @Published var includeFormulae: Bool = true
    @Published var includeMas: Bool = true

    private var installedCasks: Set<String> = []
    private var installedFormulae: Set<String> = []
    private var installedMasIds: Set<String> = []

    // MARK: Search

    func search() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else {
            results = []
            searchMessage = ""
            state = .idle
            return
        }
        guard let brew = CommandRunner.brewPath else {
            searchMessage = "Homebrew not found."
            return
        }

        state = .searching
        results = []
        searchMessage = "Searching…"

        await refreshInstalledSets(brew: brew)

        var collected: [SearchResult] = []

        if includeCasks {
            collected += await searchBrew(brew: brew, flag: "--casks", kind: .cask, query: q)
        }
        if includeFormulae {
            collected += await searchBrew(brew: brew, flag: "--formula", kind: .formula, query: q)
        }
        if includeMas, let mas = CommandRunner.masPath {
            collected += await searchMas(mas: mas, query: q)
        }

        results = collected
        state = .ready
        searchMessage = collected.isEmpty
            ? "No results for '\(q)'."
            : "\(collected.count) result\(collected.count == 1 ? "" : "s") for '\(q)'."
        announce(searchMessage)
    }

    private func searchBrew(brew: String,
                            flag: String,
                            kind: UpdateKind,
                            query: String) async -> [SearchResult] {
        // brew search has surprisingly strict regex/substring match. Use brew
        // search first; if empty, fall back to a subsequence scan against the
        // full catalog.
        let (_, out, _) = await CommandRunner.runOnce(executable: brew, args: ["search", flag, query])
        var names = out
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("==>") }

        if names.isEmpty {
            names = await fuzzyCatalogSearch(brew: brew,
                                             catalog: kind == .cask ? "casks" : "formulae",
                                             query: query)
        }

        let installedSet = (kind == .cask) ? installedCasks : installedFormulae
        return names.map { name in
            SearchResult(
                kind: kind,
                name: name,
                masId: nil,
                isInstalled: installedSet.contains(name)
            )
        }
    }

    /// Subsequence match against `brew casks` / `brew formulae` for typo fuzz.
    /// Returns up to 25 shortest matches.
    private func fuzzyCatalogSearch(brew: String, catalog: String, query: String) async -> [String] {
        let normQ = normalize(query)
        guard !normQ.isEmpty else { return [] }

        let (_, out, _) = await CommandRunner.runOnce(executable: brew, args: [catalog])
        let candidates = out.split(separator: "\n").map { String($0) }

        var hits: [(Int, String)] = []
        for name in candidates {
            let norm = normalize(name)
            if isSubsequence(normQ, norm) {
                hits.append((name.count, name))
            }
        }
        return hits
            .sorted(by: { $0.0 < $1.0 })
            .prefix(25)
            .map { $0.1 }
    }

    private func searchMas(mas: String, query: String) async -> [SearchResult] {
        let (_, out, _) = await CommandRunner.runOnce(executable: mas, args: ["search", query])
        var results: [SearchResult] = []
        for line in out.split(separator: "\n") {
            // Lines look like:    "1435957248  Drafts  (52.0.1)"
            // (or with leading whitespace).
            let trimmed = String(line).trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2, let _ = Int(parts[0]) else { continue }
            let id = String(parts[0])
            var name = String(parts[1])
            // strip trailing (version)
            if let openParen = name.lastIndex(of: "("),
               let closeParen = name.lastIndex(of: ")"),
               openParen < closeParen {
                name = String(name[..<openParen]).trimmingCharacters(in: .whitespaces)
            }
            results.append(SearchResult(
                kind: .mas,
                name: name,
                masId: id,
                isInstalled: installedMasIds.contains(id)
            ))
        }
        return results
    }

    private func refreshInstalledSets(brew: String) async {
        let (_, casks, _) = await CommandRunner.runOnce(executable: brew, args: ["list", "--cask"])
        installedCasks = Set(casks.split(separator: "\n").map { String($0) })

        let (_, formulae, _) = await CommandRunner.runOnce(executable: brew, args: ["list", "--formula"])
        installedFormulae = Set(formulae.split(separator: "\n").map { String($0) })

        if let mas = CommandRunner.masPath {
            let (_, listed, _) = await CommandRunner.runOnce(executable: mas, args: ["list"])
            installedMasIds = Set(listed.split(separator: "\n").compactMap { line in
                String(line).trimmingCharacters(in: .whitespaces)
                    .split(separator: " ").first.map(String.init)
            })
        }
    }

    // MARK: Install

    func install(_ result: SearchResult) async {
        sheetVisible = true
        state = .installing(result.name)
        currentInstallName = result.name
        installLog = ""
        appendLog("==> Installing \(result.kind.displayLabel.lowercased()): \(result.name)\n")
        announce("Installing \(result.name).")

        // Casks may use pkg installers and need sudo via SUDO_ASKPASS. MAS
        // installs go through a different admin path (osascript-backed),
        // since mas's internal sudo cannot read SUDO_ASKPASS.
        var env: [String: String]? = nil
        if result.kind == .cask {
            env = await Sudo.setupAskpass()
            if env == nil {
                appendLog("(no sudo password — if this cask uses a pkg installer it will fail)\n")
            }
        }

        let ok: Bool
        switch result.kind {
        case .cask:
            guard let brew = CommandRunner.brewPath else { state = .done(success: false); return }
            ok = await stream(executable: brew, args: ["install", "--cask", result.name], extra: env ?? [:])
        case .formula:
            guard let brew = CommandRunner.brewPath else { state = .done(success: false); return }
            ok = await stream(executable: brew, args: ["install", result.name], extra: env ?? [:])
        case .mas:
            guard let mas = CommandRunner.masPath, let id = result.masId else {
                state = .done(success: false)
                return
            }
            ok = await CommandRunner.streamAsAdmin(
                executable: mas,
                args: ["install", id],
                prompt: "Mac Updater is installing the App Store app \(result.name).",
                onLine: { [weak self] line in
                    Task { @MainActor in self?.appendLog(line + "\n") }
                }
            )
        }

        Sudo.cleanup()
        currentInstallName = ""
        state = .done(success: ok)
        let msg = ok ? "Installed \(result.name)." : "\(result.name) failed to install."
        appendLog("\n==> \(msg)\n")
        announce(msg)
    }

    private func stream(executable: String,
                        args: [String],
                        extra: [String: String]) async -> Bool {
        await CommandRunner.stream(
            executable: executable,
            args: args,
            extraEnv: extra,
            onLine: { [weak self] line in
                Task { @MainActor in self?.appendLog(line + "\n") }
            }
        )
    }

    // MARK: Helpers

    private func appendLog(_ s: String) {
        installLog += s
        if installLog.count > 200_000 {
            installLog = String(installLog.suffix(150_000))
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

    private func normalize(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private func isSubsequence(_ pattern: String, _ str: String) -> Bool {
        var pi = pattern.startIndex
        var si = str.startIndex
        while pi < pattern.endIndex && si < str.endIndex {
            if pattern[pi] == str[si] {
                pi = pattern.index(after: pi)
            }
            si = str.index(after: si)
        }
        return pi == pattern.endIndex
    }
}
