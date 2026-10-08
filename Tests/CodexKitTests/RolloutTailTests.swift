import SidekickCore
import XCTest
@testable import CodexKit

final class RolloutTailTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_791_490_000.125)
    private func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }

    private func parse(_ lines: [String], offset: Int = 0) -> RolloutTail {
        RolloutTail.parse(Data(lines.joined(separator: "\n").utf8), offset: offset)
    }

    func testExtractsUserAndAgentMessagesOnly() {
        let tail = parse([
            RolloutLine.line(["type": "session_meta", "payload": ["id": "x", "originator": "codex-tui"]], at: at(0)),
            RolloutLine.taskStarted("turn1", at: at(1)),
            RolloutLine.line(["type": "response_item", "payload": [
                "type": "message", "role": "user", "content": [["type": "input_text", "text": "duplicate"]],
            ]], at: at(1)),
            RolloutLine.user("Fix the build", id: "u1", at: at(2), image: true),
            RolloutLine.agent("Looking at it", id: "a1", phase: "commentary", at: at(3)),
            RolloutLine.event(["type": "item_completed", "item": ["type": "CommandExecution", "id": "c1"]], at: at(4)),
            RolloutLine.event(["type": "token_count", "info": NSNull()], at: at(4)),
            RolloutLine.line(["type": "token_usage_record", "payload": ["turn_id": "turn1"]], at: at(4)),
            RolloutLine.event(["type": "some_future_event", "message": "AgentMessage"], at: at(4)),
            "{not json \"event_msg\" \"AgentMessage\"",
            RolloutLine.agent("Done.\n\nAll green.", id: "a2", at: at(5)),
            RolloutLine.user("   ", at: at(6)),
            RolloutLine.event(["type": "user_message", "message": "legacy question"], at: at(7)),
            RolloutLine.event(["type": "agent_message", "message": "legacy answer"], at: at(8)),
            RolloutLine.taskComplete("turn1", at: at(9)),
        ])

        XCTAssertEqual(tail.messages.map(\.role), [.user, .assistant, .assistant, .user, .assistant])
        XCTAssertEqual(tail.messages.map(\.text), [
            "Fix the build", "Looking at it", "Done.\n\nAll green.", "legacy question", "legacy answer",
        ])
        XCTAssertEqual(Array(tail.messages.map(\.id).prefix(3)), ["u1", "a1", "a2"])
        XCTAssertTrue(tail.messages[3].id.hasPrefix("rollout-"))
        XCTAssertEqual(tail.messages[0].date?.timeIntervalSince1970 ?? 0, at(2).timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(tail.lastAssistantText, "legacy answer")
    }

    func testLifecycleIsTheLastTurnEvent() {
        let running = parse([
            RolloutLine.taskStarted("t1", at: at(0)),
            RolloutLine.taskComplete("t1", at: at(1)),
            RolloutLine.taskStarted("t2", at: at(2)),
            RolloutLine.agent("Working", at: at(3)),
        ])
        XCTAssertEqual(running.lifecycle?.event, .started)
        XCTAssertEqual(running.lifecycle?.date?.timeIntervalSince1970 ?? 0, at(2).timeIntervalSince1970, accuracy: 0.001)

        let done = parse([RolloutLine.taskStarted("t1", at: at(0)), RolloutLine.taskComplete("t1", at: at(1))])
        XCTAssertEqual(done.lifecycle, RolloutTail.Lifecycle(event: .completed, date: done.lifecycle?.date, failed: false))

        let failed = parse([RolloutLine.taskStarted("t1", at: at(0)), RolloutLine.taskComplete("t1", at: at(1), error: true)])
        XCTAssertEqual(failed.lifecycle?.event, .completed)
        XCTAssertEqual(failed.lifecycle?.failed, true)

        let interrupted = parse([RolloutLine.taskStarted("t1", at: at(0)), RolloutLine.turnAborted("t1", at: at(1))])
        XCTAssertEqual(interrupted.lifecycle?.event, .aborted)

        XCTAssertNil(parse([RolloutLine.user("hi", at: at(0))]).lifecycle)
    }

    func testTimestampsWithoutFractionalSeconds() {
        let line = #"{"timestamp":"2026-10-08T18:50:28Z","type":"event_msg","payload":{"type":"task_started","turn_id":"t"}}"#
        let tail = parse([line])
        XCTAssertEqual(tail.lifecycle?.date, Date(timeIntervalSince1970: 1_791_485_428))
    }

    func testSkipsTheCutFirstLineOfATail() {
        let lines = [RolloutLine.user("cut", at: at(0)), RolloutLine.user("kept", at: at(1))]
        XCTAssertEqual(parse(lines).messages.map(\.text), ["cut", "kept"])
        XCTAssertEqual(parse(lines, offset: 10).messages.map(\.text), ["kept"])
    }

    func testReadsOnlyTheLast256KiB() throws {
        let fx = try CodexFixture()
        let padding = RolloutLine.line(["type": "response_item", "payload": [
            "type": "function_call_output", "output": String(repeating: "x", count: RolloutTail.maxBytes),
        ]], at: at(1))
        let path = try fx.writeRollout("big", lines: [
            RolloutLine.user("too early", at: at(0)),
            padding,
            RolloutLine.taskStarted("t1", at: at(2)),
            RolloutLine.user("recent", at: at(3)),
            RolloutLine.turnAborted("t1", at: at(4)),
        ])
        let tail = try XCTUnwrap(RolloutTail.read(path: path))
        XCTAssertEqual(tail.messages.map(\.text), ["recent"])
        XCTAssertEqual(tail.lifecycle?.event, .aborted)
        XCTAssertNil(RolloutTail.read(path: fx.home.appendingPathComponent("missing.jsonl").path))
    }
}
