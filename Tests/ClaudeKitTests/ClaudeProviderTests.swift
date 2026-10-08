import Foundation
import SidekickCore
import XCTest
@testable import ClaudeKit

/// Records send/open side effects instead of touching the clipboard, URLs or terminals.
private actor Effects {
    var copied: [String] = []
    var opened: [URL] = []
    var focused: [[String?]] = []

    func copy(_ text: String) { copied.append(text) }
    func open(_ url: URL) { opened.append(url) }
    func focus(_ args: [String?]) { focused.append(args) }

    nonisolated var actions: ClaudeProvider.Actions {
        ClaudeProvider.Actions(
            copy: { await self.copy($0) },
            openURL: { await self.open($0); return true },
            focusTerminal: { await self.focus([$0.map { String($0) }, $1, $2, $3]); return true })
    }
}

final class ClaudeProviderTests: XCTestCase {
    private var home: ClaudeHome!
    private var pid: Int32 { getpid() }
    private var procStart = ""

    override func setUp() async throws {
        home = try ClaudeHome()
        procStart = await processStart(pid)
    }

    override func tearDown() {
        home = nil
    }

    private func registry(_ fileName: String, sessionId: String, _ fields: [String: Any] = [:]) throws {
        var row: [String: Any] = [
            "pid": Int(pid), "sessionId": sessionId, "cwd": "/Users/me/repo", "procStart": procStart, "kind": "interactive",
            "entrypoint": "cli", "status": "idle", "startedAt": 1_791_490_000_000, "statusUpdatedAt": 1_791_490_000_000,
            "messagingSocketPath": "/tmp/cc-socks/\(pid).sock", "name": "repo-5f", "nameSource": "derived",
        ]
        row.merge(fields) { _, new in new }
        try home.writeRegistry(fileName, row)
    }

    private func transcript(_ sessionId: String, folder: String = "-Users-me-repo", title: String) throws {
        try home.writeTranscript(folder: folder, sessionId: sessionId, [
            Line.prompt("Do the thing", at: "2026-10-08T10:00:00.000Z", uuid: "\(sessionId)-u1"),
            Line.assistant([Line.text("Done.")], stop: "end_turn", at: "2026-10-08T10:00:01.000Z", uuid: "\(sessionId)-a1"),
            Line.aiTitle(title),
        ])
    }

    private func provider(hub: BridgeHub = BridgeHub(), effects: Effects = Effects(), timeout: TimeInterval = 15) -> ClaudeProvider {
        ClaudeProvider(hub: hub, claudeDir: home.root, actions: effects.actions, sendTimeout: timeout)
    }

    private func first(_ provider: ClaudeProvider) async throws -> AgentThread {
        let threads = await provider.snapshot()
        return try XCTUnwrap(threads.first)
    }

    func testSnapshotListsLiveInteractiveSessionsOnly() async throws {
        try registry("\(pid).json", sessionId: "live")
        try transcript("live", title: "Live session")
        let dead = deadPID()
        try registry("\(dead).json", sessionId: "dead", ["pid": Int(dead)])
        try registry("1.json", sessionId: "reused", ["procStart": "Mon Jan  1 00:00:00 2001"])
        try registry("2.json", sessionId: "missing-start", ["procStart": NSNull()])
        try registry("3.json", sessionId: "background", ["kind": "bg"])
        try registry("foo.json", sessionId: "not-canonical")

        let threads = await provider().snapshot()
        XCTAssertEqual(threads.map(\.nativeId), ["live"])
        let thread = try XCTUnwrap(threads.first)
        XCTAssertEqual(thread.title, "Live session")
        XCTAssertEqual(thread.status, .idle)
        XCTAssertEqual(thread.surface, .terminal)
        XCTAssertEqual(thread.subtitle, "Done.")
        XCTAssertEqual(thread.lastTurnEndedAt, date("2026-10-08T10:00:01.000Z"))
        XCTAssertFalse(thread.canSendLive)
        XCTAssertEqual(thread.extra["pid"], String(pid))
        XCTAssertEqual(thread.extra["transcriptPath"], home.root.appendingPathComponent("projects/-Users-me-repo/live.jsonl").path)
    }

