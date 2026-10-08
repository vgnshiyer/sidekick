import Foundation
import SidekickCore

/// The `codex` command line: finding the newest binary, `codex queue`, and the process
/// lookups behind "Open" for terminal threads.
enum CodexCLI {
    /// The desktop-bundled executable first, so it wins a version tie, then Homebrew.
    static let candidatePaths = [
        "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
        "/opt/homebrew/bin/codex",
        "/usr/local/bin/codex",
    ]

    /// `codex queue` arguments. The `--flag=value` form keeps text that starts with "-" a value.
    static func queueArguments(threadId: String, text: String) -> [String] {
        ["queue", "--thread=\(threadId)", "--message=\(text)"]
    }

    /// "codex-cli 0.160.1" → [0, 160, 1].
    static func version(from output: String) -> [Int]? {
        guard let token = output.split(whereSeparator: \.isWhitespace).first(where: { $0.first?.isNumber == true })
        else { return nil }
        return token.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
    }

    /// The path with the highest version; the earlier path wins a tie.
    static func newest(_ found: [(path: String, version: [Int])]) -> String? {
        found.max { $0.version.lexicographicallyPrecedes($1.version) }?.path
    }

    /// What a finished `codex queue` run means for the user.
    static func queueOutcome(_ result: ShellResult, lastTurnInterrupted: Bool) -> SendOutcome {
        if result.timedOut { return .failed("codex queue timed out") }
        guard result.ok else { return .failed(firstLine(result.stderr) ?? "codex queue failed") }
        // Codex holds queued input after an interrupted turn until the user resumes the thread.
        if lastTurnInterrupted { return .queued("Paused in Codex — open to resume") }
        return .queued("Runs when Codex is idle (up to ~10 s)")
    }

    static func firstLine(_ text: String) -> String? {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }

    /// `codex://threads/<id>`, which the Codex desktop app opens.
    static func threadURL(id: String) -> URL? {
        guard let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return URL(string: "codex://threads/\(encoded)")
    }

    struct Process: Equatable {
        var pid: Int32
        var args: String
    }

    /// Interactive `codex` processes from `ps -axo pid=,tty=,args=`: ones with a terminal
    /// that aren't an app-server.
    static func terminalProcesses(fromPS output: String) -> [Process] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count == 3, let pid = Int32(fields[0]), fields[1] != "??" else { return nil }
            let args = fields[2].trimmingCharacters(in: .whitespaces)
            let executable = args.split(separator: " ").first.map { URL(fileURLWithPath: String($0)).lastPathComponent }
            guard executable == "codex", !args.contains(" app-server") else { return nil }
            return Process(pid: pid, args: args)
        }
    }

    /// Pids from `lsof -t`.
    static func pids(fromLsof output: String) -> [Int32] {
        output.split(whereSeparator: \.isNewline).compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// The working directory from `lsof -a -p <pid> -d cwd -Fn`.
    static func cwd(fromLsof output: String) -> String? {
        output.split(whereSeparator: \.isNewline).first { $0.hasPrefix("n") }.map { String($0.dropFirst()) }
    }

    /// The terminal process that holds the thread's writer lock, else one launched with the thread id.
    static func owner(of threadId: String, among processes: [Process], lockHolders: [Int32]) -> Int32? {
        processes.first { lockHolders.contains($0.pid) }?.pid
            ?? processes.first { $0.args.contains(threadId) }?.pid
    }
}

/// Resolves and caches the newest installed `codex` binary.
actor CodexBinary {
    private let candidates: [String]
    private var cached: String?

    init(candidates: [String] = CodexCLI.candidatePaths) {
        self.candidates = candidates
    }

    nonisolated var isInstalled: Bool {
        candidates.contains { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func path() async -> String? {
        if let cached, FileManager.default.isExecutableFile(atPath: cached) { return cached }
        // A throwaway CODEX_HOME keeps `--version` from touching the user's ~/.codex.
        let probeHome = FileManager.default.temporaryDirectory.appendingPathComponent("sidekick-codex-probe").path
        try? FileManager.default.createDirectory(atPath: probeHome, withIntermediateDirectories: true)
        var found: [(path: String, version: [Int])] = []
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            let result = await Shell.run(path, ["--version"], env: ["CODEX_HOME": probeHome], timeout: 5)
            if result.ok, let version = CodexCLI.version(from: result.stdout) {
                found.append((path, version))
            }
        }
        cached = CodexCLI.newest(found)
        return cached
    }
}
