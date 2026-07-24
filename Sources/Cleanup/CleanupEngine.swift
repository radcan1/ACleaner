import Foundation
import AppKit

// One-click cleanup. Every category here passes one test: nobody could
// ever regret cleaning it, because everything regenerates automatically.
// Anything that needs a decision (LLM models, orphans, Time Machine
// snapshots, user data) lives in Disk Space instead, with review.

struct CleanupCategoryResult: Identifiable {
    let id = UUID()
    let title: String
    var detail: String          // "1.2 GB" or "14 files" or "—"
    var sizeBytes: Int64?       // nil until estimated / not size-based
}

@MainActor
final class CleanupEngine: ObservableObject {

    enum State: Equatable {
        case idle             // sizes may still be estimating
        case cleaning(String) // current category title
        case done
    }

    @Published var state: State = .idle
    @Published var categories: [CleanupCategoryResult] = []
    @Published var statusLine: String = ""
    @Published var lastFreedBytes: Int64 = 0
    @Published var lastNotes: [String] = []
    @Published var isEstimating = false

    private let home = FileManager.default.homeDirectoryForCurrentUser.path

    // MARK: - Category definitions

    private struct Category {
        let title: String
        let paths: [String]           // dirs whose CONTENTS are cleaned (size = du)
        let isBrewCleanup: Bool
        let isBrewAutoremove: Bool
        let isGhostReceipts: Bool
        let isDSStore: Bool

        init(title: String,
             paths: [String] = [],
             isBrewCleanup: Bool = false,
             isBrewAutoremove: Bool = false,
             isGhostReceipts: Bool = false,
             isDSStore: Bool = false) {
            self.title = title
            self.paths = paths
            self.isBrewCleanup = isBrewCleanup
            self.isBrewAutoremove = isBrewAutoremove
            self.isGhostReceipts = isGhostReceipts
            self.isDSStore = isDSStore
        }
    }

    private var definitions: [Category] {
        [
            Category(title: "Homebrew junk", isBrewCleanup: true),
            Category(title: "Unused dependencies", isBrewAutoremove: true),
            Category(title: "Records of deleted apps", isGhostReceipts: true),
            Category(title: "AI caches", paths: [
                "\(home)/Library/Application Support/Claude/Cache",
                "\(home)/Library/Application Support/Claude/Code Cache",
                "\(home)/Library/Application Support/Claude/GPUCache",
                "\(home)/Library/Application Support/Claude/DawnWebGPUCache",
                "\(home)/Library/Application Support/Claude/DawnGraphiteCache",
                "\(home)/Library/Application Support/Claude/vm_bundles/warm",
                "\(home)/.claude/cache",
                "\(home)/.claude/shell-snapshots",
            ]),
            Category(title: "App & browser caches", paths: [
                "\(home)/Library/Caches",
            ]),
            Category(title: "Logs", paths: [
                "\(home)/Library/Logs",
            ]),
            Category(title: "Developer caches", paths: [
                "\(home)/Library/Developer/Xcode/DerivedData",
                "\(home)/Library/Developer/Xcode/iOS DeviceSupport",
                "\(home)/Library/Developer/CoreSimulator/Caches",
            ]),
            Category(title: ".DS_Store litter", isDSStore: true),
        ]
    }

    // MARK: - Size estimation (runs on view appear, never blocks Clean Now)

    func estimate() async {
        guard !isEstimating else { return }
        isEstimating = true
        statusLine = "Measuring what can be cleaned…"

        categories = definitions.map {
            CleanupCategoryResult(title: $0.title, detail: "…", sizeBytes: nil)
        }

        for (index, def) in definitions.enumerated() {
            let (detail, bytes) = await estimateOne(def)
            if index < categories.count {
                categories[index].detail = detail
                categories[index].sizeBytes = bytes
            }
        }

        isEstimating = false
        let total = totalEstimatedBytes
        statusLine = total > 0
            ? "\(Self.formatBytes(total)) reclaimable."
            : "Estimates ready."
        Announcer.announce("Cleanup ready. \(Self.formatBytes(total)) reclaimable.", priority: .medium)
    }

