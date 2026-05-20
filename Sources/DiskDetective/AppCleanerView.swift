import SwiftUI
import AppKit

// MARK: - Models

struct AppInfo: Identifiable {
    let id = UUID()
    let name: String
    let path: String
    let bundleID: String
    let sizeBytes: Int64
}

struct LinkedFile: Identifiable {
    let id = UUID()
    var isSelected: Bool = false
    let path: String
    let category: String
    let sizeBytes: Int64
}

struct DeletionResult {
    let appCount: Int
    let fileCount: Int
    let freedBytes: Int64
}

struct OrphanGroup: Identifiable {
    let id = UUID()
    var isSelected: Bool = false
    let key: String          // bare identifier, e.g. "com.example.MyApp" or "Sketch"
    var files: [LinkedFile]

    var totalBytes: Int64 { files.reduce(0) { $0 + $1.sizeBytes } }

    var displayName: String {
        // For bundle IDs show the meaningful tail; for plain names show as-is
        let parts = key.split(separator: ".").map(String.init)
        if parts.count >= 3 { return parts[2...].joined(separator: ".") }
        return key
    }

    var locationSummary: String {
        let cats = Array(Set(files.map(\.category))).sorted()
        return cats.joined(separator: ", ")
    }

    // Up to 3 unique parent-directory paths, shortened to ~ — shown in the
    // collapsed row so the user knows exactly which folders this covers.
    var pathHints: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dirs = files.map {
            URL(fileURLWithPath: $0.path)
                .deletingLastPathComponent().path
                .replacingOccurrences(of: home, with: "~")
        }
        var seen = Set<String>()
        var result: [String] = []
        for d in dirs where seen.insert(d).inserted { result.append(d) }
        return Array(result.prefix(3))
    }
}

// MARK: - Engine

@MainActor
class AppCleanerEngine: ObservableObject {
    @Published var apps: [AppInfo] = []
    @Published var isLoadingApps = false
    @Published var appsStatus = "Press Load Apps to begin."

    @Published var linkedFiles: [LinkedFile] = []
    @Published var isDeepScanning = false

    @Published var orphanGroups: [OrphanGroup] = []
    @Published var isOrphanScanning = false
    @Published var orphanStatus = ""

    @Published var lastFreedBytes: Int64 = 0
    @Published var orphanDeletionResult: DeletionResult? = nil

    private let home = FileManager.default.homeDirectoryForCurrentUser.path

    // MARK: Load all installed apps

