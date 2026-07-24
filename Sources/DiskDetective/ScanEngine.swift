import Foundation
import AppKit
import SwiftUI

// MARK: - Model

struct ScanItem: Identifiable, Codable {
    var id = UUID()
    var isSelected: Bool = false
    let category: String
    let name: String
    let detail: String
    let path: String
    let sizeBytes: Int64
    let actionType: ActionType

    enum ActionType: Codable {
        case deleteDirectory
        case deleteFile
        case shellCommand(String)      // opens Terminal — only for commands needing sudo
        case backgroundCommand(String) // runs silently inside the app, no Terminal needed
        case openInFinder              // opens Finder for manual review
        case emptyTrash
    }

    var sizeString: String {
        let gb = Double(sizeBytes) / 1_073_741_824
        let mb = Double(sizeBytes) / 1_048_576
        if gb >= 1.0 { return String(format: "%.1f GB", gb) }
        if mb >= 1.0 { return String(format: "%.0f MB", mb) }
        return "< 1 MB"
    }

    var sizeColor: Color {
        if sizeBytes > 2_000_000_000 { return .red }
        if sizeBytes > 500_000_000  { return .orange }
        return .primary
    }

    var methodLabel: String {
        switch actionType {
        case .deleteDirectory, .deleteFile, .emptyTrash: return "Auto-delete"
        case .backgroundCommand: return "Auto-delete"
        case .shellCommand: return "Opens Terminal"
        case .openInFinder: return "Opens Finder"
        }
    }

    var methodColor: Color {
        switch actionType {
        case .deleteDirectory, .deleteFile, .emptyTrash: return .green
        case .backgroundCommand: return .green
        case .shellCommand: return .orange
        case .openInFinder: return .blue
        }
    }

    var displayPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.replacingOccurrences(of: home, with: "~")
    }
}

// MARK: - Scan summary

struct ScanSummary {
    let duration: TimeInterval
    let itemCount: Int
    let totalBytes: Int64

    var durationString: String {
        let m = Int(duration) / 60
        let s = Int(duration) % 60
        return m > 0 ? "\(m)m \(s)s" : "\(s)s"
    }
}

// MARK: - Engine

@MainActor
class ScanEngine: ObservableObject {
    @Published var items: [ScanItem] = []
    @Published var isScanning = false
    @Published var scanStatus = "Ready to scan"
    @Published var scanComplete = false
    @Published var lastFreedBytes: Int64 = 0
    @Published var scanStartDate: Date? = nil
    @Published var completionSummary: ScanSummary? = nil
    /// Progress through the scan's phases (known paths, downloads, node_modules,
    /// etc.), shown as "step N of M" — the scan doesn't count individual files
    /// up front, so phase-level progress is what's actually knowable.
    @Published var completedPhases: Int = 0
    @Published var totalPhases: Int = 0

    private let home = FileManager.default.homeDirectoryForCurrentUser.path
    private static let cacheKey = "diskDetective"
    private var scanTask: Task<Void, Never>?

    init() {
        loadAreaDurations()
        guard let cached = ScanCache.load([ScanItem].self, key: Self.cacheKey) else { return }
        let existing = cached.payload.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else { return }
        items = existing
        scanComplete = true
        scanStatus = "Results from \(ScanCache.ageLabel(cached.savedAt)) — press Scan Now to refresh."
    }

    /// Starts a scan in the background and returns immediately — the actual
    /// work runs in `scanTask`, which `stopScan()` cancels.
    func startScan(
        includeKnown: Bool = true,
        includeRecent: Bool = false,
        recentHours: Int = 24,
        includeTop: Bool = false
    ) {
        scanTask?.cancel()
        scanTask = Task { [weak self] in
            await self?.runScan(
                includeKnown: includeKnown,
                includeRecent: includeRecent,
                recentHours: recentHours,
                includeTop: includeTop
            )
        }
    }

    /// Cancels the in-progress scan. Individual `du` measurements already
    /// running are terminated (see FileSize.duSizeInKB), not left to finish.
    func stopScan() {
        guard isScanning else { return }
        scanTask?.cancel()
        isScanning = false
        scanStatus = "Scan stopped — \(items.count) item\(items.count == 1 ? "" : "s") found before stopping."
        Announcer.announce("Scan stopped.", priority: .high)
    }

    private func runScan(
        includeKnown: Bool,
        includeRecent: Bool,
        recentHours: Int,
        includeTop: Bool
    ) async {
        isScanning = true
        scanComplete = false
        completionSummary = nil
        items = []
        scanStartDate = Date()
        Announcer.announce("Scan started.", priority: .medium)

        // Each area is a named unit of work. Unlike before, they run
        // concurrently: while one area is waiting on a `find`/`du`/`mdfind`
        // process, the others are already running theirs. Total scan time
        // becomes the slowest single area instead of the sum of them all.
        // (The methods are @MainActor, so their Swift bodies interleave on the
        // main actor at each `await`, but the actual subprocess work overlaps.)
        struct Area { let name: String; let run: () async -> [ScanItem] }
        var areas: [Area] = []
        if includeKnown {
            areas.append(Area(name: "known locations", run: { await self.scanKnownPaths() }))
            areas.append(Area(name: "Downloads", run: { await self.scanDownloadItems() }))
            areas.append(Area(name: "SDK & updater caches", run: { await self.scanSDKCaches() }))
            areas.append(Area(name: "developer folders", run: { await self.scanDevFolders() }))
        }
        if includeRecent {
            areas.append(Area(name: "recently written files", run: { await self.scanRecentFiles(hours: recentHours) }))
        }
        if includeTop {
            areas.append(Area(name: "largest files", run: { await self.scanTopFiles() }))
        }

        totalPhases = areas.count
        completedPhases = 0
        let typical = typicalTotalEstimate(for: areas.map(\.name))
        scanStatus = areas.isEmpty
            ? "Nothing selected to scan."
            : "Scanning \(areas.count) area\(areas.count == 1 ? "" : "s")…\(typical.map { " (usually about \($0))" } ?? "")"

        await withTaskGroup(of: (name: String, items: [ScanItem], duration: TimeInterval).self) { group in
            for area in areas {
                group.addTask {
                    let start = Date()
                    let batch = await area.run()
                    return (area.name, batch, Date().timeIntervalSince(start))
                }
            }
            for await finished in group {
                if Task.isCancelled { continue }   // drain the group, but stop updating UI
                items = (items + finished.items).sorted { $0.sizeBytes > $1.sizeBytes }
                completedPhases += 1
                areaDurations[finished.name] = finished.duration
                let count = items.count
                scanStatus = "Finished \(finished.name) — \(completedPhases) of \(totalPhases) area\(totalPhases == 1 ? "" : "s"), \(count) item\(count == 1 ? "" : "s") so far"
                Announcer.announceThrottled(scanStatus, key: "diskDetectiveScan")
            }
        }

        guard !Task.isCancelled else {
            // stopScan() already set isScanning/scanStatus/announced.
            return
        }

        saveAreaDurations()

        let duration   = Date().timeIntervalSince(scanStartDate ?? Date())
        let totalBytes = items.reduce(0) { $0 + $1.sizeBytes }
        completionSummary = ScanSummary(
            duration: duration,
            itemCount: items.count,
            totalBytes: totalBytes
        )

        isScanning = false
        scanComplete = true
        scanStatus = "\(items.count) item\(items.count == 1 ? "" : "s") found"
        NSSound(named: NSSound.Name("Glass"))?.play()
        HistoryEngine.shared.record()
        ScanCache.save(items, key: Self.cacheKey)
        Announcer.announce(
            "Scan complete. \(items.count) item\(items.count == 1 ? "" : "s") found, \(formatBytesForAnnouncement(totalBytes)) recoverable.",
            priority: .high
        )
    }

