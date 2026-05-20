import Foundation

struct LeftoverFile: Identifiable, Hashable {
    let url: URL
    let sizeBytes: Int64
    let kind: Kind

    var id: URL { url }

    enum Kind: String {
        case appBundle = "Application bundle"
        case applicationSupport = "Application Support"
        case preferences = "Preferences"
        case caches = "Caches"
        case logs = "Logs"
        case containers = "Containers"
        case groupContainers = "Group Containers"
        case savedState = "Saved State"
        case launchAgent = "Launch Agent"
        case launchDaemon = "Launch Daemon"
        case webKit = "WebKit data"
        case httpStorage = "HTTP storage"
        case other = "Other"
    }

    var category: String { kind.rawValue }

    var sizeDescription: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }

    var locationDescription: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var path = url.path
        if path.hasPrefix(home) {
            path = "~" + path.dropFirst(home.count)
        }
        return path
    }
}
