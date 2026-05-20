import SwiftUI

enum DiskTab: String, CaseIterable {
    case diskScan    = "Disk Scan"
    case timeMachine = "Time Machine"
    case appCleaner  = "App Cleaner"
    case orphans     = "Orphaned Files"
    case history     = "History"

    var icon: String {
        switch self {
        case .diskScan:    return "internaldrive"
        case .timeMachine: return "clock.arrow.circlepath"
        case .appCleaner:  return "app.badge.minus"
        case .orphans:     return "questionmark.folder"
        case .history:     return "chart.xyaxis.line"
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
            }
        }
    }
}
