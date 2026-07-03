import Foundation

@MainActor
final class ClaudeCleanupScanner: ObservableObject {
    @Published var items: [ClaudeCleanupItem] = []
    @Published var isScanning = false

    var selectedBytes: Int64 {
        items.filter(\.isSelected).reduce(0) { $0 + $1.sizeBytes }
    }

    func scan() async {
        isScanning = true
        items = []
        Announcer.announce("Scanning Claude cleanup categories.", priority: .medium)

        let found = await Self.buildItems()

        items = found
        isScanning = false
        let totalBytes = found.reduce(Int64(0)) { $0 + $1.sizeBytes }
        let bytesLabel = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        Announcer.announce(
            found.isEmpty
                ? "Scan complete. Nothing to clean up."
                : "Scan complete. \(found.count) categor\(found.count == 1 ? "y" : "ies") found, \(bytesLabel).",
            priority: .high
        )
    }

    func toggleSelection(for item: ClaudeCleanupItem) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[idx].isSelected.toggle()
    }

    func clean() async -> (Int, [String]) {
        let toDelete = items.filter(\.isSelected).flatMap(\.paths)
        var trashed = 0
        var failed: [String] = []
        var pairs: [TrashedRecord] = []
        for url in toDelete {
            do {
                var resultURL: NSURL?
                try FileManager.default.trashItem(at: url, resultingItemURL: &resultURL)
                trashed += 1
                if let trashedPath = (resultURL as URL?)?.path {
                    pairs.append(TrashedRecord(originalPath: url.path, trashPath: trashedPath))
                }
            } catch {
                failed.append("\(url.path): \(error.localizedDescription)")
            }
        }
        CleanupJournal.shared.record(label: "Claude Cleanup", items: pairs)
        return (trashed, failed)
    }

    // MARK: - Background work

    private nonisolated static func buildItems() async -> [ClaudeCleanupItem] {
        struct Category {
            let title: String
            let explanation: String
            let warningNote: String?
            let paths: [URL]
            let isSelected: Bool
        }

        let categories: [Category] = [
            Category(
                title: "App Caches",
                explanation: "Temporary files Claude downloads and generates to load faster — similar to how a web browser caches pages. They are rebuilt automatically the next time Claude starts. Completely safe to delete at any time.",
                warningNote: nil,
                paths: existingURLs([
                    "~/Library/Application Support/Claude/Cache",
                    "~/Library/Application Support/Claude/Code Cache",
                    "~/Library/Application Support/Claude/GPUCache",
                    "~/Library/Application Support/Claude/DawnWebGPUCache",
                    "~/Library/Application Support/Claude/DawnGraphiteCache",
                ]),
                isSelected: true
            ),
            Category(
                title: "App Logs",
                explanation: "Records of what Claude did while running — useful for diagnosing crashes or unexpected behaviour. New logs are created automatically as you use Claude, so deleting old ones is always safe.",
                warningNote: nil,
                paths: existingURLs([
                    "~/Library/Logs/Claude",
                    "~/Library/Logs/claude-chat-done.log",
                ]),
                isSelected: true
            ),
            Category(
                title: "VM Warm Cache",
                explanation: "A pre-started virtual machine that Claude Code keeps in the background so your first command runs instantly. Deleting it just means the next Claude Code session takes a few extra seconds to start — it rebuilds itself automatically.",
                warningNote: nil,
                paths: existingURLs([
                    "~/Library/Application Support/Claude/vm_bundles/warm",
                ]),
                isSelected: true
            ),
            Category(
                title: "Agent & Cowork Sessions",
                explanation: "Saved state from Claude's agent tasks and cowork sessions — the files Claude used to pick up where it left off in long-running jobs. Once a task is finished you no longer need these. Deleting them does not affect Claude's ability to start new tasks.",
                warningNote: "If you have an active cowork session running right now, do not delete this — wait until the task finishes first.",
                paths: subdirectories(of: expand("~/Library/Application Support/Claude/local-agent-mode-sessions"))
                    .filter { $0.lastPathComponent != "skills-plugin" },
                isSelected: false
            ),
            Category(
                title: "Claude Code Project Transcripts",
                explanation: "Full conversation logs from every Claude Code session, stored per project. These let Claude Code remember your past conversations and refer back to earlier decisions. Deleting them means Claude Code will not remember previous work in those projects — it will start fresh.",
                warningNote: "Only delete these if you are happy for Claude Code to lose its memory of past sessions in those projects.",
                paths: subdirectories(of: expand("~/.claude/projects")),
                isSelected: false
            ),
            Category(
                title: "CLI Temp Files",
                explanation: "Small temporary files the Claude command-line tool writes to speed up repeated operations and remember your shell environment. Safe to delete — they are recreated automatically the next time you run a Claude Code command.",
                warningNote: nil,
                paths: existingURLs([
                    "~/.claude/cache",
                    "~/.claude/shell-snapshots",
                ]),
                isSelected: true
            ),
            Category(
                title: "VM Sandbox Bundle",
                explanation: "A full virtual machine image that lets Claude Code run code safely inside an isolated sandbox, so nothing it executes can affect the rest of your Mac. This is what powers Claude Code's code-execution and cowork features.",
                warningNote: "Deleting this means Claude Code's sandboxed code execution will not work until the bundle is re-downloaded, which can take several minutes. Only delete if you are sure you do not use those features.",
                paths: existingURLs([
                    "~/Library/Application Support/Claude/vm_bundles/claudevm.bundle",
                ]),
                isSelected: false
            ),
        ]

        // Size every category's paths in one bounded batch instead of one
        // sequential pass per category.
        let sizes = await FileSize.allocatedSizes(of: categories.flatMap(\.paths))

        var found: [ClaudeCleanupItem] = []
        for category in categories {
            let totalSize = category.paths.reduce(Int64(0)) { $0 + (sizes[$1] ?? 0) }
            guard totalSize > 0 else { continue }
            found.append(ClaudeCleanupItem(
                id: UUID(),
                title: category.title,
                explanation: category.explanation,
                warningNote: category.warningNote,
                paths: category.paths,
                sizeBytes: totalSize,
                isSelected: category.isSelected
            ))
        }
        return found
    }

    private nonisolated static func expand(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    private nonisolated static func existingURLs(_ paths: [String]) -> [URL] {
        paths
            .map { URL(fileURLWithPath: expand($0)) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private nonisolated static func subdirectories(of path: String) -> [URL] {
        let url = URL(fileURLWithPath: path)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        ) else { return [] }
        return contents.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }
    }

}
