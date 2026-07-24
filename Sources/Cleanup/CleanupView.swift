import SwiftUI

// One screen, one primary action. No list to review, no ticking — by
// construction everything this cleans regenerates automatically. The
// category breakdown lives in a collapsed disclosure for transparency,
// never as an obligation.
struct CleanupView: View {
    @StateObject private var engine = CleanupEngine()
    @State private var showDetails = false
    @AccessibilityFocusState private var focusCleanButton: Bool

    private var isCleaning: Bool {
        if case .cleaning = engine.state { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    cleanButton
                    statusSection
                    detailsSection
                    Spacer(minLength: 0)
                }
                .padding(16)
            }
        }
        .task {
            focusCleanButton = true
            await engine.estimate()
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Cleanup")
                .font(.title)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Text(engine.statusLine)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(16)
    }

    private var cleanButton: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                Task { await engine.cleanAll() }
            } label: {
                Label(cleanButtonTitle, systemImage: "sparkles")
                    .font(.title3)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isCleaning)
            .keyboardShortcut(.defaultAction)
            .accessibilityFocused($focusCleanButton)
            .accessibilityLabel(cleanButtonAccessibilityLabel)
            .accessibilityHint("Cleans caches, logs, Homebrew junk, and other files that rebuild themselves. Nothing here needs review.")

            Text("Everything cleaned here rebuilds itself automatically — caches, logs, Homebrew junk. Anything that needs a decision (language models, orphaned files, snapshots) lives in Disk Space instead.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var cleanButtonTitle: String {
        if isCleaning { return "Cleaning…" }
        let total = engine.totalEstimatedBytes
        return total > 0
            ? "Clean Now — \(CleanupEngine.formatBytes(total)) reclaimable"
            : "Clean Now"
    }

    private var cleanButtonAccessibilityLabel: String {
        if case .cleaning(let title) = engine.state { return "Cleaning \(title)" }
        let total = engine.totalEstimatedBytes
        return total > 0
            ? "Clean Now. \(CleanupEngine.formatBytes(total)) reclaimable."
            : "Clean Now"
    }

    @ViewBuilder
    private var statusSection: some View {
        if engine.state == .done, !engine.lastNotes.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Last cleanup — freed \(CleanupEngine.formatBytes(engine.lastFreedBytes))")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                ForEach(engine.lastNotes, id: \.self) { note in
                    Text(note)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .background(Color.green.opacity(0.08))
            .cornerRadius(8)
            .accessibilityElement(children: .combine)
        }
    }

    private var detailsSection: some View {
        DisclosureGroup(isExpanded: $showDetails) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(engine.categories) { cat in
                    HStack {
                        Text(cat.title)
                        Spacer()
                        Text(cat.detail)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .font(.callout)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(cat.title): \(cat.detail)")
                }
            }
            .padding(.top, 8)
        } label: {
            Text("What this cleans")
                .font(.headline)
        }
        .accessibilityHint("Expands the list of cleanup categories and their sizes. Informational only — Clean Now always cleans all of them.")
    }
}
