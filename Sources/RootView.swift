import SwiftUI

// One flat level: every job is a sidebar item, no nested tab bars anywhere.
// Each item is one linear screen with a single primary action, and Cmd-1…5
// jumps straight to it. Cleanup is the no-thinking one-click sweep of
// self-regenerating junk; Disk Space holds everything that needs review.
enum ACleanerTool: String, CaseIterable, Identifiable {
    case updates   = "Updates"
    case uninstall = "Uninstall"
    case cleanup   = "Cleanup"
    case diskSpace = "Disk Space"
    case startup   = "Startup"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .updates:   return "arrow.down.circle"
        case .uninstall: return "trash.slash"
        case .cleanup:   return "sparkles"
        case .diskSpace: return "internaldrive"
        case .startup:   return "power"
        }
    }
}

struct RootView: View {
    let cleanState: AppState
    @EnvironmentObject var updateChecker: UpdateChecker
    @StateObject private var selfUpdater = SelfUpdater()
    @State private var selected: ACleanerTool? = .updates
    @State private var showPermissions: Bool = false

    // Pearcleaner's approach: check FDA fresh on every launch, no "acknowledged" flag,
    // no blocking modal. If FDA is missing, show a non-blocking banner. That's it.
    // Optimistic default (true) prevents a flash of the banner on fast-launching Macs.
    @State private var hasFullDiskAccess: Bool = true

    var body: some View {
        VStack(spacing: 0) {

            // ── Update banner (only when a newer release is on GitHub) ──────
            if let version = updateChecker.availableVersion {
                updateBanner(version: version)
            }

            // ── FDA banner — non-blocking, same philosophy as Pearcleaner ──
            // Shows when FDA is missing. Disappears the moment FDA is granted
            // and "Check Again" is pressed (or on the next app launch).
            // Never blocks the UI. Never asks the user to "acknowledge" anything.
            if !hasFullDiskAccess {
                fdaBanner
            }

            NavigationSplitView {
                List(ACleanerTool.allCases, selection: $selected) { tool in
                    Label(tool.rawValue, systemImage: tool.icon)
                        .tag(tool)
                        .padding(.vertical, 2)
                }
                .navigationSplitViewColumnWidth(min: 155, ideal: 175, max: 210)
                .navigationTitle("ACleaner")
            } detail: {
                switch selected {
                case .updates:
                    UpdaterView()
                case .uninstall:
                    MainView()
                        .environmentObject(cleanState)
                        .frame(minWidth: 640, minHeight: 480)
                case .cleanup:
                    CleanupView()
                        .frame(minWidth: 640, minHeight: 480)
                case .diskSpace:
                    DiskScanView()
                        .frame(minWidth: 640, minHeight: 480)
                case .startup:
                    StartupManagerView()
                        .frame(minWidth: 640, minHeight: 480)
                case nil:
                    Text("Select a tool from the sidebar.")
                        .font(.title2)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            // Cmd-1…6 jump straight to a sidebar section (VoiceOver-friendly:
            // no need to navigate to the sidebar list first).
            .background(sectionShortcuts)
            .accessibilityLabel("ACleaner")
            .onAppear { checkFDA() }
            // Sheet is only opened via ACleaner menu → Privacy & Permissions.
            // It is never auto-shown on launch.
            .sheet(isPresented: $showPermissions) {
                PermissionsView { showPermissions = false }
            }
            // Switch to Uninstall when trash watcher detects an app
            .onReceive(NotificationCenter.default.publisher(for: .acleanerShowCleanUninstall)) { _ in
                selected = .uninstall
            }
            // Open permissions sheet from the menu bar item
            .onReceive(NotificationCenter.default.publisher(for: .acleanerShowPermissions)) { _ in
                showPermissions = true
            }

        } // end VStack
    }

    // MARK: - FDA banner

    /// Invisible buttons carrying the Cmd-1…6 section shortcuts. Hidden from
    /// VoiceOver — the shortcuts themselves are the accessibility feature.
    private var sectionShortcuts: some View {
        ZStack {
            ForEach(Array(ACleanerTool.allCases.enumerated()), id: \.element.id) { index, tool in
                Button("") { selected = tool }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    private var fdaBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield.fill")
                .foregroundColor(.orange)
                .accessibilityHidden(true)
            Text("Full Disk Access not granted — disk scans and uninstalls may not work correctly.")
                .fontWeight(.medium)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Open Settings") {
                PermissionsChecker.openFullDiskAccessSettings()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            Button("Check Again") {
                checkFDA()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Full Disk Access not granted. Disk scans and uninstalls need this permission to scan your Library folders. Press Open Settings to grant it in System Settings, then press Check Again once done.")
    }

    // MARK: - Update banner

    private func updateBanner(version: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundColor(.accentColor)
                .accessibilityHidden(true)

            switch selfUpdater.state {
            case .idle:
                Text("ACleaner \(version) is available")
                    .fontWeight(.medium)
                Spacer()
                Button("Update Now") {
                    Task { await selfUpdater.updateNow(to: version) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityHint("Downloads and installs the update in the background, then relaunches ACleaner. No browser needed.")
            case .downloading(let percent):
                Text("Downloading ACleaner \(version)… \(percent)%")
                    .fontWeight(.medium)
                Spacer()
            case .installing:
                Text("Installing ACleaner \(version)…")
                    .fontWeight(.medium)
                Spacer()
            case .failed(let message):
                Text("Update failed: \(message)")
                    .fontWeight(.medium)
                    .lineLimit(2)
                Spacer()
                Button("Retry") {
                    Task { await selfUpdater.updateNow(to: version) }
                }
                .controlSize(.small)
                Button("Open GitHub") {
                    NSWorkspace.shared.open(updateChecker.releasePageURL)
                }
                .controlSize(.small)
                .accessibilityHint("Fallback: opens the releases page in your browser.")
            }

            if !updateInProgress {
                Button {
                    updateChecker.dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Dismiss update notification")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(bannerAccessibilityLabel(version: version))
    }

    private var updateInProgress: Bool {
        switch selfUpdater.state {
        case .downloading, .installing: return true
        case .idle, .failed:            return false
        }
    }

    private func bannerAccessibilityLabel(version: String) -> String {
        switch selfUpdater.state {
        case .idle:
            return "Update available: ACleaner \(version). Update Now button."
        case .downloading(let percent):
            return "Downloading ACleaner \(version). \(percent) percent."
        case .installing:
            return "Installing ACleaner \(version)."
        case .failed(let message):
            return "Update failed. \(message). Retry and Open GitHub buttons."
        }
    }

    // MARK: - FDA check

    /// Checks FDA on a background thread (same pattern as Pearcleaner).
    /// Updates the banner and announces via VoiceOver if access is missing.
    private func checkFDA() {
        PermissionsChecker.checkAsync { granted in
            hasFullDiskAccess = granted
            if !granted {
                Announcer.announce("Full Disk Access is not granted. A warning banner has appeared at the top of the ACleaner window. Use the Open Settings button to grant access, then press Check Again.")
            }
        }
    }
}
