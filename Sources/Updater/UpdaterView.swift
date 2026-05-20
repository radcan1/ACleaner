import SwiftUI
import AppKit

enum UpdaterTab: String, CaseIterable, Identifiable {
    case updates, install, maintenance
    var id: String { rawValue }

    var label: String {
        switch self {
        case .updates:     return "Updates"
        case .install:     return "Install"
        case .maintenance: return "Maintenance"
        }
    }

    var systemImage: String {
        switch self {
        case .updates:     return "arrow.down.circle"
        case .install:     return "plus.app"
        case .maintenance: return "wand.and.sparkles"
        }
    }
}

struct UpdaterView: View {
    @StateObject private var skipList: SkipList
    @StateObject private var updateEngine: UpdateEngine
    @StateObject private var installEngine: InstallEngine
    @StateObject private var maintenanceEngine: MaintenanceEngine

    @State private var tab: UpdaterTab = .updates
    @State private var showSkipped = false

    init() {
        let sl = SkipList()
        _skipList = StateObject(wrappedValue: sl)
        _updateEngine = StateObject(wrappedValue: UpdateEngine(skipList: sl))
        _installEngine = StateObject(wrappedValue: InstallEngine())
        _maintenanceEngine = StateObject(wrappedValue: MaintenanceEngine())
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            currentView
        }
        .sheet(isPresented: $showSkipped) {
            SkippedAppsSheet(skipList: skipList) {
                Task { await updateEngine.reapplySkipFilter() }
            }
        }
    }

    @ViewBuilder
    private var tabBar: some View {
        HStack(spacing: 12) {
            Picker("View", selection: $tab) {
                ForEach(UpdaterTab.allCases) { t in
                    Label(t.label, systemImage: t.systemImage).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 420)
            .accessibilityLabel("View selector")

            Spacer()

            Button {
                showSkipped = true
            } label: {
                Label("Skipped (\(skipList.entries.count))", systemImage: "nosign")
            }
            .buttonStyle(.borderless)
            .help("View the list of apps you have chosen to skip.")
            .accessibilityLabel("View skipped apps. \(skipList.entries.count) currently skipped.")
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    @ViewBuilder
    private var currentView: some View {
        switch tab {
        case .updates:
            UpdatesView(engine: updateEngine, skipList: skipList)
        case .install:
            InstallView(engine: installEngine)
        case .maintenance:
            MaintenanceView(engine: maintenanceEngine)
        }
    }
}

// MARK: - Updates view (extracted)

struct UpdatesView: View {
    @ObservedObject var engine: UpdateEngine
    @ObservedObject var skipList: SkipList

    /// Set to a row's item to open the release-notes sheet for that row.
    @State private var notesItem: OutdatedItem? = nil

    private var selectedItems: [OutdatedItem] { engine.items.filter(\.isSelected) }

    private var categories: [UpdateKind] {
        var seen = Set<UpdateKind>()
        var order: [UpdateKind] = []
        for item in engine.items where seen.insert(item.kind).inserted {
            order.append(item.kind)
        }
        return order
    }

    private func indices(for kind: UpdateKind) -> [Int] {
        engine.items.indices.filter { engine.items[$0].kind == kind }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            optionsBar
            Divider()
            mainContent
            Divider()
            footerBar
        }
        .sheet(isPresented: $engine.sheetVisible) {
            UpdateLogSheet(engine: engine)
        }
        .sheet(item: $notesItem) { item in
            ReleaseNotesSheet(item: item)
        }
    }

    // MARK: Header

    @ViewBuilder
    private var headerBar: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "arrow.down.circle")
                .font(.title2)
                .foregroundColor(.accentColor)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("Updates")
                    .font(.headline)
                Group {
                    if engine.state == .checking {
                        Text(engine.checkStatus)
                    } else if engine.state == .ready {
                        Text(summaryText)
                    } else if case .done(let s, let f) = engine.state {
                        Text("Last run: \(s) succeeded, \(f) failed.")
                    } else {
                        Text("Click Check for Updates to scan Homebrew and the App Store.")
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
            .accessibilityElement(children: .combine)

            Spacer()

            if engine.state == .checking {
                ProgressView().scaleEffect(0.75).accessibilityHidden(true)
            }

            Button {
                Task { await engine.checkForUpdates() }
            } label: {
                Label(engine.state == .checking ? "Checking…" : "Check for Updates",
                      systemImage: "arrow.clockwise")
            }
            .disabled(engine.state == .checking || engine.state == .upgrading)
            .keyboardShortcut("r", modifiers: .command)
            .accessibilityLabel(engine.state == .checking
                ? "Checking for updates, please wait"
                : "Check for Updates")
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var summaryText: String {
        let total = engine.items.count
        if total == 0 {
            return engine.hiddenSkippedCount > 0
                ? "Everything is up to date (\(engine.hiddenSkippedCount) skipped)."
                : "Everything is up to date."
        }
        var parts: [String] = []
        for kind in [UpdateKind.cask, .formula, .mas] {
            let n = engine.items.filter { $0.kind == kind }.count
            if n > 0 { parts.append("\(n) \(kind.displayLabel.lowercased())\(n == 1 ? "" : "s")") }
        }
        let breakdown = parts.joined(separator: ", ")
        let skipSuffix = engine.hiddenSkippedCount > 0 ? " (\(engine.hiddenSkippedCount) skipped)" : ""
        let sizeSuffix = totalSizeSuffix(of: engine.items)
        return "\(total) update\(total == 1 ? "" : "s") available — \(breakdown)\(sizeSuffix)\(skipSuffix)."
    }

    /// " · 1.2 GB" or " · 1.2 GB+" if some sizes are still loading or unknown.
    /// Empty when nothing is known yet.
    private func totalSizeSuffix(of items: [OutdatedItem]) -> String {
        let known = items.compactMap { $0.sizeBytes }
        guard !known.isEmpty else { return "" }
        let total = known.reduce(0, +)
        let allKnown = known.count == items.count
        return " · " + SizeFormat.bytes(total) + (allKnown ? "" : "+")
    }

    private var selectionAccessibilityLabel: String {
        let known = selectedItems.compactMap { $0.sizeBytes }
        let total = known.reduce(0, +)
        if known.isEmpty {
            return "\(selectedItems.count) of \(engine.items.count) selected. Download size unknown."
        }
        let qualifier = known.count == selectedItems.count ? "" : " or more"
        return "\(selectedItems.count) of \(engine.items.count) selected. Total download \(SizeFormat.spoken(total))\(qualifier)."
    }

    // MARK: Options bar

    private var optionsBar: some View {
        HStack(spacing: 18) {
            Text("Scan:")
                .font(.caption).foregroundColor(.secondary)
                .accessibilityHidden(true)

            Toggle("App Store apps", isOn: $engine.includeMas)
                .toggleStyle(.checkbox)
                .font(.callout)
                .accessibilityLabel("Include Mac App Store apps")

            Toggle("Auto-updating casks (--greedy)", isOn: $engine.includeGreedy)
                .toggleStyle(.checkbox)
                .font(.callout)
                .accessibilityLabel("Include auto-updating casks like Chrome and Brave")

            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 7)
        .background(Color(nsColor: .controlBackgroundColor))
        .disabled(engine.state == .checking || engine.state == .upgrading)
    }

    // MARK: Main content

    @ViewBuilder
    private var mainContent: some View {
        if engine.items.isEmpty {
            emptyState
        } else {
            List {
                ForEach(categories, id: \.self) { kind in
                    Section {
                        ForEach(indices(for: kind), id: \.self) { index in
                            OutdatedRow(
                                item: Binding(
                                    get: { engine.items[index] },
                                    set: { engine.items[index] = $0 }
                                ),
                                onSkip: { skip(at: index) },
                                onShowNotes: { notesItem = engine.items[index] }
                            )
                        }
                    } header: {
                        let count = indices(for: kind).count
                        HStack {
                            Text(sectionTitle(kind)).fontWeight(.semibold)
                            Spacer()
                            Text("\(count) item\(count == 1 ? "" : "s")")
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 2)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(sectionTitle(kind)), \(count) item\(count == 1 ? "" : "s")")
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        }
    }

    private func sectionTitle(_ kind: UpdateKind) -> String {
        switch kind {
        case .cask:    return "Homebrew Casks"
        case .formula: return "Homebrew Formulae"
        case .mas:     return "Mac App Store"
        }
    }

    private func skip(at index: Int) {
        guard engine.items.indices.contains(index) else { return }
        let item = engine.items[index]
        skipList.add(kind: item.kind, name: item.name)
        engine.items.remove(at: index)
        engine.hiddenSkippedCount += 1
        engine.announce("Skipped \(item.name). It will not be offered again until you unskip it.")
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: stateIcon)
                .font(.system(size: 56))
                .foregroundColor(.secondary)
                .accessibilityHidden(true)

            Text(emptyTitle).font(.title3).foregroundColor(.secondary)

            if engine.state == .idle {
                Text("The scan covers Homebrew formulae, Homebrew casks, and the Mac App Store.")
                    .font(.body)
                    .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(emptyAccessibilityLabel)
    }

    private var stateIcon: String {
        switch engine.state {
        case .checking: return "arrow.triangle.2.circlepath"
        case .ready:    return "checkmark.seal"
        case .done:     return "checkmark.seal"
        default:        return "arrow.down.circle"
        }
    }

    private var emptyTitle: String {
        switch engine.state {
        case .checking: return engine.checkStatus.isEmpty ? "Checking for updates…" : engine.checkStatus
        case .ready:    return engine.hiddenSkippedCount > 0
            ? "Everything is up to date (\(engine.hiddenSkippedCount) skipped)."
            : "Everything is up to date."
        case .done:     return "All done."
        default:        return "Press Check for Updates to begin."
        }
    }

    private var emptyAccessibilityLabel: String {
        switch engine.state {
        case .checking: return "Scanning: \(engine.checkStatus)"
        case .ready:    return emptyTitle
        case .done(let s, let f): return "Last run: \(s) succeeded, \(f) failed."
        default: return "No results yet. Press Check for Updates."
        }
    }

    // MARK: Footer

    @ViewBuilder
    private var footerBar: some View {
        HStack(spacing: 10) {
            if engine.items.isEmpty {
                Text("")
            } else if selectedItems.isEmpty {
                Text("Tick the apps you want to update, then press Update Selected.")
                    .font(.callout).foregroundColor(.secondary)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.accentColor).accessibilityHidden(true)
                Text("\(selectedItems.count) of \(engine.items.count) selected\(totalSizeSuffix(of: selectedItems))")
                    .font(.callout).fontWeight(.medium)
                    .accessibilityLabel(selectionAccessibilityLabel)
            }

            Spacer()

            if !engine.items.isEmpty {
                Button("Select All") {
                    for i in engine.items.indices { engine.items[i].isSelected = true }
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("a", modifiers: .command)

                Button("Deselect All") {
                    for i in engine.items.indices { engine.items[i].isSelected = false }
                }
                .buttonStyle(.borderless)

                Button("Update All") {
                    for i in engine.items.indices { engine.items[i].isSelected = true }
                    Task { await engine.upgradeSelected() }
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(engine.state == .upgrading)
                .accessibilityLabel("Update all \(engine.items.count) item\(engine.items.count == 1 ? "" : "s")")

                Button("Update Selected") {
                    Task { await engine.upgradeSelected() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedItems.isEmpty || engine.state == .upgrading)
                .keyboardShortcut(.return, modifiers: .command)
                .accessibilityLabel(selectedItems.isEmpty
                    ? "Update Selected, no items selected"
                    : "Update \(selectedItems.count) selected item\(selectedItems.count == 1 ? "" : "s")")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}

// MARK: Row

struct OutdatedRow: View {
    @Binding var item: OutdatedItem
    let onSkip: () -> Void
    let onShowNotes: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Toggle(isOn: $item.isSelected) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .frame(width: 18)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).fontWeight(.medium).lineLimit(1)
                HStack(spacing: 6) {
                    Text(item.versionString)
                        .lineLimit(1).monospacedDigit()
                    if item.sizeBytes != nil {
                        Text("·")
                        Text(SizeFormat.bytes(item.sizeBytes))
                            .monospacedDigit()
                    }
                }
                .font(.caption).foregroundColor(.secondary)
            }

            Spacer()

            Text(item.kind.displayLabel)
                .font(.caption2).foregroundColor(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color.secondary.opacity(0.12))
                .cornerRadius(4)

            // Info button: mouse-discoverable trigger for the release-notes
            // sheet. Hidden from VoiceOver because the whole row is collapsed
            // into one VO element with a "Show release notes" custom action.
            Button {
                onShowNotes()
            } label: {
                Image(systemName: "info.circle")
                    .foregroundColor(.accentColor)
            }
            .buttonStyle(.borderless)
            .help("Show release notes for \(item.name)")
            .accessibilityHidden(true)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { item.isSelected.toggle() }
        .contextMenu {
            Button("Show release notes…") { onShowNotes() }
            Button("Always skip this app") { onSkip() }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(item.isSelected ? "checked" : "unchecked")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Toggle selection")      { item.isSelected.toggle() }
        .accessibilityAction(named: "Show release notes")    { onShowNotes() }
        .accessibilityAction(named: "Always skip this app")  { onSkip() }
    }

    private var accessibilityLabel: String {
        let sizePart: String
        if item.sizeBytes != nil {
            sizePart = " Download size \(SizeFormat.spoken(item.sizeBytes))."
        } else {
            sizePart = ""
        }
        return "\(item.name). \(item.kind.displayLabel). \(item.currentVersion) to \(item.newVersion).\(sizePart)"
    }
}
