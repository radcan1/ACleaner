import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Model

struct FolderItem: Identifiable {
    let id = UUID()
    let name: String
    let path: String
    let sizeBytes: Int64
    let isDirectory: Bool

    var sizeString: String {
        let gb = Double(sizeBytes) / 1_073_741_824
        let mb = Double(sizeBytes) / 1_048_576
        let kb = Double(sizeBytes) / 1_024
        if gb >= 1.0 { return String(format: "%.1f GB", gb) }
        if mb >= 1.0 { return String(format: "%.0f MB", mb) }
        if kb >= 1.0 { return String(format: "%.0f KB", kb) }
        return "\(sizeBytes) B"
    }

    var typeLabel: String {
        if isDirectory { return "folder" }
        let ext = URL(fileURLWithPath: path).pathExtension.uppercased()
        return ext.isEmpty ? "file" : "\(ext) file"
    }

    var icon: String {
        if isDirectory { return "folder.fill" }
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        switch ext {
        case "app":                              return "app.fill"
        case "pdf":                              return "doc.richtext.fill"
        case "zip", "gz", "tar", "rar", "7z", "bz2", "xz": return "archivebox.fill"
        case "mp4", "mov", "avi", "mkv", "m4v": return "film.fill"
        case "mp3", "m4a", "flac", "wav", "aac": return "music.note"
        case "jpg", "jpeg", "png", "gif", "heic", "webp": return "photo.fill"
        case "dmg", "pkg":                       return "opticaldisc"
        default:                                 return "doc.fill"
        }
    }

    /// Full spoken label for VoiceOver — name, type, and size in one sentence.
    var accessibilityLabel: String { "\(name), \(typeLabel), \(sizeString)" }
}

// MARK: - Engine

@MainActor
class FolderSizeEngine: ObservableObject {
    @Published var items: [FolderItem] = []
    @Published var isScanning = false
    @Published var currentPath: String
    @Published var scanStatus = "Ready."

    private let home = FileManager.default.homeDirectoryForCurrentUser.path

    init() {
        currentPath = FileManager.default.homeDirectoryForCurrentUser.path
    }

    // MARK: Breadcrumbs

    /// Path components from the filesystem root down to currentPath.
    var breadcrumbs: [(name: String, path: String)] {
        var result: [(String, String)] = []
        var url = URL(fileURLWithPath: currentPath)
        while true {
            let name: String
            if url.path == home     { name = "Home" }
            else if url.path == "/" { name = "/"    }
            else                    { name = url.lastPathComponent }
            result.insert((name, url.path), at: 0)
            if url.path == "/" { break }
            url = url.deletingLastPathComponent()
        }
        return result
    }

    var canGoUp: Bool { currentPath != "/" }

    // MARK: Scan

    func scan(path: String? = nil) async {
        let target = path ?? currentPath
        currentPath = target
        isScanning  = true
        scanStatus  = "Scanning\u{2026}"
        items       = []

        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: target) else {
            isScanning = false
            scanStatus = "Cannot read this folder."
            return
        }

        let visible = entries.filter { !$0.hasPrefix(".") }
        scanStatus = "Measuring \(visible.count) item\(visible.count == 1 ? "" : "s")\u{2026}"