    func testSnapshotDedupesDesktopHelperAndFindsTranscriptByGlob() async throws {
        let desktop: [String: Any] = ["entrypoint": "claude-desktop", "hostSessionId": "local_abc", "cwd": "/Users/me/elsewhere"]
        try registry("10.json", sessionId: "helper", desktop.merging(["messagingSocketPath": NSNull()]) { _, new in new })
        try registry("11.json", sessionId: "main", desktop.merging(["name": "Desktop title"]) { _, new in new })
        try transcript("main", folder: "-Users-me-some-renamed-folder", title: "Main title")

        let threads = await provider().snapshot()
        XCTAssertEqual(threads.map(\.nativeId), ["main"])
        XCTAssertEqual(threads.first?.title, "Main title")
        XCTAssertEqual(threads.first?.surface, .desktop)
        XCTAssertEqual(threads.first?.extra["hostSessionId"], "local_abc")
    }

    func testSnapshotFollowsRegistryAndTranscriptChanges() async throws {
        try registry("\(pid).json", sessionId: "s", ["status": "busy"])
        try transcript("s", title: "Working")
        let provider = provider()
        var thread = try await first(provider)
        XCTAssertEqual(thread.status, .running)

        try registry("\(pid).json", sessionId: "s", ["status": "waiting", "waitingFor": "permission prompt"])
        thread = try await first(provider)
        XCTAssertEqual(thread.status, .needsInput)
        XCTAssertEqual(thread.detail, "Needs permission")

        let url = home.root.appendingPathComponent("projects/-Users-me-repo/s.jsonl")
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: jsonl([Line.customTitle("Renamed")]))
        try handle.close()
        thread = try await first(provider)
        XCTAssertEqual(thread.title, "Renamed")
    }

    func testSessionWithoutTranscriptIsANewSession() async throws {
        try registry("\(pid).json", sessionId: "fresh")
        let thread = try await first(provider())
        XCTAssertEqual(thread.title, "New session")
        XCTAssertNil(thread.extra["transcriptPath"])
        XCTAssertNil(thread.lastTurnEndedAt)
    }

    func testMessagesReturnsTheLatestOnes() async throws {
        try registry("\(pid).json", sessionId: "chat")
        var lines: [[String: Any]] = []
        for i in 0..<30 {
            lines.append(Line.prompt("question \(i)", at: "2026-10-08T10:00:\(String(format: "%02d", i)).000Z", uuid: "u\(i)"))
            lines.append(Line.assistant([Line.thinking(), Line.text("answer \(i)")], stop: "end_turn",
                                        at: "2026-10-08T10:00:\(String(format: "%02d", i)).500Z", uuid: "a\(i)"))
        }
        try home.writeTranscript(folder: "-Users-me-repo", sessionId: "chat", lines)
        let provider = provider()
        let thread = try await first(provider)
        let messages = await provider.messages(for: thread, limit: 20)
        XCTAssertEqual(messages.count, 20)
        XCTAssertEqual(messages.first?.text, "question 20")
        XCTAssertEqual(messages.last?.text, "answer 29")
        XCTAssertEqual(messages.last?.role, .assistant)
    }

    // MARK: Send

    private func thread(status: ThreadStatus = .idle, surface: Surface = .desktop) -> AgentThread {
        AgentThread(
            platform: .claude, nativeId: "s", surface: surface, title: "Thread", status: status, cwd: "/Users/me/repo",
            updatedAt: Date(), extra: ["pid": String(pid), "hostSessionId": "local_abc", "tmux": "main:@1.%2"])
    }

    /// Plays the bridge mod: marks the session live, then takes and acks the next item.
    private func mod(_ hub: BridgeHub, ack: Bool?) -> Task<Void, Never> {
        Task {
            for _ in 0..<200 {
                if let item = await hub.serverClaudePoll(sessionId: "s") {
                    if let ack { await hub.serverClaudeAck(itemId: item.id, ok: ack, error: ack ? nil : "nope") }
                    return
                }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
    }

    func testSendDeliversThroughTheBridge() async throws {
        try registry("\(pid).json", sessionId: "s", ["status": "idle"])
        let hub = BridgeHub()
        _ = await hub.serverClaudePoll(sessionId: "s")
        let modTask = mod(hub, ack: true)
        let outcome = await provider(hub: hub).send("hello", to: thread())
        await modTask.value
        XCTAssertEqual(outcome, .delivered)
    }

    func testSendTakenButNotAckedRunsAfterTheCurrentTurn() async throws {
        try registry("\(pid).json", sessionId: "s")
        let hub = BridgeHub()
        _ = await hub.serverClaudePoll(sessionId: "s")
        let modTask = mod(hub, ack: nil)
        let outcome = await provider(hub: hub, timeout: 0.5).send("hello", to: thread())
        await modTask.value
        XCTAssertEqual(outcome, .queued("Runs after the current turn"))
    }

    func testSendNeverTakenIsCancelledAndCopied() async throws {
        try registry("\(pid).json", sessionId: "s")
        let hub = BridgeHub()
        _ = await hub.serverClaudePoll(sessionId: "s")
        let effects = Effects()
        let outcome = await provider(hub: hub, effects: effects, timeout: 0.3).send("hello", to: thread())
        XCTAssertEqual(outcome, .copiedToClipboard("Copied — paste it into the session"))
        let leftover = await hub.serverClaudePoll(sessionId: "s")
        XCTAssertNil(leftover, "the timed-out item was withdrawn")
        let copied = await effects.copied
        XCTAssertEqual(copied, ["hello"])
    }

    func testSendRejectedByTheModFallsBack() async throws {
        try registry("\(pid).json", sessionId: "s")
        let hub = BridgeHub()
        _ = await hub.serverClaudePoll(sessionId: "s")
        let effects = Effects()
        let modTask = mod(hub, ack: false)
        let outcome = await provider(hub: hub, effects: effects).send("hello", to: thread())
        await modTask.value
        XCTAssertEqual(outcome, .copiedToClipboard("Copied — paste it into the session"))
        let opened = await effects.opened
        XCTAssertEqual(opened.map(\.absoluteString), ["claude://code/continue?session=local_abc"])
    }

    func testSendWithoutBridgeCopiesAndOpens() async throws {
        let effects = Effects()
        let outcome = await provider(effects: effects).send("hello", to: thread(surface: .terminal))
        XCTAssertEqual(outcome, .copiedToClipboard("Copied — paste it into the session"))
        let (copied, focused) = (await effects.copied, await effects.focused)
        XCTAssertEqual(copied, ["hello"])
        XCTAssertEqual(focused, [[String(pid), "/Users/me/repo", "Thread", "main:@1.%2"]])
    }

    func testSlashCommandsAreCopiedEvenWithABridge() async throws {
        let hub = BridgeHub()
        _ = await hub.serverClaudePoll(sessionId: "s")
        let effects = Effects()
        let outcome = await provider(hub: hub, effects: effects).send("/compact", to: thread())
        XCTAssertEqual(outcome, .copiedToClipboard("Slash commands can't be sent from Sidekick — copied instead"))
        let leftover = await hub.serverClaudePoll(sessionId: "s")
        XCTAssertNil(leftover, "nothing was enqueued")
        let copied = await effects.copied
        XCTAssertEqual(copied, ["/compact"])
    }

    func testCanSendLiveFollowsTheBridge() async throws {
        try registry("\(pid).json", sessionId: "s")
        let hub = BridgeHub()
        let provider = provider(hub: hub)
        let before = await provider.snapshot().first?.canSendLive
        XCTAssertEqual(before, false)
        _ = await hub.serverClaudePoll(sessionId: "s")
        let after = await provider.snapshot().first?.canSendLive
        XCTAssertEqual(after, true)
    }

    // MARK: Open

    func testDeepLinks() {
        XCTAssertEqual(ClaudeProvider.deepLink(for: thread())?.absoluteString, "claude://code/continue?session=local_abc")
        XCTAssertEqual(ClaudeProvider.deepLink(for: thread(status: .needsInput))?.absoluteString,
                       "claude://code/needs-input?session=local_abc")
        XCTAssertEqual(ClaudeProvider.deepLink(for: thread(surface: .ide))?.absoluteString,
                       "vscode://anthropic.claude-code/open?session=s")
        XCTAssertNil(ClaudeProvider.deepLink(for: thread(surface: .terminal)))
    }

    func testOpenTerminalSessionUsesTerminalFocus() async {
        let effects = Effects()
        let opened = await provider(effects: effects).open(thread(surface: .terminal))
        XCTAssertTrue(opened)
        let (urls, focused) = (await effects.opened, await effects.focused)
        XCTAssertEqual(urls, [])
        XCTAssertEqual(focused, [[String(pid), "/Users/me/repo", "Thread", "main:@1.%2"]])
    }
}
