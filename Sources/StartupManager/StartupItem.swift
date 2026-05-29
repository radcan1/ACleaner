import Foundation

enum StartupItemKind: String {
    case loginItem    = "Login Item"
    case userAgent    = "User Launch Agent"
    case systemAgent  = "System Launch Agent"
    case systemDaemon = "System Launch Daemon"
}

struct StartupItem: Identifiable {
    let id: UUID
    let kind: StartupItemKind
    let name: String
    let detail: String       // bundle ID or plist label
    let plistURL: URL?       // nil for SMAppService-managed items
    var isEnabled: Bool

    var canToggle: Bool {
        switch kind {
        case .loginItem, .userAgent: return true
        case .systemAgent, .systemDaemon: return false
        }
    }

    var canDelete: Bool {
        switch kind {
        case .userAgent: return true
        case .loginItem, .systemAgent, .systemDaemon: return false
        }
    }
}
