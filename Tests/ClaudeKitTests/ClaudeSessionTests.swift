import Foundation
import SidekickCore
import XCTest
@testable import ClaudeKit

final class ClaudeSessionTests: XCTestCase {
    private func record(
        pid: Int32 = 100, sessionId: String = "s1", entrypoint: String = "cli", status: String? = "idle",
        waitingFor: String? = nil, name: String? = nil, nameSource: String? = nil, hostSessionId: String? = nil,
        socket: String? = nil, startedAt: Double? = 1_000
    ) -> SessionRecord {
        SessionRecord(
            pid: pid, sessionId: sessionId, cwd: "/w", procStart: "Thu Oct  8 03:45:45 2026", kind: "interactive",
            entrypoint: entrypoint, hostSessionId: hostSessionId, tmux: nil, messagingSocketPath: socket, name: name,
            nameSource: nameSource, status: status, waitingFor: waitingFor, startedAt: startedAt, statusUpdatedAt: startedAt)
    }

    private func session(_ record: SessionRecord, _ summary: TranscriptSummary? = TranscriptSummary(), transcript: Bool = true) -> ClaudeSession {
        ClaudeSession(record: record, transcriptURL: transcript ? URL(fileURLWithPath: "/t/\(record.sessionId).jsonl") : nil, summary: summary)
    }

    private func status(_ record: SessionRecord, _ summary: TranscriptSummary = TranscriptSummary()) -> [String?] {
        let (status, detail) = session(record, summary).status
        return [status.rawValue, detail]
    }

    func testStatusMapping() {
        let ended = TranscriptSummary(mainTurnEnded: true)
        XCTAssertEqual(status(record(status: "waiting", waitingFor: "permission prompt")), ["needsInput", "Needs permission"])
        XCTAssertEqual(status(record(status: "waiting", waitingFor: "input needed")), ["needsInput", "Waiting for you"])
        XCTAssertEqual(status(record(status: "waiting", waitingFor: "goal proposal")), ["needsInput", "Waiting for you"])
        XCTAssertEqual(status(record(status: "busy")), ["running", nil])
        XCTAssertEqual(status(record(status: "busy"), ended), ["running", nil], "a terminal session is busy only mid-turn")
        XCTAssertEqual(status(record(entrypoint: "claude-desktop", status: "busy")), ["running", nil])
        XCTAssertEqual(status(record(entrypoint: "claude-desktop", status: "busy"), ended), ["running", "Background work running"])
        XCTAssertEqual(status(record(status: "shell"), ended), ["running", "Background task running"])
        XCTAssertEqual(status(record(status: "idle"), ended), ["idle", nil])
        XCTAssertEqual(status(record(status: "idle"), TranscriptSummary(lastTurnFailed: true)), ["failed", nil])
        XCTAssertEqual(status(record(status: nil)), ["idle", nil])
    }

    func testTitlePrecedence() {
        let all = TranscriptSummary(customTitle: "Custom", aiTitle: "AI", lastPrompt: "Last prompt", firstPrompt: "First prompt")
        let named = record(name: "Renamed", nameSource: "user")
        let derived = record(name: "work-5f", nameSource: "derived")
        let desktop = record(entrypoint: "claude-desktop", name: "Desktop title")

        XCTAssertEqual(session(named, all).title, "Custom")
        XCTAssertEqual(session(named, TranscriptSummary(aiTitle: "AI", lastPrompt: "Last prompt")).title, "AI")
        XCTAssertEqual(session(named, TranscriptSummary(lastPrompt: "Last prompt")).title, "Renamed")
        XCTAssertEqual(session(desktop, TranscriptSummary(lastPrompt: "Last prompt")).title, "Desktop title")
        XCTAssertEqual(session(derived, TranscriptSummary(lastPrompt: "Last prompt", firstPrompt: "First")).title, "Last prompt")
        XCTAssertEqual(session(derived, TranscriptSummary(firstPrompt: "\n  First line  \nsecond")).title, "First line")
        XCTAssertEqual(session(derived, nil, transcript: false).title, "New session")
        XCTAssertEqual(session(derived, TranscriptSummary(customTitle: "   ")).title, "New session")
    }

