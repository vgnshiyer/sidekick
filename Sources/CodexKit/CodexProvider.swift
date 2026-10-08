import Foundation
import SidekickCore
import TerminalKit

/// Codex CLI and desktop threads, read from CODEX_HOME's state databases, rollouts and the
/// desktop's global state, plus hook events from the bridge. Everything is read-only except
/// `codex queue`, which sends.
public final class CodexProvider: ThreadProvider, Sendable {
    public let platform: Platform = .codex
    private let hub: BridgeHub
    private let home: URL
    private let index: CodexIndex
    private let binary: CodexBinary

    public convenience init(hub: BridgeHub = .shared) {
        self.init(hub: hub, home: Paths.codexHome, codexCandidates: CodexCLI.candidatePaths)
    }

    init(hub: BridgeHub, home: URL, codexCandidates: [String]) {
        self.hub = hub
        self.home = home
        self.index = CodexIndex(home: home)
        self.binary = CodexBinary(candidates: codexCandidates)
    }

    public func snapshot() async -> [AgentThread] {
        let now = Date()
        let hooked = await hub.codexThreadIdsWithHooks(since: now.addingTimeInterval(-CodexIndex.window))
        let entries = await index.entries(hookedIds: Set(hooked), now: now)
        let canSend = binary.isInstalled
        var threads: [AgentThread] = []
        for entry in entries {
            threads.append(CodexStatus.thread(
                row: entry.row,
                tail: entry.tail,
                hookEvents: await hub.codexHookEvents(threadId: entry.row.id),
                inProgress: entry.inProgress,
                unread: entry.unread,
                canSend: canSend))
        }
        return threads
    }

    public func messages(for thread: AgentThread, limit: Int) async -> [ChatMessage] {
        guard let path = thread.extra["rolloutPath"], let tail = await index.tail(path: path) else { return [] }
        return Array(tail.messages.suffix(max(0, limit)))
    }

    /// Queues the text with `codex queue`; whichever Codex process owns the thread runs it once idle.
    public func send(_ text: String, to thread: AgentThread) async -> SendOutcome {
        guard let codex = await binary.path() else { return .failed("Codex CLI not found") }
        let result = await Shell.run(codex, CodexCLI.queueArguments(threadId: thread.nativeId, text: text), timeout: 30)
        var interrupted = false
        if let path = thread.extra["rolloutPath"] {
            interrupted = await index.tail(path: path)?.lifecycle?.event == .aborted
        }
        return CodexCLI.queueOutcome(result, lastTurnInterrupted: interrupted)
    }

    /// Terminal threads focus their terminal; everything else, and any miss, opens the desktop app.
    public func open(_ thread: AgentThread) async -> Bool {
        if thread.surface == .terminal {
            let pid = await terminalPid(for: thread)
            if await TerminalFocus.focus(pid: pid, cwd: thread.cwd, titleHint: thread.nativeId, tmux: nil) {
                return true
            }
        }
        guard let url = CodexCLI.threadURL(id: thread.nativeId) else { return false }
        return await SystemActions.open(url)
    }

    /// The `codex` TUI driving a terminal thread: the writer-lock holder, a process launched
    /// with the thread id, or one whose working directory matches.
    private func terminalPid(for thread: AgentThread) async -> Int32? {
        let ps = await Shell.run("/bin/ps", ["-axo", "pid=,tty=,args="], timeout: 3)
        let processes = CodexCLI.terminalProcesses(fromPS: ps.stdout)
        guard !processes.isEmpty else { return nil }

        let lock = home.appendingPathComponent("thread-writer-locks/\(thread.nativeId).lock").path
        var holders: [Int32] = []
        if FileManager.default.fileExists(atPath: lock) {
            holders = CodexCLI.pids(fromLsof: await Shell.run("/usr/sbin/lsof", ["-t", lock], timeout: 3).stdout)
        }
        if let pid = CodexCLI.owner(of: thread.nativeId, among: processes, lockHolders: holders) { return pid }

        guard let cwd = thread.cwd.map(canonicalPath) else { return nil }
        for process in processes {
            let lsof = await Shell.run("/usr/sbin/lsof", ["-a", "-p", String(process.pid), "-d", "cwd", "-Fn"], timeout: 3)
            if CodexCLI.cwd(fromLsof: lsof.stdout).map(canonicalPath) == cwd { return process.pid }
        }
        return nil
    }

    private func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }
}
