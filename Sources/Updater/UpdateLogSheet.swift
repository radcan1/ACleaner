import SwiftUI

// Modal sheet shown while updates are running.
//
// Top:    progress line "Upgrading 3 of 7: microsoft-word" — kept short and
//         announced to VoiceOver by the engine.
// Middle: scrollable plain-text log of brew/mas output.
// Bottom: Cancel (while running) / Close (when finished) + Copy Log.

struct UpdateLogSheet: View {
    @ObservedObject var engine: UpdateEngine

    private var isRunning: Bool { engine.state == .upgrading }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            logView
            Divider()
            footerBar
        }
        .frame(minWidth: 640, minHeight: 420)
        .frame(idealWidth: 760, idealHeight: 520)
    }

    @ViewBuilder
    private var headerBar: some View {
        HStack(alignment: .center, spacing: 12) {
            Group {
                if isRunning {
                    ProgressView()
                        .scaleEffect(0.7)
                } else {
                    Image(systemName: stateIcon)
                        .foregroundColor(stateColor)
                        .font(.title3)
                }
            }
            .frame(width: 24)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(headerTitle)
                    .font(.headline)
                Text(headerSubtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(headerTitle). \(headerSubtitle).")

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var headerTitle: String {
        if isRunning {
            if engine.upgradeTotal > 0 {
                return "Upgrading \(engine.upgradeIndex) of \(engine.upgradeTotal)"
            }
            return "Upgrading…"
        }
        if case .done(let s, let f) = engine.state {
            if f == 0 { return "All \(s) update\(s == 1 ? "" : "s") complete." }
            return "\(s) succeeded, \(f) failed."
        }
        return "Mac Updater"
    }

    private var headerSubtitle: String {
        if isRunning {
            return engine.currentUpgradeName.isEmpty
                ? "Preparing…"
                : "Currently: \(engine.currentUpgradeName)"
        }
        if case .done(_, let f) = engine.state, f > 0 {
            return "Failed: " + engine.failedItems.joined(separator: ", ")
        }
        return ""
    }

    private var stateIcon: String {
        if case .done(_, let f) = engine.state, f > 0 { return "exclamationmark.triangle" }
        return "checkmark.circle"
    }

    private var stateColor: Color {
        if case .done(_, let f) = engine.state, f > 0 { return .orange }
        return .green
    }

    // MARK: Log

    @ViewBuilder
    private var logView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(engine.upgradeLog.isEmpty ? " " : engine.upgradeLog)
                    .id("logBottom-marker")
                    .font(.system(.callout, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .textSelection(.enabled)
                    // VoiceOver: keep the entire log as one selectable element rather
                    // than reading every line on scroll. Users who want to read it use
                    // VO+Cmd+A to read the field, or Copy Log to inspect elsewhere.
                    .accessibilityLabel("Update log")
            }
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: engine.upgradeLog) { _ in
                proxy.scrollTo("logBottom-marker", anchor: .bottom)
            }
        }
    }

    // MARK: Footer

    @ViewBuilder
    private var footerBar: some View {
        HStack(spacing: 10) {
            Button("Copy Log") {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(engine.upgradeLog, forType: .string)
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .accessibilityLabel("Copy log to clipboard")

            Spacer()

            if isRunning {
                Button("Cancel", role: .destructive) {
                    engine.cancelUpgrade()
                }
                .keyboardShortcut(".", modifiers: .command)
                .accessibilityLabel("Cancel the current update batch")
            } else {
                Button("Close") {
                    engine.sheetVisible = false
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .accessibilityLabel("Close update log")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
