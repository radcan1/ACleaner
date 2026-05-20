import SwiftUI
import AppKit

struct InstallView: View {
    @ObservedObject var engine: InstallEngine

    @State private var queryDraft: String = ""

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            optionsBar
            Divider()
            content
        }
        .sheet(isPresented: $engine.sheetVisible) {
            InstallLogSheet(engine: engine)
        }
    }

    // MARK: Search bar

    @ViewBuilder
    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
                .accessibilityHidden(true)

            TextField("Search Homebrew and the App Store", text: $queryDraft)
                .textFieldStyle(.roundedBorder)
                .onSubmit { runSearch() }
                .accessibilityLabel("Search query for new apps")

            Button("Search") { runSearch() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(queryDraft.trimmingCharacters(in: .whitespaces).isEmpty
                          || engine.state == .searching)
                .accessibilityLabel("Run search")

            if !engine.searchMessage.isEmpty {
                Text(engine.searchMessage)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func runSearch() {
        engine.query = queryDraft
        Task { await engine.search() }
    }

    // MARK: Options bar

    private var optionsBar: some View {
        HStack(spacing: 18) {
            Text("Sources:")
                .font(.caption)
                .foregroundColor(.secondary)
                .accessibilityHidden(true)

            Toggle("Casks (apps)", isOn: $engine.includeCasks)
                .toggleStyle(.checkbox)
                .font(.callout)
                .accessibilityLabel("Search Homebrew casks")

            Toggle("Formulae (CLI tools)", isOn: $engine.includeFormulae)
                .toggleStyle(.checkbox)
                .font(.callout)
                .accessibilityLabel("Search Homebrew formulae")

            Toggle("App Store", isOn: $engine.includeMas)
                .toggleStyle(.checkbox)
                .font(.callout)
                .accessibilityLabel("Search the Mac App Store")

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if engine.results.isEmpty {
            emptyState
        } else {
            List(engine.results) { result in
                SearchResultRow(result: result) {
                    Task { await engine.install(result) }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 56))
                .foregroundColor(.secondary)
                .accessibilityHidden(true)
            Text(engine.state == .searching ? "Searching…" : "Type a name above to search.")
                .font(.title3)
                .foregroundColor(.secondary)
            Text("Examples: chrome, ripgrep, drafts. Multi-word queries work too.")
                .font(.body)
                .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(engine.state == .searching ? "Searching" : "No results yet. Type a query and press Search.")
    }
}

// MARK: Row

struct SearchResultRow: View {
    let result: SearchResult
    let onInstall: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(result.name)
                    .fontWeight(.medium)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(result.kind.displayLabel)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12))
                        .cornerRadius(4)
                    if let id = result.masId {
                        Text("id \(id)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    if result.isInstalled {
                        Text("installed")
                            .font(.caption2)
                            .foregroundColor(.orange)
                    }
                }
            }

            Spacer()

            Button(result.isInstalled ? "Reinstall" : "Install") {
                onInstall()
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(result.isInstalled
                                ? "Reinstall \(result.name)"
                                : "Install \(result.name)")
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(result.name). \(result.kind.displayLabel). \(result.isInstalled ? "Already installed." : "")")
    }
}

// MARK: Log sheet (parallels UpdateLogSheet but for installs)

struct InstallLogSheet: View {
    @ObservedObject var engine: InstallEngine

    private var isRunning: Bool {
        if case .installing = engine.state { return true }
        return false
    }

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
                } else if case .done(let success) = engine.state {
                    Image(systemName: success ? "checkmark.circle" : "exclamationmark.triangle")
                        .foregroundColor(success ? .green : .orange)
                        .font(.title3)
                } else {
                    Image(systemName: "arrow.down.app").font(.title3)
                }
            }
            .frame(width: 24)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(headerText)
                    .font(.headline)
                if !engine.currentInstallName.isEmpty {
                    Text("Currently: \(engine.currentInstallName)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(headerText)
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var headerText: String {
        switch engine.state {
        case .installing(let n): return "Installing \(n)…"
        case .done(let ok):      return ok ? "Install complete." : "Install failed."
        default:                 return "Install"
        }
    }

    @ViewBuilder
    private var logArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(engine.installLog.isEmpty ? " " : engine.installLog)
                    .id("installLogBottom")
                    .font(.system(.callout, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .textSelection(.enabled)
                    .accessibilityLabel("Install log")
            }
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: engine.installLog) { _ in
                proxy.scrollTo("installLogBottom", anchor: .bottom)
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack {
            Button("Copy Log") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(engine.installLog, forType: .string)
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            Spacer()
            Button("Close") { engine.sheetVisible = false }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isRunning)
                .accessibilityLabel("Close install log")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}
