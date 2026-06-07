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

        let found = await Task.detached(priority: .userInitiated) {
            Self.buildItems()
        }.value

        items = found
        isScanning = false
    }

    func toggleSelection(for item: ClaudeCleanupItem) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[idx].isSelected.toggle()
    }

    func clean() async -> (Int, [String]) {
        let toDelete = items.filter(\.isSelected).flatMap(\.paths)
        var trashed = 0
        var failed: [String] = []
        for url in toDelete {
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                trashed += 1
            } catch {
                failed.append("\(url.path): \(error.localizedDescription)")
            }
        }
        return (trashed, failed)
    }

    // MARK: - Background work (nonisolated)

    private nonisolated static func buildItems() -> [ClaudeCleanupItem] {
        var found: [ClaudeCleanupItem] = []

        // 1. Electron caches — always safe
        let cachePaths = existingURLs([
            "~/Library/Application Support/Claude/Cache",
            "~/Library/Application Support/Claude/Code Cache",
            "~/Library/Application Support/Claude/GPUCache",
            "~/Library/Application Support/Claude/DawnWebGPUCache",
            "~/Library/Application Support/Claude/DawnGraphiteCache",
        ])
        let cacheSize = cachePaths.reduce(Int64(0)) { $0 + size(of: $1) }
        if cacheSize > 0 {
            found.append(ClaudeCleanupItem(
                id: UUID(),
                title: "App Caches",
                explanation: "Temporary files Claude downloads and generates to load faster — similar to how a web browser caches pages. They are rebuilt automatically the next time Claude starts. Completely safe to delete at any time.",
                warningNote: nil,
                paths: cachePaths,
                sizeBytes: cacheSize,
                isSelected: true
            ))
        }

        // 2. App logs
        let logPaths = existingURLs([
            "~/Library/Logs/Claude",
            "~/Library/Logs/claude-chat-done.log",
        ])
        let logSize = logPaths.reduce(Int64(0)) { $0 + size(of: $1) }
        if logSize > 0 {
            found.append(ClaudeCleanupItem(
                id: UUID(),
                title: "App Logs",
                explanation: "Records of what Claude did while running — useful for diagnosing crashes or unexpected behaviour. New logs are created automatically as you use Claude, so deleting old ones is always safe.",
                warningNote: nil,
                paths: logPaths,
                sizeBytes: logSize,
                isSelected: true
            ))
        }

        // 3. VM warm-start cache
        let warmPaths = existingURLs([
            "~/Library/Application Support/Claude/vm_bundles/warm",
        ])
        let warmSize = warmPaths.reduce(Int64(0)) { $0 + size(of: $1) }
        if warmSize > 0 {
            found.append(ClaudeCleanupItem(
                id: UUID(),
                title: "VM Warm Cache",
                explanation: "A pre-started virtual machine that Claude Code keeps in the background so your first command runs instantly. Deleting it just means the next Claude Code session takes a few extra seconds to start — it rebuilds itself automatically.",
                warningNote: nil,
                paths: warmPaths,
                sizeBytes: warmSize,
                isSelected: true
            ))
        }

        // 4. Agent / cowork sessions
        let sessionDir = expand("~/Library/Application Support/Claude/local-agent-mode-sessions")
        let sessionPaths = subdirectories(of: sessionDir).filter {
            $0.lastPathComponent != "skills-plugin"
        }
        let sessionSize = sessionPaths.reduce(Int64(0)) { $0 + size(of: $1) }
        if sessionSize > 0 {
            found.append(ClaudeCleanupItem(
                id: UUID(),
                title: "Agent & Cowork Sessions",
                explanation: "Saved state from Claude's agent tasks and cowork sessions — the files Claude used to pick up where it left off in long-running jobs. Once a task is finished you no longer need these. Deleting them does not affect Claude's ability to start new tasks.",
                warningNote: "If you have an active cowork session running right now, do not delete this — wait until the task finishes first.",
                paths: sessionPaths,
                sizeBytes: sessionSize,
                isSelected: false
            ))
        }

        // 5. Claude Code CLI project transcripts
        let projectsDir = expand("~/.claude/projects")
        let projectPaths = subdirectories(of: projectsDir)
        let projectSize = projectPaths.reduce(Int64(0)) { $0 + size(of: $1) }
        if projectSize > 0 {
            found.append(ClaudeCleanupItem(
                id: UUID(),
                title: "Claude Code Project Transcripts",
                explanation: "Full conversation logs from every Claude Code session, stored per project. These let Claude Code remember your past conversations and refer back to earlier decisions. Deleting them means Claude Code will not remember previous work in those projects — it will start fresh.",
                warningNote: "Only delete these if you are happy for Claude Code to lose its memory of past sessions in those projects.",
                paths: projectPaths,
                sizeBytes: projectSize,
                isSelected: false
            ))
        }

        // 6. CLI cache and shell snapshots
        let cliTempPaths = existingURLs([
            "~/.claude/cache",
            "~/.claude/shell-snapshots",
        ])
        let cliTempSize = cliTempPaths.reduce(Int64(0)) { $0 + size(of: $1) }
        if cliTempSize > 0 {
            found.append(ClaudeCleanupItem(
                id: UUID(),
                title: "CLI Temp Files",
                explanation: "Small temporary files the Claude command-line tool writes to speed up repeated operations and remember your shell environment. Safe to delete — they are recreated automatically the next time you run a Claude Code command.",
                warningNote: nil,
                paths: cliTempPaths,
                sizeBytes: cliTempSize,
                isSelected: true
            ))
        }

        // 7. VM sandbox bundle — large, requires explicit selection
        let vmPaths = existingURLs([
            "~/Library/Application Support/Claude/vm_bundles/claudevm.bundle",
        ])
        let vmSize = vmPaths.reduce(Int64(0)) { $0 + size(of: $1) }
        if vmSize > 0 {
            found.append(ClaudeCleanupItem(
                id: UUID(),
                title: "VM Sandbox Bundle",
                explanation: "A full virtual machine image that lets Claude Code run code safely inside an isolated sandbox, so nothing it executes can affect the rest of your Mac. This is what powers Claude Code's code-execution and cowork features.",
                warningNote: "Deleting this means Claude Code's sandboxed code execution will not work until the bundle is re-downloaded, which can take several minutes. Only delete if you are sure you do not use those features.",
                paths: vmPaths,
                sizeBytes: vmSize,
                isSelected: false
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

    private nonisolated static func size(of url: URL) -> Int64 {
        var total: Int64 = 0
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: .skipsHiddenFiles
        ) else {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let sz = attrs[.size] as? Int64 { return sz }
            return 0
        }
        while let file = enumerator.nextObject() as? URL {
            if let vals = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
               vals.isRegularFile == true,
               let sz = vals.fileSize {
                total += Int64(sz)
            }
        }
        return total
    }
}
