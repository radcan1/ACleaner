import SwiftUI

struct MainView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding()
        // Error alert — populated by AppState when the trash operation fails
        .alert("Could Not Uninstall App", isPresented: Binding(
            get:  { state.trashingError != nil },
            set:  { if !$0 { state.trashingError = nil } }
        )) {
            Button("OK", role: .cancel) { state.trashingError = nil }
        } message: {
            Text(state.trashingError ?? "")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Uninstall")
                .font(.title)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Toggle(isOn: Binding(
                get: { state.watchEnabled },
                set: { state.setWatch($0) }
            )) {
                Text("Watch Trash")
            }
            .toggleStyle(.switch)
            .accessibilityLabel("Watch the Trash for applications")
            .accessibilityHint(state.watchEnabled
                ? "Currently watching. Switch off to stop monitoring."
                : "Currently off. Switch on to start monitoring.")
        }
        .padding(.bottom, 8)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch state.phase {
        case .idle:
            IdleView()
        case .trashing(let name):
            ProgressMessageView(message: "Moving \"\(name)\" to the Trash\u{2026}")
        case .scanning(let app):
            ScanningView(app: app)
        case .results(let app, let files):
            ResultsView(app: app, files: files)
        case .cleaning:
            ProgressMessageView(message: "Moving items to the Trash. Please wait.")
        }
    }
}

// MARK: - Idle

struct IdleView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {

                // ── Apps currently in Trash ───────────────────────────────
                if !state.appsInTrash.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 6) {
                            Image(systemName: "trash.fill")
                                .foregroundStyle(.orange)
                            Text("Apps in Trash")
                                .font(.headline)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(.isHeader)
                        Text("These apps are in your Trash. Scan any of them to find and remove leftover files.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        ForEach(state.appsInTrash, id: \.trashURL) { app in
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(app.displayName)
                                        .fontWeight(.medium)
                                    if let id = app.bundleIdentifier {
                                        Text(id)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Button("Scan for leftovers") {
                                    state.scanExistingTrashedApp(app)
                                }
                                .controlSize(.small)
                                .accessibilityLabel("Scan \(app.displayName) for leftover files")
                            }
                            .padding(.vertical, 4)
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .padding(14)
                    .background(Color.orange.opacity(0.08))
                    .cornerRadius(10)
                    .overlay(RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.orange.opacity(0.3), lineWidth: 1))

                    Divider()
                }

                // ── Direct uninstall: inline searchable list, no sheet ─────
                VStack(alignment: .leading, spacing: 8) {
                    Text("Uninstall an App")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    Text("Press an app to move it to the Trash and scan for its leftover files. Everything goes to the Trash — recoverable until you empty it.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    InlineAppPicker { appURL in
                        state.trashAndScan(appURL: appURL)
                    }
                    .frame(minHeight: 260)
                }
                .padding(14)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(10)
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1))

                Divider()

                // ── Trash watcher status ──────────────────────────────────
                VStack(alignment: .leading, spacing: 6) {
                    Text("Trash Watcher")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    Text(state.watchEnabled
                         ? "Watching the Trash. When you move an app to the Trash, ACleaner will offer to remove its leftover files automatically."
                         : "Watching is off. Turn on the Watch Trash switch to enable automatic detection.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // ── Recent events ─────────────────────────────────────────
                Text("Recent events")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                if state.recentEvents.isEmpty {
                    Text("No applications detected yet.")
                        .foregroundStyle(.secondary)
                } else {
                    List(Array(state.recentEvents.enumerated()), id: \.offset) { _, event in
                        Text(event)
                    }
                    .accessibilityLabel("Recent detection events")
                    .frame(minHeight: 120)
                }

                Spacer(minLength: 0)
            }
        }
        .onAppear { state.refreshTrashContents() }
    }
}

// MARK: - Detection

struct DetectionView: View {
    let app: TrashedApp
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("\(app.displayName) was moved to the Trash")
                .font(.title2)
                .accessibilityAddTraits(.isHeader)

            Text("Would you like ACleaner to find and remove the application's leftover files such as preferences, caches, and support data?")
                .fixedSize(horizontal: false, vertical: true)

            if let bundleID = app.bundleIdentifier {
                LabeledContent("Bundle identifier", value: bundleID)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Bundle identifier: \(bundleID)")
            }
            LabeledContent("Location in Trash", value: app.trashURL.path)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Location in Trash: \(app.trashURL.path)")

