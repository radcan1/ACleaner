import SwiftUI
import AppKit

struct TMSnapshot: Identifiable {
    let id = UUID()
    var isSelected: Bool = false
    let name: String       // full name, e.g. com.apple.TimeMachine.2026-05-19-154500.local
    let dateString: String // e.g. 2026-05-19-154500
    let displayDate: String
    let displayTime: String
    let sizeBytes: Int64   // 0 if unknown
    let sizeLabel: String
}

@MainActor
class TimeMachineEngine: ObservableObject {
    @Published var snapshots: [TMSnapshot] = []
    @Published var isLoading = false
    @Published var statusMessage = ""
    @Published var feedbackMessage = ""

    func loadSnapshots() async {
        isLoading = true
        feedbackMessage = ""
        statusMessage = "Loading snapshots…"

        let rawList = await shell("tmutil listlocalsnapshots / 2>/dev/null")
        let names = rawList.split(separator: "\n").map(String.init).filter { !$0.isEmpty }

        // Try to get sizes from diskutil apfs listSnapshots
        let dev = await shell("df / | awk 'NR==2{print $1}'").trimmingCharacters(in: .whitespacesAndNewlines)
        let apfsOut = await shell("diskutil apfs listSnapshots \"\(dev)\" 2>/dev/null")
        let sizeMap = parseAPFSSizes(apfsOut)

        var result: [TMSnapshot] = []
        for name in names {
            // name looks like: com.apple.TimeMachine.2026-05-19-154500.local
            let dateStr = extractDate(from: name)          // 2026-05-19-154500
            let (dispDate, dispTime) = formatDate(dateStr)
            let sizeBytes = sizeMap[name] ?? 0
            let sizeLabel = sizeBytes > 0 ? formatBytes(sizeBytes) : "size unknown"
            result.append(TMSnapshot(
                name: name,
                dateString: dateStr,
                displayDate: dispDate,
                displayTime: dispTime,
                sizeBytes: sizeBytes,
                sizeLabel: sizeLabel
            ))
        }

        // Sort newest first
        snapshots = result.sorted { $0.dateString > $1.dateString }
        isLoading = false
        statusMessage = snapshots.isEmpty
            ? "No local snapshots found."
            : "\(snapshots.count) snapshot\(snapshots.count == 1 ? "" : "s") on disk"
    }

    func deleteSelected() async {
        let toDelete = snapshots.filter(\.isSelected)
        guard !toDelete.isEmpty else { return }

        let commands = toDelete
            .map { "sudo tmutil deletelocalsnapshots \($0.dateString)" }
            .joined(separator: " && ")
        let countStr = "\(toDelete.count) snapshot\(toDelete.count == 1 ? "" : "s")"
        let fullCmd = "\(commands) && echo '\\nDone — \(countStr) deleted.'"

        let script = """
        tell application "Terminal"
            activate
            do script "\(fullCmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))"
        end tell
        """
        NSAppleScript(source: script)?.executeAndReturnError(nil)

        feedbackMessage = "Terminal opened — \(countStr) queued for deletion. Your password may be required."
    }

    func deleteAll() async {
        let script = """
        tell application "Terminal"
            activate
            do script "sudo tmutil deletelocalsnapshots / && echo 'Done — all local snapshots deleted.'"
        end tell
        """
        NSAppleScript(source: script)?.executeAndReturnError(nil)
        feedbackMessage = "Terminal opened — all snapshots queued for deletion. Your password may be required."
    }

    // MARK: - Helpers

    private func extractDate(from name: String) -> String {
        // com.apple.TimeMachine.2026-05-19-154500.local  →  2026-05-19-154500
        let stripped = name
            .replacingOccurrences(of: "com.apple.TimeMachine.", with: "")
            .replacingOccurrences(of: ".local", with: "")
        return stripped
    }