    var totalEstimatedBytes: Int64 {
        categories.compactMap { $0.sizeBytes }.reduce(0, +)
    }

    private func estimateOne(_ def: Category) async -> (String, Int64?) {
        if def.isBrewCleanup {
            guard let brew = CommandRunner.brewPath else { return ("Homebrew not installed", 0) }
            let (_, out, _) = await CommandRunner.runOnce(
                executable: brew, args: ["cleanup", "--dry-run", "--prune=all"], timeoutSeconds: 120)
            let bytes = Self.parseApproxFreed(out) ?? 0
            return (bytes > 0 ? Self.formatBytes(bytes) : "nothing to clean", bytes)
        }
        if def.isBrewAutoremove {
            guard let brew = CommandRunner.brewPath else { return ("Homebrew not installed", 0) }
            let (_, out, _) = await CommandRunner.runOnce(
                executable: brew, args: ["autoremove", "--dry-run"], timeoutSeconds: 120)
            let count = Self.parseAutoremoveCount(out)
            return (count > 0 ? "\(count) formula\(count == 1 ? "" : "e")" : "none", nil)
        }
        if def.isGhostReceipts {
            let ghosts = await Self.findGhostCasks()
            return (ghosts.isEmpty ? "none" : "\(ghosts.count) record\(ghosts.count == 1 ? "" : "s")", nil)
        }
        if def.isDSStore {
            return ("counted at clean time", nil)
        }
        // Path-based: sum du -sk over existing paths.
        var total: Int64 = 0
        for path in def.paths where FileManager.default.fileExists(atPath: path) {
            let (_, out, _) = await CommandRunner.runOnce(
                executable: "/usr/bin/du", args: ["-sk", path], timeoutSeconds: 180)
            if let kb = Int64(out.split(separator: "\t").first?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "") {
                total += kb * 1024
            }
        }
        return (total > 0 ? Self.formatBytes(total) : "nothing to clean", total)
    }

    // MARK: - Clean everything

    func cleanAll() async {
        var freed: Int64 = 0
        var notes: [String] = []
        lastNotes = []

        Announcer.announce("Cleaning \(definitions.count) categories. This can take a few minutes.")

        for (index, def) in definitions.enumerated() {
            state = .cleaning(def.title)
            statusLine = "Cleaning \(def.title)…"

            if def.isBrewCleanup {
                if let brew = CommandRunner.brewPath {
                    let (_, out, _) = await CommandRunner.runOnce(
                        executable: brew, args: ["cleanup", "--prune=all"], timeoutSeconds: 600)
                    let bytes = Self.parseApproxFreed(out) ?? categories[safe: index]?.sizeBytes ?? 0
                    freed += bytes
                    notes.append("Homebrew junk: \(Self.formatBytes(bytes)) freed.")
                }
            } else if def.isBrewAutoremove {
                if let brew = CommandRunner.brewPath {
                    let (_, out, _) = await CommandRunner.runOnce(
                        executable: brew, args: ["autoremove"], timeoutSeconds: 600)
                    let count = Self.parseAutoremoveCount(out)
                    notes.append(count > 0
                        ? "Unused dependencies: removed \(count)."
                        : "Unused dependencies: none.")
                }
            } else if def.isGhostReceipts {
                let ghosts = await Self.findGhostCasks()
                var removed = 0
                for token in ghosts {
                    if await BrewReceipts.purgeReceipt(token: token) { removed += 1 }
                }
                notes.append(ghosts.isEmpty
                    ? "Deleted-app records: none."
                    : "Deleted-app records: cleared \(removed) of \(ghosts.count).")
            } else if def.isDSStore {
                let (_, out, _) = await CommandRunner.runOnce(
                    executable: "/usr/bin/find",
                    args: [home, "-x", "-name", ".DS_Store", "-type", "f", "-delete", "-print"],
                    timeoutSeconds: 600)
                let count = out.split(separator: "\n").count
                notes.append(".DS_Store: removed \(count).")
            } else {
                let bytes = categories[safe: index]?.sizeBytes ?? 0
                var failures = 0
                for path in def.paths {
                    failures += Self.removeContents(of: path)
                }
                freed += bytes
                notes.append("\(def.title): \(Self.formatBytes(bytes)) freed\(failures > 0 ? " (\(failures) items skipped — in use)" : "").")
            }
            Announcer.announce("\(def.title) done.", priority: .medium)
        }

        lastFreedBytes = freed
        lastNotes = notes
        state = .done
        statusLine = "Freed \(Self.formatBytes(freed))."
        NSSound(named: NSSound.Name("Glass"))?.play()
        Announcer.announce("Cleanup complete. Freed \(Self.formatBytes(freed)).")

        // Refresh estimates so the disclosure shows the new (near-zero) sizes.
        Task { await estimate() }
    }

