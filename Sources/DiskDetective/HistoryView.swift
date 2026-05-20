import SwiftUI
import Foundation

// MARK: - Model

struct DiskRecord: Codable {
    let timestamp: Double
    let freeBytes: Int64
    let totalBytes: Int64

    var date: Date { Date(timeIntervalSince1970: timestamp) }
    var freeGB: Double { Double(freeBytes) / 1_073_741_824 }
    var totalGB: Double { Double(totalBytes) / 1_073_741_824 }
    var usedBytes: Int64 { totalBytes - freeBytes }
    var freePercent: Double { totalBytes > 0 ? Double(freeBytes) / Double(totalBytes) * 100 : 0 }
}

// MARK: - Engine

@MainActor
class HistoryEngine: ObservableObject {
    static let shared = HistoryEngine()

    @Published var records: [DiskRecord] = []

    private var storePath: String {
        FileManager.default.homeDirectoryForCurrentUser.path + "/.disk-detective/disk-history.json"
    }

    private init() { load() }

    func record() {
        let url = URL(fileURLWithPath: "/")
        guard let values = try? url.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeTotalCapacityKey
        ]) else { return }
        let free = values.volumeAvailableCapacityForImportantUsage ?? 0
        let total = Int64(values.volumeTotalCapacity ?? 0)
        let r = DiskRecord(timestamp: Date().timeIntervalSince1970, freeBytes: free, totalBytes: total)
        records.append(r)
        if records.count > 200 { records = Array(records.suffix(200)) }
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: storePath)),
              let loaded = try? JSONDecoder().decode([DiskRecord].self, from: data)
        else { return }
        records = loaded
    }

    private func save() {
        let dir = FileManager.default.homeDirectoryForCurrentUser.path + "/.disk-detective"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: URL(fileURLWithPath: storePath))
    }
}

// MARK: - View

struct HistoryView: View {
    @ObservedObject private var engine = HistoryEngine.shared
    @State private var showTable = false

    private var sorted: [DiskRecord] { engine.records.sorted { $0.timestamp < $1.timestamp } }

