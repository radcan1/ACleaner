import Foundation
import AppKit

@MainActor
final class LLMScanner: ObservableObject {
    @Published var sources: [LLMSource] = []
    @Published var isScanning = false
    @Published var progress = ""

    var totalSize: Int64 { sources.reduce(0) { $0 + $1.totalSize } }
    var totalModels: Int { sources.reduce(0) { $0 + $1.models.count } }

    private static let cacheKey = "llmModels"

    init() {
        guard let cached = ScanCache.load([LLMSource].self, key: Self.cacheKey) else { return }
        let existing = cached.payload.compactMap { source -> LLMSource? in
            let models = source.models.filter { FileManager.default.fileExists(atPath: $0.url.path) }
            return models.isEmpty ? nil : LLMSource(id: source.id, name: source.name, icon: source.icon, models: models)
        }
        guard !existing.isEmpty else { return }
        sources = existing
        progress = "Results from \(ScanCache.ageLabel(cached.savedAt)) — press Scan to refresh."
    }

    func scan() {
        isScanning = true
        progress = "Starting scan\u{2026}"
        sources = []
        Announcer.announce("Scanning for local language models.", priority: .medium)

        Task.detached(priority: .userInitiated) { [weak self] in
            var found: [LLMSource] = []

            // ── Ollama ─────────────────────────────────────────────────────────
            await self?.setProgress("Scanning Ollama\u{2026}")
            if let src = Self.scanOllama() { found.append(src) }

            // ── LM Studio ─────────────────────────────────────────────────────
            await self?.setProgress("Scanning LM Studio\u{2026}")
            if let src = Self.scanDirectory(
                paths: [
                    "~/.cache/lm-studio/models",
                    "~/.cache/lm_studio/models",
                    "~/Library/Application Support/LM Studio/models",
                    "~/Library/Application Support/com.lmstudio.app/models"
                ],
                sourceName: "LM Studio",
                icon: "cpu",
                extensions: LLMExtensions.all,
                minBytes: 50_000_000
            ) { found.append(src) }

            // ── Jan.ai ────────────────────────────────────────────────────────
            await self?.setProgress("Scanning Jan\u{2026}")
            if let src = Self.scanDirectory(
                paths: ["~/jan/models"],
                sourceName: "Jan",
                icon: "cube.box",
                extensions: LLMExtensions.all,
                minBytes: 50_000_000
            ) { found.append(src) }

            // ── GPT4All ───────────────────────────────────────────────────────
            await self?.setProgress("Scanning GPT4All\u{2026}")
            if let src = Self.scanDirectory(
                paths: ["~/Library/Application Support/nomic.ai/GPT4All"],
                sourceName: "GPT4All",
                icon: "4.square",
                extensions: LLMExtensions.all,
                minBytes: 50_000_000
            ) { found.append(src) }

            // ── Hugging Face ──────────────────────────────────────────────────
            await self?.setProgress("Scanning Hugging Face cache\u{2026}")
            if let src = Self.scanHuggingFace() { found.append(src) }

            // ── Meetily (Whisper) ─────────────────────────────────────────────
            await self?.setProgress("Scanning Meetily\u{2026}")
            if let src = Self.scanDirectory(
                paths: ["~/Library/Application Support/com.meetily.ai/models"],
                sourceName: "Meetily",
                icon: "waveform",
                extensions: LLMExtensions.whisper,
                minBytes: 50_000_000
            ) { found.append(src) }

            // ── MacWhisper ────────────────────────────────────────────────────
            await self?.setProgress("Scanning MacWhisper\u{2026}")
            if let src = Self.scanDirectory(
                paths: [
                    "~/Library/Application Support/com.krisp.MacWhisper",
                    "~/Library/Application Support/MacWhisper"
                ],
                sourceName: "MacWhisper",
                icon: "waveform",
                extensions: LLMExtensions.whisper,
                minBytes: 50_000_000
            ) { found.append(src) }

            // ── Aiko ──────────────────────────────────────────────────────────
            await self?.setProgress("Scanning Aiko\u{2026}")
            if let src = Self.scanDirectory(
                paths: ["~/Library/Application Support/co.apptorium.Aiko"],
                sourceName: "Aiko",
                icon: "waveform",
                extensions: LLMExtensions.whisper,
                minBytes: 50_000_000
            ) { found.append(src) }

            // ── Whisper Transcription ─────────────────────────────────────────
            await self?.setProgress("Scanning Whisper Transcription\u{2026}")
            if let src = Self.scanDirectory(
                paths: ["~/Library/Application Support/com.apple.whispertranscription"],
                sourceName: "Whisper Transcription",
                icon: "waveform",
                extensions: LLMExtensions.whisper,
                minBytes: 50_000_000
            ) { found.append(src) }

            // ── Msty ──────────────────────────────────────────────────────────
            await self?.setProgress("Scanning Msty\u{2026}")
            if let src = Self.scanDirectory(
                paths: ["~/Library/Application Support/Msty/models"],
                sourceName: "Msty",
                icon: "bubble.left.and.bubble.right",
                extensions: LLMExtensions.all,
                minBytes: 50_000_000
            ) { found.append(src) }

            // ── AnythingLLM ───────────────────────────────────────────────────
            await self?.setProgress("Scanning AnythingLLM\u{2026}")
            if let src = Self.scanDirectory(
                paths: ["~/Library/Application Support/AnythingLLM/models"],
                sourceName: "AnythingLLM",
                icon: "sparkles",
                extensions: LLMExtensions.all,
                minBytes: 50_000_000
            ) { found.append(src) }

            // ── Raw GGUF / GGML files in user folders ─────────────────────────
            await self?.setProgress("Scanning Downloads and Documents\u{2026}")
            if let src = Self.scanRawFiles(
                paths: ["~/Downloads", "~/Documents", "~/Desktop"],
                sourceName: "Loose Model Files",
                icon: "doc.badge.gearshape"
            ) { found.append(src) }

            let result = found.filter { !$0.models.isEmpty }
            let totalModels = result.reduce(0) { $0 + $1.models.count }
            let totalBytes  = result.reduce(Int64(0)) { $0 + $1.totalSize }
            await MainActor.run { [weak self] in
                self?.sources = result
                self?.isScanning = false
                self?.progress = ""
                ScanCache.save(result, key: Self.cacheKey)
                let bytesLabel = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
                Announcer.announce(
                    totalModels == 0
                        ? "Scan complete. No local language models found."
                        : "Scan complete. \(totalModels) model\(totalModels == 1 ? "" : "s") found, \(bytesLabel).",
                    priority: .high
                )
            }
        }
    }

