import Foundation
import SidekickCore

/// Fake threads for `--demo` and `--snapshot`: every status, both platforms, every surface.
/// Sends are simulated; nothing leaves the process.
final class DemoProvider: ThreadProvider, @unchecked Sendable {
    let platform: Platform
    private let lock = NSLock()
    private var threads: [AgentThread]
    private var conversations: [String: [ChatMessage]]

    private init(platform: Platform, threads: [AgentThread], conversations: [String: [ChatMessage]]) {
        self.platform = platform
        self.threads = threads
        self.conversations = conversations
    }

    /// One provider per platform, seeded relative to `now`.
    static func all(now: Date = Date()) -> [DemoProvider] {
        let seed = DemoSeed(now: now)
        return Platform.allCases.map { platform in
            let threads = seed.threads.filter { $0.platform == platform }
            let ids = Set(threads.map(\.id))
            return DemoProvider(
                platform: platform, threads: threads, conversations: seed.conversations.filter { ids.contains($0.key) })
        }
    }

    func snapshot() async -> [AgentThread] {
        lock.withLock { threads }
    }

    func messages(for thread: AgentThread, limit: Int) async -> [ChatMessage] {
        lock.withLock { Array((conversations[thread.id] ?? []).suffix(limit)) }
    }

    func send(_ text: String, to thread: AgentThread) async -> SendOutcome {
        try? await Task.sleep(nanoseconds: 600_000_000)
        let outcome: SendOutcome
        switch platform {
        case .claude where text.hasPrefix("/"):
            outcome = .copiedToClipboard("Copied — paste it in \(thread.surface.displayName)")
        case .claude:
            outcome = thread.status == .running ? .queued("Runs after the current turn") : .delivered
        case .codex:
            outcome = .queued("Runs when Codex is idle (up to ~10 s)")
        }
        if case .copiedToClipboard = outcome { return outcome }
        lock.withLock {
            let message = ChatMessage(id: UUID().uuidString, role: .user, text: text, date: Date())
            conversations[thread.id, default: []].append(message)
        }
        return outcome
    }

    func open(_ thread: AgentThread) async -> Bool {
        true
    }
}

/// The demo's threads and conversations.
private struct DemoSeed {
    var threads: [AgentThread] = []
    var conversations: [String: [ChatMessage]] = [:]

    init(now: Date) {
        let repos = NSHomeDirectory() + "/repos"
        func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }

        add(AgentThread(
            platform: .claude, nativeId: "demo-bridge", surface: .terminal,
            title: "Fix flaky bridge reconnect", status: .needsInput, detail: "Needs permission",
            subtitle: "Bash: swift test --filter BridgeKitTests",
            cwd: repos + "/sidekick", branch: "fix/bridge-reconnect", updatedAt: ago(50), canSendLive: true),
            [
                (.user, "The bridge drops the session after the Mac sleeps. Can you find out why and fix it?"),
                (.assistant, """
                Found it. After wake, the mod keeps polling with the old socket handle, so every request \
                fails until the session restarts.

                Plan:
                - reopen the socket when a poll fails with `ECONNRESET`
                - back off to 5 s while Sidekick is unreachable
                - add a test that restarts the server mid-poll
                """),
                (.user, "Sounds good, go ahead."),
                (.assistant, """
                Updated `BridgeClient.request` to reconnect once after a reset, and added a test:

                ```swift
                func testReconnectsAfterServerRestart() async throws
                ```

                I'd like to run the bridge tests next: **swift test --filter BridgeKitTests**.
                """),
            ])

        add(AgentThread(
            platform: .codex, nativeId: "demo-toml", surface: .desktop,
            title: "Migrate config loader to TOML", status: .failed,
            subtitle: "stream disconnected before completion",
            cwd: repos + "/dotfiles", branch: "main", updatedAt: ago(6 * 60)),
            [
                (.user, "Move the config loader from JSON to TOML and keep the old keys working."),
                (.assistant, "Started on `config/loader.rs`: parsing both formats behind one `Config::load`."),
            ])

        add(AgentThread(
            platform: .claude, nativeId: "demo-notes", surface: .desktop,
            title: "Draft release notes for 0.1", status: .idle,
            subtitle: "Release notes are in CHANGELOG.md, grouped by area.",
            cwd: repos + "/sidekick", branch: "main", updatedAt: ago(3 * 60), lastTurnEndedAt: ago(3 * 60)),
            [
                (.user, "Draft release notes for 0.1 from the merged PRs."),
                (.assistant, "Release notes are in `CHANGELOG.md`, grouped by area: **Pets**, **Bridge**, **CLI**."),
            ])

        add(AgentThread(
            platform: .codex, nativeId: "demo-bench", surface: .terminal,
            title: "Profile cold start", status: .running,
            subtitle: "Running cargo bench --bench startup",
            cwd: repos + "/engine", branch: "perf/startup", updatedAt: ago(40)),
            [
                (.user, "Cold start got slower this week. Profile it and tell me what changed."),
                (.assistant, "Building the bench profile first, then I'll compare against last week's tag."),
            ])

        add(AgentThread(
            platform: .claude, nativeId: "demo-retry", surface: .ide,
            title: "Add retry to webhook sender", status: .running,
            subtitle: "Editing src/webhooks/sender.ts",
            cwd: repos + "/hooks", branch: "feat/retry", updatedAt: ago(20), canSendLive: true),
            [
                (.user, "Add exponential backoff to the webhook sender, max 5 attempts."),
                (.assistant, "Adding a `retry` helper with jitter and wiring it into `send()`."),
            ])

        add(AgentThread(
            platform: .codex, nativeId: "demo-rename", surface: .ide,
            title: "Rename PetLibrary APIs", status: .idle,
            subtitle: "Renamed loadAll and updated every call site.",
            cwd: repos + "/sidekick", branch: "refactor/pets", updatedAt: ago(2 * 3600), lastTurnEndedAt: ago(2 * 3600)),
            [
                (.user, "Rename the PetLibrary loaders to match the new folder layout."),
                (.assistant, "Renamed `loadAll` and updated every call site. Tests pass."),
            ])

        add(AgentThread(
            platform: .claude, nativeId: "demo-acks", surface: .terminal,
            title: "Explain the ThreadStore ack rule", status: .idle,
            subtitle: "Acks older than 14 days are dropped on save.",
            cwd: repos + "/sidekick", branch: "main", updatedAt: ago(5 * 3600), lastTurnEndedAt: ago(5 * 3600)),
            [
                (.user, "Why does a thread go back to Idle after I open it?"),
                (.assistant, """
                Opening a thread acknowledges it. `Ready` only shows while the last turn ended after your \
                last acknowledgement. Acks older than 14 days are dropped on save.
                """),
            ])
    }

    private mutating func add(_ thread: AgentThread, _ messages: [(ChatMessage.Role, String)]) {
        threads.append(thread)
        conversations[thread.id] = messages.enumerated().map { index, message in
            ChatMessage(
                id: "\(thread.nativeId)-\(index)", role: message.0, text: message.1,
                date: thread.updatedAt.addingTimeInterval(TimeInterval(index - messages.count) * 60))
        }
    }
}
