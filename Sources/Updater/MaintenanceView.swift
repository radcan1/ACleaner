import SwiftUI
import AppKit

struct MaintenanceView: View {
    @ObservedObject var engine: MaintenanceEngine

    private var selected: [CleanupCandidate] { engine.candidates.filter(\.isSelected) }

    private var sections: [(label: String, kind: CleanupCandidate.Kind)] {
        [
            ("Old versions (brew cleanup)", .oldVersion),
            ("Unused dependencies (brew autoremove)", .orphanedFormula),
            ("Stale casks (.app missing from /Applications)", .staleCask)
        ]
    }

    private func indices(for kind: CleanupCandidate.Kind) -> [Int] {
        engine.candidates.indices.filter { engine.candidates[$0].kind == kind }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            content
            Divider()
            footerBar
        }
        .sheet(isPresented: $engine.sheetVisible) {
            MaintenanceLogSheet(engine: engine)
        }
    }

    // MARK: Header

    @ViewBuilder
    private var headerBar: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "wand.and.sparkles")
                .font(.title2)
                .foregroundColor(.accentColor)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("Maintenance")
                    .font(.headline)
                Group {
                    if engine.state == .scanning {
                        Text(engine.scanStatus)
                    } else if engine.state == .ready {
                        Text(summaryText)
                    } else if case .done(let n, let b) = engine.state {
                        Text("Removed \(n) item\(n == 1 ? "" : "s"). Freed \(MaintenanceEngine.formatBytes(b)).")
                    } else {
                        Text("Click Scan to find old versions, unused dependencies, and stale casks.")
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
            .accessibilityElement(children: .combine)

            Spacer()

            if engine.state == .scanning {
                ProgressView().scaleEffect(0.75).accessibilityHidden(true)
            }

            Button {
                Task { await engine.scan() }
            } label: {
                Label(engine.state == .scanning ? "Scanning…" : "Scan",
                      systemImage: "magnifyingglass")
            }
            .disabled(engine.state == .scanning || engine.state == .acting)
            .keyboardShortcut("r", modifiers: [.command, .option])
            .accessibilityLabel(engine.state == .scanning
                ? "Scanning, please wait"
                : "Scan for maintenance items")
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var summaryText: String {
        if engine.candidates.isEmpty { return "Nothing to clean up." }
        var parts: [String] = []
        for s in sections {
            let n = indices(for: s.kind).count
            if n > 0 { parts.append("\(n) \(s.kind.shortLabelBase)\(n == 1 ? "" : "s")") }
        }
        let breakdown = parts.joined(separator: ", ")
        if engine.freeableBytes > 0 {
            return "\(breakdown). Could free \(MaintenanceEngine.formatBytes(engine.freeableBytes))."
        }
        return breakdown + "."
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if engine.candidates.isEmpty {
            empty
        } else {
            List {
                ForEach(sections, id: \.kind) { section in
                    let idxs = indices(for: section.kind)
                    if !idxs.isEmpty {
                        Section {
                            ForEach(idxs, id: \.self) { i in
                                MaintenanceRow(item: Binding(
                                    get: { engine.candidates[i] },
                                    set: { engine.candidates[i] = $0 }
                                ))
                            }
                        } header: {
                            HStack {
                                Text(section.label).fontWeight(.semibold)
                                Spacer()
                                Text("\(idxs.count) item\(idxs.count == 1 ? "" : "s")")
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 2)
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("\(section.label), \(idxs.count) item\(idxs.count == 1 ? "" : "s")")
                        }
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        }
    }

    @ViewBuilder
    private var empty: some View {
        VStack(spacing: 12) {
            Image(systemName: engine.state == .scanning ? "magnifyingglass" : "wand.and.sparkles")
                .font(.system(size: 56))
                .foregroundColor(.secondary)
                .accessibilityHidden(true)
            Text(emptyText)
                .font(.title3)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(emptyText)
    }

    private var emptyText: String {
        switch engine.state {
        case .scanning: return engine.scanStatus.isEmpty ? "Scanning…" : engine.scanStatus
        case .ready:    return "Nothing to clean up."
        case .done:     return "All done."
        default:        return "Press Scan to begin."
        }
    }

    // MARK: Footer

    @ViewBuilder
    private var footerBar: some View {
        HStack(spacing: 10) {
            if engine.candidates.isEmpty {
                Text("")
            } else if selected.isEmpty {
                Text("Tick items, then press Clean Up Selected.")
                    .font(.callout)
                    .foregroundColor(.secondary)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.accentColor)
                    .accessibilityHidden(true)
                Text("\(selected.count) of \(engine.candidates.count) selected")
                    .font(.callout).fontWeight(.medium)
            }

            Spacer()

            if !engine.candidates.isEmpty {
                Button("Select All") {
                    for i in engine.candidates.indices { engine.candidates[i].isSelected = true }
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("a", modifiers: .command)

                Button("Deselect All") {
                    for i in engine.candidates.indices { engine.candidates[i].isSelected = false }
                }
                .buttonStyle(.borderless)

                Button("Clean Up Selected") {
                    Task { await engine.performSelected() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selected.isEmpty || engine.state == .acting)
                .keyboardShortcut(.return, modifiers: .command)
                .accessibilityLabel(selected.isEmpty
                    ? "Clean Up Selected, no items selected"
                    : "Clean up \(selected.count) selected item\(selected.count == 1 ? "" : "s")")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}

// MARK: Row

struct MaintenanceRow: View {
    @Binding var item: CleanupCandidate

    var body: some View {
        HStack(spacing: 10) {
            Toggle(isOn: $item.isSelected) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .frame(width: 18)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text(item.detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Text(item.kind.badge)
                .font(.caption2)
                .foregroundColor(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.12))
                .cornerRadius(4)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { item.isSelected.toggle() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.name). \(item.kind.badge). \(item.detail).")
        .accessibilityValue(item.isSelected ? "checked" : "unchecked")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Toggle selection") { item.isSelected.toggle() }
    }
}

private extension CleanupCandidate.Kind {
    var badge: String {
        switch self {
        case .oldVersion:       return "Old version"
        case .orphanedFormula:  return "Unused"
        case .staleCask:        return "Stale cask"
        }
    }
    var shortLabelBase: String {
        switch self {
        case .oldVersion:       return "old version"
        case .orphanedFormula:  return "unused dependency"
        case .staleCask:        return "stale cask"
        }
    }
}

// MARK: Log sheet

struct MaintenanceLogSheet: View {
    @ObservedObject var engine: MaintenanceEngine

    private var isRunning: Bool { engine.state == .acting }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            logArea
            Divider()
            footer
        }
        .frame(minWidth: 640, minHeight: 420)
        .frame(idealWidth: 760, idealHeight: 500)
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 12) {
            Group {
                if isRunning {
                    ProgressView().scaleEffect(0.7)
                } else if case .done = engine.state {
                    Image(systemName: "checkmark.circle").foregroundColor(.green).font(.title3)
                } else {
                    Image(systemName: "wand.and.sparkles").font(.title3)
                }
            }
            .frame(width: 24)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(headerText).font(.headline)
            }
            .accessibilityLabel(headerText)
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var headerText: String {
        switch engine.state {
        case .acting: return "Cleaning up…"
        case .done(let n, let b):
            return "Removed \(n) item\(n == 1 ? "" : "s"). Freed \(MaintenanceEngine.formatBytes(b))."
        default: return "Maintenance"
        }
    }

    @ViewBuilder
    private var logArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(engine.actionLog.isEmpty ? " " : engine.actionLog)
                    .id("maintLogBottom")
                    .font(.system(.callout, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .textSelection(.enabled)
                    .accessibilityLabel("Maintenance log")
            }
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: engine.actionLog) { _ in
                proxy.scrollTo("maintLogBottom", anchor: .bottom)
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack {
            Button("Copy Log") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(engine.actionLog, forType: .string)
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            Spacer()
            Button("Close") { engine.sheetVisible = false }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isRunning)
                .accessibilityLabel("Close maintenance log")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}
