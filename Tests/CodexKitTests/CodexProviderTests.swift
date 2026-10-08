import SidekickCore
import XCTest
@testable import CodexKit

final class CodexProviderTests: XCTestCase {
    private let now = Date()
    private func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }

    func testSnapshot() async throws {
        let fx = try CodexFixture()
        try fx.addThread("desk-running", updatedAt: ago(1), name: "Running", rollout: [
            RolloutLine.taskStarted("t1", at: ago(2)),
            RolloutLine.user("Refactor", at: ago(2)),
            RolloutLine.agent("Reading files", phase: "commentary", at: ago(1)),
        ])
        try fx.addThread("cli-approval", updatedAt: ago(3), source: "vscode", originator: "codex-tui", name: "Approve", rollout: [
            RolloutLine.taskStarted("t2", at: ago(4)),
        ])
        try fx.addThread("ide-failed", updatedAt: ago(5), originator: "Cursor", name: "Failed", rollout: [
            RolloutLine.taskStarted("t3", at: ago(6)),
            RolloutLine.taskComplete("t3", at: ago(5), error: true),
        ])
        try fx.addThread("desk-unread", updatedAt: ago(7), name: "Unread", rollout: [
            RolloutLine.taskStarted("t4", at: ago(8)),
            RolloutLine.agent("Shipped it.", at: ago(7)),
            RolloutLine.taskComplete("t4", at: ago(7)),
        ])
        try fx.addThread("no-rollout", updatedAt: ago(9), name: "Busy")
        try fx.addTurn(thread: "no-rollout", turn: "t5", ordinal: 1, status: "inProgress")
        try fx.writeGlobalState(local: ["desk-unread"])

        let hub = BridgeHub()
        await hub.serverCodexHook(.init(event: "UserPromptSubmit", threadId: "cli-approval", toolName: nil, cwd: nil, date: ago(4)))
        await hub.serverCodexHook(.init(event: "PermissionRequest", threadId: "cli-approval", toolName: "Bash", cwd: nil, date: ago(3)))
        let provider = CodexProvider(hub: hub, home: fx.home, codexCandidates: [])

        let threads = await provider.snapshot()
        let byId = Dictionary(uniqueKeysWithValues: threads.map { ($0.nativeId, $0) })
        XCTAssertEqual(threads.map(\.nativeId), ["desk-running", "cli-approval", "ide-failed", "desk-unread", "no-rollout"])

        XCTAssertEqual(byId["desk-running"]?.status, .running)
        XCTAssertEqual(byId["desk-running"]?.surface, .desktop)
        XCTAssertEqual(byId["desk-running"]?.subtitle, "Reading files")
        XCTAssertNil(byId["desk-running"]?.lastTurnEndedAt)

        XCTAssertEqual(byId["cli-approval"]?.status, .needsInput)
        XCTAssertEqual(byId["cli-approval"]?.detail, "Needs approval: Bash")
        XCTAssertEqual(byId["cli-approval"]?.surface, .terminal)

        XCTAssertEqual(byId["ide-failed"]?.status, .failed)
        XCTAssertEqual(byId["ide-failed"]?.surface, .ide)

        XCTAssertEqual(byId["desk-unread"]?.status, .ready)
        XCTAssertEqual(byId["desk-unread"]?.title, "Unread")
        XCTAssertEqual(byId["desk-unread"]?.subtitle, "Shipped it.")
        XCTAssertEqual(byId["desk-unread"]?.lastTurnEndedAt?.timeIntervalSince1970 ?? 0, ago(7).timeIntervalSince1970, accuracy: 0.01)

        XCTAssertEqual(byId["no-rollout"]?.status, .running)
        XCTAssertFalse(threads.contains { $0.canSendLive })

        // The approval is answered: the thread goes back to running.
        await hub.serverCodexHook(.init(event: "PostToolUse", threadId: "cli-approval", toolName: "Bash", cwd: nil, date: ago(2)))
        let after = await provider.snapshot()
        XCTAssertEqual(after.first { $0.nativeId == "cli-approval" }?.status, .running)
    }

    func testHookEventKeepsAnOldThreadListed() async throws {
        let fx = try CodexFixture()
        try fx.addThread("old", updatedAt: ago(60 * 30))
        let hub = BridgeHub()
        let provider = CodexProvider(hub: hub, home: fx.home, codexCandidates: [])
        let before = await provider.snapshot()
        XCTAssertTrue(before.isEmpty)

        await hub.serverCodexHook(.init(event: "PermissionRequest", threadId: "old", toolName: nil, cwd: nil, date: now))
        let after = await provider.snapshot()
        XCTAssertEqual(after.map(\.status), [.needsInput])
        XCTAssertEqual(after.first?.detail, "Waiting for you")
    }

    func testMessages() async throws {
        let fx = try CodexFixture()
        try fx.addThread("t", updatedAt: ago(1), rollout: (0..<30).map { i in
            i.isMultiple(of: 2) ? RolloutLine.user("q\(i)", at: ago(60 - Double(i))) : RolloutLine.agent("a\(i)", at: ago(60 - Double(i)))
        })
        let provider = CodexProvider(hub: BridgeHub(), home: fx.home, codexCandidates: [])
        let snapshot = await provider.snapshot()
        let thread = try XCTUnwrap(snapshot.first)
        let messages = await provider.messages(for: thread, limit: 20)
        XCTAssertEqual(messages.count, 20)
        XCTAssertEqual(messages.first?.text, "q10")
        XCTAssertEqual(messages.last?.text, "a29")
        XCTAssertEqual(messages.last?.role, .assistant)
        let none = await provider.messages(for: thread, limit: 0)
        XCTAssertEqual(none, [])
    }

    func testSendQueuesThroughTheNewestCodex() async throws {
        let fx = try CodexFixture()
        let log = fx.home.appendingPathComponent("argv.log").path
        let old = try fakeCodex(in: fx.home, name: "old", version: "0.159.0", log: log, exit: 0)
        let new = try fakeCodex(in: fx.home, name: "new", version: "0.160.1", log: log, exit: 0)
        try fx.addThread("idle", updatedAt: ago(1), rollout: [RolloutLine.taskComplete("t1", at: ago(1))])
        try fx.addThread("stopped", updatedAt: ago(2), rollout: [RolloutLine.turnAborted("t2", at: ago(2))])
        let provider = CodexProvider(hub: BridgeHub(), home: fx.home, codexCandidates: [old, "/nonexistent/codex", new])
        let threads = await provider.snapshot()
        XCTAssertTrue(threads.allSatisfy(\.canSendLive))

        let idle = try XCTUnwrap(threads.first { $0.nativeId == "idle" })
        let stopped = try XCTUnwrap(threads.first { $0.nativeId == "stopped" })
        let sentIdle = await provider.send("-n check this", to: idle)
        let sentStopped = await provider.send("hello", to: stopped)
        XCTAssertEqual(sentIdle, .queued("Runs when Codex is idle (up to ~10 s)"))
        XCTAssertEqual(sentStopped, .queued("Paused in Codex — open to resume"))

        let calls = try String(contentsOfFile: log, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(calls, [
            "new|queue|--thread=idle|--message=-n check this",
            "new|queue|--thread=stopped|--message=hello",
        ])
    }

    func testSendReportsTheFirstErrorLine() async throws {
        let fx = try CodexFixture()
        let codex = try fakeCodex(in: fx.home, name: "codex", version: "0.160.1", log: "/dev/null", exit: 1)
        try fx.addThread("t", updatedAt: ago(1))
        let provider = CodexProvider(hub: BridgeHub(), home: fx.home, codexCandidates: [codex])
        let snapshot = await provider.snapshot()
        let thread = try XCTUnwrap(snapshot.first)
        let outcome = await provider.send("hi", to: thread)
        XCTAssertEqual(outcome, .failed("Error: no rollout found for thread id t"))

        let missing = CodexProvider(hub: BridgeHub(), home: fx.home, codexCandidates: [])
        let notFound = await missing.send("hi", to: thread)
        XCTAssertEqual(notFound, .failed("Codex CLI not found"))
    }

    /// A stand-in `codex`: answers `--version`, logs other argv joined by "|", and exits with `exit`.
    private func fakeCodex(in dir: URL, name: String, version: String, log: String, exit: Int32) throws -> String {
        let url = dir.appendingPathComponent("bin-\(name)")
        let script = """
            #!/bin/sh
            if [ "$1" = "--version" ]; then echo "codex-cli \(version)"; exit 0; fi
            (printf '%s' "\(name)"; for a in "$@"; do printf '|%s' "$a"; done; printf '\\n') >> "\(log)"
            [ \(exit) -eq 0 ] && echo "Queued message m for thread x." || echo "Error: no rollout found for thread id t" >&2
            exit \(exit)
            """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }
}