    // MARK: - Helpers

    /// Deletes the CONTENTS of `path` (never the folder itself). Cache and
    /// log directories must keep existing so apps can write into them.
    /// Returns the number of children that could not be removed (files held
    /// open by running apps — normal, they get cleaned next time).
    private nonisolated static func removeContents(of path: String) -> Int {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(atPath: path) else {
            // A file (not a dir): remove it directly.
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue {
                return (try? fm.removeItem(atPath: path)) == nil ? 1 : 0
            }
            return 0
        }
        var failures = 0
        for child in children {
            do { try fm.removeItem(atPath: "\(path)/\(child)") } catch { failures += 1 }
        }
        return failures
    }

    /// Installed casks that declare an .app artifact which is missing from
    /// disk — brew receipts for apps the user deleted outside brew.
    private static func findGhostCasks() async -> [String] {
        guard let brew = CommandRunner.brewPath else { return [] }
        let (status, out, _) = await CommandRunner.runOnce(
            executable: brew, args: ["info", "--cask", "--json=v2", "--installed"],
            timeoutSeconds: 120)
        guard status == 0, let data = out.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let casks = root["casks"] as? [[String: Any]] else { return [] }

        let home = NSHomeDirectory()
        var ghosts: [String] = []
        for cask in casks {
            guard let token = cask["token"] as? String,
                  let artifacts = cask["artifacts"] as? [[String: Any]] else { continue }
            let appNames = artifacts.compactMap { ($0["app"] as? [Any])?.first as? String }
            guard let app = appNames.first else { continue }   // pkg/CLI casks: skip
            let exists = FileManager.default.fileExists(atPath: "/Applications/\(app)")
                || FileManager.default.fileExists(atPath: "\(home)/Applications/\(app)")
            if !exists { ghosts.append(token) }
        }
        return ghosts
    }

    /// "This operation would free approximately 1.2GB of disk space." → bytes
    nonisolated static func parseApproxFreed(_ out: String) -> Int64? {
        guard let line = out.split(separator: "\n")
            .first(where: { $0.localizedCaseInsensitiveContains("free") &&
                            $0.localizedCaseInsensitiveContains("approximately") }) else { return nil }
        let lower = line.lowercased()
        let units: [(String, Double)] = [("tb", 1_099_511_627_776), ("gb", 1_073_741_824),
                                         ("mb", 1_048_576), ("kb", 1_024), ("b", 1)]
        for (unit, factor) in units {
            guard let unitRange = lower.range(of: unit) else { continue }
            var idx = unitRange.lowerBound
            while idx > lower.startIndex {
                let prev = lower.index(before: idx)
                let ch = lower[prev]
                if ch.isNumber || ch == "." || ch == "," { idx = prev } else { break }
            }
            let numStr = lower[idx..<unitRange.lowerBound].replacingOccurrences(of: ",", with: "")
            if let value = Double(numStr) { return Int64(value * factor) }
        }
        return nil
    }

    /// Counts formulae named in `brew autoremove --dry-run` output.
    nonisolated static func parseAutoremoveCount(_ out: String) -> Int {
        var names: [String] = []
        var inBlock = false
        for raw in out.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.localizedCaseInsensitiveContains("autoremove") {
                inBlock = true
                if let colon = line.range(of: ":") {
                    names += line[colon.upperBound...].split(separator: " ").map(String.init)
                }
                continue
            }
            if inBlock, !line.hasPrefix("==>") {
                names += line.split(separator: " ").map(String.init)
            }
        }
        return names.filter { !$0.isEmpty }.count
    }

    nonisolated static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
