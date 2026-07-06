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

    /// Full spoken label for VoiceOver — name, type, and size.
    var accessibilityLabel: String { "\(name), \(typeLabel), \(sizeString)" }
}

// MARK: - Engine

@MainActor
class FolderSizeEngine: ObservableObject {
    @Published var items: [FolderItem] = []
    @Published var isScanning = false
    @Published var currentPath: String
    @Published var scanStatus = "Ready."
    /// Incremented on every completed scan so the view can detect navigation.
    @Published var scanVersion: Int = 0

    private let home = FileManager.default.homeDirectoryForCurrentUser.path

    init() {
        currentPath = FileManager.default.homeDirectoryForCurrentUser.path
    }

    // MARK: Breadcrumbs

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
        scanVersion += 1

        let total = items.reduce(0) { $0 + $1.sizeBytes }
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
            var resultURL: NSURL?
            try FileManager.default.trashItem(at: URL(fileURLWithPath: item.path),
                                              resultingItemURL: &resultURL)
            items.removeAll { $0.id == item.id }
            let total = items.reduce(0) { $0 + $1.sizeBytes }
            scanStatus = items.isEmpty
                ? "This folder is empty."
                : "\(items.count) item\(items.count == 1 ? "" : "s") \u{2014} \(formatBytes(total))"
            if let trashedPath = (resultURL as URL?)?.path {
                CleanupJournal.shared.record(
                    label: "Folder Browser: \(item.name)",
                    items: [TrashedRecord(originalPath: item.path, trashPath: trashedPath)])
            }
            AccessibilityNotification.Announcement("\(item.name) moved to Trash.").post()
            return true
        } catch {
            AccessibilityNotification.Announcement("Could not move \(item.name) to Trash.").post()
            return false
        }
    }

    // MARK: Helpers

    // nonisolated so this doesn't inherit @MainActor from the class — without
    // this, calling it from inside the TaskGroup below forces the (blocking,
    // potentially slow) recursive directory walk to run on the main thread,
    // freezing the UI. The previous du-based implementation avoided this by
    // wrapping itself in Task.detached; that detachment was lost when it was
    // replaced with a direct native FileManager call.
    private nonisolated static func measureSize(_ path: String) async -> Int64 {
        await FileSize.allocatedSize(of: URL(fileURLWithPath: path))
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

    // Tracks which row VoiceOver should focus after navigation.
    // Using an enum lets us distinguish "parent" from any item row.
    private enum RowID: Hashable {
        case parent
        case item(UUID)
    }
    @AccessibilityFocusState private var focusedRow: RowID?

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
        // After every navigation (scanVersion > 1), move VoiceOver focus to
        // the top of the refreshed list so the user doesn't have to hunt for it.
        .onChange(of: engine.scanVersion) { version in
            guard version > 1 else { return }   // skip the initial load
            // Brief delay lets SwiftUI finish rebuilding list cells.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if engine.canGoUp {
                    focusedRow = .parent
                } else if let first = engine.items.first {
                    focusedRow = .item(first.id)
                }
            }
        }
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
            List {
                if engine.canGoUp {
                    // "Parent Folder" row — real Button so Enter activates it.
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
                    .buttonStyle(.plain)
                    .disabled(engine.isScanning)
                    .accessibilityLabel("Parent folder")
                    .accessibilityHint("Opens the parent folder. Shortcut: Command-[")
                    // Bind VoiceOver focus so we can return here after navigation.
                    .accessibilityFocused($focusedRow, equals: .parent)
                }

                ForEach(engine.items) { item in
                    FolderItemRow(
                        item: item,
                        isScanning: engine.isScanning,
                        onOpen:   { Task { await engine.navigateInto(item) } },
                        onReveal: { engine.revealInFinder(item) },
                        onTrash:  { itemToTrash = item; showTrashConfirm = true }
                    )
                    // Bind each row to focusedRow so we can restore focus here
                    // after navigation without the user having to hunt for the list.
                    .accessibilityFocused($focusedRow, equals: .item(item.id))
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            )
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .accessibilityLabel("File browser. \(engine.items.count) item\(engine.items.count == 1 ? "" : "s").")
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Text(engine.isScanning
                    ? engine.scanStatus
                    : "Items sorted largest first. Press Enter on a folder to open it.")
                .font(.callout)
                .foregroundColor(.secondary)
                .accessibilityHidden(true)

            Spacer()

            UndoLastCleanupButton()

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
//
// Using a real Button (not a plain HStack with accessibilityAction) is what
// makes the Enter key work in VoiceOver on macOS. The .isButton trait +
// unnamed accessibilityAction only responds to VO+Space, not Enter.
// A Button responds to Enter natively.

struct FolderItemRow: View {
    let item: FolderItem
    let isScanning: Bool
    let onOpen: () -> Void
    let onReveal: () -> Void
    let onTrash: () -> Void

    var body: some View {
        Button {
            // Primary action: open folder, or reveal file in Finder.
            if item.isDirectory { onOpen() } else { onReveal() }
        } label: {
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
        }
        .buttonStyle(.plain)
        .disabled(isScanning)
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
        // Single combined accessibility label read by VoiceOver.
        .accessibilityLabel(item.accessibilityLabel)
        .accessibilityHint(item.isDirectory
            ? "Opens folder. Use VoiceOver rotor for Reveal in Finder or Move to Trash."
            : "Reveals in Finder. Use VoiceOver rotor for Move to Trash.")
        // Named rotor actions — accessible via VO+Command+J
        .accessibilityAction(named: "Reveal in Finder") { onReveal() }
        .accessibilityAction(named: "Move to Trash")    { onTrash()  }
    }
}