    // MARK: - Per-area timing (drives the "usually about Ns" estimate)

    /// Wall-clock duration of each named area on the most recent scans, so the
    /// next scan can tell the user roughly how long to expect.
    @Published var areaDurations: [String: TimeInterval] = [:]
    private static let areaDurationsKey = "diskDetective.areaDurations"

    private func loadAreaDurations() {
        guard let dict = UserDefaults.standard.dictionary(forKey: Self.areaDurationsKey) as? [String: Double] else { return }
        areaDurations = dict
    }

    private func saveAreaDurations() {
        UserDefaults.standard.set(areaDurations, forKey: Self.areaDurationsKey)
    }

    /// Because areas run in parallel, the expected wall-clock time is roughly
    /// the slowest area, not the sum — so the estimate is the max of the known
    /// per-area durations. Returns nil until at least one full scan has run.
    private func typicalTotalEstimate(for names: [String]) -> String? {
        let known = names.compactMap { areaDurations[$0] }
        guard let slowest = known.max(), slowest >= 1 else { return nil }
        let seconds = Int(slowest.rounded())
        return seconds < 60 ? "\(seconds) seconds" : "\(seconds / 60) min \(seconds % 60) sec"
    }

    private func formatBytesForAnnouncement(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        let mb = Double(bytes) / 1_048_576
        if gb >= 1.0 { return String(format: "%.1f gigabytes", gb) }
        if mb >= 1.0 { return String(format: "%.0f megabytes", mb) }
        return "less than 1 megabyte"
    }

    // MARK: - Scan: Known Paths

