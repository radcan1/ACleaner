import SwiftUI

struct SkippedAppsSheet: View {
    @ObservedObject var skipList: SkipList
    /// Called when the user closes the sheet, so the Updates view can
    /// re-check (because unskipped apps may now reappear in the list).
    let onClose: () -> Void

    @Environment(\.dismiss) private var dismiss

    private var entries: [(key: String, kind: UpdateKind, name: String)] {
        skipList.entries.compactMap { key in
            guard let (kind, name) = SkipList.decompose(key) else { return nil }
            return (key, kind, name)
        }.sorted {
            if $0.kind.rawValue == $1.kind.rawValue { return $0.name < $1.name }
            return $0.kind.rawValue < $1.kind.rawValue
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 480, minHeight: 360)
        .frame(idealWidth: 560, idealHeight: 440)
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "nosign")
                .font(.title3)
                .foregroundColor(.accentColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Skipped Apps").font(.headline)
                Text(entries.isEmpty
                     ? "You have not skipped any apps yet."
                     : "\(entries.count) app\(entries.count == 1 ? "" : "s") will be hidden from update checks.")
                    .font(.caption).foregroundColor(.secondary)
            }
            .accessibilityElement(children: .combine)
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    @ViewBuilder
    private var content: some View {
        if entries.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 48))
                    .foregroundColor(.secondary)
                    .accessibilityHidden(true)
                Text("Nothing to show.")
                    .font(.title3).foregroundColor(.secondary)
                Text("Right-click an app on the Updates tab and choose “Always skip this app” to add it here.")
                    .font(.body)
                    .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("No skipped apps. Add one by right-clicking an app on the Updates tab.")
        } else {
            List(entries, id: \.key) { entry in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name).fontWeight(.medium)
                        Text(entry.kind.displayLabel)
                            .font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("Unskip") {
                        skipList.remove(entry.key)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Unskip \(entry.name)")
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("\(entry.name). \(entry.kind.displayLabel). Skipped.")
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack {
            Button("Unskip All") {
                skipList.clear()
            }
            .disabled(entries.isEmpty)
            .accessibilityLabel("Unskip all apps")

            Spacer()

            Button("Done") {
                onClose()
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}
