import Foundation
import SidekickCore
import XCTest
@testable import BridgeKit

/// Opt-in harness for scratch end-to-end runs against a live Claude Code or Codex session.
/// `SIDEKICK_E2E=1` enables it; it serves the bridge on `Paths.socketPath` (so set `SIDEKICK_HOME`)
/// for `SIDEKICK_E2E_SECONDS` (default 120) or until the file `SIDEKICK_E2E_STOP` exists, and
/// writes what reaches the hub to the JSONL file `SIDEKICK_E2E_LOG`. Sends go through
/// `POST /api/send` with `{"threadId":"claude:<sessionId>","text":…}` and follow the ClaudeKit
/// rule: enqueue, wait up to 15 s for the ack, else report queued and keep logging until it settles.
final class BridgeE2ETests: XCTestCase {
    func testServeBridgeForScratchE2E() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["SIDEKICK_E2E"] == "1", "set SIDEKICK_E2E=1 to run the scratch end-to-end harness")
        let log = E2ELog(path: env["SIDEKICK_E2E_LOG"] ?? NSTemporaryDirectory() + "sidekick-e2e.jsonl")
        let hub = BridgeHub()
        let server = BridgeServer(hub: hub, socketPath: Paths.socketPath, api: E2EAPI(hub: hub, log: log))
        try server.start()
        defer { server.stop() }
        log.write(["kind": "listening", "socket": Paths.socketPath])

        let started = Date()
        let deadline = started.addingTimeInterval(Double(env["SIDEKICK_E2E_SECONDS"] ?? "") ?? 120)
        var lastClaude: [String: BridgeHub.ClaudeEvent] = [:]
        var liveClaude: [String: Bool] = [:]
        var codexSeen: [String: Int] = [:]
        var sessions: Set<String> = []
        while Date() < deadline, !(env["SIDEKICK_E2E_STOP"].map(FileManager.default.fileExists) ?? false) {
            sessions.formUnion(claudeSessionIds())
            for session in sessions.sorted() {
                let live = await hub.isClaudeBridgeLive(sessionId: session)
                if liveClaude[session] != live {
                    liveClaude[session] = live
                    log.write(["kind": "claude.live", "session": session, "live": live])
                }
                if let event = await hub.lastClaudeEvent(sessionId: session), event != lastClaude[session] {
                    lastClaude[session] = event
                    log.write(["kind": "claude.event", "session": session, "event": event.kind])
                }
            }
            for thread in await hub.codexThreadIdsWithHooks(since: started) {
                let events = await hub.codexHookEvents(threadId: thread)
                for event in events.dropFirst(codexSeen[thread] ?? 0) {
                    log.write(["kind": "codex.hook", "thread": event.threadId, "event": event.event,
                               "tool": event.toolName ?? NSNull(), "cwd": event.cwd ?? NSNull()])
                }
                codexSeen[thread] = events.count
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        log.write(["kind": "done"])
    }

    /// Session ids from the scratch registry (`$CLAUDE_CONFIG_DIR/sessions/<pid>.json`).
    private func claudeSessionIds() -> [String] {
        let dir = Paths.claudeDir.appendingPathComponent("sessions")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { url in
            guard url.pathExtension == "json", let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return object["sessionId"] as? String
        }
    }
}

/// Appends timestamped JSON lines; `t` is milliseconds since the log was opened.
private final class E2ELog: @unchecked Sendable {
    private let handle: FileHandle?
    private let opened = Date()
    private let lock = NSLock()

    init(path: String) {
        FileManager.default.createFile(atPath: path, contents: nil)
        handle = FileHandle(forWritingAtPath: path)
    }

    func write(_ fields: [String: Any]) {
        var record = fields
        record["t"] = Int(Date().timeIntervalSince(opened) * 1000)
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
        lock.withLock { handle?.write(data + Data("\n".utf8)) }
    }
}

/// Just enough of the app API for E2E sends; threads, messages and open are not exercised.
private final class E2EAPI: SidekickAPI, @unchecked Sendable {
    let hub: BridgeHub
    let log: E2ELog

    init(hub: BridgeHub, log: E2ELog) {
        self.hub = hub
        self.log = log
    }

    func apiThreads() async -> [AgentThread] { [] }
    func apiMessages(threadId: String, limit: Int) async -> [ChatMessage] { [] }
    func apiOpen(threadId: String) async -> Bool { false }

    func apiSend(threadId: String, text: String) async -> SendOutcome {
        let session = threadId.hasPrefix("claude:") ? String(threadId.dropFirst("claude:".count)) : threadId
        guard await hub.isClaudeBridgeLive(sessionId: session) else {
            log.write(["kind": "send.nobridge", "session": session])
            return .copiedToClipboard("No live bridge")
        }
        let id = await hub.enqueueClaude(sessionId: session, text: text)
        log.write(["kind": "send.enqueued", "item": id, "session": session, "text": text])
        if let outcome = await follow(id, for: 15) { return outcome }
        guard await hub.delivery(of: id) == .taken else {
            await hub.cancelClaude(itemId: id)
            log.write(["kind": "send.cancelled", "item": id])
            return .failed("Not picked up")
        }
        log.write(["kind": "send.queued", "item": id])
        Task { _ = await self.follow(id, for: 600) }
        return .queued("Runs after the current turn")
    }

    /// Log each delivery change until the item settles or `seconds` pass; nil when it did not settle.
    private func follow(_ id: String, for seconds: TimeInterval) async -> SendOutcome? {
        let deadline = Date().addingTimeInterval(seconds)
        var last: BridgeHub.Delivery?
        while Date() < deadline {
            let delivery = await hub.delivery(of: id)
            if delivery != last {
                last = delivery
                log.write(["kind": "send.delivery", "item": id, "state": "\(delivery.map { "\($0)" } ?? "nil")"])
            }
            switch delivery {
            case .submitted: return .delivered
            case .failed(let error): return .failed(error)
            default: try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        return nil
    }
}