    func loadApps() async {
        isLoadingApps = true
        appsStatus = "Scanning /Applications…"
        apps = []

        let script = """
        find /Applications ~/Applications -maxdepth 2 -name "*.app" -type d 2>/dev/null | sort | \
        while read -r app; do
            bid=$(defaults read "$app/Contents/Info.plist" CFBundleIdentifier 2>/dev/null)
            [ -z "$bid" ] && continue
            sz=$(du -sm "$app" 2>/dev/null | awk '{print $1}')
            printf "%s\t%s\t%s\n" "$bid" "${sz:-0}" "$app"
        done
        """
        let out = await shell(script)
        var result: [AppInfo] = []
        for line in out.split(separator: "\n").map(String.init).filter({ !$0.isEmpty }) {
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 3 else { continue }
            let bid  = parts[0].trimmingCharacters(in: .whitespaces)
            let mb   = Int64(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
            let path = parts[2].trimmingCharacters(in: .whitespaces)
            guard !bid.isEmpty, !path.isEmpty else { continue }
            let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            result.append(AppInfo(name: name, path: path, bundleID: bid, sizeBytes: mb * 1_048_576))
        }
        apps = result.sorted { $0.name.lowercased() < $1.name.lowercased() }
        isLoadingApps = false
        appsStatus = apps.isEmpty ? "No apps found." : "\(apps.count) apps — tap one to find all its files"
    }

    // MARK: Deep scan one app

    func deepScan(app: AppInfo) async {
        isDeepScanning = true
        linkedFiles = []

        let bid  = app.bundleID
        let name = app.name
        let fm   = FileManager.default
        var seen = Set<String>()
        var found: [LinkedFile] = []

        // Direct path checks
        let direct: [(String, String)] = [
            ("App Bundle",          app.path),
            ("App Support",         "\(home)/Library/Application Support/\(bid)"),
            ("App Support",         "\(home)/Library/Application Support/\(name)"),
            ("Caches",              "\(home)/Library/Caches/\(bid)"),
            ("Caches",              "\(home)/Library/Caches/\(name)"),
            ("Container",           "\(home)/Library/Containers/\(bid)"),
            ("Saved State",         "\(home)/Library/Saved Application State/\(bid).savedState"),
            ("App Scripts",         "\(home)/Library/Application Scripts/\(bid)"),
            ("WebKit Storage",      "\(home)/Library/WebKit/\(bid)"),
            ("HTTP Storage",        "\(home)/Library/HTTPStorages/\(bid)"),
            ("System App Support",  "/Library/Application Support/\(bid)"),
            ("System App Support",  "/Library/Application Support/\(name)"),
        ]
        for (category, path) in direct {
            guard !seen.contains(path), fm.fileExists(atPath: path) else { continue }
            seen.insert(path)
            let size = await itemSize(path)
            found.append(LinkedFile(path: path, category: category, sizeBytes: size))
        }

        // Prefix-match in directories
        let prefixDirs: [(String, String, [String])] = [
            ("Preferences",    "\(home)/Library/Preferences",       [bid]),
            ("Launch Agents",  "\(home)/Library/LaunchAgents",      [bid]),
            ("Launch Agents",  "/Library/LaunchAgents",             [bid]),
            ("Launch Daemons", "/Library/LaunchDaemons",            [bid]),
            ("Logs",           "\(home)/Library/Logs",              [bid, name]),
            ("Logs",           "/Library/Logs",                     [bid, name]),
        ]
        for (category, dir, prefixes) in prefixDirs {
            guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for entry in entries {
                guard prefixes.contains(where: { entry.hasPrefix($0) }) else { continue }
                let path = "\(dir)/\(entry)"
                guard !seen.contains(path) else { continue }
                seen.insert(path)
                let size = await itemSize(path)
                found.append(LinkedFile(path: path, category: category, sizeBytes: size))
            }
        }

        // Group containers
        let gcDir = "\(home)/Library/Group Containers"
        if let entries = try? fm.contentsOfDirectory(atPath: gcDir) {
            for entry in entries where entry.contains(bid) {
                let path = "\(gcDir)/\(entry)"
                guard !seen.contains(path) else { continue }
                seen.insert(path)
                let size = await itemSize(path)
                found.append(LinkedFile(path: path, category: "Group Container", sizeBytes: size))
            }
        }

        linkedFiles = found.sorted { $0.sizeBytes > $1.sizeBytes }
        isDeepScanning = false
    }

    // MARK: Orphan finder (Mole + PearCleaner-style)

    func findOrphans() async {
        isOrphanScanning = true
        orphanStatus = "Building installed app inventory…"
        orphanGroups = []

        // ── 1. Multi-root app inventory ──────────────────────────────────────
        // FIX: Previously only checked /Applications. Now includes Homebrew Cask,
        // Setapp, /System/Applications and a Spotlight fallback so apps installed
        // via Cask or Setapp are not falsely reported as orphans.
        let appOut = await shell("""
        {
          find /Applications ~/Applications /System/Applications \
               -maxdepth 3 -name "*.app" -type d 2>/dev/null
          find /opt/homebrew/Caskroom /usr/local/Caskroom \
               -maxdepth 4 -name "*.app" -type d 2>/dev/null
          find /Applications/Setapp \
               -maxdepth 3 -name "*.app" -type d 2>/dev/null
          mdfind "kMDItemContentType == 'com.apple.application-bundle'" 2>/dev/null
        } | sort -u | \
        while read -r app; do
            [ -d "$app" ] || continue
            bid=$(mdls -name kMDItemCFBundleIdentifier -raw "$app" 2>/dev/null)
            name=$(mdls -name kMDItemDisplayName -raw "$app" 2>/dev/null | sed 's/\\.app$//')
            [ -n "$bid"  ] && [ "$bid"  != "(null)" ] && printf "bid\t%s\n"  "$bid"
            [ -n "$name" ] && [ "$name" != "(null)" ] && printf "name\t%s\n" "$name"
        done
        """)

        // ── 2. Two-tier token matching (FIX: boundary-aware) ────────────────
        // FIX: Old code did pearFormat substring matching only. Problem: "example"
        // would match "example123" causing real orphans to be silently skipped.
        // New approach:
        //   boundaryTokens — exact component matches (split bundle ID by ".", name by " -_")
        //   substringTokens — full pearFormat of the whole bundle ID (fallback for
        //     camelCase folder names like "BraveSoftware" that don't split cleanly)
        var boundaryTokens  = Set<String>()
        var substringTokens = Set<String>()
        let wordSeps = CharacterSet(charactersIn: " -_.")

        for line in appOut.split(separator: "\n").map(String.init).filter({ !$0.isEmpty }) {
            let parts = line.components(separatedBy: "\t")
            guard parts.count == 2 else { continue }
            let kind = parts[0]; let value = parts[1].trimmingCharacters(in: .whitespaces)

            if kind == "bid" {
                // Boundary: each dot-separated component, e.g. "com.brave.Browser" → "brave","browser"
                for part in value.split(separator: ".") {
                    let t = String(part).lowercased().filter { $0.isLetter || $0.isNumber }
                    if t.count >= 4 { boundaryTokens.insert(t) }
                }
                // Substring fallback: full pearFormat of the bundle ID
                let full = pearFormat(value)
                if full.count >= 5 { substringTokens.insert(full) }
            }
            if kind == "name" {
                for component in value.components(separatedBy: wordSeps) {
                    let t = component.lowercased().filter { $0.isLetter || $0.isNumber }
                    if t.count >= 4 { boundaryTokens.insert(t) }
                }
            }
        }

        // Returns true if the given name belongs to a currently-installed app.
        func entryMatchesApp(_ name: String) -> Bool {
            // Step 1 — boundary match: split name by delimiters, check each component
            let components = name.components(separatedBy: wordSeps)
                .map { $0.lowercased().filter { $0.isLetter || $0.isNumber } }
                .filter { $0.count >= 4 }
            if components.contains(where: { boundaryTokens.contains($0) }) { return true }

            // Step 2 — substring fallback for camelCase names (e.g. "BraveSoftware")
            let normalized = pearFormat(name)
            return substringTokens.contains { normalized.contains($0) }
        }

        // ── 3. Directories to scan ───────────────────────────────────────────
        let scanDirs: [(String, String)] = [
            ("App Support",    "\(home)/Library/Application Support"),
            ("App Support",    "\(home)/Library/Application Support/Caches"),
            ("Caches",         "\(home)/Library/Caches"),
            ("Containers",     "\(home)/Library/Containers"),
            ("HTTP Storage",   "\(home)/Library/HTTPStorages"),
            ("Launch Agents",  "\(home)/Library/LaunchAgents"),
            ("Logs",           "\(home)/Library/Logs"),
            ("Preferences",    "\(home)/Library/Preferences"),
            ("Preferences",    "\(home)/Library/Preferences/ByHost"),
            ("Pref Panes",     "\(home)/Library/PreferencePanes"),
            ("Saved State",    "\(home)/Library/Saved Application State"),
            ("App Scripts",    "\(home)/Library/Application Scripts"),
            ("WebKit",         "\(home)/Library/WebKit"),
            ("App Support",    "/Library/Application Support"),
            ("Launch Agents",  "/Library/LaunchAgents"),
            ("Launch Daemons", "/Library/LaunchDaemons"),
            ("Helper Tools",   "/Library/PrivilegedHelperTools"),
        ]

        // Apple / system skip list — any entry whose pearFormat contains one of
        // these is definitely system-owned and never an orphan.
        let skipTokens: Set<String> = [
            "apple","temporary","btserver","proapps","scripteditor","ilife",
            "siritoday","addressbook","animoji","appstore","askpermission",
            "callhistory","clouddocs","diskimages","dock","facetime",
            "fileprovider","instruments","knowledge","mobilesync","syncservices",
            "homeenergyd","icloud","icdd","networkserviceproxy","familycircle",
            "geoservices","installation","passkit","sharedimagecache","desktop",
            "mbuseragent","swiftpm","baseband","coresimulator","siritts",
            "ipod","globalpreferences","apmanalytics","apmexperiment",
            "avatarcache","byhost","contextstoreagent","mobilemeaccounts",
            "mobiledocuments","mobile","intentbuilderc","loginwindow","momc",
            "replayd","sharedfilelistd","clang","audiocomponent",
            "livetranscriptionagent","sandboxhelper","statuskitagent",
            "gamed","heard","homed","itunescloudd","lldb","mds","mediaanalysisd",
            "metrickitd","mobiletimerd","proactived","ptpcamerad","studentd",
            "talagent","watchlistd","apptranslocation","xcrun","dsstore",
            "crashreporter","trash","amsdatamigratortool","arfilecache",
            "assistant","chromium","cloudkit","webkit","databases","diagnostic",
            "gamekit","homebrew","logi","microsoft","mozilla","sync","google",
            "sentinel","hexnode","sentry","tvappservices","reminders","pbs",
            "notarytool","differentialprivacy","storeassetd","webpush",
            "storedownloadd","fsck","crash","python","discrecording",
            "photossearch","pylint","jamf","scopedbookmarkagent","anonymous",
            "isolated","nobackup","privacypreservingmeasurement","symbols",
            "stickersd","privatecloudcomputed","tipsd","controlcenter",
            "contactsd","staticcheck","segment","sparkle","summaryevents",
            "launchdarkly","identityservicesd","automator","spotlight","cef",
            "photoslibrary","preview","maps","mail","calendar","safari",
            "notes","news","music","podcasts","tvos",
        ]

        let fm = FileManager.default
        var found: [(key: String, file: LinkedFile)] = []

        for (category, dir) in scanDirs {
            orphanStatus = "Scanning \(category)…"
            guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }

            for entry in entries {
                guard !entry.hasPrefix(".") else { continue }
                guard !isHexUUID(entry) else { continue }

                let formattedEntry = pearFormat(entry)
                guard formattedEntry.count >= 5 else { continue }
                guard !skipTokens.contains(where: { formattedEntry.contains($0) }) else { continue }

                let fullPath = "\(dir)/\(entry)"
                let isLaunchFile = (dir.contains("LaunchAgent") || dir.contains("LaunchDaemon"))
                    && entry.hasSuffix(".plist")

                // FIX: LaunchAgent/Daemon special path — read ProgramArguments from
                // the plist to check if the binary it points to still exists on disk.
                // This catches agents whose filename doesn't contain the bundle ID at all.
                if isLaunchFile {
                    if let orphaned = isOrphanedLaunchPlist(at: fullPath) {
                        if orphaned {
                            var key = entry
                            if key.hasSuffix(".plist") { key = String(key.dropLast(6)) }
                            found.append((key: key, file: LinkedFile(
                                path: fullPath, category: category, sizeBytes: 4_096)))
                        }
                        continue   // handled — skip name-matching below
                    }
                }

                // For UUID-named Containers, resolve the real bundle ID
                var matchName = entry
                if dir.contains("/Containers"),
                   let resolvedBID = resolveContainerBundleID(at: fullPath) {
                    matchName = resolvedBID
                }

                // Core match: skip if the entry belongs to a currently-installed app
                guard !entryMatchesApp(matchName) else { continue }

                let size = await itemSize(fullPath)
                guard size >= 1_000 else { continue }

                var key = entry
                for suffix in [".plist", ".savedState", ".binarycookies", ".pkd", ".db"] {
                    if key.hasSuffix(suffix) { key = String(key.dropLast(suffix.count)); break }
                }
                found.append((key: key, file: LinkedFile(path: fullPath, category: category, sizeBytes: size)))
            }
        }

        // ── 4. Hidden dot-directory scan (FIX: new, Mole-style) ─────────────
        // Scans ~/.<name> folders and ~/.config/<name> subdirectories that no
        // longer have a corresponding installed app. Dev tool dirs are allowlisted.
        orphanStatus = "Scanning hidden config directories…"
        let dotAllowlist: Set<String> = [
            ".Trash",".ssh",".gnupg",".config",".cache",".local",".gem",
            ".rbenv",".pyenv",".nvm",".rustup",".cargo",".docker",".kube",
            ".aws",".azure",".terraform",".vagrant",".ansible",
            ".npm",".gradle",".m2",".ivy2",".cocoapods",".bundle",
            ".rvm",".sdkman",".volta",".pnpm",".yarn",
            ".oh-my-zsh",".bash_sessions",".viminfo",".lesshst",
            ".CFUserTextEncoding",".DS_Store",".localized",
            ".Spotlight-V100",".fseventsd",".hotfiles.btree",
        ]
        let dotScript = """
        {
          find "\(home)" -maxdepth 1 -name ".*" -type d 2>/dev/null
          find "\(home)/.config" -maxdepth 1 -mindepth 1 -type d 2>/dev/null
        } | while read -r d; do
            sz=$(du -sk "$d" 2>/dev/null | awk '{print $1}')
            [ -z "$sz" ] || [ "$sz" -lt 200 ] && continue
            printf '%s\t%s\t%s\n' "$(basename "$d")" "$sz" "$d"
        done
        """
        let dotOut = await shell(dotScript)
        for line in dotOut.split(separator: "\n").map(String.init).filter({ !$0.isEmpty }) {
            let parts = line.components(separatedBy: "\t")
            guard parts.count == 3 else { continue }
            let name = parts[0], path = parts[2]
            guard !dotAllowlist.contains(name) else { continue }
            let cleanName = name.hasPrefix(".") ? String(name.dropFirst()) : name
            guard cleanName.count >= 3 else { continue }
            guard !skipTokens.contains(where: { pearFormat(cleanName).contains($0) }) else { continue }
            guard !entryMatchesApp(cleanName) else { continue }
            let size = await itemSize(path)
            guard size >= 1_000 else { continue }
            found.append((key: cleanName, file: LinkedFile(path: path, category: "Hidden Config", sizeBytes: size)))
        }

        // ── 5. Group by key, sort largest first ──────────────────────────────
        var groupMap: [String: [LinkedFile]] = [:]
        for (key, file) in found { groupMap[key, default: []].append(file) }
        orphanGroups = groupMap.map { key, files in
            OrphanGroup(key: key, files: files.sorted { $0.sizeBytes > $1.sizeBytes })
        }.sorted { $0.totalBytes > $1.totalBytes }

        isOrphanScanning = false
        let total     = orphanGroups.reduce(0) { $0 + $1.totalBytes }
        let fileCount = orphanGroups.reduce(0) { $0 + $1.files.count }
        orphanStatus  = orphanGroups.isEmpty
            ? "No orphaned files found."
            : "\(orphanGroups.count) deleted app\(orphanGroups.count == 1 ? "" : "s") — \(fileCount) files, \(fmtBytes(total)) recoverable"
    }

