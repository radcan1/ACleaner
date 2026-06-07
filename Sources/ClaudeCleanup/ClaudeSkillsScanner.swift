import Foundation

@MainActor
final class ClaudeSkillsScanner: ObservableObject {
    @Published var skills: [ClaudeSkillItem] = []
    @Published var isScanning = false

    var codeSkills: [ClaudeSkillItem]  { skills.filter { $0.surface == .code } }
    var chatSkills: [ClaudeSkillItem]  { skills.filter { $0.surface == .chat } }
    var selectedCount: Int             { skills.filter(\.isSelected).count }

    func scan() async {
        isScanning = true
        skills = []

        let found = await Task.detached(priority: .userInitiated) {
            Self.scanCodeSkills() + Self.scanChatExtensions()
        }.value

        skills = found
        isScanning = false
    }

    func toggleSelection(for item: ClaudeSkillItem) {
        guard let idx = skills.firstIndex(where: { $0.id == item.id }) else { return }
        skills[idx].isSelected.toggle()
    }

    func removeSelected() async -> (Int, [String]) {
        let toDelete = skills.filter(\.isSelected).map(\.folderURL)
        var removed = 0
        var failed: [String] = []
        for url in toDelete {
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                removed += 1
            } catch {
                failed.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return (removed, failed)
    }

    // MARK: - Claude Code skills  (~/.claude/skills/<name>/)

    private nonisolated static func scanCodeSkills() -> [ClaudeSkillItem] {
        let dir = URL(fileURLWithPath: ("~/.claude/skills" as NSString).expandingTildeInPath)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles
        ) else { return [] }

        return contents.compactMap { folder -> ClaudeSkillItem? in
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return nil }
            let name = displayName(fromSkillFolder: folder)
            let desc = description(fromSkillFolder: folder)
            let sz   = directorySize(url: folder)
            return ClaudeSkillItem(
                id: UUID(),
                name: name,
                description: desc,
                surface: .code,
                folderURL: folder,
                sizeBytes: sz,
                isSelected: false
            )
        }.sorted { $0.name < $1.name }
    }

    private nonisolated static func displayName(fromSkillFolder folder: URL) -> String {
        for candidate in ["SKILL.md", "SYSTEM.md"] {
            let mdURL = folder.appendingPathComponent(candidate)
            guard let text = try? String(contentsOf: mdURL, encoding: .utf8) else { continue }
            for line in text.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("# ") {
                    return String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                }
            }
        }
        return folder.lastPathComponent
            .replacingOccurrences(of: "-", with: " ")
            .capitalized
    }

    private nonisolated static func description(fromSkillFolder folder: URL) -> String {
        for candidate in ["SKILL.md", "SYSTEM.md"] {
            let mdURL = folder.appendingPathComponent(candidate)
            guard let text = try? String(contentsOf: mdURL, encoding: .utf8) else { continue }
            var passedHeading = false
            for line in text.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("#") { passedHeading = true; continue }
                if passedHeading && !trimmed.isEmpty && !trimmed.hasPrefix("##") {
                    let clean = trimmed
                        .replacingOccurrences(of: "**", with: "")
                        .replacingOccurrences(of: "*", with: "")
                    return clean.count > 140 ? String(clean.prefix(140)) + "\u{2026}" : clean
                }
            }
        }
        return "Claude Code skill"
    }

    // MARK: - Claude Chat / Cowork extensions

    private nonisolated static func scanChatExtensions() -> [ClaudeSkillItem] {
        let base = ("~/Library/Application Support/Claude/Claude Extensions" as NSString)
            .expandingTildeInPath
        let dir = URL(fileURLWithPath: base)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles
        ) else { return [] }

        return contents.compactMap { folder -> ClaudeSkillItem? in
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return nil }
            guard let (name, desc) = readManifest(in: folder) else { return nil }
            let sz = directorySize(url: folder)
            return ClaudeSkillItem(
                id: UUID(),
                name: name,
                description: desc,
                surface: .chat,
                folderURL: folder,
                sizeBytes: sz,
                isSelected: false
            )
        }.sorted { $0.name < $1.name }
    }

    private nonisolated static func readManifest(in folder: URL) -> (String, String)? {
        let manifestURL = folder.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let name = json["name"] as? String ?? folder.lastPathComponent
        let desc = json["description"] as? String ?? "Claude Chat / Cowork extension"
        return (name, desc)
    }

    private nonisolated static func directorySize(url: URL) -> Int64 {
        var total: Int64 = 0
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: .skipsHiddenFiles
        ) else { return 0 }
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
