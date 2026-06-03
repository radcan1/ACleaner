import Foundation

struct LLMModel: Identifiable {
    let id: UUID
    let name: String
    let url: URL
    let size: Int64
}

struct LLMSource: Identifiable {
    let id: UUID
    let name: String
    let icon: String
    let models: [LLMModel]

    var totalSize: Int64 { models.reduce(0) { $0 + $1.size } }
}
