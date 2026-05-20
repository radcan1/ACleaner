import Foundation

// Shared subprocess helpers used by UpdateEngine, InstallEngine, and
// MaintenanceEngine. Keeps Homebrew env defaults in one place and makes the
// streaming pipe handling testable.

enum CommandRunner {

    /// Run a command and collect the full stdout+stderr.
    @discardableResult
    static func runOnce(executable: String,
                        args: [String],
                        extraEnv: [String: String] = [:]) async -> (status: Int32, out: String) {
        await withCheckedContinuation { (continuation: CheckedContinuation<(Int32, String), Never>) in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: executable)
            proc.arguments = args
            proc.environment = brewEnv(adding: extraEnv)

            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe

            do {
                try proc.run()
            } catch {
                continuation.resume(returning: (1, ""))
                return
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            let s = String(data: data, encoding: .utf8) ?? ""
            continuation.resume(returning: (proc.terminationStatus, s))
        }
    }

    /// Run a command and stream every output line to `onLine` as soon as it
    /// is produced. Returns true on exit 0.
    static func stream(executable: String,
                       args: [String],
                       extraEnv: [String: String] = [:],
                       onLine: @escaping (String) -> Void,
                       processStarted: ((Process) -> Void)? = nil) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: executable)
            proc.arguments = args
            proc.environment = brewEnv(adding: extraEnv)

            let outPipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe

            let buffer = LineBuffer(onLine: onLine)

            outPipe.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                if !d.isEmpty { buffer.feed(d) }
            }
            errPipe.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                if !d.isEmpty { buffer.feed(d) }
            }

            proc.terminationHandler = { p in
                buffer.flush()
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(returning: p.terminationStatus == 0)
            }

            do {
                try proc.run()
                processStarted?(proc)
            } catch {
                onLine("error launching \(executable): \(error)")
                continuation.resume(returning: false)
            }
        }
    }

    private static func brewEnv(adding extra: [String: String]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["HOMEBREW_NO_EMOJI"] = "1"
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        for (k, v) in extra { env[k] = v }
        return env
    }

    // MARK: - Path resolution

    static func resolve(_ candidates: [String]) -> String? {
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    static var brewPath: String? {
        resolve(["/opt/homebrew/bin/brew", "/usr/local/bin/brew"])
    }

    static var masPath: String? {
        resolve(["/opt/homebrew/bin/mas", "/usr/local/bin/mas"])
    }

    // MARK: - Run as administrator (no terminal involved)

    /// Run a command as root via macOS's standard authorization dialog
    /// (native, VoiceOver-readable). The whole `executable args…` invocation
    /// runs with admin rights, so any sudo calls inside it become no-ops
    /// (root never has to re-authenticate). This is the only reliable way
    /// to invoke `mas upgrade`/`mas install` for App Store apps whose
    /// internal sudo call cannot read SUDO_ASKPASS.
    ///
    /// Output is streamed line-by-line via onLine while the command runs.
    /// macOS caches authorization for ~5 minutes, so consecutive admin-mode
    /// calls inside a single batch only prompt once.
    static func streamAsAdmin(
        executable: String,
        args: [String],
        prompt: String?,
        onLine: @escaping (String) -> Void
    ) async -> Bool {
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("macupdater-\(UUID().uuidString).log")
        let logPath = logURL.path
        FileManager.default.createFile(atPath: logPath, contents: Data(), attributes: nil)
        defer { try? FileManager.default.removeItem(atPath: logPath) }

        let exeQ   = shellEscape(executable)
        let argsQ  = args.map(shellEscape).joined(separator: " ")
        // Capture the real user identity BEFORE the privilege escalation. mas-cli
        // (and well-behaved sudo-aware tools generally) refuse to operate as
        // root unless they can find out which user invoked them via SUDO_UID /
        // SUDO_GID / USER / LOGNAME / HOME — without these, mas errors out with
        // "Failed to get sudo uid". osascript's "with administrator privileges"
        // doesn't set them, so we plant them ourselves.
        let realUid  = getuid()
        let realGid  = getgid()
        let realUser = NSUserName()
        let realHome = NSHomeDirectory()
        let envPrefix =
            "SUDO_UID=\(realUid) " +
            "SUDO_GID=\(realGid) " +
            "SUDO_USER=\(shellEscape(realUser)) " +
            "USER=\(shellEscape(realUser)) " +
            "LOGNAME=\(shellEscape(realUser)) " +
            "HOME=\(shellEscape(realHome))"
        // Run the command, capture its exit code, append a sentinel line so
        // we can pluck the real exit code out of the log afterwards.
        let shellCmd = "{ env \(envPrefix) \(exeQ) \(argsQ) ; printf '\\nMACUPDATER_EXIT:%d\\n' $?; } >> \(shellEscape(logPath)) 2>&1"

        let promptText = prompt ?? "Mac Updater needs admin access."
        let appleScript =
            "do shell script \"" + osaEscape(shellCmd) + "\"" +
            " with administrator privileges" +
            " with prompt \"" + osaEscape(promptText) + "\""

        let tailTask = Task.detached {
            await tailFile(path: logPath, onLine: onLine)
        }

        // osascript blocks until the shell command finishes (or auth fails).
        let (osaStatus, osaErr) = await runOnce(
            executable: "/usr/bin/osascript",
            args: ["-e", appleScript]
        )

        tailTask.cancel()
        _ = await tailTask.value

        if osaStatus != 0 {
            // Auth cancelled or osascript itself errored.
            let trimmedErr = osaErr.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedErr.isEmpty { onLine(trimmedErr) }
            return false
        }

        // Read the log one final time to scrape the exit-code sentinel.
        let final = (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? ""
        if let range = final.range(of: "MACUPDATER_EXIT:", options: .backwards) {
            let after = final[range.upperBound...]
            let trimmed = after.trimmingCharacters(in: .whitespacesAndNewlines)
            if let n = Int32(trimmed) { return n == 0 }
        }
        return false
    }

    /// Polls a file and emits any new lines as they appear. Stops when the
    /// surrounding task is cancelled. Lines containing the internal exit
    /// sentinel are suppressed.
    private static func tailFile(path: String, onLine: @escaping (String) -> Void) async {
        var lastSize: UInt64 = 0
        var carry = Data()
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 200_000_000) // 200 ms
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = (attrs[.size] as? NSNumber)?.uint64Value else { continue }
            if size > lastSize {
                if let handle = FileHandle(forReadingAtPath: path) {
                    try? handle.seek(toOffset: lastSize)
                    let chunk = handle.readDataToEndOfFile()
                    try? handle.close()
                    carry.append(chunk)
                    while let nl = carry.firstIndex(of: 0x0a) {
                        let lineData = carry.subdata(in: 0..<nl)
                        carry.removeSubrange(0...nl)
                        if let s = String(data: lineData, encoding: .utf8),
                           !s.contains("MACUPDATER_EXIT:") {
                            onLine(s)
                        }
                    }
                }
                lastSize = size
            }
        }
        if !carry.isEmpty,
           let s = String(data: carry, encoding: .utf8),
           !s.contains("MACUPDATER_EXIT:") {
            onLine(s)
        }
    }

    private static func shellEscape(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func osaEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

// MARK: - Line buffering

/// Splits incoming pipe Data into UTF-8 lines on \n boundaries.
final class LineBuffer {
    private var carry = Data()
    private let onLine: (String) -> Void
    private let queue = DispatchQueue(label: "MacUpdater.LineBuffer")

    init(onLine: @escaping (String) -> Void) {
        self.onLine = onLine
    }

    func feed(_ data: Data) {
        queue.async {
            self.carry.append(data)
            while let nl = self.carry.firstIndex(of: 0x0a) {
                let lineData = self.carry.subdata(in: 0..<nl)
                self.carry.removeSubrange(0...nl)
                if let s = String(data: lineData, encoding: .utf8) {
                    self.onLine(s)
                }
            }
        }
    }

    func flush() {
        queue.async {
            if !self.carry.isEmpty, let s = String(data: self.carry, encoding: .utf8), !s.isEmpty {
                self.onLine(s)
            }
            self.carry.removeAll()
        }
    }
}
