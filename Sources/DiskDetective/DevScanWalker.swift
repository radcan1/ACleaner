import Foundation

/// Single-pass replacement for the four developer-junk scans that each used
/// to walk the entire home folder separately (node_modules, five build-folder
/// types, Python venvs) plus the .DS_Store count and stale-large-file search.
///
/// The old code ran eight full `find` traversals of $HOME back to back, and
/// each descended *into* every node_modules / build folder it found — often
/// 100,000+ files apiece — just to keep walking. This does all of it in one
/// `find` process that:
///   • prunes $HOME/Library and $HOME/.Trash (the biggest, least relevant
///     subtrees; their space is already covered by the known-location checks),
///   • prints each matched directory and then prunes it (never descends —
///     we only need the folder's path, not its contents), and
///   • also emits every .DS_Store file and every >500 MB file older than
///     180 days in the same pass.
///
/// Safety carried over from FileSize: the home path is passed to `find` as a
/// plain argv element (never interpolated into a shell string), stderr is
/// discarded to a null sink (so a flood of "Permission denied" lines can't
/// fill a pipe and deadlock), stdout is drained continuously (same reason),
/// and the process is terminated if the surrounding Task is cancelled (so the
/// Stop button works mid-walk).
enum DevScanWalker {

    /// Directory basenames that mark a developer folder. Classification back
    /// into categories (and marker-file verification) happens in ScanEngine.
    static let directoryNames: Set<String> = [
        "node_modules",
        "target", ".build", "build", ".next", ".nuxt",
        ".venv", "venv", ".virtualenv",
    ]

    /// Depth bound from $HOME. The old per-scan limits were 8 (dev folders),
    /// 6 (stale files), and unbounded (.DS_Store); 10 covers all three
    /// generously while pruning keeps the walk cheap.
    static let maxDepth = 10

    /// Stale-file thresholds — must match the old scanStaleFiles behaviour.
    static let staleMinBytesArg = "+500M"   // BSD find size suffix (megabytes)
    static let staleOlderThanDaysArg = "+180"

    /// The exact `find` argument vector. Pulled out as a pure function so a
    /// test can assert the expression without spawning a process.
    static func findArguments(home: String) -> [String] {
        var args: [String] = [home, "-maxdepth", "\(maxDepth)"]

        // Prune the two big irrelevant subtrees.
        args += ["(", "-path", "\(home)/Library", "-o", "-path", "\(home)/.Trash", ")", "-prune"]

        // OR: a developer directory — print it, then prune (do not descend).
        args += ["-o", "(", "-type", "d", "("]
        var first = true
        for name in directoryNamesOrdered {
            if !first { args.append("-o") }
            args += ["-name", name]
            first = false
        }
        args += [")", "-print", "-prune", ")"]

        // OR: any .DS_Store file.
        args += ["-o", "(", "-type", "f", "-name", ".DS_Store", "-print", ")"]

        // OR: a large, old file (stale-file candidate).
        args += ["-o", "(", "-type", "f", "-size", staleMinBytesArg,
                 "-mtime", staleOlderThanDaysArg, "-print", ")"]

        return args
    }

    /// Deterministic ordering of the directory names for the find expression
    /// (Set iteration order is not stable, which would make the expression —
    /// and the test asserting it — non-reproducible).
    static let directoryNamesOrdered: [String] = [
        "node_modules",
        "target", ".build", "build", ".next", ".nuxt",
        ".venv", "venv", ".virtualenv",
    ]

    /// Runs the single find pass and returns every matched path (directories,
    /// .DS_Store files, and stale large files intermixed). Classification is
    /// the caller's job — see ScanEngine.scanDevFolders.
    static func walk(home: String) async -> [String] {
        let output = await runFind(arguments: findArguments(home: home))
        return output
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    // MARK: - Process plumbing

    private static func runFind(arguments: [String]) async -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/find")
        process.arguments = arguments

        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = FileHandle.nullDevice   // discard, never an unread pipe

        let collector = DataCollector()
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty { collector.append(chunk) }
        }

        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
                process.terminationHandler = { _ in
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    // Drain anything buffered after the last readability callback.
                    let remainder = outPipe.fileHandleForReading.readDataToEndOfFile()
                    if !remainder.isEmpty { collector.append(remainder) }
                    continuation.resume(returning: collector.string())
                }
                do {
                    try process.run()
                } catch {
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(returning: "")
                }
            }
        }, onCancel: {
            process.terminate()
        })
    }

    /// Thread-safe byte accumulator — the readability handler and the
    /// termination handler run on different queues.
    private final class DataCollector: @unchecked Sendable {
        private var data = Data()
        private let lock = NSLock()

        func append(_ chunk: Data) {
            lock.lock(); defer { lock.unlock() }
            data.append(chunk)
        }

        func string() -> String {
            lock.lock(); defer { lock.unlock() }
            return String(data: data, encoding: .utf8) ?? ""
        }
    }
}
