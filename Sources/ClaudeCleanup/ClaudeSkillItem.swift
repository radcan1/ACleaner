import Foundation

enum ClaudeSurface: String {
    case code       = "Claude Code"
    case chat       = "Claude Chat / Cowork"
}

struct ClaudeSkillItem: Identifiable {
    let id: UUID
    let name: String
    let description: String
    let surface: ClaudeSurface
    let folderURL: URL
    let sizeBytes: Int64
    var isSelected: Bool

    var sizeDescription: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}