    private func scanKnownPaths() async -> [ScanItem] {
        typealias Check = (cat: String, name: String, detail: String, path: String, action: ScanItem.ActionType)
        typealias Sized = (check: Check, size: Int64)

        let checks: [Check] = [
            ("Trash",
             "Trash",
             "Files waiting to be permanently deleted",
             "\(home)/.Trash",
             .emptyTrash),

            ("Xcode",
             "DerivedData (build cache)",
             "Safe to delete — Xcode rebuilds automatically on next build",
             "\(home)/Library/Developer/Xcode/DerivedData",
             .deleteDirectory),

            ("Xcode",
             "CoreSimulator Devices",
             "Unavailable iOS/iPad simulator devices — removed silently, Xcode recreates on demand",
             "\(home)/Library/Developer/CoreSimulator/Devices",
             .backgroundCommand("xcrun simctl delete unavailable 2>/dev/null")),

            ("Xcode",
             "iOS DeviceSupport",
             "Device symbols for each iOS version — safe to delete old versions, Xcode re-downloads if needed",
             "\(home)/Library/Developer/Xcode/iOS DeviceSupport",
             .deleteDirectory),

            ("Xcode",
             "Xcode Archives",
             "App archive builds — moved to Trash, recoverable if needed",
             "\(home)/Library/Developer/Xcode/Archives",
             .deleteDirectory),

            ("App Caches",
             "User App Caches",
             "Cached data for all apps — safe to delete, apps rebuild caches on next launch",
             "\(home)/Library/Caches",
             .deleteDirectory),

            // ── Local language models: deliberate installs, review before
            //    deleting. Re-download from the source app to restore. ──────
            ("LLM Models",
             "Ollama models",
             "Local language models — re-download with ollama pull if needed",
             "\(home)/.ollama/models",
             .deleteDirectory),

            ("LLM Models",
             "LM Studio models",
             "Local language models — re-download in LM Studio if needed",
             "\(home)/.cache/lm-studio/models",
             .deleteDirectory),

            ("LLM Models",
             "LM Studio models (Application Support)",
             "Local language models — re-download in LM Studio if needed",
             "\(home)/Library/Application Support/LM Studio/models",
             .deleteDirectory),

            ("LLM Models",
             "Hugging Face cache",
             "Downloaded models and datasets — re-downloaded on next use",
             "\(home)/.cache/huggingface",
             .deleteDirectory),

            ("LLM Models",
             "Jan models",
             "Local language models — re-download in Jan if needed",
             "\(home)/jan/models",
             .deleteDirectory),

            ("LLM Models",
             "GPT4All models",
             "Local language models — re-download in GPT4All if needed",
             "\(home)/Library/Application Support/nomic.ai/GPT4All",
             .deleteDirectory),

            ("LLM Models",
             "Meetily models",
             "Local Whisper models — re-downloaded by Meetily if needed",
             "\(home)/Library/Application Support/com.meetily.ai/models",
             .deleteDirectory),

            ("LLM Models",
             "Aiko models",
             "Local transcription models — re-downloaded by Aiko if needed",
             "\(home)/Library/Application Support/co.apptorium.Aiko",
             .deleteDirectory),

            ("LLM Models",
             "Whisper Transcription models",
             "Local transcription models — re-downloaded on next use",
             "\(home)/Library/Application Support/com.apple.whispertranscription",
             .deleteDirectory),

            // ── Claude data that needs review (NOT in one-click Cleanup:
            //    sessions and transcripts are your data, not cache). ────────
            ("AI Data",
             "Claude agent & cowork sessions",
             "Saved agent session data — review before deleting",
             "\(home)/Library/Application Support/Claude/local-agent-mode-sessions",
             .deleteDirectory),

            ("AI Data",
             "Claude Code project transcripts",
             "Conversation history for Claude Code projects — review before deleting",
             "\(home)/.claude/projects",
             .deleteDirectory),

            ("AI Data",
             "Claude VM sandbox bundle",
             "Claude Code virtual machine — rebuilt automatically, a few minutes on next use",
             "\(home)/Library/Application Support/Claude/vm_bundles/claudevm.bundle",
             .deleteDirectory),

            ("Logs",
             "User Log Files",
             "Application log files — safe to delete",
             "\(home)/Library/Logs",
             .deleteDirectory),

            ("Logs",
             "System Log Files",
             "System-level log files — safe to delete",
             "/Library/Logs",
             .deleteDirectory),

            // Downloads is scanned per-file in scanDownloadItems() instead

            ("Games",
             "Steam Library",
             "Steam game installs — moved to Trash (reinstall from Steam if needed)",
             "\(home)/Library/Application Support/Steam/steamapps/common",
             .deleteDirectory),

            ("Games",
             "Battle.net Data",
             "Blizzard games and launcher data — moved to Trash",
             "\(home)/Library/Application Support/Battle.net",
             .deleteDirectory),

            ("Microsoft",
             "Teams Cache",
             "Teams web cache — safe to delete when Teams is not running",
             "\(home)/Library/Application Support/Microsoft/Teams/Cache",
             .deleteDirectory),

            ("Microsoft",
             "Teams Code Cache",
             "Teams compiled code cache",
             "\(home)/Library/Application Support/Microsoft/Teams/Code Cache",
             .deleteDirectory),

            ("Microsoft",
             "Outlook Data",
             "Outlook email database and cache — moved to Trash (Outlook will re-sync from server)",
             "\(home)/Library/Application Support/com.microsoft.Outlook",
             .deleteDirectory),

            ("Browser Caches",
             "Brave — Web Cache",
             "Brave browser web cache — safe to delete, rebuilds as you browse",
             "\(home)/Library/Application Support/BraveSoftware/Brave-Browser/Default/Cache",
             .deleteDirectory),

            ("Browser Caches",
             "Brave — Code Cache",
             "Brave compiled JavaScript cache",
             "\(home)/Library/Application Support/BraveSoftware/Brave-Browser/Default/Code Cache",
             .deleteDirectory),

            ("Browser Caches",
             "Chrome — Web Cache",
             "Chrome browser web cache — safe to delete",
             "\(home)/Library/Application Support/Google/Chrome/Default/Cache",
             .deleteDirectory),

            ("Browser Caches",
             "Chrome — Code Cache",
             "Chrome compiled JavaScript cache",
             "\(home)/Library/Application Support/Google/Chrome/Default/Code Cache",
             .deleteDirectory),

            ("Browser Caches",
             "Safari — Cache",
             "Safari web cache — safe to delete",
             "\(home)/Library/Caches/com.apple.Safari",
             .deleteDirectory),

            ("Browser Caches",
             "Arc — Cache",
             "Arc browser cache",
             "\(home)/Library/Application Support/Arc/User Data/Default/Cache",
             .deleteDirectory),

            ("Browser Caches",
             "Firefox — Cache",
             "Firefox web cache — safe to delete, Firefox rebuilds as you browse",
             "\(home)/Library/Caches/Firefox",
             .deleteDirectory),

            // ── Adobe ─────────────────────────────────────────────────────
            ("Adobe",
             "Adobe App Caches",
             "Cached data for all Adobe apps (Photoshop, Illustrator, Premiere etc.) — safe to delete, rebuilt on next launch",
             "\(home)/Library/Caches/Adobe",
             .deleteDirectory),

            ("Adobe",
             "Adobe Media Cache Files",
             "Transcoded media cached by Premiere Pro and After Effects — can be very large, safe to delete, rebuilt when you reopen the project",
             "\(home)/Library/Application Support/Adobe/Media Cache Files",
             .deleteDirectory),

            ("Adobe",
             "Adobe Media Cache Metadata",
             "Index metadata for Adobe media cache — safe to delete alongside Media Cache Files",
             "\(home)/Library/Application Support/Adobe/Media Cache",
             .deleteDirectory),

            ("Adobe",
             "Adobe Creative Cloud Logs",
             "Creative Cloud Desktop app logs — safe to delete",
             "\(home)/Library/Logs/Adobe",
             .deleteDirectory),

            // ── Communication apps ────────────────────────────────────────
            ("Communication",
             "Discord — Cache",
             "Discord web cache — safe to delete when Discord is not running",
             "\(home)/Library/Application Support/Discord/Cache",
             .deleteDirectory),

            ("Communication",
             "Discord — Code Cache",
             "Discord compiled JavaScript cache — safe to delete",
             "\(home)/Library/Application Support/Discord/Code Cache",
             .deleteDirectory),

            ("Communication",
             "Discord — GPU Cache",
             "Discord GPU shader cache — safe to delete",
             "\(home)/Library/Application Support/Discord/GPUCache",
             .deleteDirectory),

            ("Communication",
             "Slack — Cache",
             "Slack web cache — safe to delete when Slack is not running",
             "\(home)/Library/Application Support/Slack/Cache",
             .deleteDirectory),

            ("Communication",
             "Slack — Code Cache",
             "Slack compiled JavaScript cache — safe to delete",
             "\(home)/Library/Application Support/Slack/Code Cache",
             .deleteDirectory),

            ("Zoom",
             "Zoom Recordings",
             "Local meeting recordings — moved to Trash so you can recover if needed",
             "\(home)/Documents/Zoom",
             .deleteDirectory),

            ("Zoom",
             "Zoom App Data",
             "Zoom cache and app data — safe to delete, Zoom recreates on next launch",
             "\(home)/Library/Application Support/zoom.us",
             .deleteDirectory),

            ("Cloud Storage",
             "Dropbox (local files)",
             "Local Dropbox copies — files remain safely in your Dropbox cloud account",
             "\(home)/Dropbox",
             .deleteDirectory),

            ("Cloud Storage",
             "iCloud Drive (local copies)",
             "Local iCloud Drive copies — files remain in iCloud and re-download on demand",
             "\(home)/Library/Mobile Documents",
             .deleteDirectory),

            // ── Developer package-manager caches ──────────────────────────

            ("Dev Caches",
             "Homebrew Cache",
             "Old package downloads cached by Homebrew — safe to delete, Homebrew re-downloads if needed",
             "\(home)/Library/Caches/Homebrew",
             .deleteDirectory),

            ("Dev Caches",
             "npm Cache",
             "npm package download cache — safe to delete, npm re-downloads as needed",
             "\(home)/.npm",
             .deleteDirectory),

            ("Dev Caches",
             "Yarn Cache",
             "Yarn package download cache — safe to delete",
             "\(home)/Library/Caches/Yarn",
             .deleteDirectory),

            ("Dev Caches",
             "pip Cache",
             "Python pip package download cache — safe to delete",
             "\(home)/Library/Caches/pip",
             .deleteDirectory),

            ("Dev Caches",
             "pnpm Store",
             "pnpm global package store — safe to delete, pnpm re-downloads on next install",
             "\(home)/Library/pnpm/store",
             .deleteDirectory),

            ("Dev Caches",
             "CocoaPods Cache",
             "CocoaPods downloaded pod cache — safe to delete",
             "\(home)/Library/Caches/CocoaPods",
             .deleteDirectory),

            ("Dev Caches",
             "Gradle Cache",
             "Gradle build dependency cache — safe to delete, Gradle re-downloads on next build",
             "\(home)/.gradle/caches",
             .deleteDirectory),

            // ── Additional package manager caches ─────────────────────────

            ("Dev Caches",
             "Cargo Registry (Rust)",
             "Rust crate source downloads cached by Cargo — can grow to several GB, safe to delete, Cargo re-downloads on next build",
             "\(home)/.cargo/registry",
             .deleteDirectory),

            ("Dev Caches",
             "Cargo Git Checkouts (Rust)",
             "Rust git-sourced crate checkouts cached by Cargo — safe to delete",
             "\(home)/.cargo/git",
             .deleteDirectory),

            ("Dev Caches",
             "Go Module Cache",
             "Go module source downloads cached by the Go toolchain — safe to delete, Go re-downloads on next build",
             "\(home)/go/pkg/mod",
             .deleteDirectory),

            ("Dev Caches",
             "Maven Local Repository",
             "Java/Kotlin dependencies cached locally by Maven — safe to delete, Maven re-downloads on next build",
             "\(home)/.m2/repository",
             .deleteDirectory),

            ("Dev Caches",
             "Dart / Flutter Pub Cache",
             "Dart and Flutter package downloads cached by pub — safe to delete, pub re-downloads on next flutter pub get",
             "\(home)/.pub-cache",
             .deleteDirectory),

            ("Dev Caches",
             "Ruby Gems",
             "Globally installed Ruby gems — safe to delete, reinstall with: gem install",
             "\(home)/.gem",
             .deleteDirectory),

            ("Dev Caches",
             "NuGet Packages (.NET)",
             ".NET NuGet package cache — safe to delete, NuGet re-downloads on next build",
             "\(home)/.nuget/packages",
             .deleteDirectory),

            ("Dev Caches",
             "Swift Package Manager Cache",
             "Swift PM downloaded source packages — safe to delete, SPM re-fetches on next build",
             "\(home)/.swiftpm",
             .deleteDirectory),

            ("Dev Caches",
             "Composer Cache (PHP)",
             "PHP Composer package download cache — safe to delete",
             "\(home)/.composer/cache",
             .deleteDirectory),

            // ── Xcode: Simulator runtimes ─────────────────────────────────

            ("Xcode",
             "Simulator Runtimes",
             "Full OS images for each iOS/macOS simulator version — each is 5–10 GB, Xcode re-downloads if needed",
             "\(home)/Library/Developer/CoreSimulator/Runtimes",
             .deleteDirectory),

            // ── Docker ───────────────────────────────────────────────────

            ("Docker",
             "Docker Data",
             "Docker container images and volumes — moved to Trash",
             "\(home)/Library/Group Containers/group.com.docker",
             .deleteDirectory),

            // ── App State & WebKit ───────────────────────────────────────

            ("System",
             "App Window Restore State",
             "Saved window layouts for every app — safe to delete, apps recreate on next launch",
             "\(home)/Library/Saved Application State",
             .deleteDirectory),

            ("App Caches",
             "WebKit Data Stores",
             "Local databases for Electron and web-based apps (Slack, Notion, Figma, Linear) — safe to delete when apps are not running",
             "\(home)/Library/WebKit",
             .deleteDirectory),

            // ── Mail & Messages ──────────────────────────────────────────

            ("Mail & Messages",
             "Mail Downloads & Attachments",
             "Email attachments cached locally — originals remain on your mail server",
             "\(home)/Library/Mail",
             .deleteDirectory),

            ("Mail & Messages",
             "iMessage Attachments",
             "Photos and files received in Messages — moved to Trash",
             "\(home)/Library/Messages/Attachments",
             .deleteDirectory),

            // ── System ───────────────────────────────────────────────────

            ("System",
             "Hibernate Sleep Image",
             "A copy of your RAM written to disk when the Mac hibernates. Exactly the size of your RAM. macOS recreates it automatically",
             "/private/var/vm/sleepimage",
             .shellCommand("sudo rm -f /private/var/vm/sleepimage && echo 'Sleep image deleted. macOS will recreate it on next hibernate.'")),
        ]

        // Filter to paths that exist, then size them all in one bounded batch.
        scanStatus = "Checking known locations…"
        let existing = checks.filter { FileManager.default.fileExists(atPath: $0.path) }
        let sizes = await FileSize.allocatedSizes(ofPaths: existing.map(\.path))

        var result: [ScanItem] = []
        for check in existing {
            let size = sizes[check.path] ?? 0
            guard size > 5_000_000 else { continue }
            result.append(ScanItem(
                category: check.cat, name: check.name, detail: check.detail,
                path: check.path, sizeBytes: size, actionType: check.action
            ))
        }

        // iOS Backups — one entry per backup device
        scanStatus = "Checking iOS backups…"
        let backupBase = "\(home)/Library/Application Support/MobileSync/Backup"
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: backupBase) {
            let backupPaths = contents.map { "\(backupBase)/\($0)" }
            let backupSizes = await FileSize.allocatedSizes(ofPaths: backupPaths)
            for backup in contents {
                let p = "\(backupBase)/\(backup)"
                let size = backupSizes[p] ?? 0
                guard size > 10_000_000 else { continue }
                result.append(ScanItem(
                    category: "iOS Backups",
                    name: "iPhone/iPad Backup (\(backup.prefix(8))…)",
                    detail: "Local device backup — moved to Trash, iTunes/Finder will create a new one when you next sync",
                    path: p,
                    sizeBytes: size,
                    actionType: .deleteDirectory
                ))
            }
        }

