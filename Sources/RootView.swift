import SwiftUI

enum ACleanerTool: String, CaseIterable, Identifiable {
    case updater       = "Updater"
    case diskDetective = "Disk Detective"
    case cleanUninstall = "Clean Uninstall"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .updater:        return "arrow.down.circle"
        case .diskDetective:  return "internaldrive"
        case .cleanUninstall: return "trash.slash"
        }
    }
}

struct RootView: View {
    let cleanState: AppState
    @EnvironmentObject var updateChecker: UpdateChecker
    @State private var selected: ACleanerTool? = .updater

    // Starts hidden. checkPermissionsIfNeeded() runs an async FDA test on first
    // appear and raises the sheet only when FDA is definitively not granted.
    // This mirrors Pearcleaner's pattern and eliminates false-positive flashes.
    @State private var showPermissions: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // Update banner — only visible when a newer release exists on GitHub
            if let version = updateChecker.availableVersion {
                updateBanner(version: version)
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
            case nil:
                Text("Select a tool from the sidebar.")
                    .font(.title2)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .accessibilityLabel("ACleaner")
        .onAppear { checkPermissionsIfNeeded() }
        .sheet(isPresented: $showPermissions, onDismiss: {
            // Mark acknowledged whenever the sheet is dismissed — whether the user
            // clicked Continue, pressed Escape, or clicked outside the sheet.
            // Without this, dismissing via Escape left hasBeenAcknowledged = false
            // and the sheet re-appeared on every launch.
            PermissionsChecker.hasBeenAcknowledged = true
        }) {
            PermissionsView {
                showPermissions = false
            }
        }
        // Switch to Clean Uninstall tab when the trash watcher detects an app
        .onReceive(NotificationCenter.default.publisher(for: .acleanerShowCleanUninstall)) { _ in
            selected = .cleanUninstall
        }
        // Re-open the permissions sheet from the menu bar item
        .onReceive(NotificationCenter.default.publisher(for: .acleanerShowPermissions)) { _ in
            showPermissions = true
        }
        } // end VStack
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

    // MARK: - Permissions check

    private func checkPermissionsIfNeeded() {
        PermissionsChecker.checkAsync { granted in
            if granted {
                // FDA confirmed — auto-acknowledge so we never bother the user again
                PermissionsChecker.hasBeenAcknowledged = true
            } else if !PermissionsChecker.hasBeenAcknowledged {
                // First launch and FDA genuinely not granted — show the sheet
                showPermissions = true
            }
            // If acknowledged but FDA was revoked (e.g., after an ad-hoc rebuild),
            // stay quiet. The user can re-open the sheet via ACleaner > Privacy & Permissions.
        }
    }
}