            HStack(spacing: 12) {
                Button("Scan for leftover files") { state.startScan(app) }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityHint("Searches your Library folders and reports files associated with \(app.displayName).")
                Button("Not now") { state.dismissDetection() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityHint("Dismisses the detection without scanning.")
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Scanning

struct ScanningView: View {
    let app: TrashedApp

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Scanning for files associated with \(app.displayName)")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            ProgressView()
                .progressViewStyle(.linear)
                .accessibilityLabel("Scanning in progress")
            Text("This usually takes a few seconds.")
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Progress message

struct ProgressMessageView: View {
    let message: String
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(message).font(.headline).accessibilityAddTraits(.isHeader)
            ProgressView().progressViewStyle(.linear).accessibilityLabel("Working")
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Results

struct ResultsView: View {
    let app: TrashedApp
    let files: [LeftoverFile]
    @EnvironmentObject var state: AppState
    @AccessibilityFocusState private var focusRemoveButton: Bool

    private var totalBytes: Int64 {
        files.filter { state.selection.contains($0.url) }
             .map(\.sizeBytes).reduce(0, +)
    }

    private var summaryLabel: String {
        let count = state.selection.count
        let size = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        return "\(count) of \(files.count) items selected, totaling \(size)."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Leftover files for \(app.displayName)")
                .font(.title3)
                .accessibilityAddTraits(.isHeader)

            HStack {
                Text(summaryLabel)
                    .accessibilityLabel(summaryLabel)
                Spacer()
                Button("Select all") {
                    state.selection = Set(files.map(\.url))
                }
                .accessibilityHint("Selects every leftover file in the list.")
                Button("Select none") {
                    state.selection = []
                }
                .accessibilityHint("Clears the selection.")
            }

            List {
                ForEach(files) { file in
                    Toggle(isOn: Binding(
                        get: { state.selection.contains(file.url) },
                        set: { newValue in
                            if newValue { state.selection.insert(file.url) }
                            else { state.selection.remove(file.url) }
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.url.lastPathComponent)
                                .font(.body)
                            Text("\(file.category) — \(file.sizeDescription)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(file.locationDescription)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .truncationMode(.middle)
                        }
                    }
                    .toggleStyle(.checkbox)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(file.category): \(file.url.lastPathComponent), \(file.sizeDescription), at \(file.locationDescription)")
                    .accessibilityValue(state.selection.contains(file.url) ? "selected for removal" : "not selected")
                    .accessibilityHint("Toggles whether this item will be moved to the Trash.")
                }
            }
            .accessibilityLabel("Leftover files. \(files.count) items.")

            HStack(spacing: 12) {
                Button(removeButtonTitle) {
                    state.performCleanup(app, items: files)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(state.selection.isEmpty)
                .accessibilityFocused($focusRemoveButton)
                .accessibilityHint("Moves the selected leftovers to the Trash. Press Return to confirm.")

                Button("Keep leftovers") { state.resetToIdle() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityHint("Leaves all files in place and returns to the app list.")
            }
        }
        .onAppear {
            // Land VoiceOver on the primary action: one Return press finishes
            // the uninstall. The review list stays available above it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                focusRemoveButton = true
            }
        }
    }

    private var removeButtonTitle: String {
        let size = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        return "Remove \(state.selection.count) leftover\(state.selection.count == 1 ? "" : "s") (\(size))"
    }
}

// MARK: - Done

struct DoneView: View {
    let app: TrashedApp
    let removed: Int
    let failed: [String]
    @EnvironmentObject var state: AppState
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {

            Text("Cleanup finished")
                .font(.title3)
                .accessibilityAddTraits(.isHeader)

            Text("Moved \(removed) item\(removed == 1 ? "" : "s") to the Trash.")

            if !failed.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("\(failed.count) item\(failed.count == 1 ? "" : "s") could not be deleted")
                            .font(.headline)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isHeader)

                    // Scrollable failure list
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(failed.enumerated()), id: \.offset) { _, entry in
                                Text(entry)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.primary)
                                    .textSelection(.enabled)   // user can select & copy individual lines
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(8)
                                    .background(Color(nsColor: .textBackgroundColor))
                                    .cornerRadius(6)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .frame(minHeight: 80, maxHeight: 220)
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1))
                    .accessibilityLabel("Failed items. \(failed.count) item\(failed.count == 1 ? "" : "s") listed.")

                    // Copy report button
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(failureReport, forType: .string)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                    } label: {
                        Label(copied ? "Copied!" : "Copy Failure Report",
                              systemImage: copied ? "checkmark" : "doc.on.clipboard")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel(copied
                        ? "Report copied to clipboard"
                        : "Copy failure report to clipboard so you can share it for troubleshooting")
                }
                .padding(12)
                .background(Color.orange.opacity(0.07))
                .cornerRadius(10)
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.orange.opacity(0.25), lineWidth: 1))
            }

            HStack(spacing: 12) {
                Button("Done") { state.resetToIdle() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityHint("Returns to the idle screen.")
                UndoLastCleanupButton()
            }
            Spacer(minLength: 0)
        }
    }

    // Formatted plain-text report ready to paste into a conversation.
    private var failureReport: String {
        let dateStr = DateFormatter.localizedString(
            from: Date(), dateStyle: .medium, timeStyle: .short)
        var lines: [String] = []
        lines.append("ACleaner — Cleanup Failure Report")
        lines.append("Generated: \(dateStr)")
        lines.append("App: \(app.displayName)")
        if let id = app.bundleIdentifier { lines.append("Bundle ID: \(id)") }
        lines.append("Removed successfully: \(removed) file\(removed == 1 ? "" : "s")")
        lines.append("Could not delete: \(failed.count) file\(failed.count == 1 ? "" : "s")")
        lines.append(String(repeating: "─", count: 50))
        for entry in failed {
            lines.append(entry)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}
