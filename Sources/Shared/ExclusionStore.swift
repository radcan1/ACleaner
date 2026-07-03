import Foundation
import SwiftUI

/// User-managed list of apps to always skip in orphan and leftover scans, so
/// a false positive never needs dismissing twice. One shared list covers
/// both scanning flows — excluding an app from the Orphaned Files scan also
/// keeps it out of Clean Uninstall's leftover results.
///
/// Matching reuses AppTokenMatcher's identity tokens (the same logic behind
/// orphan clustering) rather than a raw string comparison, so "Spotify" and
/// "com.spotify.client" are recognized as the same exclusion.
@MainActor
final class ExclusionStore: ObservableObject {
    static let shared = ExclusionStore()

    struct Entry: Identifiable, Codable, Equatable {
        let id: String            // UUID string
        let displayName: String   // human-readable, as first added
        let tokens: [String]      // AppTokenMatcher.identityTokens(for: displayName)
    }

    @Published private(set) var entries: [Entry] = []

    private let defaultsKey = "ACleaner.exclusions"

    private init() {
        load()
    }

    /// True if `name`'s identity tokens match any excluded entry.
    func isExcluded(_ name: String) -> Bool {
        let tokens = AppTokenMatcher.identityTokens(for: name)
        return isExcluded(tokens: tokens)
    }

    func isExcluded(tokens: Set<String>) -> Bool {
        guard !tokens.isEmpty else { return false }
        return entries.contains { AppTokenMatcher.tokenSetsMatch(Set($0.tokens), tokens) }
    }

    /// Adds `displayName` to the exclusion list. No-ops if it has no usable
    /// identity tokens (too short / generic) or already matches an entry.
    func exclude(_ displayName: String) {
        let tokens = AppTokenMatcher.identityTokens(for: displayName)
        guard !tokens.isEmpty, !isExcluded(tokens: tokens) else { return }
        entries.append(Entry(id: UUID().uuidString, displayName: displayName, tokens: Array(tokens)))
        save()
    }

    func remove(_ entry: Entry) {
        entries.removeAll { $0.id == entry.id }
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([Entry].self, from: data) else { return }
        entries = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}

// MARK: - Manage Exclusions sheet

struct ManageExclusionsSheet: View {
    @ObservedObject private var store = ExclusionStore.shared
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Excluded Apps")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Done") { onDone() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()

            Divider()

            if store.entries.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "eye.slash")
                        .font(.system(size: 36))
                        .foregroundColor(.secondary)
                    Text("No apps are excluded.")
                        .foregroundColor(.secondary)
                    Text("Use \u{201C}Exclude from Future Scans\u{201D} on any orphan row to add one here.")
                        .font(.caption)
                        .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                List {
                    ForEach(store.entries) { entry in
                        HStack {
                            Text(entry.displayName)
                            Spacer()
                            Button("Remove") { store.remove(entry) }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Remove \(entry.displayName) from exclusions")
                                .accessibilityHint("Future scans will show \(entry.displayName) again.")
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
        .frame(width: 420, height: 360)
    }
}
