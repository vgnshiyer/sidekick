import SidekickCore
import XCTest
@testable import CodexKit

final class CodexStatusTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_791_490_000)
    private func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }

    private func hook(_ event: String, tool: String? = nil, at seconds: Double) -> BridgeHub.CodexHookEvent {
        BridgeHub.CodexHookEvent(event: event, threadId: "t", toolName: tool, cwd: nil, date: at(seconds))
    }

    private func lifecycle(_ event: RolloutTail.TurnEvent, at seconds: Double, failed: Bool = false) -> RolloutTail.Lifecycle {
        RolloutTail.Lifecycle(event: event, date: at(seconds), failed: failed)
    }

    func testSurfaceClassification() {
        XCTAssertEqual(CodexStatus.surface(originator: "Codex Desktop", source: "vscode"), .desktop)
        XCTAssertEqual(CodexStatus.surface(originator: "codex-tui", source: "vscode"), .terminal)
        XCTAssertEqual(CodexStatus.surface(originator: nil, source: "cli"), .terminal)
        XCTAssertEqual(CodexStatus.surface(originator: "codex_cli_rs", source: "cli"), .terminal)
        XCTAssertEqual(CodexStatus.surface(originator: "Cursor", source: "vscode"), .ide)
        XCTAssertEqual(CodexStatus.surface(originator: "VS Code", source: "vscode"), .ide)
        XCTAssertEqual(CodexStatus.surface(originator: "codex_vscode", source: "vscode"), .ide)
        XCTAssertEqual(CodexStatus.surface(originator: "Windsurf", source: "vscode"), .ide)
        XCTAssertEqual(CodexStatus.surface(originator: nil, source: "vscode"), .unknown)
    }

    func testPendingApproval() {
        let request = hook("PermissionRequest", tool: "Bash", at: 10)
        XCTAssertEqual(CodexStatus.pendingApproval([hook("UserPromptSubmit", at: 1), request], turnChangedAt: at(0)), request)
        XCTAssertNil(CodexStatus.pendingApproval([hook("Stop", at: 1)], turnChangedAt: nil))
        XCTAssertNil(CodexStatus.pendingApproval([], turnChangedAt: nil))

        for clearing in ["PostToolUse", "Stop", "UserPromptSubmit"] {
            XCTAssertNil(CodexStatus.pendingApproval([request, hook(clearing, at: 11)], turnChangedAt: nil), clearing)
        }
        // Another tool starting doesn't answer the open request.
        XCTAssertEqual(CodexStatus.pendingApproval([request, hook("PreToolUse", at: 11)], turnChangedAt: nil), request)
        // A later request replaces an answered one.
        let second = hook("PermissionRequest", tool: "apply_patch", at: 20)
        XCTAssertEqual(CodexStatus.pendingApproval([request, hook("PostToolUse", at: 11), second], turnChangedAt: nil), second)
        // A turn starting or ending after the request clears it.
        XCTAssertNil(CodexStatus.pendingApproval([request], turnChangedAt: at(12)))
    }

    func testStatusPrecedence() {
        let pending = hook("PermissionRequest", tool: "Bash", at: 10)
        func resolve(
            _ pending: BridgeHub.CodexHookEvent? = nil, _ lifecycle: RolloutTail.Lifecycle? = nil,
            inProgress: Bool = false, unread: Bool = false
        ) -> ThreadStatus {
            CodexStatus.resolve(pending: pending, lifecycle: lifecycle, inProgress: inProgress, unread: unread).0
        }

        XCTAssertEqual(resolve(pending, lifecycle(.started, at: 1), inProgress: true, unread: true), .needsInput)
        XCTAssertEqual(resolve(nil, lifecycle(.started, at: 1), unread: true), .running)
        XCTAssertEqual(resolve(nil, lifecycle(.completed, at: 1, failed: true), unread: true), .failed)
        XCTAssertEqual(resolve(nil, lifecycle(.completed, at: 1), unread: true), .ready)
        XCTAssertEqual(resolve(nil, lifecycle(.completed, at: 1)), .idle)
        XCTAssertEqual(resolve(nil, lifecycle(.aborted, at: 1)), .idle)
        // thread_turns `inProgress` only stands in when the rollout tail has no lifecycle event.
        XCTAssertEqual(resolve(nil, nil, inProgress: true), .running)
        XCTAssertEqual(resolve(nil, lifecycle(.completed, at: 1), inProgress: true), .idle)
        XCTAssertEqual(resolve(nil, nil, unread: true), .ready)
    }

    func testNeedsInputDetail() {
        let bash = CodexStatus.resolve(pending: hook("PermissionRequest", tool: "Bash", at: 1), lifecycle: nil, inProgress: false, unread: false)
        XCTAssertEqual(bash.0, .needsInput)
        XCTAssertEqual(bash.1, "Needs approval: Bash")
        let unnamed = CodexStatus.resolve(pending: hook("PermissionRequest", at: 1), lifecycle: nil, inProgress: false, unread: false)
        XCTAssertEqual(unnamed.1, "Waiting for you")
        XCTAssertNil(CodexStatus.resolve(pending: nil, lifecycle: lifecycle(.started, at: 1), inProgress: false, unread: false).1)
    }

    func testThreadBuilding() {
        let row = CodexThreadRow(
            id: "01a11d34-3367-7d61-8a6a-68dc1d91d5f8", rolloutPath: "/r.jsonl", updatedAt: at(0), source: "cli",
            originator: "codex-tui", cwd: "/tmp/p", branch: "main", title: "Fix build")
        var tail = RolloutTail(lifecycle: lifecycle(.completed, at: 30))
        tail.messages = [
            ChatMessage(id: "1", role: .user, text: "go", date: nil),
            ChatMessage(id: "2", role: .assistant, text: "All done.\nTests pass.", date: nil),
        ]
        let thread = CodexStatus.thread(
            row: row, tail: tail, hookEvents: [hook("PermissionRequest", tool: "Bash", at: 10)],
            inProgress: false, unread: false, canSend: true)

        XCTAssertEqual(thread.id, "codex:01a11d34-3367-7d61-8a6a-68dc1d91d5f8")
        XCTAssertEqual(thread.platform, .codex)
        XCTAssertEqual(thread.surface, .terminal)
        XCTAssertEqual(thread.title, "Fix build")
        XCTAssertEqual(thread.status, .idle, "the turn ended after the permission request")
        XCTAssertNil(thread.detail)
        XCTAssertEqual(thread.subtitle, "All done. Tests pass.")
        XCTAssertEqual(thread.lastTurnEndedAt, at(30))
        XCTAssertEqual(thread.cwd, "/tmp/p")
        XCTAssertEqual(thread.branch, "main")
        XCTAssertEqual(thread.updatedAt, at(0))
        XCTAssertTrue(thread.canSendLive)
        XCTAssertEqual(thread.extra, ["rolloutPath": "/r.jsonl", "originator": "codex-tui", "source": "cli"])

        tail.lifecycle = lifecycle(.aborted, at: 30)
        let interrupted = CodexStatus.thread(row: row, tail: tail, hookEvents: [], inProgress: false, unread: true, canSend: false)
        XCTAssertEqual(interrupted.status, .ready)
        XCTAssertNil(interrupted.lastTurnEndedAt)

        let bare = CodexStatus.thread(row: row, tail: nil, hookEvents: [], inProgress: true, unread: false, canSend: false)
        XCTAssertEqual(bare.status, .running)
        XCTAssertNil(bare.subtitle)
    }

    func testUnreadThreadIds() throws {
        let json = """
            {"other": 1, "electron-thread-read-state-v1": {"version": 1, "unreadByIdentity": {
              "id1": {"local:abc": ["a", "b"], "durable:def": ["c"], "remote:x": ["nope"]},
              "id2": {"local:zzz": ["d"]}}}}
            """
        XCTAssertEqual(CodexStatus.unreadThreadIds(globalState: Data(json.utf8)), ["a", "b", "c", "d"])
        XCTAssertEqual(CodexStatus.unreadThreadIds(globalState: Data(#"{"x": 1}"#.utf8)), [])
        XCTAssertNil(CodexStatus.unreadThreadIds(globalState: Data("{truncated".utf8)))
    }
}
