import Foundation
import AppKit

/// Downloads the latest ACleaner release from GitHub and installs it in
/// place — no browser involved. Pearcleaner-style flow:
///
///   1. Resolve the release's .zip asset from the GitHub API.
///   2. Stream-download it with percentage progress (announced via
///      VoiceOver at 25% milestones, no spinner).
///   3. Unpack with `ditto -xk` (preserves the code signature).
///   4. Validate: bundle exists, bundle ID is ours, signature verifies.
///   5. Strip the quarantine flag so Gatekeeper allows the relaunch.
///   6. Move the running copy to the Trash (reversible), move the new
///      one into /Applications, and relaunch.
@MainActor
final class SelfUpdater: ObservableObject {
    enum State: Equatable {
        case idle
        case downloading(percent: Int)
        case installing
        case failed(String)
    }
    @Published var state: State = .idle

    private let repo = "radcan1/ACleaner"
    private let installedAppPath = "/Applications/ACleaner.app"
    private let expectedBundleID = "com.user.ACleaner"

    struct UpdateError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
        init(_ m: String) { message = m }
    }

    func updateNow(to version: String) async {
        do {
            state = .downloading(percent: 0)
            Announcer.announce("Downloading ACleaner \(version).")
            let zipURL = try await downloadAsset()

            state = .installing
            Announcer.announce("Installing update.")
            try await install(zipURL: zipURL)

            Announcer.announce("Update installed. ACleaner will now relaunch.")
            try? await Task.sleep(nanoseconds: 1_500_000_000)  // let VoiceOver finish
            relaunch()
        } catch {
            state = .failed(error.localizedDescription)
            Announcer.announce("Update failed. \(error.localizedDescription)")
        }
    }

    // MARK: - Download

    private func downloadAsset() async throws -> URL {
        // Resolve the asset URL fresh so we always get the latest release.
        guard let apiURL = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            throw UpdateError("Bad release URL.")
        }
        var request = URLRequest(url: apiURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, _) = try await URLSession.shared.data(for: request)
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let assets = json["assets"] as? [[String: Any]],
            let asset = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".zip") == true }),
            let urlString = asset["browser_download_url"] as? String,
            let assetURL = URL(string: urlString)
        else {
            throw UpdateError("No downloadable app archive found in the latest release.")
        }
        let expectedBytes = (asset["size"] as? Int) ?? 0

        // Stream to disk, publishing percent progress as bytes arrive.
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("ACleaner-update-\(UUID().uuidString).zip")
        FileManager.default.createFile(atPath: dest.path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: dest.path) else {
            throw UpdateError("Could not create the download file.")
        }
        defer { try? handle.close() }

        let (bytes, response) = try await URLSession.shared.bytes(from: assetURL)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError("Download failed (server error).")
        }
        let total = response.expectedContentLength > 0
            ? Int(response.expectedContentLength) : expectedBytes

        var received = 0
        var lastShown = 0
        var lastSpoken = 0
        var buffer = Data()
        buffer.reserveCapacity(128 * 1024)
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 128 * 1024 {
                try handle.write(contentsOf: buffer)
                received += buffer.count
                buffer.removeAll(keepingCapacity: true)
                if total > 0 {
                    let pct = min(99, received * 100 / total)
                    if pct >= lastShown + 5 {
                        lastShown = pct
                        state = .downloading(percent: pct)
                    }
                    // Milestone announcements only — a running commentary
                    // would drown VoiceOver users in numbers.
                    if pct >= lastSpoken + 25 {
                        lastSpoken = pct
                        Announcer.announce("\(pct) percent downloaded.", priority: .medium)
                    }
                }
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
        }
        state = .downloading(percent: 100)
        return dest
    }

    // MARK: - Install

    private func install(zipURL: URL) async throws {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory
            .appendingPathComponent("ACleaner-staging-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        // ditto preserves code signatures and extended attributes; unzip(1)
        // does not always.
        let (unzipStatus, _, unzipErr) = await CommandRunner.runOnce(
            executable: "/usr/bin/ditto",
            args: ["-xk", zipURL.path, staging.path],
            timeoutSeconds: 60)
        try? fm.removeItem(at: zipURL)
        guard unzipStatus == 0 else {
            throw UpdateError("Could not unpack the update. \(unzipErr)")
        }

        guard let appName = try fm.contentsOfDirectory(atPath: staging.path)
            .first(where: { $0.hasSuffix(".app") }) else {
            throw UpdateError("The downloaded archive did not contain an app.")
        }
        let newApp = staging.appendingPathComponent(appName)

        // Refuse anything that is not ACleaner or fails signature integrity.
        guard let bundle = Bundle(url: newApp), bundle.bundleIdentifier == expectedBundleID else {
            throw UpdateError("The downloaded app failed validation.")
        }
        let (signStatus, _, _) = await CommandRunner.runOnce(
            executable: "/usr/bin/codesign",
            args: ["--verify", "--deep", newApp.path],
            timeoutSeconds: 60)
        guard signStatus == 0 else {
            throw UpdateError("The downloaded app failed signature verification.")
        }

        // Without this, Gatekeeper blocks the downloaded copy on relaunch.
        _ = await CommandRunner.runOnce(
            executable: "/usr/bin/xattr",
            args: ["-dr", "com.apple.quarantine", newApp.path],
            timeoutSeconds: 30)

        // Swap: running copy goes to the Trash (recoverable), new copy in.
        let installed = URL(fileURLWithPath: installedAppPath)
        if fm.fileExists(atPath: installed.path) {
            try fm.trashItem(at: installed, resultingItemURL: nil)
        }
        do {
            try fm.moveItem(at: newApp, to: installed)
        } catch {
            // Cross-volume move can fail; ditto copies instead.
            let (cpStatus, _, cpErr) = await CommandRunner.runOnce(
                executable: "/usr/bin/ditto",
                args: [newApp.path, installed.path],
                timeoutSeconds: 60)
            guard cpStatus == 0 else {
                throw UpdateError("Could not install the new version. \(cpErr)")
            }
        }
    }

    // MARK: - Relaunch

    private func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"\(installedAppPath)\""]
        try? p.run()
        NSApp.terminate(nil)
    }
}
