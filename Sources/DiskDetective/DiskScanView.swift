import SwiftUI

struct DiskScanView: View {
    @StateObject private var engine = ScanEngine()
    @State private var showConfirm = false
    @State private var showScanComplete = false
    @State private var now = Date()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    // Scan options
    @State private var includeKnown  = true
    @State private var includeRecent = false
    @State private var recentHours   = 24
    @State private var includeTop    = false

    // Collapsed category state — persists while the app is open
    @State private var collapsedCategories: Set<String> = []

    // Excluded categories — hidden from results without re-scanning
    @State private var excludedCategories: Set<String> = []
    @State private var showCategoryFilter = false

    private var selectedItems: [ScanItem] { engine.items.filter(\.isSelected) }
    private var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + $1.sizeBytes } }

    // FDA detection — checked once on appear and cached so it doesn't re-run on every render.
    @State private var hasFullDiskAccess: Bool = true   // optimistic default; checked on appear

    private let home = FileManager.default.homeDirectoryForCurrentUser.path

    /// Delegates to PermissionsChecker so all FDA detection is in one place.
    private static func checkFullDiskAccess() -> Bool {
        PermissionsChecker.hasFullDiskAccess
    }

    /// All categories discovered in scan results, in first-seen order.
    private var allCategories: [String] {
        var seen = Set<String>()
        var order: [String] = []
        for item in engine.items {
            if seen.insert(item.category).inserted { order.append(item.category) }
        }
        return order
    }

    /// Categories shown in the list — excludedCategories are filtered out.
    private var visibleCategories: [String] {
        allCategories.filter { !excludedCategories.contains($0) }
    }

    private func indices(for category: String) -> [Int] {
        engine.items.indices.filter { engine.items[$0].category == category }
    }

    private func categoryBytes(for category: String) -> Int64 {
        indices(for: category).reduce(0) { $0 + engine.items[$1].sizeBytes }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            scanOptionsBar
            if !hasFullDiskAccess {
                Divider()
                fullDiskAccessBanner
            }
            Divider()
            mainContent
            Divider()
            if engine.lastFreedBytes > 0 {
                freedBytesBar
                Divider()
            }
            footerBar
        }
        .onAppear {
            hasFullDiskAccess = DiskScanView.checkFullDiskAccess()
        }
        .onReceive(timer) { _ in
            if engine.isScanning { now = Date() }
        }
        .onChange(of: engine.scanComplete) { complete in
            // Re-check FDA after each scan — user may have granted it during the scan
            if complete { hasFullDiskAccess = DiskScanView.checkFullDiskAccess() }
            if complete, engine.completionSummary != nil {
                showScanComplete = true
            }
        }
        .alert("Confirm Deletion", isPresented: $showConfirm) {
            Button("Delete", role: .destructive) {
                Task { await engine.deleteSelected() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmMessage)
        }
        .alert("Scan Complete", isPresented: $showScanComplete) {
            Button("OK") { showScanComplete = false }
        } message: {
            if let s = engine.completionSummary {
                Text("Found \(s.itemCount) item\(s.itemCount == 1 ? "" : "s") totalling \(formatBytes(s.totalBytes)).\nScan finished in \(s.durationString).")
            }
        }
    }

    private var confirmMessage: String {
        let autoCount = selectedItems.filter {
            switch $0.actionType {
            case .deleteDirectory, .deleteFile, .emptyTrash, .backgroundCommand: return true
            default: return false
            }
        }.count
        let terminalCount = selectedItems.filter {
            if case .shellCommand = $0.actionType { return true }
            return false
        }.count

        var parts: [String] = []
        if autoCount > 0 { parts.append("\(autoCount) item\(autoCount == 1 ? "" : "s") will be moved to Trash automatically") }
        if terminalCount > 0 { parts.append("\(terminalCount) will open in Terminal (requires your password)") }
        return parts.joined(separator: "\n")
    }

    // MARK: - Header

    @ViewBuilder
    private var headerBar: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "internaldrive")
                .font(.title2)
                .foregroundColor(.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text("Disk Detective")
                    .font(.headline)
                Group {
                    if engine.isScanning {
                        let elapsed = engine.scanStartDate.map { formatElapsed(now.timeIntervalSince($0)) } ?? ""
                        Text("\(engine.scanStatus)\(elapsed.isEmpty ? "" : " · \(elapsed)")")
                    } else if engine.scanComplete && !engine.items.isEmpty {
                        Text("\(engine.items.count) items found — \(formatBytes(engine.items.reduce(0) { $0 + $1.sizeBytes })) potentially recoverable")
                    } else if engine.scanComplete {
                        Text("No significant items found.")
                    } else {
                        Text("Click Scan Now to find what is using your disk space.")
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }

            Spacer()

            if engine.isScanning {
                ProgressView()
                    .scaleEffect(0.75)
                    .padding(.trailing, 4)
            }

            Button {
                Task {
                    await engine.startScan(
                        includeKnown:  includeKnown,
                        includeRecent: includeRecent,
                        recentHours:   recentHours,
                        includeTop:    includeTop
                    )
                }
            } label: {
                Label(engine.isScanning ? "Scanning…" : "Scan Now", systemImage: "magnifyingglass")
            }
            .disabled(engine.isScanning || (!includeKnown && !includeRecent && !includeTop))
            .keyboardShortcut("r", modifiers: .command)
            .accessibilityLabel(engine.isScanning ? "Scanning, please wait" : "Scan Now")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Scan options bar

    private var scanOptionsBar: some View {
        HStack(spacing: 18) {
            Text("Scan:")
                .font(.caption)
                .foregroundColor(.secondary)
                .accessibilityHidden(true)

            Toggle("Known locations", isOn: $includeKnown)
                .toggleStyle(.checkbox)
                .font(.callout)
                .accessibilityLabel("Include known locations scan")

            Toggle("Recent files", isOn: $includeRecent)
                .toggleStyle(.checkbox)
                .font(.callout)
                .accessibilityLabel("Include recent files scan")

            if includeRecent {
                Picker("", selection: $recentHours) {
                    Text("1 hour").tag(1)
                    Text("3 hours").tag(3)
                    Text("12 hours").tag(12)
                    Text("24 hours").tag(24)
                    Text("3 days").tag(72)
                    Text("5 days").tag(120)
                    Text("7 days").tag(168)
                }
                .pickerStyle(.menu)
                .frame(width: 110)
                .accessibilityLabel("Time window for recent files scan")
            }

            Toggle("Largest files on disk", isOn: $includeTop)
                .toggleStyle(.checkbox)
                .font(.callout)
                .accessibilityLabel("Include largest files scan — scans entire disk, takes a few minutes")

            if includeTop {
                Label("Takes a few minutes", systemImage: "clock")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(Color(nsColor: .controlBackgroundColor))
        .disabled(engine.isScanning)
    }

    // MARK: - Main content

    @ViewBuilder
    private var mainContent: some View {
        if engine.items.isEmpty {
            emptyState
        } else {
            List {
                ForEach(visibleCategories, id: \.self) { category in
                    let isCollapsed = collapsedCategories.contains(category)
                    let count       = indices(for: category).count

                    // Category header is a plain flat row — NOT a Section header.
                    // Keeping everything at one level means VoiceOver never needs
                    // to interact/uninteract to reach individual items underneath.
                    CategoryHeader(
                        category: category,
                        count: count,
                        bytesLabel: formatBytes(categoryBytes(for: category)),
                        isCollapsed: isCollapsed,
                        onToggleCollapse: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                if isCollapsed { collapsedCategories.remove(category) }
                                else           { collapsedCategories.insert(category) }
                            }
                        },
                        onHide: {
                            withAnimation { _ = excludedCategories.insert(category) }
                        }
                    )
                    .listRowBackground(Color(nsColor: .controlBackgroundColor))
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    .listRowSeparator(.hidden)

                    if !isCollapsed {
                        ForEach(indices(for: category), id: \.self) { index in
                            ScanItemRow(
                                item: Binding(
                                    get: { engine.items[index] },
                                    set: { engine.items[index] = $0 }
                                )
                            )
                        }
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: engine.isScanning ? "magnifyingglass" : (engine.scanComplete ? "checkmark.circle" : "internaldrive"))
                .font(.system(size: 56))
                .foregroundColor(engine.scanComplete ? .green : .secondary)
                .symbolEffect(.pulse, isActive: engine.isScanning)

            if engine.isScanning {
                Text(engine.scanStatus)
                    .font(.title3)
                    .foregroundColor(.secondary)
            } else if engine.scanComplete {
                Text("Nothing significant found.")
                    .font(.title3)
                    .foregroundColor(.secondary)
                Text("Try enabling \"Recent files\" or \"Largest files on disk\" for a broader search.\nYou can also lower the thresholds by enabling more scan options.")
                    .font(.body)
                    .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                    .multilineTextAlignment(.center)
            } else {
                Text("Press Scan Now to analyse your disk.")
                    .font(.title3)
                    .foregroundColor(.secondary)
                Text("The scan checks over 30 known locations for\ncaches, backups, games, logs, and more.")
                    .font(.body)
                    .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel(engine.isScanning
            ? "Scanning: \(engine.scanStatus)"
            : engine.scanComplete
                ? "Scan complete. Nothing significant found. Try enabling more scan options."
                : "No results yet. Press Scan Now to begin.")
    }

    // MARK: - Full Disk Access banner

    private var fullDiskAccessBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield")
                .foregroundColor(.orange)
                .font(.title3)

            VStack(alignment: .leading, spacing: 2) {
                Text("Full Disk Access not granted")
                    .font(.callout)
                    .fontWeight(.medium)
                Text("macOS will ask permission for each folder scanned. Grant Full Disk Access once in System Settings to avoid repeated prompts.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Button("Open System Settings") {
                NSWorkspace.shared.open(
                    URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
                )
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Full Disk Access not granted. macOS will prompt for each folder. Press Open System Settings to grant access once and avoid repeated prompts.")
    }

    // MARK: - Footer

    @ViewBuilder
    private var footerBar: some View {
        HStack(spacing: 10) {
            if selectedItems.isEmpty {
                Text(engine.scanComplete ? "Check the items you want to remove, then press Delete Selected." : "")
                    .font(.callout)
                    .foregroundColor(.secondary)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.accentColor)
                Text("\(selectedItems.count) item\(selectedItems.count == 1 ? "" : "s") selected — \(formatBytes(selectedBytes)) to free")
                    .font(.callout)
                    .fontWeight(.medium)
            }

            Spacer()

            if engine.scanComplete && !engine.items.isEmpty {
                Button("Select All") {
                    for i in engine.items.indices { engine.items[i].isSelected = true }
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("a", modifiers: .command)

                Button("Deselect All") {
                    for i in engine.items.indices { engine.items[i].isSelected = false }
                }
                .buttonStyle(.borderless)

                // Select only items that can be auto-deleted without manual steps
                Button("Select Safe Items") {
                    for i in engine.items.indices {
                        switch engine.items[i].actionType {
                        case .deleteDirectory, .deleteFile, .emptyTrash, .backgroundCommand:
                            engine.items[i].isSelected = true
                        case .shellCommand, .openInFinder:
                            engine.items[i].isSelected = false
                        }
                    }
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Select Safe Items — selects only items that can be automatically deleted, leaving items that need manual review untouched")

                // Category filter button
                Button {
                    showCategoryFilter = true
                } label: {
                    if excludedCategories.isEmpty {
                        Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
                    } else {
                        Label("\(excludedCategories.count) hidden", systemImage: "line.3.horizontal.decrease.circle.fill")
                            .foregroundColor(.accentColor)
                    }
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(excludedCategories.isEmpty
                    ? "Filter categories"
                    : "\(excludedCategories.count) categor\(excludedCategories.count == 1 ? "y" : "ies") hidden. Open filter.")
                .popover(isPresented: $showCategoryFilter, arrowEdge: .top) {
                    categoryFilterPopover
                }
            }

            Button("Delete Selected") {
                showConfirm = true
            }
            .buttonStyle(.borderedProminent)
            .disabled(selectedItems.isEmpty)
            .keyboardShortcut(.delete, modifiers: .command)
            .accessibilityLabel(selectedItems.isEmpty
                ? "Delete Selected, no items selected"
                : "Delete \(selectedItems.count) selected item\(selectedItems.count == 1 ? "" : "s"), freeing \(formatBytes(selectedBytes))")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Category filter popover

    private var categoryFilterPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Show / Hide Categories")
                    .font(.headline)
                Spacer()
                if !excludedCategories.isEmpty {
                    Button("Show All") {
                        withAnimation { excludedCategories.removeAll() }
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundColor(.accentColor)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)

            Divider()

            // One row per discovered category
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(allCategories, id: \.self) { category in
                        let isExcluded = excludedCategories.contains(category)
                        let count      = indices(for: category).count

                        HStack(spacing: 10) {
                            Toggle(isOn: Binding(
                                get: { !isExcluded },
                                set: { show in
                                    withAnimation {
                                        if show { excludedCategories.remove(category) }
                                        else    { excludedCategories.insert(category) }
                                    }
                                }
                            )) {
                                EmptyView()
                            }
                            .toggleStyle(.checkbox)
                            .labelsHidden()

                            VStack(alignment: .leading, spacing: 1) {
                                Text(category)
                                    .fontWeight(isExcluded ? .regular : .medium)
                                    .foregroundColor(isExcluded ? .secondary : .primary)
                                Text("\(count) item\(count == 1 ? "" : "s") · \(formatBytes(categoryBytes(for: category)))")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation {
                                if isExcluded { excludedCategories.remove(category) }
                                else          { excludedCategories.insert(category) }
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(category), \(count) item\(count == 1 ? "" : "s"), \(formatBytes(categoryBytes(for: category))). Currently \(isExcluded ? "hidden" : "shown").")
                        .accessibilityValue(isExcluded ? "hidden" : "shown")
                        .accessibilityAddTraits(.isButton)

                        Divider().padding(.leading, 42)
                    }
                }
            }
            .frame(maxHeight: 360)

            Divider()

            // Done button
            HStack {
                Spacer()
                Button("Done") { showCategoryFilter = false }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .keyboardShortcut(.return, modifiers: [])
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(width: 320)
        .accessibilityLabel("Category filter. Toggle categories to show or hide them in results.")
    }

    // MARK: - Freed bytes banner

    private var freedBytesBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
            Text("Done — \(formatBytes(engine.lastFreedBytes)) moved to Trash.")
                .font(.callout)
                .fontWeight(.medium)
            Spacer()
            Button("Dismiss") { engine.lastFreedBytes = 0 }
                .buttonStyle(.borderless)
                .font(.caption)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.green.opacity(0.12))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Deletion complete. \(formatBytes(engine.lastFreedBytes)) moved to Trash. Press Dismiss to close.")
    }

    // MARK: - Helpers

    func formatBytes(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        let mb = Double(bytes) / 1_048_576
        if gb >= 1.0 { return String(format: "%.1f GB", gb) }
        if mb >= 1.0 { return String(format: "%.0f MB", mb) }
        return "< 1 MB"
    }

    func formatElapsed(_ t: TimeInterval) -> String {
        let total = Int(t)
        let m = total / 60
        let s = total % 60
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }
}

// MARK: - Row

struct ScanItemRow: View {
    @Binding var item: ScanItem

    var body: some View {
        HStack(spacing: 10) {
            Toggle(isOn: $item.isSelected) {
                EmptyView()
            }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text(item.detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                if item.path != "/" && !item.path.isEmpty {
                    Text(item.displayPath)
                        .font(.caption)
                        .foregroundColor(Color(nsColor: .secondaryLabelColor))
                        .lineLimit(1)
                        .truncationMode(.head)   // keep the filename end visible, trim the front
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                Text(item.sizeString)
                    .fontWeight(.semibold)
                    .foregroundColor(item.sizeColor)
                    .monospacedDigit()
                    .frame(minWidth: 70, alignment: .trailing)

                Text(item.methodLabel)
                    .font(.caption2)
                    .foregroundColor(item.methodColor)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(item.methodColor.opacity(0.1))
                    .cornerRadius(4)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { item.isSelected.toggle() }
        .contextMenu {
            // Always available: reveal in Finder
            Button {
                revealInFinder()
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }

            // Open if it's an app or known-openable type
            if item.path.hasSuffix(".app") {
                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: item.path))
                } label: {
                    Label("Open Application", systemImage: "arrow.up.forward.app")
                }
            }

            Divider()

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.path, forType: .string)
            } label: {
                Label("Copy Full Path", systemImage: "doc.on.clipboard")
            }

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.name, forType: .string)
            } label: {
                Label("Copy Name", systemImage: "doc.on.doc")
            }

            Divider()

            Button {
                item.isSelected.toggle()
            } label: {
                Label(item.isSelected ? "Deselect" : "Select for Deletion",
                      systemImage: item.isSelected ? "checkmark.circle.fill" : "checkmark.circle")
            }
        }
        // VoiceOver: read the whole row as one element
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.name). \(item.detail). Path: \(item.displayPath). Size: \(item.sizeString). \(item.methodLabel).")
        .accessibilityValue(item.isSelected ? "checked" : "unchecked")
        .accessibilityAddTraits(.isButton)
        // Default action fires on Enter / VO+Space — toggles selection
        .accessibilityAction { item.isSelected.toggle() }
        .accessibilityAction(named: "Toggle selection") { item.isSelected.toggle() }
        .accessibilityAction(named: "Reveal in Finder") { revealInFinder() }
        .accessibilityAction(named: "Copy path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.path, forType: .string)
        }
    }

    private func revealInFinder() {
        let url = URL(fileURLWithPath: item.path)
        if FileManager.default.fileExists(atPath: item.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }
}

// MARK: - Category section header

struct CategoryHeader: View {
    let category: String
    let count: Int
    let bytesLabel: String
    let isCollapsed: Bool
    let onToggleCollapse: () -> Void
    let onHide: () -> Void

    private var countLabel: String { count == 1 ? "1 item" : "\(count) items" }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.down")
                .font(.caption)
                .foregroundColor(.secondary)
                .rotationEffect(isCollapsed ? .degrees(-90) : .zero)
                .animation(.easeInOut(duration: 0.2), value: isCollapsed)

            Text(category)
                .fontWeight(.semibold)

            if isCollapsed {
                Text("(\(countLabel))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Text(bytesLabel)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { onToggleCollapse() }
        .contextMenu {
            Button(action: onHide) {
                Label("Hide \"\(category)\" from Results", systemImage: "eye.slash")
            }
            Divider()
            Button(action: onToggleCollapse) {
                Label(isCollapsed ? "Expand" : "Collapse",
                      systemImage: isCollapsed ? "chevron.down" : "chevron.right")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(category), \(countLabel), \(bytesLabel). \(isCollapsed ? "Collapsed" : "Expanded").")
        .accessibilityAddTraits(.isButton)
        // Default action fires on Enter / VO+Space — expands or collapses
        .accessibilityAction { onToggleCollapse() }
        .accessibilityAction(named: isCollapsed ? "Expand" : "Collapse") { onToggleCollapse() }
        .accessibilityAction(named: "Hide category") { onHide() }
    }
}
