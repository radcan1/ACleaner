import SwiftUI
import AppKit

// MARK: - Top-level view

struct ClaudeCleanupView: View {
    @StateObject private var junkScanner   = ClaudeCleanupScanner()
    @StateObject private var skillsScanner = ClaudeSkillsScanner()

    enum Section: String, CaseIterable {
        case junk   = "Junk Files"
        case skills = "Skills & Extensions"
    }

    @State private var section: Section = .junk

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            // Section picker
            Picker("Section", selection: $section) {
                ForEach(Section.allCases, id: \.self) { s in
                    Text(s.rawValue).tag(s)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .accessibilityLabel("Section selector")
            .accessibilityHint("Choose between Junk Files and Skills & Extensions.")

            Divider()

            switch section {
            case .junk:
                JunkFilesView(scanner: junkScanner)
            case .skills:
                SkillsView(scanner: skillsScanner)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Claude Cleanup")
                .font(.title)
                .accessibilityAddTraits(.isHeader)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - Junk Files tab

private struct JunkFilesView: View {
    @ObservedObject var scanner: ClaudeCleanupScanner
    @AccessibilityFocusState private var focusAfterScan: Bool

    enum Phase { case idle, scanning, ready, cleaning, done(Int, [String]) }
    @State private var phase: Phase = .idle

    var body: some View {
        switch phase {
        case .idle:
            idleView
        case .scanning:
            scanningView
        case .ready:
            readyView
        case .cleaning:
            VStack(spacing: 12) {
                Text("Moving items to the Trash\u{2026}")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                ProgressView().progressViewStyle(.linear).accessibilityLabel("Working")
                Spacer(minLength: 0)
            }
            .padding()
        case .done(let count, let failures):
            CleanupDoneView(removed: count, failed: failures) {
                phase = .idle
                scanner.items = []
            }
        }
    }

    // MARK: Idle

    private var idleView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("ACleaner can find and remove temporary files, caches, logs, and other data that builds up from using Claude. Press Scan to see what is on your Mac and how much space each category takes.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Scan for Claude Junk\u{2026}") {
                phase = .scanning
                Task {
                    await scanner.scan()
                    phase = .ready
                    focusAfterScan = true
                    announce("Scan complete. Found \(scanner.items.count) categor\(scanner.items.count == 1 ? "y" : "ies").")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityHint("Measures each category of Claude data on your Mac and lists them with explanations.")
            Spacer(minLength: 0)
        }
        .padding()
    }

    // MARK: Scanning

    private var scanningView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Scanning\u{2026}")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            ProgressView().progressViewStyle(.linear).accessibilityLabel("Scanning")
            Text("Measuring directory sizes. This may take a few seconds.")
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding()
    }

    // MARK: Ready

    private var readyView: some View {
        VStack(alignment: .leading, spacing: 0) {
            summaryBar
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach($scanner.items) { $item in
                        JunkCategoryRow(item: $item)
                    }
                }
                .padding(16)
            }
            .accessibilityLabel("Junk file categories")
            .accessibilityFocused($focusAfterScan)
            Divider()
            cleanBar
        }
    }

    private var summaryBar: some View {
        HStack {
            Text("\(scanner.items.count) categor\(scanner.items.count == 1 ? "y" : "ies") found")
            Spacer()
            Text("Selected: \(formatSize(scanner.selectedBytes))")
                .fontWeight(.semibold)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(scanner.items.count) categories found. Selected total: \(formatSize(scanner.selectedBytes)).")
    }

    private var cleanBar: some View {
        HStack(spacing: 12) {
            Button("Clean Selected") {
                phase = .cleaning
                Task {
                    let (count, failures) = await scanner.clean()
                    phase = .done(count, failures)
                    announce("Cleanup complete. Moved \(count) item\(count == 1 ? "" : "s") to the Trash.")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(scanner.selectedBytes == 0)
            .accessibilityHint("Moves the checked categories to the Trash.")

            Button("Scan Again") {
                phase = .scanning
                Task {
                    await scanner.scan()
                    phase = .ready
                }
            }
            .accessibilityHint("Re-runs the scan to refresh sizes.")

            Spacer()
        }
        .padding(16)
    }
}

// MARK: - Junk category row

private struct JunkCategoryRow: View {
    @Binding var item: ClaudeCleanupItem
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {

            // Title row with checkbox
            HStack(spacing: 10) {
                Toggle(isOn: $item.isSelected) {
                    EmptyView()
                }
                .toggleStyle(.checkbox)
                .accessibilityLabel(item.isSelected ? "\(item.title): selected" : "\(item.title): not selected")
                .accessibilityHint("Toggles whether this category will be moved to the Trash.")

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .fontWeight(.medium)
                    Text(item.sizeDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Expand / collapse button — shows the plain-language explanation
                Button {
                    expanded.toggle()
                } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(expanded ? "Collapse explanation for \(item.title)" : "Expand explanation for \(item.title)")
            }

            // Explanation + optional warning — shown when expanded
            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.explanation)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let warning = item.warningNote {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .font(.callout)
                                .accessibilityHidden(true)
                            Text(warning)
                                .font(.callout)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.leading, 26)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(item.warningNote != nil
                    ? "\(item.explanation) Warning: \(item.warningNote!)"
                    : item.explanation)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(Color(nsColor: .separatorColor), lineWidth: 1))
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Skills & Extensions tab

private struct SkillsView: View {
    @ObservedObject var scanner: ClaudeSkillsScanner
    @AccessibilityFocusState private var focusAfterScan: Bool

    enum Phase { case idle, scanning, ready, removing, done(Int, [String]) }
    @State private var phase: Phase = .idle
    @State private var showConfirm = false

    var body: some View {
        switch phase {
        case .idle:
            idleView
        case .scanning:
            VStack(alignment: .leading, spacing: 12) {
                Text("Scanning for skills and extensions\u{2026}")
                    .font(.headline).accessibilityAddTraits(.isHeader)
                ProgressView().progressViewStyle(.linear).accessibilityLabel("Scanning")
                Spacer(minLength: 0)
            }
            .padding()
        case .ready:
            readyView
        case .removing:
            VStack(spacing: 12) {
                Text("Removing selected items\u{2026}")
                    .font(.headline).accessibilityAddTraits(.isHeader)
                ProgressView().progressViewStyle(.linear).accessibilityLabel("Working")
                Spacer(minLength: 0)
            }
            .padding()
        case .done(let count, let failures):
            CleanupDoneView(removed: count, failed: failures) {
                phase = .idle
                scanner.skills = []
            }
        }
    }

    private var idleView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("ACleaner can list every skill and extension installed across Claude Code, Claude Chat, and Cowork so you can review and remove ones you no longer use.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Scan for Skills & Extensions\u{2026}") {
                phase = .scanning
                Task {
                    await scanner.scan()
                    phase = .ready
                    focusAfterScan = true
                    let total = scanner.skills.count
                    announce("Scan complete. Found \(total) installed item\(total == 1 ? "" : "s").")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityHint("Lists every installed Claude skill and extension with its size.")
            Spacer(minLength: 0)
        }
        .padding()
    }

    private var readyView: some View {
        VStack(alignment: .leading, spacing: 0) {
            skillsSummaryBar
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !scanner.codeSkills.isEmpty {
                        skillsSection(
                            title: "Claude Code Skills",
                            subtitle: "Installed in ~/.claude/skills — these give Claude Code new abilities via slash commands.",
                            icon: "terminal",
                            items: scanner.codeSkills
                        )
                    }
                    if !scanner.chatSkills.isEmpty {
                        skillsSection(
                            title: "Claude Chat & Cowork Extensions",
                            subtitle: "Installed in your Claude app as MCP server extensions — they give Claude access to apps like Drafts, PowerPoint, Reminders, and more.",
                            icon: "puzzlepiece.extension",
                            items: scanner.chatSkills
                        )
                    }
                }
                .padding(.bottom, 12)
            }
            .accessibilityLabel("Installed skills and extensions")
            .accessibilityFocused($focusAfterScan)
            Divider()
            skillsActionBar
        }
        .confirmationDialog(
            "Remove \(scanner.selectedCount) item\(scanner.selectedCount == 1 ? "" : "s")?",
            isPresented: $showConfirm,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                phase = .removing
                Task {
                    let (count, failures) = await scanner.removeSelected()
                    phase = .done(count, failures)
                    announce("Done. Moved \(count) item\(count == 1 ? "" : "s") to the Trash.")
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The selected skills and extensions will be moved to the Trash. You can restore them from the Trash if you change your mind.")
        }
    }

    private var skillsSummaryBar: some View {
        HStack {
            Text("\(scanner.skills.count) item\(scanner.skills.count == 1 ? "" : "s") found")
            Spacer()
            if scanner.selectedCount > 0 {
                Text("\(scanner.selectedCount) selected")
                    .fontWeight(.semibold)
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(scanner.skills.count) items found. \(scanner.selectedCount) selected.")
    }

    private func skillsSection(title: String, subtitle: String, icon: String, items: [ClaudeSkillItem]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Section header
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .foregroundColor(.accentColor)
                        .accessibilityHidden(true)
                    Text(title)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                    Text("(\(items.count))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 6)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(title), \(items.count) item\(items.count == 1 ? "" : "s"). \(subtitle)")
            .accessibilityAddTraits(.isHeader)

            ForEach(items) { item in
                SkillRow(item: item) {
                    scanner.toggleSelection(for: item)
                }
                Divider().padding(.leading, 16)
            }
        }
    }

    private var skillsActionBar: some View {
        HStack(spacing: 12) {
            Button("Remove Selected") {
                showConfirm = true
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(scanner.selectedCount == 0)
            .accessibilityHint("Moves the selected skills and extensions to the Trash.")

            Button("Scan Again") {
                phase = .scanning
                Task {
                    await scanner.scan()
                    phase = .ready
                }
            }
            .accessibilityHint("Re-scans to refresh the list.")

            Spacer()

            if scanner.selectedCount > 0 {
                Button("Select None") {
                    for idx in scanner.skills.indices {
                        scanner.skills[idx].isSelected = false
                    }
                }
                .foregroundStyle(.secondary)
                .buttonStyle(.borderless)
                .accessibilityHint("Clears all selections.")
            }
        }
        .padding(16)
    }
}

// MARK: - Skill row

private struct SkillRow: View {
    let item: ClaudeSkillItem
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Toggle(isOn: Binding(get: { item.isSelected }, set: { _ in onToggle() })) {
                EmptyView()
            }
            .toggleStyle(.checkbox)
            .accessibilityLabel(item.isSelected ? "\(item.name): selected" : "\(item.name): not selected")
            .accessibilityHint("Toggles whether this item will be removed.")

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text(item.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Text(item.sizeDescription)
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([item.folderURL])
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Reveal \(item.name) in Finder")
            .accessibilityHint("Opens Finder and selects the folder.")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.name), \(item.sizeDescription), \(item.surface.rawValue). \(item.description). Reveal in Finder button.")
    }
}

// MARK: - Shared Done view

private struct CleanupDoneView: View {
    let removed: Int
    let failed: [String]
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Done")
                .font(.title3)
                .accessibilityAddTraits(.isHeader)

            Text("Moved \(removed) item\(removed == 1 ? "" : "s") to the Trash.")

            if !failed.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("\(failed.count) item\(failed.count == 1 ? "" : "s") could not be moved")
                            .font(.headline)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isHeader)
                    ForEach(Array(failed.enumerated()), id: \.offset) { _, entry in
                        Text(entry)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(Color(nsColor: .textBackgroundColor))
                            .cornerRadius(6)
                    }
                }
                .padding(12)
                .background(Color.orange.opacity(0.07))
                .cornerRadius(10)
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.orange.opacity(0.25), lineWidth: 1))
            }

            Button("Done") { onDismiss() }
                .keyboardShortcut(.defaultAction)
                .accessibilityHint("Returns to the idle screen.")
            Spacer(minLength: 0)
        }
        .padding()
    }
}

// MARK: - Helpers

private func formatSize(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

private func announce(_ message: String) {
    NSAccessibility.post(
        element: NSApp as Any,
        notification: .announcementRequested,
        userInfo: [
            .announcement: message,
            .priority: NSAccessibilityPriorityLevel.medium.rawValue
        ]
    )
}