        var result: [FolderItem] = []
        await withTaskGroup(of: FolderItem?.self) { group in
            for name in visible {
                let fullPath = "\(target)/\(name)"
                group.addTask {
                    var isDir: ObjCBool = false
                    FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDir)
                    let size = await Self.measureSize(fullPath)
                    return FolderItem(name: name, path: fullPath,
                                     sizeBytes: size, isDirectory: isDir.boolValue)
                }
            }
            for await item in group { if let item { result.append(item) } }
        }

        items      = result.sorted { $0.sizeBytes > $1.sizeBytes }
        isScanning = false
        let total  = items.reduce(0) { $0 + $1.sizeBytes }
        scanStatus = items.isEmpty
            ? "This folder is empty."
            : "\(items.count) item\(items.count == 1 ? "" : "s") \u{2014} \(formatBytes(total))"

        AccessibilityNotification.Announcement(scanStatus).post()
    }

    func navigateInto(_ item: FolderItem) async {
        guard item.isDirectory else { return }
        await scan(path: item.path)
    }

    func navigateUp() async {
        let parent = URL(fileURLWithPath: currentPath).deletingLastPathComponent().path
        await scan(path: parent)
    }

    func navigateTo(_ path: String) async {
        await scan(path: path)
    }

    // MARK: Actions

    func revealInFinder(_ item: FolderItem) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
    }

    func moveToTrash(_ item: FolderItem) async -> Bool {
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: item.path),
                                              resultingItemURL: nil)
            items.removeAll { $0.id == item.id }
            let total = items.reduce(0) { $0 + $1.sizeBytes }
            scanStatus = items.isEmpty
                ? "This folder is empty."
                : "\(items.count) item\(items.count == 1 ? "" : "s") \u{2014} \(formatBytes(total))"
            AccessibilityNotification.Announcement("\(item.name) moved to Trash.").post()
            return true
        } catch {
            AccessibilityNotification.Announcement("Could not move \(item.name) to Trash.").post()
            return false
        }
    }

    // MARK: Helpers

    private static func measureSize(_ path: String) async -> Int64 {
        await Task.detached(priority: .utility) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = ["-c", "du -sk \"\(path)\" 2>/dev/null | awk '{print $1}'"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError  = Pipe()
            try? p.run()
            p.waitUntilExit()
            let raw = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                             encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "0"
            return (Int64(raw) ?? 0) * 1_024
        }.value
    }

    func formatBytes(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        let mb = Double(bytes) / 1_048_576
        if gb >= 1.0 { return String(format: "%.1f GB", gb) }
        if mb >= 1.0 { return String(format: "%.0f MB", mb) }
        return "< 1 MB"
    }
}

// MARK: - View