    private func formatDate(_ dateStr: String) -> (String, String) {
        // dateStr: 2026-05-19-154500
        let parts = dateStr.split(separator: "-")
        guard parts.count == 4 else { return (dateStr, "") }
        let year  = parts[0]
        let month = parts[1]
        let day   = parts[2]
        let time  = parts[3]  // 154500

        let months = ["","Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"]
        let monthNum = Int(month) ?? 0
        let monthName = monthNum > 0 && monthNum < 13 ? months[monthNum] : String(month)

        let h = time.prefix(2)
        let m = time.dropFirst(2).prefix(2)
        return ("\(day) \(monthName) \(year)", "\(h):\(m)")
    }

    private func parseAPFSSizes(_ output: String) -> [String: Int64] {
        // Parse diskutil apfs listSnapshots output for per-snapshot sizes
        var map: [String: Int64] = [:]
        var currentName: String?
        for line in output.split(separator: "\n").map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("Snapshot:") {
                currentName = trimmed.replacingOccurrences(of: "Snapshot:", with: "").trimmingCharacters(in: .whitespaces)
            } else if trimmed.contains("Bytes)"), let name = currentName {
                // e.g. "Size (Reclaimable): 2.5 GB (2500000000 Bytes)"
                if let range = trimmed.range(of: "(", options: .backwards),
                   let end  = trimmed.range(of: " Bytes)") {
                    let numStr = String(trimmed[trimmed.index(after: range.lowerBound)..<end.lowerBound])
                        .replacingOccurrences(of: ",", with: "")
                    if let bytes = Int64(numStr) {
                        map[name] = bytes
                    }
                }
            }
        }
        return map
    }

    private func shell(_ command: String) async -> String {
        await Task.detached(priority: .utility) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = ["-c", command]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = Pipe()
            try? p.run()
            p.waitUntilExit()
            return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        }.value
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        let mb = Double(bytes) / 1_048_576
        if gb >= 1.0 { return String(format: "%.1f GB", gb) }
        if mb >= 1.0 { return String(format: "%.0f MB", mb) }
        return "< 1 MB"
    }
}

// MARK: - View

struct TimeMachineView: View {
    @StateObject private var engine = TimeMachineEngine()
    @State private var showDeleteAllConfirm = false
    @State private var showDeleteSelectedConfirm = false

