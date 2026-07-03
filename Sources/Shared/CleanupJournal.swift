import Foundation
import SwiftUI

/// One file moved to the Trash by ACleaner, and where it came from — enough
/// to move it back.
struct TrashedRecord: Codable {
    let originalPath: String
    let trashPath: String
}

/// One deletion operation (a single "Delete Selected" / "Clean" press).
struct CleanupBatch: Codable, Identifiable {
    let id: UUID
    let label: String
    let date: Date
    let items: [TrashedRecord]
}

/// Journal of recent Trash operations performed by ACleaner's various
/// cleaners, enabling a one-button "Undo Last Cleanup". Everything ACleaner
/// deletes already goes through FileManager.trashItem rather than permanent
/// deletion, so undo is just moving items back to where they came from.
@MainActor
final class CleanupJournal: ObservableObject {
    static let shared = CleanupJournal()

    @Published private(set) var batches: [CleanupBatch] = []

    var lastBatch: CleanupBatch? { batches.first }

    private let maxBatches = 10
    private let storeURL: URL

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ACleaner", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        storeURL = dir.appendingPathComponent("cleanup-journal.json")
        load()
    }

    /// Records a batch of successfully-trashed items. No-ops if `items` is
    /// empty so a deletion that moved nothing doesn't create an undo entry.
    func record(label: String, items: [TrashedRecord]) {
        guard !items.isEmpty else { return }
        let batch = CleanupBatch(id: UUID(), label: label, date: Date(), items: items)
        batches.insert(batch, at: 0)
        if batches.count > maxBatches { batches.removeLast(batches.count - maxBatches) }
        save()
    }

    struct UndoResult {
        let restored: Int
        let failed: [String]
    }

    /// Restores the most recent batch. Fails per item (not the whole batch)
    /// when the Trash copy is gone or the original location is now occupied
    /// — never overwrites an existing file.
    func undoLast() -> UndoResult {
        guard let batch = batches.first else { return UndoResult(restored: 0, failed: []) }
        let fm = FileManager.default
        var restored = 0
        var failed: [String] = []

        for item in batch.items {
            let trashURL = URL(fileURLWithPath: item.trashPath)
            let originalURL = URL(fileURLWithPath: item.originalPath)

            guard fm.fileExists(atPath: trashURL.path) else {
                failed.append("\(item.originalPath) — Trash copy no longer exists (Trash may have been emptied)")
                continue
            }
            guard !fm.fileExists(atPath: originalURL.path) else {
                failed.append("\(item.originalPath) — a new item now exists at the original location")
                continue
            }
            do {
                let parent = originalURL.deletingLastPathComponent()
                if !fm.fileExists(atPath: parent.path) {
                    try fm.createDirectory(at: parent, withIntermediateDirectories: true)
                }
                try fm.moveItem(at: trashURL, to: originalURL)
                restored += 1
            } catch {
                failed.append("\(item.originalPath) — \(error.localizedDescription)")
            }
        }

        batches.removeFirst()
        save()
        return UndoResult(restored: restored, failed: failed)
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: storeURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        batches = (try? decoder.decode([CleanupBatch].self, from: data)) ?? []
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(batches) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}

// MARK: - Reusable "Undo Last Cleanup" button

/// Drop into any footer or done screen. Renders nothing when there is
/// nothing to undo.
struct UndoLastCleanupButton: View {
    @ObservedObject private var journal = CleanupJournal.shared
    @State private var showResult = false
    @State private var resultText = ""

    var body: some View {
        if let batch = journal.lastBatch {
            Button {
                let result = journal.undoLast()
                resultText = result.failed.isEmpty
                    ? "Restored \(result.restored) item\(result.restored == 1 ? "" : "s")."
                    : "Restored \(result.restored) item\(result.restored == 1 ? "" : "s"). \(result.failed.count) item\(result.failed.count == 1 ? "" : "s") could not be restored."
                showResult = true
                Announcer.announce("Undo: \(resultText)", priority: .high)
            } label: {
                Label("Undo \(batch.label)", systemImage: "arrow.uturn.backward")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel("Undo \(batch.label)")
            .accessibilityHint("Restores \(batch.items.count) item\(batch.items.count == 1 ? "" : "s") to where they were before this cleanup.")
            .alert("Undo Cleanup", isPresented: $showResult) {
                Button("OK") {}
            } message: {
                Text(resultText)
            }
        }
    }
}
