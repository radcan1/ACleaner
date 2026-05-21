import SwiftUI
import AppKit

// MARK: - Model

struct InstalledApp: Identifiable, Hashable, Sendable {
    let id   = UUID()
    let name: String
    let path: String
    let bundleIdentifier: String
    let version: String

    static func == (lhs: InstalledApp, rhs: InstalledApp) -> Bool { lhs.path == rhs.path }
    func hash(into hasher: inout Hasher) { hasher.combine(path) }

    /// True when at least one process with this bundle ID is currently running.
    var isRunning: Bool {
        guard !bundleIdentifier.isEmpty else { return false }
        return !NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .isEmpty
    }
}

// MARK: - Scanner

@MainActor
final class InstalledAppScanner: ObservableObject {
    @Published var apps: [InstalledApp] = []
    @Published var isScanning = false
    @Published var searchText = ""

    var filtered: [InstalledApp] {
        guard !searchText.isEmpty else { return apps }
        let q = searchText.lowercased()
        return apps.filter {
            $0.name.lowercased().contains(q) ||
            $0.bundleIdentifier.lowercased().contains(q)
        }
    }

    func scan() async {
        isScanning = true
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let searchPaths = [
            "/Applications",
            home + "/Applications",
            "/Applications/Utilities",
        ]

        let found: [InstalledApp] = await Task.detached(priority: .userInitiated) {
            var result: [InstalledApp] = []
            let fm = FileManager.default
            for base in searchPaths {
                guard let entries = try? fm.contentsOfDirectory(atPath: base) else { continue }
                for entry in entries {
                    guard entry.hasSuffix(".app") else { continue }
                    let fullPath = "\(base)/\(entry)"
                    var isDir: ObjCBool = false
                    guard fm.fileExists(atPath: fullPath, isDirectory: &isDir),
                          isDir.boolValue else { continue }
                    let bundle = Bundle(path: fullPath)
                    let bundleID = bundle?.bundleIdentifier ?? ""
                    // Skip ACleaner itself
                    guard bundleID != "com.user.ACleaner" else { continue }
                    let name = (bundle?.infoDictionary?["CFBundleDisplayName"] as? String)
                           ?? (bundle?.infoDictionary?["CFBundleName"] as? String)
                           ?? String(entry.dropLast(4))   // strip ".app"
                    let version = bundle?.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
                    result.append(InstalledApp(name: name, path: fullPath,
                                               bundleIdentifier: bundleID, version: version))
                }
            }
            return result.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }.value

        apps = found
        isScanning = false
    }
}

// MARK: - App Picker Sheet

struct AppPickerSheet: View {
    /// Called with the URL of the chosen app *before* it is trashed.
    let onSelect: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var scanner = InstalledAppScanner()
    @State private var pendingApp: InstalledApp? = nil
    @State private var showConfirm       = false
    @State private var showRunningAlert  = false

    var body: some View {
        VStack(spacing: 0) {

            // ── Header ──────────────────────────────────────────────────────
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Choose App to Uninstall")
                        .font(.title2).fontWeight(.semibold)
                        .accessibilityAddTraits(.isHeader)
                    Text("The selected app will be moved to the Trash and its leftover files located automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 14)

            Divider()

            // ── Search field ────────────────────────────────────────────────
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Search apps", text: $scanner.searchText)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("Search installed apps")
                if !scanner.searchText.isEmpty {
                    Button {
                        scanner.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // ── Content ─────────────────────────────────────────────────────
            if scanner.isScanning {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Scanning for installed apps\u{2026}")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            } else if scanner.filtered.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "app.badge.questionmark")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(scanner.searchText.isEmpty
                         ? "No applications found."
                         : "No apps match \"\(scanner.searchText)\".")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            } else {
                List(scanner.filtered) { app in
                    AppPickerRow(app: app) { selectApp(app) }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .accessibilityLabel("Installed apps. \(scanner.filtered.count) shown. Press Enter on an app to begin uninstall.")
            }
        }
        .frame(width: 500, height: 560)
        .task { await scanner.scan() }

        // ── Confirm (app not running) ────────────────────────────────────────
        .alert("Move to Trash?", isPresented: $showConfirm, presenting: pendingApp) { app in
            Button("Move to Trash & Scan", role: .destructive) {
                finish(app)
            }
            Button("Cancel", role: .cancel) { pendingApp = nil }
        } message: { app in
            Text("\"\(app.name)\" will be moved to the Trash. CleanUninstall will then scan for and offer to remove its leftover files such as preferences, caches, and support data.")
        }

        // ── Warn if app is running ───────────────────────────────────────────
        .alert("App Is Currently Open", isPresented: $showRunningAlert, presenting: pendingApp) { app in
            Button("Quit & Uninstall", role: .destructive) {
                // Send a polite quit signal, then proceed — trashing a running app
                // is safe in macOS; the process keeps running from memory until closed.
                if !app.bundleIdentifier.isEmpty {
                    NSRunningApplication
                        .runningApplications(withBundleIdentifier: app.bundleIdentifier)
                        .forEach { $0.terminate() }
                }
                finish(app)
            }
            Button("Uninstall Anyway") {
                finish(app)
            }
            Button("Cancel", role: .cancel) { pendingApp = nil }
        } message: { app in
            Text("\"\(app.name)\" is currently running. \"Quit & Uninstall\" will send it a quit signal first. You can also uninstall anyway — macOS keeps the running process in memory until it exits.")
        }
    }

    // MARK: Private

    private func selectApp(_ app: InstalledApp) {
        pendingApp = app
        if app.isRunning {
            showRunningAlert = true
        } else {
            showConfirm = true
        }
    }

    private func finish(_ app: InstalledApp) {
        dismiss()
        onSelect(URL(fileURLWithPath: app.path))
    }
}

// MARK: - Row

private struct AppPickerRow: View {
    let app: InstalledApp
    let onSelect: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // App icon from NSWorkspace (cached by macOS, fast to retrieve)
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                .resizable()
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(app.name)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    if app.isRunning {
                        Text("running")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.2))
                            .foregroundColor(.orange)
                            .clipShape(Capsule())
                            .accessibilityHidden(true)   // announced via the label
                    }
                }
                Text(app.bundleIdentifier.isEmpty ? app.path : app.bundleIdentifier)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if !app.version.isEmpty {
                Text(app.version)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }

        // ── VoiceOver ────────────────────────────────────────────────────
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(app.name)"
            + (app.version.isEmpty ? "" : ", version \(app.version)")
            + (app.isRunning ? ", currently running" : "")
            + (app.bundleIdentifier.isEmpty ? "" : ". \(app.bundleIdentifier)")
        )
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Press Enter to select this app for clean uninstall.")
        // Default action = Enter key in VoiceOver
        .accessibilityAction { onSelect() }
    }
}