struct FolderSizeView: View {
    @StateObject private var engine = FolderSizeEngine()
    @State private var showTrashConfirm = false
    @State private var itemToTrash: FolderItem? = nil
    @State private var showFolderPicker = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            breadcrumbBar
            Divider()
            content
            Divider()
            footer
        }
        .task { await engine.scan() }
        .alert("Move to Trash?", isPresented: $showTrashConfirm, presenting: itemToTrash) { item in
            Button("Move to Trash", role: .destructive) {
                Task { await engine.moveToTrash(item) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { item in
            Text("Move \"\(item.name)\" (\(item.sizeString)) to Trash?")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.badge.magnifyingglass")
                .font(.title2)
                .foregroundColor(.accentColor)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("Folder Size").font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text(engine.scanStatus)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .accessibilityAddTraits(.updatesFrequently)
            }

            Spacer()

            if engine.isScanning {
                ProgressView()
                    .scaleEffect(0.75)
                    .accessibilityHidden(true)
            }

            Button {
                showFolderPicker = true
            } label: {
                Label("Choose Folder", systemImage: "folder.badge.plus")
            }
            .disabled(engine.isScanning)
            .accessibilityLabel("Choose a different starting folder")
            .fileImporter(isPresented: $showFolderPicker,
                          allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result {
                    let accessed = url.startAccessingSecurityScopedResource()
                    Task {
                        await engine.scan(path: url.path)
                        if accessed { url.stopAccessingSecurityScopedResource() }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: Breadcrumb bar
    //
    // Each crumb is an interactive button with a clear label. VoiceOver navigates
    // them with VO+arrows; pressing Enter activates (navigates up to that folder).
    // The whole bar also reads as a single "current location" announcement if needed.

    private var breadcrumbBar: some View {
        let crumbs = engine.breadcrumbs
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(Array(crumbs.enumerated()), id: \.offset) { index, crumb in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .accessibilityHidden(true)
                    }
                    let isLast = (index == crumbs.count - 1)
                    Button {
                        guard !isLast, !engine.isScanning else { return }
                        Task { await engine.navigateTo(crumb.path) }
                    } label: {
                        Text(crumb.name)
                            .font(.caption)
                            .fontWeight(isLast ? .semibold : .regular)
                            .foregroundColor(isLast ? .primary : .accentColor)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                    }
                    .buttonStyle(.borderless)
                    .disabled(isLast || engine.isScanning)
                    .accessibilityLabel(isLast
                        ? "\(crumb.name), current folder"
                        : "Go to \(crumb.name)")
                    .accessibilityHint(isLast ? "" : "Navigates up to \(crumb.name)")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .accessibilityLabel("Location: \(crumbs.map(\.name).joined(separator: " › "))")
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if engine.isScanning && engine.items.isEmpty {
            VStack(spacing: 14) {
                ProgressView().accessibilityHidden(true)
                Text(engine.scanStatus)
                    .font(.title3)
                    .foregroundColor(.secondary)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        } else if engine.items.isEmpty {
            VStack(spacing: 14) {
                Image(systemName: "folder.badge.questionmark")
                    .font(.system(size: 52))
                    .foregroundColor(.secondary)
                    .accessibilityHidden(true)
                Text(engine.scanStatus)
                    .font(.title3)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        } else {
            // ── File browser list ──────────────────────────────────────────────
            // Wrapped in a rounded-rect container so VoiceOver users and
            // sighted users can clearly see where the browsable area is.
            List {
                if engine.canGoUp {
                    // "Parent Folder" row — navigates up one level
                    Button {
                        Task { await engine.navigateUp() }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "arrow.up.circle")
                                .foregroundColor(.secondary)
                                .frame(width: 22)
                                .accessibilityHidden(true)
                            Text("Parent Folder")
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                    .buttonStyle(.borderless)
                    .disabled(engine.isScanning)
                    .accessibilityLabel("Go up to parent folder")
                    .accessibilityHint("Press Enter to navigate up. Shortcut: Command-[")
                    // Default action so Enter works in VoiceOver
                    .accessibilityAction {
                        Task { await engine.navigateUp() }
                    }
                }

                ForEach(engine.items) { item in
                    FolderItemRow(
                        item: item,
                        isScanning: engine.isScanning,
                        onOpen:   { Task { await engine.navigateInto(item) } },
                        onReveal: { engine.revealInFinder(item) },
                        onTrash:  { itemToTrash = item; showTrashConfirm = true }
                    )
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            // Visible border that clearly frames the browsable area
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            )
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            // Announce the list to VoiceOver as a named region
            .accessibilityLabel("File browser. \(engine.items.count) item\(engine.items.count == 1 ? "" : "s"). Press Enter on a folder to open it.")
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Text(engine.isScanning
                    ? engine.scanStatus
                    : "Press Enter on a folder to open it. Items sorted largest first.")
                .font(.callout)
                .foregroundColor(.secondary)
                .accessibilityHidden(true)   // status text in header covers this

            Spacer()

            if engine.canGoUp {
                Button {
                    Task { await engine.navigateUp() }
                } label: {
                    Label("Go Up", systemImage: "arrow.up")
                }
                .buttonStyle(.borderless)
                .disabled(engine.isScanning)
                .keyboardShortcut("[", modifiers: .command)
                .accessibilityLabel("Go up to parent folder")
                .accessibilityHint("Command-[")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - Row

struct FolderItemRow: View {
    let item: FolderItem
    let isScanning: Bool
    let onOpen: () -> Void
    let onReveal: () -> Void
    let onTrash: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.icon)
                .foregroundColor(item.isDirectory ? .accentColor : .secondary)
                .frame(width: 22)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text(item.typeLabel.capitalized)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Text(item.sizeString)
                .fontWeight(.semibold)
                .monospacedDigit()
                .foregroundColor(
                    item.sizeBytes > 1_000_000_000 ? .red :
                    item.sizeBytes >   500_000_000 ? .orange : .primary
                )
                .frame(minWidth: 70, alignment: .trailing)

            if item.isDirectory {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { if item.isDirectory { onOpen() } }
        .contextMenu {
            if item.isDirectory {
                Button { onOpen() } label: {
                    Label("Open Folder", systemImage: "folder")
                }
            }
            Button { onReveal() } label: {
                Label("Reveal in Finder", systemImage: "folder.badge.magnifyingglass")
            }
            Divider()
            Button(role: .destructive) { onTrash() } label: {
                Label("Move to Trash", systemImage: "trash")
            }
        }
        // ── VoiceOver ────────────────────────────────────────────────────────
        // Combine into one element so VoiceOver reads name + type + size together.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.accessibilityLabel)
        // isButton trait tells VoiceOver "press Enter to activate"
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(item.isDirectory
            ? "Press Enter to open. Use the VoiceOver rotor for more actions."
            : "Use the VoiceOver rotor to reveal in Finder or move to Trash.")
        // Default action — triggered by Enter key in VoiceOver.
        // No `named:` parameter = this IS the Enter key action.
        .accessibilityAction {
            if item.isDirectory { onOpen() } else { onReveal() }
        }
        // Named rotor actions
        .accessibilityAction(named: "Reveal in Finder") { onReveal() }
        .accessibilityAction(named: "Move to Trash")    { onTrash()  }
    }
}
