import SwiftUI
import AppKit

struct LLMScannerView: View {
    @StateObject private var scanner = LLMScanner()
    @AccessibilityFocusState private var focusedAfterScan: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if scanner.isScanning {
                scanningView
            } else if scanner.sources.isEmpty {
                emptyView
            } else {
                listView
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("LLM Scanner")
                .font(.title)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button {
                scanner.scan()
                announce("Scanning for language models.")
            } label: {
                Label("Scan", systemImage: "magnifyingglass")
            }
            .buttonStyle(.borderedProminent)
            .disabled(scanner.isScanning)
            .accessibilityLabel("Scan for language models")
            .accessibilityHint("Searches common locations on your Mac for installed AI and language models.")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Scanning

    private var scanningView: some View {
        VStack(spacing: 12) {
            Text(scanner.progress)
                .foregroundColor(.secondary)
                .accessibilityLabel(scanner.progress)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Empty

    private var emptyView: some View {
        Group {
            if scanner.sources.isEmpty && !scanner.isScanning && scanner.progress.isEmpty {
                // Initial state — not yet scanned
                VStack(spacing: 12) {
                    Image(systemName: "cpu.fill")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                        .accessibilityHidden(true)
                    Text("Press Scan to find language models on your Mac.")
                        .font(.title3)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityFocused($focusedAfterScan)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                        .accessibilityHidden(true)
                    Text("No language models found.")
                        .font(.title3)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityFocused($focusedAfterScan)
                .onAppear {
                    focusedAfterScan = true
                    announce("Scan complete. No language models found.")
                }
            }
        }
    }

    // MARK: - List

    private var listView: some View {
        VStack(alignment: .leading, spacing: 0) {
            summaryBar
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(scanner.sources) { source in
                        sourceSection(source)
                    }
                }
                .padding(.bottom, 12)
            }
            .accessibilityLabel("Found language models")
        }
        .onAppear {
            announce("Scan complete. Found \(scanner.totalModels) model\(scanner.totalModels == 1 ? "" : "s") totalling \(formatSize(scanner.totalSize)).")
        }
    }

    private var summaryBar: some View {
        HStack {
            Text("\(scanner.totalModels) model\(scanner.totalModels == 1 ? "" : "s") across \(scanner.sources.count) source\(scanner.sources.count == 1 ? "" : "s")")
            Spacer()
            Text("Total: \(formatSize(scanner.totalSize))")
                .fontWeight(.semibold)
        }
        .font(.callout)
        .foregroundColor(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(scanner.totalModels) models across \(scanner.sources.count) sources. Total size: \(formatSize(scanner.totalSize)).")
    }

    // MARK: - Source section

    private func sourceSection(_ source: LLMSource) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(source)
            ForEach(source.models) { model in
                modelRow(model, source: source)
                Divider().padding(.leading, 16)
            }
        }
    }

    private func sectionHeader(_ source: LLMSource) -> some View {
        HStack(spacing: 8) {
            Image(systemName: source.icon)
                .foregroundColor(.accentColor)
                .accessibilityHidden(true)
            Text(source.name.uppercased())
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)
            Text("(\(source.models.count))")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Text(formatSize(source.totalSize))
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(source.name), \(source.models.count) model\(source.models.count == 1 ? "" : "s"), \(formatSize(source.totalSize)) total")
        .accessibilityAddTraits(.isHeader)
    }

    private func modelRow(_ model: LLMModel, source: LLMSource) -> some View {
        HStack(spacing: 12) {
            Image(systemName: rowIcon(for: source))
                .font(.system(size: 20))
                .foregroundColor(.secondary)
                .frame(width: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(model.name)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text(model.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Text(formatSize(model.size))
                .font(.callout)
                .foregroundColor(.secondary)
                .monospacedDigit()

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([model.url])
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Reveal \(model.name) in Finder")
            .accessibilityHint("Opens Finder and selects the model file.")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(model.name), \(formatSize(model.size)), from \(source.name). Reveal in Finder button.")
    }

    // MARK: - Helpers

    private func rowIcon(for source: LLMSource) -> String {
        switch source.name {
        case "Ollama":           return "cube"
        case "Hugging Face":     return "arrow.down.doc"
        case "Loose Model Files": return "doc.badge.gearshape"
        default:                 return "doc.text"
        }
    }

    private func formatSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
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
}
