import SwiftUI

enum DiskTab: String, CaseIterable {
    case diskScan    = "Disk Scan"
    case folderSize  = "Browse"
    case timeMachine = "Time Machine"
    case appCleaner  = "App Cleaner"
    case orphans     = "Orphans"
    case history     = "History"
    case claude      = "Claude"

    var icon: String {
        switch self {
        case .diskScan:    return "internaldrive"
        case .folderSize:  return "folder.badge.magnifyingglass"
        case .timeMachine: return "clock.arrow.circlepath"
        case .appCleaner:  return "app.badge.minus"
        case .orphans:     return "questionmark.folder"
        case .history:     return "chart.xyaxis.line"
        case .claude:      return "bubbles.and.sparkles"
        }
    }
}

struct DiskDetectiveView: View {
    @State private var selectedTab: DiskTab = .diskScan

    var body: some View {
        VStack(spacing: 0) {
            // Tab bar
            Picker("Section", selection: $selectedTab) {
                ForEach(DiskTab.allCases, id: \.self) { tab in
                    Label(tab.rawValue, systemImage: tab.icon).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(nsColor: .windowBackgroundColor))
            .accessibilityLabel("Tab bar")

            Divider()

            // All three tabs are kept alive so state (scan results, TM list) is
            // preserved when switching tabs. Only the active tab is visible and
            // reachable by VoiceOver.
            ZStack {
                DiskScanView()
                    .opacity(selectedTab == .diskScan ? 1 : 0)
                    .allowsHitTesting(selectedTab == .diskScan)
                    .accessibilityHidden(selectedTab != .diskScan)

                FolderSizeView()
                    .opacity(selectedTab == .folderSize ? 1 : 0)
                    .allowsHitTesting(selectedTab == .folderSize)
                    .accessibilityHidden(selectedTab != .folderSize)

                TimeMachineView()
                    .opacity(selectedTab == .timeMachine ? 1 : 0)
                    .allowsHitTesting(selectedTab == .timeMachine)
                    .accessibilityHidden(selectedTab != .timeMachine)

                AppCleanerView()
                    .opacity(selectedTab == .appCleaner ? 1 : 0)
                    .allowsHitTesting(selectedTab == .appCleaner)
                    .accessibilityHidden(selectedTab != .appCleaner)

                OrphanView()
                    .opacity(selectedTab == .orphans ? 1 : 0)
                    .allowsHitTesting(selectedTab == .orphans)
                    .accessibilityHidden(selectedTab != .orphans)

                HistoryView()
                    .opacity(selectedTab == .history ? 1 : 0)
                    .allowsHitTesting(selectedTab == .history)
                    .accessibilityHidden(selectedTab != .history)

                ClaudeCleanupView()
                    .opacity(selectedTab == .claude ? 1 : 0)
                    .allowsHitTesting(selectedTab == .claude)
                    .accessibilityHidden(selectedTab != .claude)
            }
        }
    }
}