        // Installed apps — largest 60 apps ≥ 50 MB. This is a "your biggest
        // apps, in case you want to uninstall one" list, NOT a junk list, so
        // the wording makes clear nothing here is being recommended for
        // deletion. Sizing is one parallel du batch.
        //
        // "Last used" no longer comes from Spotlight's kMDItemLastUsedDate —
        // macOS returns null for it even for apps in daily use (Apple
        // restricted it), which made every app read as "never opened". We
        // estimate it instead from the folders an app writes to when it runs
        // (its container, preferences, saved state, support data).
        scanStatus = "Scanning /Applications…"
        var appPaths: [String] = []
        for dir in ["/Applications", "\(home)/Applications"] {
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
            for entry in entries where entry.hasSuffix(".app") {
                appPaths.append("\(dir)/\(entry)")
            }
        }
        let appSizes = await FileSize.allocatedSizes(ofPaths: appPaths)
        let dfDisplay = DateFormatter(); dfDisplay.dateStyle = .medium; dfDisplay.timeStyle = .none
        let topApps = appPaths
            .compactMap { path -> (path: String, size: Int64)? in
                let size = appSizes[path] ?? 0
                return size >= 50_000_000 ? (path, size) : nil
            }
            .sorted { $0.size > $1.size }
            .prefix(60)
        let recentlyUsedCutoff = Date().addingTimeInterval(-14 * 24 * 3600)
        for app in topApps {
            let appURL = URL(fileURLWithPath: app.path)
            let name = appURL.deletingPathExtension().lastPathComponent
            let bundleID = Bundle(url: appURL)?.bundleIdentifier
            let lastUsed = lastUsedEstimate(bundleID: bundleID, appName: name)

            let detail: String
            if let used = lastUsed, used >= recentlyUsedCutoff {
                detail = "Recently used (around \(dfDisplay.string(from: used))) — keep it unless you're sure you want to uninstall."
            } else if let used = lastUsed {
                detail = "Last used around \(dfDisplay.string(from: used)) — select only if you want to uninstall this app."
            } else {
                detail = "One of your installed apps — select only if you want to uninstall it."
            }
            result.append(ScanItem(
                category: "Installed Apps",
                name: name,
                detail: detail,
                path: app.path,
                sizeBytes: app.size,
                actionType: .deleteDirectory
            ))
        }