    func testThreadCarriesRoutingDataAndRawStatus() {
        var r = record(pid: 42, sessionId: "abc", entrypoint: "claude-desktop", hostSessionId: "local_1")
        r.tmux = "main:@1.%2"
        let summary = TranscriptSummary(
            gitBranch: "feature", lastAssistantLine: "Done. All tests pass.", lastTurnEndedAt: date("2026-10-08T10:00:01.000Z"),
            lastActivity: date("2026-10-08T10:00:02.000Z"))
        let thread = session(r, summary).thread(canSendLive: true)

        XCTAssertEqual(thread.id, "claude:abc")
        XCTAssertEqual(thread.surface, .desktop)
        XCTAssertEqual(thread.status, .idle, "providers report idle; the store derives ready")
        XCTAssertEqual(thread.subtitle, "Done. All tests pass.")
        XCTAssertEqual(thread.branch, "feature")
        XCTAssertEqual(thread.cwd, "/w")
        XCTAssertEqual(thread.lastTurnEndedAt, date("2026-10-08T10:00:01.000Z"))
        XCTAssertEqual(thread.updatedAt, date("2026-10-08T10:00:02.000Z"))
        XCTAssertTrue(thread.canSendLive)
        XCTAssertEqual(thread.extra, [
            "pid": "42", "entrypoint": "claude-desktop", "hostSessionId": "local_1",
            "transcriptPath": "/t/abc.jsonl", "tmux": "main:@1.%2",
        ])
    }

    func testSurfaceFromEntrypoint() {
        XCTAssertEqual(record(entrypoint: "cli").surface, .terminal)
        XCTAssertEqual(record(entrypoint: "sdk-cli").surface, .terminal)
        XCTAssertEqual(record(entrypoint: "claude-desktop").surface, .desktop)
        XCTAssertEqual(record(entrypoint: "claude-desktop-3p").surface, .desktop)
        XCTAssertEqual(record(entrypoint: "claude-vscode").surface, .ide)
    }

    func testDedupeKeepsDesktopMainOverSideForkHelper() {
        let helper = session(record(pid: 2, sessionId: "fork", entrypoint: "claude-desktop", hostSessionId: "local_1", startedAt: 500),
                             nil, transcript: false)
        let main = session(record(pid: 1, sessionId: "main", entrypoint: "claude-desktop", hostSessionId: "local_1",
                                  socket: "/tmp/cc-socks/1.sock", startedAt: 900))
        let other = session(record(pid: 3, sessionId: "cli-a"))
        let another = session(record(pid: 4, sessionId: "cli-b"))
        let kept = ClaudeSession.dedupe([helper, other, main, another]).map(\.record.sessionId)
        XCTAssertEqual(kept, ["cli-a", "main", "cli-b"])
    }

    func testDedupePrefersSocketThenOldestAndCollapsesRepeatedSessionIds() {
        let newer = session(record(pid: 5, sessionId: "x", hostSessionId: "local_2", startedAt: 2_000))
        let older = session(record(pid: 6, sessionId: "y", hostSessionId: "local_2", startedAt: 1_000))
        XCTAssertEqual(ClaudeSession.dedupe([newer, older]).map(\.record.pid), [6])

        let withSocket = session(record(pid: 7, sessionId: "z", hostSessionId: "local_3", socket: "/s", startedAt: 3_000))
        let withoutSocket = session(record(pid: 8, sessionId: "w", hostSessionId: "local_3", startedAt: 1_000))
        XCTAssertEqual(ClaudeSession.dedupe([withoutSocket, withSocket]).map(\.record.pid), [7])

        let first = session(record(pid: 9, sessionId: "same", startedAt: 1_000))
        let second = session(record(pid: 10, sessionId: "same", startedAt: 2_000))
        XCTAssertEqual(ClaudeSession.dedupe([second, first]).map(\.record.pid), [9])
    }

    func testRegistryFileNames() {
        XCTAssertTrue(SessionRecord.isRegistryFileName("44691.json"))
        XCTAssertFalse(SessionRecord.isRegistryFileName("44691.dfab.key"))
        XCTAssertFalse(SessionRecord.isRegistryFileName("foo.json"))
        XCTAssertFalse(SessionRecord.isRegistryFileName("44691.json.tmp"))
    }

    func testParseProcessStarts() {
        let output = " 4469 Thu Oct  8 03:45:45 2026    \n68834 Thu Oct  8 17:53:57 2026\n  bogus\n"
        XCTAssertEqual(SessionIndex.parseProcessStarts(output), [
            4469: "Thu Oct  8 03:45:45 2026",
            68834: "Thu Oct  8 17:53:57 2026",
        ])
    }
}
