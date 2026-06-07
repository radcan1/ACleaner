import Foundation

struct ClaudeCleanupItem: Identifiable {
    let id: UUID
    let title: String
    let explanation: String      // plain-language "what is this?"
    let warningNote: String?     // non-nil for items that need extra caution
    let paths: [URL]             // all paths that belong to this category
    let sizeBytes: Int64
    var isSelected: Bool

    var sizeDescription: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}
