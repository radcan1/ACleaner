import Foundation

enum ScanLocations {
    struct Entry {
        let path: String
        let kind: LeftoverFile.Kind
        let depth: Int
    }

    static var all: [Entry] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            Entry(path: "\(home)/Library/Application Support",            kind: .applicationSupport, depth: 2),
            Entry(path: "\(home)/Library/Application Scripts",            kind: .applicationSupport, depth: 1),
            Entry(path: "\(home)/Library/Preferences",                    kind: .preferences,        depth: 1),
            Entry(path: "\(home)/Library/Preferences/ByHost",             kind: .preferences,        depth: 1),
            Entry(path: "\(home)/Library/Caches",                         kind: .caches,             depth: 2),
            Entry(path: "\(home)/Library/HTTPStorages",                   kind: .httpStorage,        depth: 1),
            Entry(path: "\(home)/Library/WebKit",                         kind: .webKit,             depth: 1),
            Entry(path: "\(home)/Library/Logs",                           kind: .logs,               depth: 2),
            Entry(path: "\(home)/Library/Containers",                     kind: .containers,         depth: 1),
            Entry(path: "\(home)/Library/Group Containers",               kind: .groupContainers,    depth: 1),
            Entry(path: "\(home)/Library/Saved Application State",        kind: .savedState,         depth: 1),
            Entry(path: "\(home)/Library/LaunchAgents",                   kind: .launchAgent,        depth: 1),
            Entry(path: "/Library/Application Support",                   kind: .applicationSupport, depth: 2),
            Entry(path: "/Library/Caches",                                kind: .caches,             depth: 2),
            Entry(path: "/Library/Preferences",                           kind: .preferences,        depth: 1),
            Entry(path: "/Library/Logs",                                  kind: .logs,               depth: 1),
            Entry(path: "/Library/LaunchAgents",                          kind: .launchAgent,        depth: 1),
            Entry(path: "/Library/LaunchDaemons",                         kind: .launchDaemon,       depth: 1),
            Entry(path: "/Library/PrivilegedHelperTools",                 kind: .other,              depth: 1)
        ]
    }
}
