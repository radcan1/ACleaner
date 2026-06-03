import SwiftUI

enum ACleanerTool: String, CaseIterable, Identifiable {
    case updater        = "Updater"
    case diskDetective  = "Disk Detective"
    case cleanUninstall = "Clean Uninstall"
    case startupManager = "Startup Manager"
    case llmScanner     = "LLM Scanner"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .updater:        return "arrow.down.circle"
        case .diskDetective:  return "internaldrive"
        case .cleanUninstall: return "trash.slash"
        case .startupManager: return "power"
        case .llmScanner:     return "cpu"
        }
    }
}

struct RootView: View {
    let cleanState: AppState
    @EnvironmentObject var updateChecker: UpdateChecker
    @State private var selected: ACleanerTool? = .updater
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
                case .updater:
                    UpdaterView()
                case .diskDetective:
                    DiskDetectiveView()
                case .cleanUninstall:
                    MainView()
                        .environmentObject(cleanState)
                        .frame(minWidth: 640, minHeight: 480)
                case .startupManager:
                    StartupManagerView()
                        .frame(minWidth: 640, minHeight: 480)
                case .llmScanner:
                    LLMScannerView()
                        .frame(minWidth: 640, minHeight: 480)
                case nil:
                    Text("Select a tool from the sidebar.")
                        .font(.title2)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .accessibilityLabel("ACleaner")
            .onAppear { checkFDA() }
            // Sheet is only opened via ACleaner menu → Privacy & Permissions.
            // It is never auto-shown on launch.
            .sheet(isPresented: $showPermissions) {
                PermissionsView { showPermissions = false }
            }
            // Switch to Clean Uninstall tab when trash watcher detects an app
            .onReceive(NotificationCenter.default.publisher(for: .acleanerShowCleanUninstall)) { _ in
                selected = .cleanUninstall
            }
            // Open permissions sheet from the menu bar item
            .onReceive(NotificationCenter.default.publisher(for: .acleanerShowPermissions)) { _ in
                showPermissions = true
            }

        } // end VStack
    }

    // MARK: - FDA banner

    private var fdaBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield.fill")
                .foregroundColor(.orange)
                .accessibilityHidden(true)
            Text("Full Disk Access not granted — Disk Detective and Clean Uninstall may not work correctly.")
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
        .accessibilityLabel("Full Disk Access not granted. Disk Detective and Clean Uninstall need this permission to scan your Library folders. Press Open Settings to grant it in System Settings, then press Check Again once done.")
    }

    // MARK: - Update banner

    private func updateBanner(version: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundColor(.accentColor)
                .accessibilityHidden(true)
            Text("ACleaner \(version) is available")
                .fontWeight(.medium)
            Spacer()
            Button("Download Update") {
                NSWorkspace.shared.open(updateChecker.releasePageURL)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .accessibilityHint("Opens the GitHub releases page in your browser.")
            Button {
                updateChecker.dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Dismiss update notification")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Update available: ACleaner \(version). Download Update button.")
    }

    // MARK: - FDA check

    /// Checks FDA on a background thread (same pattern as Pearcleaner).
    /// Updates the banner and announces via VoiceOver if access is missing.
    private func checkFDA() {
        PermissionsChecker.checkAsync { granted in
            hasFullDiskAccess = granted
            if !granted {
                NSAccessibility.post(
                    element: NSApp as Any,
                    notification: .announcementRequested,
                    userInfo: [
                        .announcement: "Full Disk Access is not granted. A warning banner has appeared at the top of the ACleaner window. Use the Open Settings button to grant access, then press Check Again.",
                        .priority: NSAccessibilityPriorityLevel.high.rawValue
                    ]
                )
            }
        }
    }
}