    private static let dayFmt: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none; return f
    }()
    private static let shortFmt: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .short; return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            if sorted.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        summarySection
                            .padding(.horizontal, 16)
                            .padding(.top, 14)

                        if sorted.count >= 2 {
                            chartSection
                                .padding(.horizontal, 16)
                        }

                        Button(showTable ? "Hide Data Table" : "Show Data Table") {
                            showTable.toggle()
                        }
                        .buttonStyle(.borderless)
                        .padding(.horizontal, 16)

                        if showTable {
                            dataTable
                                .padding(.horizontal, 16)
                        }
                    }
                    .padding(.bottom, 20)
                }
            }
        }
        .onAppear { engine.record() }
    }

    // MARK: Header

    private var headerBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "chart.xyaxis.line")
                .font(.title2)
                .foregroundColor(.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text("Disk Space History")
                    .font(.headline)
                Text("\(sorted.count) reading\(sorted.count == 1 ? "" : "s") recorded")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button {
                engine.record()
            } label: {
                Label("Record Now", systemImage: "plus.circle")
            }
            .keyboardShortcut("r", modifiers: .command)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "chart.xyaxis.line")
                .font(.system(size: 52))
                .foregroundColor(.secondary)
            Text("No history yet.")
                .font(.title3)
                .foregroundColor(.secondary)
            Text("Free space is recorded each time you visit this tab or press Record Now.\nThe background snapshot task also adds readings every 2 hours.")
                .font(.body)
                .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Summary — primary VoiceOver content

    private var summarySection: some View {
        let latest    = sorted.last
        let oldest    = sorted.first
        let minFree   = sorted.map(\.freeBytes).min() ?? 0
        let maxFree   = sorted.map(\.freeBytes).max() ?? 0
        let minRecord = sorted.min(by: { $0.freeBytes < $1.freeBytes })

        return VStack(alignment: .leading, spacing: 6) {
            if let l = latest {
                Text("Currently: \(fmtGB(l.freeBytes)) free of \(fmtGB(l.totalBytes)) total (\(String(format: "%.0f", l.freePercent))% free)")
                    .font(.body)
                    .fontWeight(.semibold)
            }

            if sorted.count >= 2, let o = oldest, let l = latest {
                let days = Int((l.timestamp - o.timestamp) / 86400)
                let span = days <= 0 ? "today" : "the last \(days) day\(days == 1 ? "" : "s")"
                Text("Over \(span), free space ranged from \(fmtGB(minFree)) to \(fmtGB(maxFree)).")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }

            if let mr = minRecord, sorted.count >= 3 {
                Text("Lowest recorded: \(fmtGB(mr.freeBytes)) on \(Self.dayFmt.string(from: mr.date)).")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Chart — hidden from VoiceOver, purely visual

    private var chartSection: some View {
        let values   = sorted.map { $0.freeGB }
        let minV     = values.min()!
        let maxV     = values.max()!
        let range    = max(maxV - minV, 0.5)
        let times    = sorted.map { $0.timestamp }
        let minT     = times.first!
        let timeSpan = max(times.last! - minT, 1.0)

        return VStack(alignment: .leading, spacing: 4) {
            Text("Free Space Over Time")
                .font(.caption)
                .foregroundColor(.secondary)

            Canvas { context, size in
                let w = size.width
                let h = size.height

                // Horizontal grid lines at 25%, 50%, 75%
                for frac in [0.25, 0.5, 0.75] {
                    var grid = Path()
                    let y = h * (1.0 - CGFloat(frac))
                    grid.move(to: CGPoint(x: 0, y: y))
                    grid.addLine(to: CGPoint(x: w, y: y))
                    context.stroke(grid, with: .color(Color(nsColor: .separatorColor)), lineWidth: 0.5)
                }

                // Data line
                var line = Path()
                for (i, rec) in sorted.enumerated() {
                    let x = CGFloat((rec.timestamp - minT) / timeSpan) * w
                    let y = h - CGFloat((rec.freeGB - minV) / range) * h
                    if i == 0 { line.move(to: CGPoint(x: x, y: y)) }
                    else       { line.addLine(to: CGPoint(x: x, y: y)) }
                }
                context.stroke(line, with: .color(Color.accentColor), lineWidth: 2)

                // Data points
                for rec in sorted {
                    let x = CGFloat((rec.timestamp - minT) / timeSpan) * w
                    let y = h - CGFloat((rec.freeGB - minV) / range) * h
                    let dot = Path(ellipseIn: CGRect(x: x - 3.5, y: y - 3.5, width: 7, height: 7))
                    context.fill(dot, with: .color(Color.accentColor))
                }
            }
            .frame(height: 160)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(6)

            // X-axis labels: oldest and newest date
            HStack {
                if let o = sorted.first {
                    Text(Self.dayFmt.string(from: o.date))
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
                Spacer()
                if let l = sorted.last {
                    Text(Self.dayFmt.string(from: l.date))
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: Data table

    private var dataTable: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Date & Time")
                    .font(.caption).foregroundColor(.secondary)
                    .frame(width: 155, alignment: .leading)
                Text("Free")
                    .font(.caption).foregroundColor(.secondary)
                    .frame(width: 85, alignment: .trailing)
                Text("Used")
                    .font(.caption).foregroundColor(.secondary)
                    .frame(width: 85, alignment: .trailing)
                Text("Total")
                    .font(.caption).foregroundColor(.secondary)
                    .frame(width: 85, alignment: .trailing)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            ForEach(sorted.indices.reversed(), id: \.self) { i in
                let r = sorted[i]
                HStack {
                    Text(Self.shortFmt.string(from: r.date))
                        .font(.caption)
                        .frame(width: 155, alignment: .leading)
                    Text(fmtGB(r.freeBytes))
                        .font(.caption).monospacedDigit()
                        .frame(width: 85, alignment: .trailing)
                    Text(fmtGB(r.usedBytes))
                        .font(.caption).monospacedDigit()
                        .frame(width: 85, alignment: .trailing)
                    Text(fmtGB(r.totalBytes))
                        .font(.caption).monospacedDigit()
                        .frame(width: 85, alignment: .trailing)
                }
                .padding(.vertical, 3)
                .padding(.horizontal, 8)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    "\(Self.shortFmt.string(from: r.date)): \(fmtGB(r.freeBytes)) free, \(fmtGB(r.usedBytes)) used, \(fmtGB(r.totalBytes)) total."
                )
                if i > 0 { Divider() }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor), lineWidth: 1))
    }

    // MARK: Helpers

    private func fmtGB(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1.0 { return String(format: "%.1f GB", gb) }
        let mb = Double(bytes) / 1_048_576
        if mb >= 1.0 { return String(format: "%.0f MB", mb) }
        return "< 1 MB"
    }
}