        // Firefox profile caches — profile name is random so we enumerate them
        scanStatus = "Checking Firefox profiles…"
        let ffBase = "\(home)/Library/Application Support/Firefox/Profiles"
        if let profiles = try? FileManager.default.contentsOfDirectory(atPath: ffBase) {
            let cachePaths = profiles.map { "\(ffBase)/\($0)/cache2" }
                .filter { FileManager.default.fileExists(atPath: $0) }
            let cacheSizes = await FileSize.allocatedSizes(ofPaths: cachePaths)
            for profile in profiles {
                let cachePath = "\(ffBase)/\(profile)/cache2"
                guard let size = cacheSizes[cachePath] else { continue }
                guard size > 5_000_000 else { continue }
                result.append(ScanItem(
                    category: "Browser Caches",
                    name: "Firefox — Profile Cache",
                    detail: "Firefox HTTP cache for profile \(profile.prefix(12))… — safe to delete, rebuilds as you browse",
                    path: cachePath,
                    sizeBytes: size,
                    actionType: .deleteDirectory
                ))
            }
        }

        // .DS_Store counting moved into scanDevFolders() — it's found in the
        // same single home-folder walk as node_modules and friends, instead of
        // a separate unbounded `find … | wc -l` pass.

        // Time Machine local snapshots
        scanStatus = "Checking Time Machine snapshots…"
        let tmOut = await shell("tmutil listlocalsnapshots / 2>/dev/null")
        let tmLines = tmOut.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if !tmLines.isEmpty {
            result.append(ScanItem(
                category: "Time Machine",
                name: "\(tmLines.count) Local Snapshot\(tmLines.count == 1 ? "" : "s")",
                detail: "Hidden APFS snapshots on your SSD — macOS recreates them automatically",
                path: "/",
                sizeBytes: Int64(tmLines.count) * 3_000_000_000,
                actionType: .shellCommand("sudo tmutil deletelocalsnapshots / && echo 'All local snapshots deleted.'")
            ))
        }