    private var selectedSnapshots: [TMSnapshot] { engine.snapshots.filter(\.isSelected) }
    private var knownSizeTotal: Int64 { selectedSnapshots.reduce(0) { $0 + $1.sizeBytes } }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            mainContent
            Divider()
            footerBar
        }
        .task { await engine.loadSnapshots() }
        .alert("Delete All Snapshots?", isPresented: $showDeleteAllConfirm) {
            Button("Open Terminal to Delete All", role: .destructive) {
                Task { await engine.deleteAll() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will open Terminal and run:\nsudo tmutil deletelocalsnapshots /\n\nAll local snapshots will be removed. macOS will create new ones automatically.")
        }
        .alert("Delete Selected Snapshots?", isPresented: $showDeleteSelectedConfirm) {
            Button("Open Terminal to Delete", role: .destructive) {
                Task { await engine.deleteSelected() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Terminal will open with the delete command for \(selectedSnapshots.count) snapshot\(selectedSnapshots.count == 1 ? "" : "s"). Your password will be required.")
        }
    }

    // MARK: Header

    private var headerBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.title2)
                .foregroundColor(.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text("Time Machine Snapshots")
                    .font(.headline)
                Text(engine.statusMessage)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if engine.isLoading {
                ProgressView().scaleEffect(0.75)
            }

            Button {
                Task { await engine.loadSnapshots() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(engine.isLoading)
            .keyboardShortcut("r", modifiers: .command)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: Main content

    @ViewBuilder
    private var mainContent: some View {
        if engine.snapshots.isEmpty && !engine.isLoading {
            VStack(spacing: 14) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 52))
                    .foregroundColor(.secondary)
                Text("No local Time Machine snapshots found.")
                    .font(.title3)
                    .foregroundColor(.secondary)
                Text("macOS creates local snapshots automatically when Time Machine is enabled.")
                    .font(.body)
                    .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                if !engine.feedbackMessage.isEmpty {
                    HStack {
                        Image(systemName: "terminal")
                        Text(engine.feedbackMessage)
                            .font(.callout)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.1))
                    .accessibilityLabel("Status: \(engine.feedbackMessage)")
                }

                // Column headers
                HStack {
                    Toggle("", isOn: .constant(false))
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                        .frame(width: 18)
                        .hidden()
                    Text("Date")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(width: 110, alignment: .leading)
                    Text("Time")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(width: 70, alignment: .leading)
                    Spacer()
                    Text("Size")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(width: 100, alignment: .trailing)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(Color(nsColor: .controlBackgroundColor))
                .accessibilityHidden(true)

                Divider()

                List {
                    ForEach(engine.snapshots.indices, id: \.self) { index in
                        SnapshotRow(
                            snapshot: Binding(
                                get: { engine.snapshots[index] },
                                set: { engine.snapshots[index] = $0 }
                            )
                        )
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
    }

    // MARK: Footer

    private var footerBar: some View {
        HStack(spacing: 10) {
            if selectedSnapshots.isEmpty {
                Text(engine.snapshots.isEmpty ? "" : "Select snapshots to delete, or use Delete All.")
                    .font(.callout)
                    .foregroundColor(.secondary)
            } else {
                Image(systemName: "checkmark.circle.fill").foregroundColor(.accentColor)
                let sizeHint = knownSizeTotal > 0 ? " (~\(formatBytes(knownSizeTotal)))" : ""
                Text("\(selectedSnapshots.count) selected\(sizeHint)")
                    .font(.callout)
                    .fontWeight(.medium)
            }

            Spacer()

            if !engine.snapshots.isEmpty {
                Button("Select All") {
                    for i in engine.snapshots.indices { engine.snapshots[i].isSelected = true }
                }
                .buttonStyle(.borderless)

                Button("Deselect All") {
                    for i in engine.snapshots.indices { engine.snapshots[i].isSelected = false }
                }
                .buttonStyle(.borderless)

                Button("Delete All…") { showDeleteAllConfirm = true }
                    .buttonStyle(.bordered)
                    .foregroundColor(.red)

                Button("Delete Selected…") { showDeleteSelectedConfirm = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedSnapshots.isEmpty)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        let mb = Double(bytes) / 1_048_576
        if gb >= 1.0 { return String(format: "%.1f GB", gb) }
        if mb >= 1.0 { return String(format: "%.0f MB", mb) }
        return "< 1 MB"
    }
}

struct SnapshotRow: View {
    @Binding var snapshot: TMSnapshot

    var body: some View {
        HStack(spacing: 10) {
            Toggle(isOn: $snapshot.isSelected) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .frame(width: 18)

            Text(snapshot.displayDate)
                .fontWeight(.medium)
                .frame(width: 110, alignment: .leading)

            Text(snapshot.displayTime)
                .foregroundColor(.secondary)
                .frame(width: 70, alignment: .leading)

            Spacer()

            Text(snapshot.sizeLabel)
                .foregroundColor(snapshot.sizeBytes > 0 ? .primary : .secondary)
                .fontWeight(snapshot.sizeBytes > 0 ? .medium : .regular)
                .monospacedDigit()
                .frame(width: 100, alignment: .trailing)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { snapshot.isSelected.toggle() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Snapshot from \(snapshot.displayDate) at \(snapshot.displayTime), \(snapshot.sizeLabel).")
        .accessibilityValue(snapshot.isSelected ? "checked" : "unchecked")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Toggle selection") { snapshot.isSelected.toggle() }
    }
}
