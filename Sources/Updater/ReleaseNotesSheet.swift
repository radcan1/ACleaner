import SwiftUI
import AppKit

struct ReleaseNotesSheet: View {
    let item: OutdatedItem
    @Environment(\.dismiss) private var dismiss

    @State private var notes: ReleaseNotes? = nil
    @State private var isLoading: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 560, minHeight: 440)
        .frame(idealWidth: 680, idealHeight: 540)
        .task {
            isLoading = true
            notes = await ReleaseNotesFetcher.notes(for: item)
            isLoading = false
        }
    }

    // MARK: Header

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.text")
                .font(.title2)
                .foregroundColor(.accentColor)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(item.name) — What's New")
                    .font(.headline)
                Text(subheading)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(item.name), what's new. \(subheading).")

            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var subheading: String {
        var parts = [item.versionString]
        if let n = notes { parts.append(n.source) }
        return parts.joined(separator: " · ")
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if isLoading {
            VStack(spacing: 12) {
                ProgressView().scaleEffect(0.9).accessibilityHidden(true)
                Text("Loading release notes…")
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Loading release notes for \(item.name)")
        } else if let notes = notes {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(notes.title)
                        .font(.title3)
                        .fontWeight(.semibold)

                    bodyText(notes.body)
                        .textSelection(.enabled)

                    if let hp = notes.homepage {
                        Divider()
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Homepage")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(hp)
                                .font(.callout)
                                .textSelection(.enabled)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Homepage: \(hp)")
                    }

                    Text("Source: \(notes.source)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .accessibilityLabel(spokenReleaseNotes(notes))
        } else {
            VStack(spacing: 10) {
                Image(systemName: "doc.text.below.ecg")
                    .font(.system(size: 48))
                    .foregroundColor(.secondary)
                    .accessibilityHidden(true)
                Text("Couldn't load release notes.")
                    .font(.title3)
                    .foregroundColor(.secondary)
                Text("Network was unreachable or the publisher does not expose notes through any of our sources.")
                    .font(.body)
                    .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Couldn't load release notes for \(item.name).")
        }
    }

    /// Try to render as Markdown so bold/italic/links come through. Falls
    /// back to plain text if the body isn't valid Markdown.
    @ViewBuilder
    private func bodyText(_ body: String) -> some View {
        if let attr = try? AttributedString(markdown: body,
                                            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            Text(attr)
        } else {
            Text(body)
        }
    }

    /// Plain-text spoken form for VoiceOver — strips obvious Markdown noise.
    private func spokenReleaseNotes(_ notes: ReleaseNotes) -> String {
        var body = notes.body
        // strip simple inline markdown
        for token in ["**", "__", "*", "_", "`"] {
            body = body.replacingOccurrences(of: token, with: "")
        }
        return "Release notes for \(item.name). \(notes.title). \(body)"
    }

    // MARK: Footer

    @ViewBuilder
    private var footer: some View {
        HStack {
            Button("Copy Notes") {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(notes?.body ?? "", forType: .string)
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(notes == nil)
            .accessibilityLabel("Copy release notes to clipboard")

            Spacer()

            Button("Close") { dismiss() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .accessibilityLabel("Close release notes")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}