    private func setProgress(_ message: String) async {
        await MainActor.run { [weak self] in self?.progress = message }
    }

    // MARK: - Ollama

    private nonisolated static func scanOllama() -> LLMSource? {
        let manifestsDir = expand("~/.ollama/models/manifests")
        let blobsDir = expand("~/.ollama/models/blobs")
        guard FileManager.default.fileExists(atPath: manifestsDir) else { return nil }

        // Walk manifests: registry/library/<name>/<tag>
        var models: [LLMModel] = []
        let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: manifestsDir),
            includingPropertiesForKeys: [.isRegularFileKey],
            options: .skipsHiddenFiles
        )
        while let url = enumerator?.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }

            // Path relative to manifests dir: registry.ollama.ai/library/<model>/<tag>
            let rel = url.path.dropFirst(manifestsDir.count + 1)
            let parts = rel.split(separator: "/").map(String.init)
            let modelName: String
            if parts.count >= 2 {
                modelName = parts.dropFirst(parts.count - 2).joined(separator: ":")
            } else {
                modelName = url.lastPathComponent
            }

            // Read manifest JSON to find blob digest for size
            let size = ollamaModelSize(manifestURL: url, blobsDir: blobsDir)
            models.append(LLMModel(id: UUID(), name: modelName, url: url, size: size))
        }

        guard !models.isEmpty else { return nil }
        return LLMSource(id: UUID(), name: "Ollama", icon: "cpu", models: models)
    }

    private nonisolated static func ollamaModelSize(manifestURL: URL, blobsDir: String) -> Int64 {
        guard let data = try? Data(contentsOf: manifestURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let layers = json["layers"] as? [[String: Any]]
        else { return 0 }

        var total: Int64 = 0
        for layer in layers {
            if let digest = layer["digest"] as? String {
                let blobName = digest.replacingOccurrences(of: ":", with: "-")
                let blobURL = URL(fileURLWithPath: blobsDir).appendingPathComponent(blobName)
                if let attrs = try? FileManager.default.attributesOfItem(atPath: blobURL.path),
                   let sz = attrs[.size] as? Int64 {
                    total += sz
                }
            }
        }
        return total
    }

    // MARK: - Hugging Face

    private nonisolated static func scanHuggingFace() -> LLMSource? {
        let hubDir = expand("~/.cache/huggingface/hub")
        guard FileManager.default.fileExists(atPath: hubDir) else { return nil }

        let fm = FileManager.default
        guard let repoDirs = try? fm.contentsOfDirectory(
            at: URL(fileURLWithPath: hubDir),
            includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        ) else { return nil }

        var models: [LLMModel] = []
        for repoDir in repoDirs where (try? repoDir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            let snapshotsDir = repoDir.appendingPathComponent("snapshots")
            guard fm.fileExists(atPath: snapshotsDir.path) else { continue }

            let name = repoDir.lastPathComponent
                .replacingOccurrences(of: "models--", with: "")
                .replacingOccurrences(of: "--", with: "/")

            let size = directorySize(url: repoDir)
            guard size >= 50_000_000 else { continue }
            models.append(LLMModel(id: UUID(), name: name, url: repoDir, size: size))
        }

        guard !models.isEmpty else { return nil }
        return LLMSource(id: UUID(), name: "Hugging Face", icon: "arrow.down.doc", models: models)
    }

    // MARK: - Generic directory scan

    private nonisolated static func scanDirectory(
        paths: [String],
        sourceName: String,
        icon: String,
        extensions: Set<String>,
        minBytes: Int64
    ) -> LLMSource? {
        let fm = FileManager.default
        var models: [LLMModel] = []

        for rawPath in paths {
            let dir = expand(rawPath)
            guard fm.fileExists(atPath: dir) else { continue }

            let enumerator = fm.enumerator(
                at: URL(fileURLWithPath: dir),
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: .skipsHiddenFiles
            )
            while let url = enumerator?.nextObject() as? URL {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
                guard extensions.contains(url.pathExtension.lowercased()) else { continue }
                guard let size = fileSize(url: url), size >= minBytes else { continue }
                let name = url.deletingPathExtension().lastPathComponent
                models.append(LLMModel(id: UUID(), name: name, url: url, size: size))
            }
        }

        guard !models.isEmpty else { return nil }
        let sorted = models.sorted { $0.size > $1.size }
        return LLMSource(id: UUID(), name: sourceName, icon: icon, models: sorted)
    }

    // MARK: - Raw GGUF/GGML file scan

    private nonisolated static func scanRawFiles(paths: [String], sourceName: String, icon: String) -> LLMSource? {
        let fm = FileManager.default
        var models: [LLMModel] = []

        for rawPath in paths {
            let dir = expand(rawPath)
            guard fm.fileExists(atPath: dir) else { continue }

            // Only go 3 levels deep to avoid scanning entire home directory
            guard let enumerator = fm.enumerator(
                at: URL(fileURLWithPath: dir),
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: .skipsHiddenFiles
            ) else { continue }

            for case let url as URL in enumerator {
                // Limit depth
                let depth = url.path.dropFirst(dir.count).components(separatedBy: "/").count
                if depth > 4 { enumerator.skipDescendants(); continue }

                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
                guard LLMExtensions.raw.contains(url.pathExtension.lowercased()) else { continue }
                guard let size = fileSize(url: url), size >= 100_000_000 else { continue }
                let name = url.deletingPathExtension().lastPathComponent
                models.append(LLMModel(id: UUID(), name: name, url: url, size: size))
            }
        }

        guard !models.isEmpty else { return nil }
        let sorted = models.sorted { $0.size > $1.size }
        return LLMSource(id: UUID(), name: sourceName, icon: icon, models: sorted)
    }

    // MARK: - Helpers

    private nonisolated static func expand(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    private nonisolated static func fileSize(url: URL) -> Int64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let sz = attrs[.size] as? Int64 else { return nil }
        return sz
    }

    private nonisolated static func directorySize(url: URL) -> Int64 {
        var total: Int64 = 0
        let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: .skipsHiddenFiles
        )
        while let fileURL = enumerator?.nextObject() as? URL {
            if let vals = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
               vals.isRegularFile == true,
               let sz = vals.fileSize {
                total += Int64(sz)
            }
        }
        return total
    }
}

// MARK: - Extension sets

private enum LLMExtensions {
    static let all: Set<String> = ["gguf", "ggml", "bin", "safetensors", "pt", "pth", "onnx"]
    static let whisper: Set<String> = ["bin", "gguf", "ggml", "mlmodelc"]
    static let raw: Set<String> = ["gguf", "ggml", "safetensors"]
}
