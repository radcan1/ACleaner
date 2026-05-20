import Foundation

struct TrashedApp: Equatable, Hashable {
    let trashURL: URL
    let displayName: String
    let bundleIdentifier: String?
    let originalName: String

    static func from(trashURL: URL) -> TrashedApp? {
        guard trashURL.pathExtension == "app" else { return nil }
        guard FileManager.default.fileExists(atPath: trashURL.path) else { return nil }

        let bundle = Bundle(url: trashURL)
        let info = bundle?.infoDictionary
        let bundleID = bundle?.bundleIdentifier
        let displayName = (info?["CFBundleDisplayName"] as? String)
            ?? (info?["CFBundleName"] as? String)
            ?? trashURL.deletingPathExtension().lastPathComponent

        let originalName = trashURL.deletingPathExtension().lastPathComponent

        return TrashedApp(
            trashURL: trashURL,
            displayName: displayName,
            bundleIdentifier: bundleID,
            originalName: originalName
        )
    }
}
