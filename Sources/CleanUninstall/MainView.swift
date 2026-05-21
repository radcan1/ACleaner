import SwiftUI

struct MainView: View {
    @EnvironmentObject var state: AppState
    // ── App picker lives here, not in IdleView ────────────────────────────────
    // Keeping the sheet on this view (which is always in the hierarchy) prevents
    // it from being torn down when the phase switches from .idle to .detected.
    @State private var showAppPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding()
        // Sheet is owned by MainView so it survives the .idle → .detected transition
        .sheet(isPresented: $showAppPicker) {
            AppPickerSheet { appURL in
                state.trashAndScan(appURL: appURL)
            }
        }
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
            Text("Clean Uninstall")
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
            IdleView(showAppPicker: $showAppPicker)
        case .trashing(let name):
            ProgressMessageView(message: "Moving \"\(name)\" to the Trash\u{2026}")
        case .detected(let app):
            DetectionView(app: app)
        case .scanning(let app):
            ScanningView(app: app)
        case .results(let app, let files):
            ResultsView(app: app, files: files)
        case .cleaning:
            ProgressMessageView(message: "Moving items to the Trash. Please wait.")
        case .done(let removed, let failed):
            DoneView(removed: removed, failed: failed)
        }
    }
}

// MARK: - Idle

struct IdleView: View {
    @EnvironmentObject var state: AppState
    @Binding var showAppPicker: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            // ── Direct uninstall ──────────────────────────────────────────
            VStack(alignment: .leading, spacing: 8) {
                Text("Uninstall an App")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text("Select any installed application and ACleaner will move it to the Trash then scan for its leftover files — no dragging required.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Choose App to Uninstall\u{2026}") {
                    showAppPicker = true
                }
                .controlSize(.large)
                .keyboardShortcut("u", modifiers: .command)
                .accessibilityHint("Opens a searchable list of installed apps. Press Enter on an app to move it to the Trash and scan for leftovers. Shortcut: Command-U.")
            }
            .padding(14)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(10)
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1))

            Divider()

            // ── Trash watcher status ──────────────────────────────────────
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

            // ── Recent events ─────────────────────────────────────────────
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
                Button("Move selected to Trash") {
                    state.performCleanup(app, items: files)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(state.selection.isEmpty)
                .accessibilityHint("Moves the selected items to the Trash.")

                Button("Cancel") { state.resetToIdle() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityHint("Closes the results without removing anything.")
            }
        }
    }
}

// MARK: - Done

struct DoneView: View {
    let removed: Int
    let failed: [String]
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Cleanup finished")
                .font(.title3)
                .accessibilityAddTraits(.isHeader)

            Text("Moved \(removed) item\(removed == 1 ? "" : "s") to the Trash.")

            if !failed.isEmpty {
                Text("Items that could not be removed:")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                List(Array(failed.enumerated()), id: \.offset) { _, line in
                    Text(line)
                }
                .accessibilityLabel("List of items that could not be removed.")
                .frame(minHeight: 120)
            }

            Button("Done") { state.resetToIdle() }
                .keyboardShortcut(.defaultAction)
                .accessibilityHint("Returns to the idle screen.")
            Spacer(minLength: 0)
        }
    }
}