        return result
    }

    // MARK: - Scan: Developer folders (one home-folder walk)

    /// Replaces the old node_modules, build-artifacts, Python-venv, .DS_Store,
    /// and stale-large-file scans — which each traversed the whole home folder
    /// separately and descended into every match — with a single DevScanWalker
    /// pass. Marker-file verification (Cargo.toml, pubspec.yaml, pyvenv.cfg, …)
    /// that used to run as per-folder shell loops is now instant Swift
    /// fileExists checks. Every result row (category, name, detail, thresholds,
    /// caps, delete action) is produced identically to the old code.
    private func scanDevFolders() async -> [ScanItem] {
        scanStatus = "Scanning developer folders…"
        let hits = await DevScanWalker.walk(home: home)
        guard !Task.isCancelled else { return [] }

        let fm = FileManager.default

        // Classify each matched path by its basename.
        var nodeModules: [String] = []
        var builds: [(path: String, label: String, tip: String)] = []
        var venvs: [String] = []
        var dsStoreCount = 0
        var staleFiles: [String] = []

        for path in hits {
            let base = (path as NSString).lastPathComponent
            let parent = (path as NSString).deletingLastPathComponent
            switch base {
            case "node_modules":
                nodeModules.append(path)
            case "target":
                if fileExistsAny(fm, in: parent, ["Cargo.toml", "pom.xml", "build.gradle"]) {
                    builds.append((path, "build output", "Recreate with: cargo build / mvn package"))
                }
            case ".build":
                if fm.fileExists(atPath: parent + "/Package.swift") {
                    builds.append((path, "Swift PM build", "Recreate with: swift build"))
                }
            case "build":
                if fm.fileExists(atPath: parent + "/pubspec.yaml") {
                    builds.append((path, "Flutter build", "Recreate with: flutter build"))
                }
            case ".next":
                if fm.fileExists(atPath: parent + "/next.config.js")
                    || fm.fileExists(atPath: parent + "/next.config.ts")
                    || packageJsonMentionsNext(fm, in: parent) {
                    builds.append((path, "Next.js build cache", "Recreate with: next build"))
                }
            case ".nuxt":
                if fm.fileExists(atPath: parent + "/nuxt.config.js")
                    || fm.fileExists(atPath: parent + "/nuxt.config.ts") {
                    builds.append((path, "Nuxt.js build cache", "Recreate with: nuxt build"))
                }
            case ".venv", "venv", ".virtualenv":
                if fm.fileExists(atPath: path + "/pyvenv.cfg")
                    || fm.fileExists(atPath: path + "/bin/python")
                    || fm.fileExists(atPath: path + "/bin/python3") {
                    venvs.append(path)
                }
            case ".DS_Store":
                dsStoreCount += 1
            default:
                staleFiles.append(path)   // large, old file (>500 MB, >180 days)
            }
        }

        // Same per-type caps as the old `head -N` limits.
        nodeModules = Array(nodeModules.prefix(60))
        builds = capPerLabel(builds, cap: 40)
        staleFiles = Array(staleFiles.prefix(20))

        // Size every candidate directory via du (fast) in one parallel batch.
        let dirPaths = nodeModules + builds.map(\.path) + venvs
        let sizes = await FileSize.allocatedSizes(ofPaths: dirPaths)
        guard !Task.isCancelled else { return [] }

        var result: [ScanItem] = []
        let dfDateTime = DateFormatter(); dfDateTime.dateFormat = "d MMM yyyy, HH:mm"
        let dfDate     = DateFormatter(); dfDate.dateFormat = "d MMM yyyy"
        let dfMedium   = DateFormatter(); dfMedium.dateStyle = .medium; dfMedium.timeStyle = .none

        func projectName(of path: String) -> String {
            URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
        }
        func dirDate(_ path: String) -> Date? {
            (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        }

        // node_modules ( > 30 MB )
        for path in nodeModules {
            guard let size = sizes[path], size > 30_000_000 else { continue }
            let dateLabel = dirDate(path).map { " · last used \(dfDateTime.string(from: $0))" } ?? ""
            result.append(ScanItem(
                category: "Dev: node_modules",
                name: "node_modules — \(projectName(of: path))",
                detail: "Restore any time with: npm install\(dateLabel)",
                path: path, sizeBytes: size, actionType: .deleteDirectory))
        }

        // Build artifacts ( > 30 MB )
        for build in builds {
            guard let size = sizes[build.path], size > 30_000_000 else { continue }
            let dateLabel = dirDate(build.path).map { " · last built \(dfDate.string(from: $0))" } ?? ""
            result.append(ScanItem(
                category: "Dev: Build Artifacts",
                name: "\(build.label) — \(projectName(of: build.path))",
                detail: "\(build.tip)\(dateLabel)",
                path: build.path, sizeBytes: size, actionType: .deleteDirectory))
        }

        // Python virtual environments ( > 20 MB )
        for path in venvs {
            guard let size = sizes[path], size > 20_000_000 else { continue }
            let dateLabel = dirDate(path).map { " · last used \(dfDateTime.string(from: $0))" } ?? ""
            result.append(ScanItem(
                category: "Dev: Python Envs",
                name: "Python venv — \(projectName(of: path))",
                detail: "Recreate with: python3 -m venv .venv\(dateLabel)",
                path: path, sizeBytes: size, actionType: .deleteDirectory))
        }

        // .DS_Store bulk ( > 10 files )
        if dsStoreCount > 10 {
            let h = home
            result.append(ScanItem(
                category: "System",
                name: ".DS_Store Files (\(dsStoreCount) files)",
                detail: "Hidden folder-view metadata files scattered across your home folder — safe to delete, macOS recreates them as needed",
                path: h,
                sizeBytes: Int64(dsStoreCount) * 4_096,
                actionType: .backgroundCommand("find \"\(h)\" -name .DS_Store -delete 2>/dev/null")))
        }

        // Stale large files ( > 500 MB, already older than 180 days )
        for path in staleFiles {
            guard let attrs = try? fm.attributesOfItem(atPath: path) else { continue }
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            guard size > 500_000_000 else { continue }
            let dateStr = (attrs[.modificationDate] as? Date).map { dfMedium.string(from: $0) } ?? "unknown date"
            result.append(ScanItem(
                category: "Stale Large Files",
                name: URL(fileURLWithPath: path).lastPathComponent,
                detail: "Not modified since \(dateStr) — moved to Trash",
                path: path, sizeBytes: size, actionType: .deleteFile))
        }

        return result
    }

    private func fileExistsAny(_ fm: FileManager, in dir: String, _ names: [String]) -> Bool {
        names.contains { fm.fileExists(atPath: dir + "/" + $0) }
    }

    /// Best-effort "last used" date for an installed app. macOS no longer
    /// exposes a usable kMDItemLastUsedDate (it returns null even for apps in
    /// daily use), so we approximate from the newest modification time among
    /// the folders an app writes to when it runs: its sandbox container,
    /// preferences, saved window state, and Application Support data. Returns
    /// nil only when none of those exist.
    private func lastUsedEstimate(bundleID: String?, appName: String) -> Date? {
        let fm = FileManager.default
        var candidates: [String] = []
        if let bid = bundleID, !bid.isEmpty {
            candidates += [
                "\(home)/Library/Containers/\(bid)",
                "\(home)/Library/Preferences/\(bid).plist",
                "\(home)/Library/Saved Application State/\(bid).savedState",
                "\(home)/Library/Application Support/\(bid)",
                "\(home)/Library/HTTPStorages/\(bid)",
            ]
        }
        candidates.append("\(home)/Library/Application Support/\(appName)")

        var newest: Date?
        for path in candidates {
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let modified = attrs[.modificationDate] as? Date else { continue }
            if newest == nil || modified > newest! { newest = modified }
        }
        return newest
    }

    private func packageJsonMentionsNext(_ fm: FileManager, in dir: String) -> Bool {
        let pj = dir + "/package.json"
        guard fm.fileExists(atPath: pj),
              let content = try? String(contentsOfFile: pj, encoding: .utf8) else { return false }
        return content.contains("\"next\"")
    }

    /// Keeps at most `cap` build folders per label (matches the old per-type
    /// `head -40`), preserving find's traversal order.
    private func capPerLabel(_ builds: [(path: String, label: String, tip: String)],
                             cap: Int) -> [(path: String, label: String, tip: String)] {
        var counts: [String: Int] = [:]
        var out: [(path: String, label: String, tip: String)] = []
        for b in builds where counts[b.label, default: 0] < cap {
            out.append(b)
            counts[b.label, default: 0] += 1
        }
        return out
    }

    // MARK: - Scan: Individual large files in Downloads

    private func scanDownloadItems() async -> [ScanItem] {
        scanStatus = "Scanning Downloads for large files…"
        let script = """
        find "\(home)/Downloads" -maxdepth 3 -not -type d -size +50M 2>/dev/null | \
        while read -r f; do
            sz=$(stat -f%z "$f" 2>/dev/null || echo 0)
            mod=$(stat -f "%Sm" -t "%d %b %Y" "$f" 2>/dev/null || echo "unknown date")
            printf '%s\t%s\t%s\n' "$sz" "$mod" "$f"
        done | sort -rn | head -60
        """
        let out = await shell(script)
        var result: [ScanItem] = []
        for line in out.split(separator: "\n").map(String.init).filter({ !$0.isEmpty }) {
            let parts = line.split(separator: "\t", maxSplits: 2).map(String.init)
            guard parts.count == 3 else { continue }
            let sizeBytes = Int64(parts[0]) ?? 0
            let dateStr   = parts[1]
            let path      = parts[2]
            guard sizeBytes > 50_000_000 else { continue }
            let url  = URL(fileURLWithPath: path)
            let name = url.lastPathComponent
            let ext  = url.pathExtension.lowercased()

            let typeHint: String
            switch ext {
            case "dmg", "pkg", "mpkg":
                typeHint = "Installer — safe to delete after installing"
            case "zip", "tar", "gz", "bz2", "xz", "rar", "7z":
                typeHint = "Archive — safe to delete if already extracted"
            case "mp4", "mov", "avi", "mkv", "m4v", "wmv":
                typeHint = "Video file"
            case "iso", "img":
                typeHint = "Disk image"
            case "pdf":
                typeHint = "PDF document"
            default:
                typeHint = "Downloaded file"
            }

            result.append(ScanItem(
                category: "Downloads",
                name: name,
                detail: "\(typeHint) · downloaded \(dateStr)",
                path: path,
                sizeBytes: sizeBytes,
                actionType: .deleteFile
            ))
        }
        return result
    }

    // MARK: - Scan: SDK & Updater Caches

    private func scanSDKCaches() async -> [ScanItem] {
        scanStatus = "Scanning for SDK and updater caches…"

        typealias SDKCheck = (name: String, detail: String, path: String)
        let sdkChecks: [SDKCheck] = [
            ("Sparkle Updater Cache",
             "Auto-update cache from the Sparkle framework — safe to delete, apps re-download on next update check",
             "\(home)/Library/Caches/org.sparkle-project.Sparkle"),

            ("Sentry Crash Reports Cache",
             "Pending crash report data from the Sentry SDK — safe to delete",
             "\(home)/Library/Caches/SentryCrash"),

            ("Crashlytics Cache",
             "Crash report cache from Firebase Crashlytics — safe to delete",
             "\(home)/Library/Caches/com.crashlytics"),

            ("Rollbar Cache",
             "Error reporting cache from the Rollbar SDK — safe to delete",
             "\(home)/Library/Caches/io.rollbar"),

            ("Amplitude Analytics Cache",
             "Analytics event cache from the Amplitude SDK — safe to delete",
             "\(home)/Library/Caches/Amplitude"),

            ("Google Keystone (Auto-Updater)",
             "Google's auto-updater cache for Chrome, Drive etc. — safe to delete",
             "\(home)/Library/Caches/com.google.Keystone"),

            ("Google Software Update Cache",
             "Google software update metadata cache — safe to delete",
             "\(home)/Library/Caches/com.google.SoftwareUpdate"),

            ("VS Code — Web Cache",
             "VS Code web renderer cache — safe to delete when VS Code is not running",
             "\(home)/Library/Application Support/Code/Cache"),

            ("VS Code — Code Cache",
             "VS Code compiled JavaScript cache — safe to delete when VS Code is not running",
             "\(home)/Library/Application Support/Code/Code Cache"),

            ("JetBrains IDE Caches",
             "Caches for IntelliJ, WebStorm, PyCharm etc. — safe to delete, rebuilt on next launch",
             "\(home)/Library/Caches/JetBrains"),

            ("JetBrains IDE Indexes & Settings",
             "Project indexes and IDE settings for JetBrains tools — rebuilds on next launch",
             "\(home)/Library/Application Support/JetBrains"),
        ]

        let fm = FileManager.default
        let existing = sdkChecks.filter { fm.fileExists(atPath: $0.path) }
        let sizes = await FileSize.allocatedSizes(ofPaths: existing.map(\.path))

        var result: [ScanItem] = []
        for check in existing {
            let size = sizes[check.path] ?? 0
            guard size > 1_000_000 else { continue }   // 1 MB floor — skip empty SDK dirs
            result.append(ScanItem(
                category: "SDK & Updater Caches",
                name: check.name,
                detail: check.detail,
                path: check.path,
                sizeBytes: size,
                actionType: .deleteDirectory
            ))
        }
        return result
    }

    // (scanStaleFiles removed — stale large files are now found in the same
    // single DevScanWalker pass as node_modules and .DS_Store.)

    // MARK: - Scan: Recent large files (time-based)

    private func scanRecentFiles(hours: Int) async -> [ScanItem] {
        let plural = hours == 1 ? "" : "s"
        scanStatus = "Finding files written in the last \(hours) hour\(plural)…"

        // Use Spotlight (mdfind) — fast, uses a pre-built index, no Full Disk Access needed.
        // bash echo does NOT interpret \t, so we use printf which always does.
        let seconds  = hours * 3_600
        let minBytes = 10 * 1_048_576   // 10 MB minimum

        let script = """
        mdfind -onlyin "$HOME" \
          'kMDItemFSContentChangeDate >= $time.now(-\(seconds)) && kMDItemFSSize >= \(minBytes)' \
          2>/dev/null | \
        while read -r f; do
            [ -f "$f" ] || continue
            sz=$(stat -f%z "$f" 2>/dev/null || echo 0)
            mod=$(stat -f "%Sm" -t "%d %b %Y, %H:%M" "$f" 2>/dev/null || echo "unknown")
            printf '%s\t%s\t%s\n' "$sz" "$mod" "$f"
        done | sort -rn | head -120
        """

        let out = await shell(script)
        let skipPrefixes = [home + "/Library/Caches", home + "/.Trash"]
        var result: [ScanItem] = []

        for line in out.split(separator: "\n").map(String.init).filter({ !$0.isEmpty }) {
            let parts = line.split(separator: "\t", maxSplits: 2).map(String.init)
            guard parts.count == 3 else { continue }
            let sizeBytes = Int64(parts[0]) ?? 0
            let modTime   = parts[1]
            let path      = parts[2]
            guard sizeBytes >= Int64(minBytes) else { continue }
            // Skip paths already covered by Known Locations
            if skipPrefixes.contains(where: { path.hasPrefix($0) }) { continue }
            let name = URL(fileURLWithPath: path).lastPathComponent
            result.append(ScanItem(
                category: "Recently Written — last \(hours)h",
                name: name,
                detail: "Written \(modTime)",
                path: path,
                sizeBytes: sizeBytes,
                actionType: .deleteFile
            ))
        }
        return result
    }

    // MARK: - Scan: Largest files in home folder

    private func scanTopFiles() async -> [ScanItem] {
        scanStatus = "Finding largest files in your home folder…"

        // Use Spotlight — returns results in seconds vs minutes for find /.
        // printf is used (not echo) so \t is a real tab character.
        let minBytes = 100 * 1_048_576   // 100 MB

        let script = """
        mdfind -onlyin "$HOME" 'kMDItemFSSize >= \(minBytes)' 2>/dev/null | \
        while read -r f; do
            [ -f "$f" ] || continue
            sz=$(stat -f%z "$f" 2>/dev/null || echo 0)
            mod=$(stat -f "%Sm" -t "%d %b %Y, %H:%M" "$f" 2>/dev/null || echo "unknown")
            printf '%s\t%s\t%s\n' "$sz" "$mod" "$f"
        done | sort -rn | head -60
        """

        let out = await shell(script)
        var result: [ScanItem] = []
        for line in out.split(separator: "\n").map(String.init).filter({ !$0.isEmpty }) {
            let parts = line.split(separator: "\t", maxSplits: 2).map(String.init)
            guard parts.count == 3 else { continue }
            let sizeBytes = Int64(parts[0]) ?? 0
            let modTime   = parts[1]
            let path      = parts[2]
            guard sizeBytes >= Int64(minBytes) else { continue }
            let name = URL(fileURLWithPath: path).lastPathComponent
            let dateLabel = modTime.isEmpty ? "" : " · modified \(modTime)"
            result.append(ScanItem(
                category: "Largest Files in Home",
                name: name,
                detail: "Largest file on disk\(dateLabel)",
                path: path,
                sizeBytes: sizeBytes,
                actionType: .deleteFile
            ))
        }
        return result
    }

    // MARK: - Deletion

    func deleteSelected() async {
        let toDelete = items.filter(\.isSelected)
        var succeeded = Set<UUID>()
        var freed: Int64 = 0
        var records: [TrashedRecord] = []

        for item in toDelete {
            let result = await performDelete(item)
            if result.success {
                succeeded.insert(item.id)
                freed += item.sizeBytes
            }
            if let record = result.record { records.append(record) }
        }

        items.removeAll { succeeded.contains($0.id) }
        if freed > 0 {
            lastFreedBytes = freed
            NSSound(named: NSSound.Name("Purr"))?.play()
        }
        CleanupJournal.shared.record(label: "Disk Detective", items: records)
        ScanCache.save(items, key: Self.cacheKey)
    }

    @discardableResult
    private func performDelete(_ item: ScanItem) async -> (success: Bool, record: TrashedRecord?) {
        switch item.actionType {

        case .deleteDirectory, .deleteFile:
            do {
                var resultURL: NSURL?
                try FileManager.default.trashItem(
                    at: URL(fileURLWithPath: item.path),
                    resultingItemURL: &resultURL
                )
                let record = (resultURL as URL?).map { TrashedRecord(originalPath: item.path, trashPath: $0.path) }
                return (true, record)
            } catch {
                return (false, nil)
            }

        case .emptyTrash:
            let script = "tell application \"Finder\" to empty trash"
            NSAppleScript(source: script)?.executeAndReturnError(nil)
            return (true, nil)   // Trash is emptied, not moved — nothing to undo

        case .backgroundCommand(let cmd):
            // Runs silently inside the app — no Terminal window. Not routed
            // through trashItem, so there is nothing here to undo either.
            _ = await shell(cmd)
            return (true, nil)

        case .shellCommand(let cmd):
            // Only used for commands that genuinely need sudo — opens Terminal
            let safe = cmd
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            let script = """
            tell application "Terminal"
                activate
                do script "\(safe)"
            end tell
            """
            NSAppleScript(source: script)?.executeAndReturnError(nil)
            return (false, nil)   // user confirms in Terminal; don't remove from list yet

        case .openInFinder:
            let url = URL(fileURLWithPath: item.path)
            if FileManager.default.fileExists(atPath: item.path) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } else {
                NSWorkspace.shared.open(url.deletingLastPathComponent())
            }
            return (false, nil)   // user deletes manually; don't remove from list
        }
    }

    // MARK: - Helpers

    private func shell(_ command: String) async -> String {
        await Task.detached(priority: .utility) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = ["-c", command]
            let pipe = Pipe()
            p.standardOutput = pipe
            // nullDevice, not an unread Pipe: with waitUntilExit() below, a
            // command that writes a lot to stderr would fill an unread stderr
            // pipe and deadlock (process blocks on the stderr write, never
            // exits, waitUntilExit never returns).
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
            return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        }.value
    }
}