    // MARK: - PearCleaner / Mole helpers

    /// Strips all non-alphanumeric characters and lowercases.
    private func pearFormat(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Returns true if the string is a 32-character hex UUID
    /// (the format macOS uses for UUID-named sandbox container directories).
    private func isHexUUID(_ s: String) -> Bool {
        let stripped = s.replacingOccurrences(of: "-", with: "")
        guard stripped.count == 32 else { return false }
        return stripped.allSatisfy { $0.isHexDigit }
    }

    /// For UUID-named entries inside ~/Library/Containers, reads the
    /// containermanagerd metadata plist to get the real bundle identifier.
    private func resolveContainerBundleID(at path: String) -> String? {
        let plistPath = path + "/.com.apple.containermanagerd.metadata.plist"
        guard let dict = NSDictionary(contentsOfFile: plistPath),
              let bid  = dict["MCMMetadataIdentifier"] as? String else { return nil }
        return bid
    }

    /// FIX (Mole-style): reads a LaunchAgent/Daemon plist and checks whether the
    /// binary it references still exists on disk. Returns nil if the plist can't
    /// be read (treated as unknown — falls through to name matching).
    private func isOrphanedLaunchPlist(at path: String) -> Bool? {
        guard let dict = NSDictionary(contentsOfFile: path) else { return nil }
        // "Program" key — direct path to binary
        if let program = dict["Program"] as? String {
            return !FileManager.default.fileExists(atPath: program)
        }
        // "ProgramArguments" array — first element is the binary
        if let args = dict["ProgramArguments"] as? [String], let binary = args.first {
            // Skip shell interpreters (they always exist)
            let isShell = ["/bin/sh", "/bin/bash", "/usr/bin/env"].contains(binary)
            if !isShell {
                return !FileManager.default.fileExists(atPath: binary)
            }
        }
        return nil
    }

    // MARK: Delete

    func deleteSelectedLinked() async {
        let freed = await trashFiles(linkedFiles.filter(\.isSelected))
        linkedFiles.removeAll { $0.isSelected }
        if freed > 0 { lastFreedBytes += freed }
    }

    func deleteSelectedOrphans() async {
        let selected = orphanGroups.filter(\.isSelected)
        let appCount  = selected.count
        let fileCount = selected.reduce(0) { $0 + $1.files.count }
        let freed = await trashFiles(selected.flatMap(\.files))
        orphanGroups.removeAll { $0.isSelected }
        if freed > 0 { lastFreedBytes += freed }
        orphanDeletionResult = DeletionResult(appCount: appCount, fileCount: fileCount, freedBytes: freed)
    }

    private func trashFiles(_ files: [LinkedFile]) async -> Int64 {
        var freed: Int64 = 0
        for f in files {
            do {
                try FileManager.default.trashItem(at: URL(fileURLWithPath: f.path), resultingItemURL: nil)
                freed += f.sizeBytes
            } catch {}
        }
        return freed
    }

    // MARK: - Helpers

    private func itemSize(_ path: String) async -> Int64 {
        await Task.detached(priority: .utility) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            // Use -sk (kilobytes) instead of -sm (megabytes) so files under 1 MB
            // still report a non-zero size and the descending sort stays accurate.
            p.arguments = ["-c", "du -sk \"\(path)\" 2>/dev/null | awk '{print $1}'"]
            let pipe = Pipe()
            p.standardOutput = pipe; p.standardError = Pipe()
            try? p.run(); p.waitUntilExit()
            let raw = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "0"
            return (Int64(raw) ?? 0) * 1_024
        }.value
    }

