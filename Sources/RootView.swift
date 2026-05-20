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
    @State private var selected: ACleanerTool? = .updater
    @State private var showPermissions: Bool = !PermissionsChecker.allGranted

    var body: some View {
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
        .sheet(isPresented: $showPermissions) {
            PermissionsView {
                showPermissions = false
            }
        }
    }
}