    private func shell(_ cmd: String) async -> String {
        await Task.detached(priority: .utility) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = ["-c", cmd]
            let pipe = Pipe()
            p.standardOutput = pipe; p.standardError = Pipe()
            try? p.run(); p.waitUntilExit()
            return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        }.value
    }

    func fmtBytes(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        let mb = Double(bytes) / 1_048_576
        if gb >= 1.0 { return String(format: "%.1f GB", gb) }
        if mb >= 1.0 { return String(format: "%.0f MB", mb) }
        return "< 1 MB"
    }
}

// MARK: - View

enum CleanerScreen { case appList, appDetail(AppInfo) }

struct AppCleanerView: View {
    @StateObject private var engine = AppCleanerEngine()
    @State private var screen: CleanerScreen = .appList
    @State private var showDeleteLinkedConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            switch screen {
            case .appList:
                appListHeader
                Divider()
                appListContent
                Divider()
                appListFooter
            case .appDetail(let app):
                appDetailHeader(app: app)
                Divider()
                appDetailContent(app: app)
                Divider()
                appDetailFooter
            }
        }
        .alert("Delete Selected Files?", isPresented: $showDeleteLinkedConfirm) {
            Button("Move to Trash", role: .destructive) {
                Task { await engine.deleteSelectedLinked() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            let sel = engine.linkedFiles.filter(\.isSelected)
            Text("Move \(sel.count) item\(sel.count == 1 ? "" : "s") to Trash? The app may not work correctly afterwards.")
        }
    }

    // MARK: - App List

    private var appListHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: "app.badge.minus")
                .font(.title2).foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("App Cleaner").font(.headline)
                Text(engine.appsStatus).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            if engine.isLoadingApps { ProgressView().scaleEffect(0.75) }
            Button { Task { await engine.loadApps() } } label: {
                Label(engine.isLoadingApps ? "Loading…" : "Load Apps", systemImage: "arrow.clockwise")
            }
            .disabled(engine.isLoadingApps)
            .keyboardShortcut("r", modifiers: .command)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    @ViewBuilder
    private var appListContent: some View {
        if engine.apps.isEmpty && !engine.isLoadingApps {
            VStack(spacing: 14) {
                Image(systemName: "app.badge.minus").font(.system(size: 52)).foregroundColor(.secondary)
                Text("Press Load Apps to scan installed applications.")
                    .font(.title3).foregroundColor(.secondary)
                Text("Tap any app to find all its associated files across your Library.")
                    .font(.body).foregroundColor(Color(nsColor: .tertiaryLabelColor))
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(engine.apps) { app in
                    AppInfoRow(app: app)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            screen = .appDetail(app)
                            Task { await engine.deepScan(app: app) }
                        }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityLabel("\(app.name), \(engine.fmtBytes(app.sizeBytes)). Tap to find all associated files.")
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        }
    }

    private var appListFooter: some View {
        HStack {
            if engine.lastFreedBytes > 0 {
                Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                Text("Freed \(engine.fmtBytes(engine.lastFreedBytes)) — items moved to Trash.")
                    .font(.callout).fontWeight(.medium)
                Button("Dismiss") { engine.lastFreedBytes = 0 }.buttonStyle(.borderless).font(.caption)
            } else {
                Text(engine.apps.isEmpty ? "" : "Tap an app to deep scan it.")
                    .font(.callout).foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    // MARK: - App Detail

    private func appDetailHeader(app: AppInfo) -> some View {
        HStack(spacing: 12) {
            Button { screen = .appList } label: {
                Label("Back", systemImage: "chevron.left")
            }
            .buttonStyle(.borderless)

            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).font(.headline)
                if engine.isDeepScanning {
                    Text("Scanning for associated files…").font(.caption).foregroundColor(.secondary)
                } else {
                    let total = engine.linkedFiles.reduce(0) { $0 + $1.sizeBytes }
                    Text("\(engine.linkedFiles.count) item\(engine.linkedFiles.count == 1 ? "" : "s") found — \(engine.fmtBytes(total))")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            Spacer()
            if engine.isDeepScanning { ProgressView().scaleEffect(0.75) }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    @ViewBuilder
    private func appDetailContent(app: AppInfo) -> some View {
        if engine.isDeepScanning && engine.linkedFiles.isEmpty {
            VStack(spacing: 14) {
                ProgressView()
                Text("Finding files associated with \(app.name)…")
                    .font(.title3).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if engine.linkedFiles.isEmpty {
            VStack(spacing: 14) {
                Image(systemName: "checkmark.circle").font(.system(size: 48)).foregroundColor(.secondary)
                Text("No associated files found outside the app bundle.")
                    .font(.title3).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                // Select All / Deselect All bar
                HStack {
                    Button("Select All") {
                        for i in engine.linkedFiles.indices { engine.linkedFiles[i].isSelected = true }
                    }.buttonStyle(.borderless)
                    Button("Deselect All") {
                        for i in engine.linkedFiles.indices { engine.linkedFiles[i].isSelected = false }
                    }.buttonStyle(.borderless)
                    Spacer()
                    Text("Tip: keep the app bundle unless uninstalling.")
                        .font(.caption2).foregroundColor(.secondary)
                }
                .padding(.horizontal, 16).padding(.vertical, 6)
                .background(Color(nsColor: .controlBackgroundColor))
                Divider()

                List {
                    ForEach(engine.linkedFiles.indices, id: \.self) { i in
                        LinkedFileRow(
                            file: Binding(
                                get: { engine.linkedFiles[i] },
                                set: { engine.linkedFiles[i] = $0 }
                            ),
                            fmtBytes: engine.fmtBytes
                        )
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
    }

    private var appDetailFooter: some View {
        let selected = engine.linkedFiles.filter(\.isSelected)
        let totalBytes = selected.reduce(0) { $0 + $1.sizeBytes }
        return HStack(spacing: 10) {
            if selected.isEmpty {
                Text("Select files to delete. The app bundle is the .app entry.")
                    .font(.callout).foregroundColor(.secondary)
            } else {
                Image(systemName: "checkmark.circle.fill").foregroundColor(.accentColor)
                Text("\(selected.count) selected — \(engine.fmtBytes(totalBytes))")
                    .font(.callout).fontWeight(.medium)
            }
            Spacer()
            Button("Delete Selected…") { showDeleteLinkedConfirm = true }
                .buttonStyle(.borderedProminent).foregroundColor(.white)
                .disabled(selected.isEmpty)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

}

// MARK: - Orphan View (standalone tab)

struct OrphanView: View {
    @StateObject private var engine = AppCleanerEngine()
    @State private var showDeleteConfirm  = false
    @State private var showDeletionResult = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .alert("Delete Orphaned Files?", isPresented: $showDeleteConfirm) {
            Button("Move to Trash", role: .destructive) {
                Task {
                    await engine.deleteSelectedOrphans()
                    showDeletionResult = true
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            let sel = engine.orphanGroups.filter(\.isSelected)
            let fileCount = sel.reduce(0) { $0 + $1.files.count }
            let bytes = sel.reduce(0) { $0 + $1.totalBytes }
            Text("Move \(fileCount) file\(fileCount == 1 ? "" : "s") from \(sel.count) deleted app\(sel.count == 1 ? "" : "s") to Trash (\(engine.fmtBytes(bytes)))?")
        }
        .alert("Deletion Complete", isPresented: $showDeletionResult) {
            Button("OK") { engine.orphanDeletionResult = nil }
        } message: {
            if let r = engine.orphanDeletionResult {
                Text("Moved \(r.fileCount) file\(r.fileCount == 1 ? "" : "s") from \(r.appCount) app\(r.appCount == 1 ? "" : "s") to Trash.\n\(engine.fmtBytes(r.freedBytes)) freed. You can recover anything from the Trash if needed.")
            } else {
                Text("Deletion complete.")
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "questionmark.folder")
                .font(.title2).foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Orphaned Files").font(.headline)
                Text(engine.isOrphanScanning
                     ? engine.orphanStatus
                     : (engine.orphanStatus.isEmpty ? "Scan to find files left behind by deleted apps." : engine.orphanStatus))
                    .font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            if engine.isOrphanScanning { ProgressView().scaleEffect(0.75) }
            Button { Task { await engine.findOrphans() } } label: {
                Label(engine.isOrphanScanning ? "Scanning…" : "Scan", systemImage: "arrow.clockwise")
            }
            .disabled(engine.isOrphanScanning)
            .keyboardShortcut("r", modifiers: .command)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    @ViewBuilder
    private var content: some View {
        if engine.orphanGroups.isEmpty && !engine.isOrphanScanning {
            VStack(spacing: 14) {
                Image(systemName: engine.orphanStatus.isEmpty ? "questionmark.folder" : "checkmark.circle")
                    .font(.system(size: 52)).foregroundColor(.secondary)
                Text(engine.orphanStatus.isEmpty
                     ? "Press Scan to search for files left behind by deleted apps."
                     : engine.orphanStatus)
                    .font(.title3).foregroundColor(.secondary).multilineTextAlignment(.center)
                if engine.orphanStatus.isEmpty {
                    Text("This checks your Library folders for data from apps that are no longer installed.")
                        .font(.body).foregroundColor(Color(nsColor: .tertiaryLabelColor))
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(32)
        } else if engine.isOrphanScanning && engine.orphanGroups.isEmpty {
            VStack(spacing: 14) {
                ProgressView()
                Text(engine.orphanStatus).font(.title3).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                HStack {
                    Button("Select All") {
                        for i in engine.orphanGroups.indices { engine.orphanGroups[i].isSelected = true }
                    }.buttonStyle(.borderless)
                    Button("Deselect All") {
                        for i in engine.orphanGroups.indices { engine.orphanGroups[i].isSelected = false }
                    }.buttonStyle(.borderless)
                    Spacer()
                    Text("Each row = one deleted app. Expand to see its files.")
                        .font(.caption2).foregroundColor(.secondary)
                }
                .padding(.horizontal, 16).padding(.vertical, 6)
                .background(Color(nsColor: .controlBackgroundColor))
                Divider()
                List {
                    ForEach(engine.orphanGroups.indices, id: \.self) { i in
                        OrphanGroupRow(
                            group: Binding(
                                get: { engine.orphanGroups[i] },
                                set: { engine.orphanGroups[i] = $0 }
                            ),
                            fmtBytes: engine.fmtBytes
                        )
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
    }

    private var footer: some View {
        let selected = engine.orphanGroups.filter(\.isSelected)
        let fileCount = selected.reduce(0) { $0 + $1.files.count }
        let totalBytes = selected.reduce(0) { $0 + $1.totalBytes }
        return HStack(spacing: 10) {
            if engine.lastFreedBytes > 0 {
                Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                Text("Freed \(engine.fmtBytes(engine.lastFreedBytes)) — moved to Trash.")
                    .font(.callout).fontWeight(.medium)
                Button("Dismiss") { engine.lastFreedBytes = 0 }.buttonStyle(.borderless).font(.caption)
            } else if selected.isEmpty {
                Text(engine.orphanGroups.isEmpty ? "" : "Select apps to remove all their leftover files.")
                    .font(.callout).foregroundColor(.secondary)
            } else {
                Image(systemName: "checkmark.circle.fill").foregroundColor(.accentColor)
                Text("\(selected.count) app\(selected.count == 1 ? "" : "s") selected — \(fileCount) files, \(engine.fmtBytes(totalBytes))")
                    .font(.callout).fontWeight(.medium)
            }
            Spacer()
            Button("Delete Selected…") { showDeleteConfirm = true }
                .buttonStyle(.borderedProminent).foregroundColor(.white)
                .disabled(selected.isEmpty)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}

// MARK: - Row Views

struct AppInfoRow: View {
    let app: AppInfo
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "app.fill")
                .foregroundColor(.accentColor)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).fontWeight(.medium)
                Text(app.bundleID).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(formatB(app.sizeBytes)).fontWeight(.semibold).monospacedDigit()
                Text("tap to deep scan").font(.caption2).foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func formatB(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        let mb = Double(bytes) / 1_048_576
        if gb >= 1.0 { return String(format: "%.1f GB", gb) }
        if mb >= 1.0 { return String(format: "%.0f MB", mb) }
        return "< 1 MB"
    }
}

struct LinkedFileRow: View {
    @Binding var file: LinkedFile
    let fmtBytes: (Int64) -> String

    var body: some View {
        HStack(spacing: 10) {
            Toggle(isOn: $file.isSelected) { EmptyView() }
                .toggleStyle(.checkbox).labelsHidden().frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(URL(fileURLWithPath: file.path).lastPathComponent)
                    .fontWeight(.medium).lineLimit(1)
                Text(file.category)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(file.path
                    .replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                    .font(.caption2)
                    .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Text(fmtBytes(file.sizeBytes))
                .fontWeight(.semibold)
                .monospacedDigit()
                .foregroundColor(file.sizeBytes > 500_000_000 ? .orange : .primary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { file.isSelected.toggle() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(URL(fileURLWithPath: file.path).lastPathComponent), \(file.category), \(fmtBytes(file.sizeBytes)).")
        .accessibilityValue(file.isSelected ? "checked" : "unchecked")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Toggle selection") { file.isSelected.toggle() }
    }
}

struct OrphanGroupRow: View {
    @Binding var group: OrphanGroup
    let fmtBytes: (Int64) -> String

    var body: some View {
        // Checkbox lives outside the DisclosureGroup so the disclosure arrow
        // cannot intercept its clicks. Each child has its own accessibility
        // element so VoiceOver can reach the checkbox independently.
        HStack(alignment: .top, spacing: 6) {
            Toggle(isOn: $group.isSelected) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .frame(width: 18)
                .padding(.top, 4)
                .accessibilityLabel("Select \(group.displayName)")
                .accessibilityHint("\(group.files.count) files, \(fmtBytes(group.totalBytes)). Double-tap to toggle.")
                .accessibilityValue(group.isSelected ? "checked" : "unchecked")

            DisclosureGroup {
                ForEach(group.files) { file in
                    HStack(spacing: 8) {
                        Text(URL(fileURLWithPath: file.path).lastPathComponent)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text(file.category)
                            .font(.caption2)
                            .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                            .frame(width: 90, alignment: .trailing)
                        Text(fmtBytes(file.sizeBytes))
                            .font(.caption).monospacedDigit()
                            .foregroundColor(.secondary)
                            .frame(width: 70, alignment: .trailing)
                    }
                    .padding(.vertical, 2)
                    .accessibilityLabel("\(URL(fileURLWithPath: file.path).lastPathComponent), \(file.category), \(fmtBytes(file.sizeBytes))")
                }
            } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        // Primary label — display name and, if different, the raw key
                        HStack(spacing: 6) {
                            Text(group.displayName).fontWeight(.medium)
                            if group.displayName != group.key {
                                Text("(\(group.key))")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        // File count and categories
                        Text("\(group.files.count) file\(group.files.count == 1 ? "" : "s") — \(group.locationSummary)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        // Actual paths — this is the key context clue
                        ForEach(group.pathHints, id: \.self) { hint in
                            Text(hint)
                                .font(.caption2)
                                .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    Spacer()
                    Text(fmtBytes(group.totalBytes))
                        .fontWeight(.semibold).monospacedDigit()
                        .foregroundColor(group.totalBytes > 500_000_000 ? .orange : .primary)
                }
            }
        }
        .padding(.vertical, 3)
    }
}
