import Foundation
import SidekickCore
import XCTest
@testable import ClaudeKit

final class TranscriptTests: XCTestCase {
    func testProjectDirectoryNameReplacesEveryNonAlphanumericUTF16Unit() {
        XCTAssertEqual(Transcript.projectDirectoryName(for: "/Users/x/repos/tinker"), "-Users-x-repos-tinker")
        XCTAssertEqual(Transcript.projectDirectoryName(for: "/private/tmp/claude-502/a_b.c d"), "-private-tmp-claude-502-a-b-c-d")
        XCTAssertEqual(Transcript.projectDirectoryName(for: "/café"), "-caf-")
        XCTAssertEqual(Transcript.projectDirectoryName(for: "/a🙂b"), "-a--b")
    }

    func testUserLineClassification() {
        func classify(_ line: [String: Any]) -> Transcript.UserLine { Transcript.classifyUser(line) }
        let at = "2026-10-08T10:00:00.000Z"

        XCTAssertEqual(classify(Line.prompt("  fix the bug \n", at: at, uuid: "1")), .prompt("fix the bug"))
        XCTAssertEqual(classify(Line.userBlocks([Line.text("look"), ["type": "image"], Line.text("here")], at: at, uuid: "2")),
                       .prompt("look\nhere"))
        XCTAssertEqual(classify(Line.prompt("from the pet", at: at, uuid: "3", ["origin": ["kind": "plugin", "asUser": true]])),
                       .prompt("from the pet"))
        XCTAssertEqual(classify(Line.prompt("from the pet", at: at, uuid: "4", ["isMeta": true, "origin": ["kind": "plugin"]])),
                       .prompt("from the pet"))
        XCTAssertEqual(classify(Line.userBlocks([Line.text("[Request interrupted by user for tool use]")], at: at, uuid: "5")),
                       .interruption)

        let ignored: [[String: Any]] = [
            Line.userBlocks([Line.toolResult("t1")], at: at, uuid: "6"),
            Line.prompt("<system-reminder>x</system-reminder>", at: at, uuid: "7", ["isMeta": true]),
            Line.prompt("subagent prompt", at: at, uuid: "8", ["isSidechain": true]),
            Line.prompt("This session is being continued…", at: at, uuid: "9", ["isCompactSummary": true]),
            Line.prompt("<task-notification><task-id>b1</task-id></task-notification>", at: at, uuid: "10",
                        ["origin": ["kind": "task-notification"]]),
            Line.prompt("<command-name>/model</command-name>", at: at, uuid: "11"),
            Line.prompt("<local-command-stdout>Set model</local-command-stdout>", at: at, uuid: "12"),
            Line.prompt("<bash-input>ls</bash-input>", at: at, uuid: "13", ["origin": ["kind": "human"]]),
            Line.prompt("   ", at: at, uuid: "14"),
            ["type": "user", "uuid": "15", "message": ["role": "user"]],
        ]
        for line in ignored {
            XCTAssertEqual(classify(line), .other, "\(line["uuid"] ?? "")")
        }
    }

    /// A transcript with every line type that matters, in the order Claude Code writes them.
    private let session: [[String: Any]] = [
        ["type": "mode", "mode": "default", "sessionId": "s"],
        Line.snapshot,
        Line.prompt("Fix the login bug\nwith details", at: "2026-10-08T10:00:00.000Z", uuid: "u1", ["origin": ["kind": "human"]]),
        Line.attachment(at: "2026-10-08T10:00:00.100Z"),
        Line.assistant([Line.thinking(), Line.text("Let me look."), Line.toolUse("t1")], stop: "tool_use",
                       at: "2026-10-08T10:00:01.000Z", uuid: "a1"),
        Line.lastPrompt("Fix the login bug"),
        Line.userBlocks([Line.toolResult("t1")], at: "2026-10-08T10:00:02.000Z", uuid: "u2"),
        Line.assistant([Line.text("Fixed it.")], stop: "end_turn", at: "2026-10-08T10:00:03.000Z", uuid: "a2"),
        Line.system("stop_hook_summary", at: "2026-10-08T10:00:03.100Z"),
        Line.aiTitle("Login bug fix"),
        Line.queued,
        Line.prompt("<task-notification>done</task-notification>", at: "2026-10-08T10:05:00.000Z", uuid: "u3",
                    ["origin": ["kind": "task-notification"]]),
        Line.assistant([Line.text("The background build passed.")], stop: "end_turn", at: "2026-10-08T10:05:01.000Z", uuid: "a3"),
        Line.assistant([Line.text("side work")], stop: "end_turn", at: "2026-10-08T10:05:02.000Z", uuid: "a4", ["isSidechain": true]),
        Line.customTitle("Login fix"),
        ["type": "agent-name", "agentName": "Login fix", "sessionId": "s"],
    ]

    func testFoldCollectsTitlesPromptsAndTurnEnd() {
        let summary = TranscriptSummary(head: nil, tail: fold(session))
        XCTAssertEqual(summary.customTitle, "Login fix")
        XCTAssertEqual(summary.aiTitle, "Login bug fix")
        XCTAssertEqual(summary.lastPrompt, "Fix the login bug")
        XCTAssertEqual(summary.firstPrompt, "Fix the login bug\nwith details")
        XCTAssertEqual(summary.gitBranch, "main")
        XCTAssertEqual(summary.lastAssistantLine, "The background build passed.")
        XCTAssertEqual(summary.lastTurnEndedAt, date("2026-10-08T10:05:01.000Z"), "a task notification is not a real prompt")
        XCTAssertTrue(summary.mainTurnEnded)
        XCTAssertFalse(summary.lastTurnFailed)
        XCTAssertEqual(summary.lastActivity, date("2026-10-08T10:05:02.000Z"))
    }

    func testFoldKeepsUserPromptsAndAssistantTextOnly() {
        let messages = fold(session).messages
        XCTAssertEqual(messages.map(\.role), [.user, .assistant, .assistant, .assistant])
        XCTAssertEqual(messages.map(\.text), ["Fix the login bug\nwith details", "Let me look.", "Fixed it.", "The background build passed."])
        XCTAssertEqual(messages.map(\.id), ["u1", "a1#1", "a2#0", "a3#0"])
    }

    func testNewPromptClearsTurnEnd() {
        let summary = TranscriptSummary(head: nil, tail: fold(session + [
            Line.prompt("Now add a test", at: "2026-10-08T11:00:00.000Z", uuid: "u9"),
            Line.assistant([Line.toolUse("t9")], stop: "tool_use", at: "2026-10-08T11:00:01.000Z", uuid: "a9"),
        ]))
        XCTAssertNil(summary.lastTurnEndedAt)
        XCTAssertFalse(summary.mainTurnEnded)
    }

    func testInterruptedTurnEndsWithoutTurnEnd() {
        let summary = TranscriptSummary(head: nil, tail: fold([
            Line.prompt("Refactor everything", at: "2026-10-08T10:00:00.000Z", uuid: "u1"),
            Line.assistant([Line.toolUse("t1")], stop: "tool_use", at: "2026-10-08T10:00:01.000Z", uuid: "a1"),
            Line.userBlocks([Line.text("[Request interrupted by user for tool use]")], at: "2026-10-08T10:00:02.000Z", uuid: "u2"),
        ]))
        XCTAssertNil(summary.lastTurnEndedAt)
        XCTAssertTrue(summary.mainTurnEnded)
        XCTAssertNil(summary.lastPrompt)
        XCTAssertEqual(summary.firstPrompt, "Refactor everything")
    }

    func testSyntheticAPIErrorFailsTheTurnUntilTheNextPrompt() {
        let errored = [
            Line.prompt("Hello", at: "2026-10-08T10:00:00.000Z", uuid: "u1"),
            Line.assistant([Line.text("API Error: 529 overloaded")], stop: "stop_sequence", at: "2026-10-08T10:00:05.000Z",
                           uuid: "a1", ["isApiErrorMessage": true]),
        ]
        let failed = TranscriptSummary(head: nil, tail: fold(errored))
        XCTAssertTrue(failed.lastTurnFailed)
        XCTAssertTrue(failed.mainTurnEnded)
        XCTAssertNil(failed.lastTurnEndedAt)
        XCTAssertEqual(failed.lastAssistantLine, "API Error: 529 overloaded")

        let retried = TranscriptSummary(head: nil, tail: fold(errored + [
            Line.prompt("Try again", at: "2026-10-08T10:01:00.000Z", uuid: "u2"),
            Line.assistant([Line.text("Hi!")], stop: "end_turn", at: "2026-10-08T10:01:02.000Z", uuid: "a2"),
        ]))
        XCTAssertFalse(retried.lastTurnFailed)
        XCTAssertEqual(retried.lastTurnEndedAt, date("2026-10-08T10:01:02.000Z"))
    }

    func testDisplayLinesAreOneLineAndCapped() {
        let summary = TranscriptSummary(head: nil, tail: fold([
            Line.prompt("Go", at: "2026-10-08T10:00:00.000Z", uuid: "u1"),
            Line.assistant([Line.text("Done.\n\n  All   tests pass.")], stop: "end_turn", at: "2026-10-08T10:00:01.000Z", uuid: "a1"),
        ]))
        XCTAssertEqual(summary.lastAssistantLine, "Done. All tests pass.")

        let long = String(repeating: "word ", count: 2_000)
        let line = DisplayLine.collapsed(long)
        XCTAssertEqual(line?.count, DisplayLine.limit)
        XCTAssertEqual(line?.hasSuffix("…"), true)
        XCTAssertEqual(DisplayLine.collapsed("short " + String(repeating: " ", count: 500) + "more"), "short…",
                       "text past the examined prefix is marked")
        XCTAssertEqual(DisplayLine.first("\n  First line  \nsecond"), "First line")
        XCTAssertEqual(DisplayLine.first(String(repeating: "t", count: 5_000))?.count, DisplayLine.limit)
        XCTAssertNil(DisplayLine.first(" \n\t\n"))
    }

    func testFoldIgnoresCorruptAndPartialLines() {
        var data = jsonl([Line.prompt("one", at: "2026-10-08T10:00:00.000Z", uuid: "u1")])
        data.append(Data("{not json\n".utf8))
        data.append(Data(#"{"type":"user","message":{"content":"half"#.utf8))
        var fold = TranscriptFold()
        fold.consume(lines: data)
        XCTAssertEqual(fold.messages.map(\.text), ["one"])
    }

    func testTranscriptFileReadsOnlyAppendedCompleteLines() throws {
        let home = try ClaudeHome()
        let url = try home.writeTranscript(folder: "-w", sessionId: "s1", [
            Line.prompt("first", at: "2026-10-08T10:00:00.000Z", uuid: "u1"),
            Line.assistant([Line.text("one")], stop: "end_turn", at: "2026-10-08T10:00:01.000Z", uuid: "a1"),
        ])
        var file = TranscriptFile(url: url)
        XCTAssertTrue(file.refresh())
        XCTAssertEqual(file.messages(limit: 20).map(\.text), ["first", "one"])

        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: jsonl([Line.prompt("second", at: "2026-10-08T10:01:00.000Z", uuid: "u2")]))
        try handle.write(contentsOf: Data(#"{"type":"assistant","uuid":"a2","message":{"content":[{"type":"text","#.utf8))
        XCTAssertTrue(file.refresh())
        XCTAssertEqual(file.messages(limit: 20).map(\.text), ["first", "one", "second"])
        XCTAssertNil(file.summary.lastTurnEndedAt)

        try handle.write(contentsOf: Data(#""text":"two"}],"stop_reason":"end_turn"},"timestamp":"2026-10-08T10:01:01.000Z"}"#.utf8 + [0x0A]))
        try handle.close()
        XCTAssertTrue(file.refresh())
        XCTAssertEqual(file.messages(limit: 2).map(\.text), ["second", "two"])
        XCTAssertEqual(file.summary.lastTurnEndedAt, date("2026-10-08T10:01:01.000Z"))
        XCTAssertEqual(file.messages(limit: 1).first?.date, date("2026-10-08T10:01:01.000Z"))
    }

    func testLargeTranscriptReadsHeadOnceAndTailWindow() throws {
        let home = try ClaudeHome()
        let filler = String(repeating: "x", count: 2_000)
        var lines: [[String: Any]] = [
            Line.customTitle("Head title"),
            Line.prompt("The very first prompt", at: "2026-10-08T09:00:00.000Z", uuid: "u0"),
        ]
        for i in 0..<300 {
            lines.append(Line.assistant([Line.text("old \(i) \(filler)")], stop: "end_turn", at: "2026-10-08T09:30:00.000Z", uuid: "o\(i)"))
        }
        lines.append(Line.prompt("Latest prompt", at: "2026-10-08T10:00:00.000Z", uuid: "u1"))
        lines.append(Line.assistant([Line.text("Latest answer")], stop: "end_turn", at: "2026-10-08T10:00:01.000Z", uuid: "a1"))
        let url = try home.writeTranscript(folder: "-w", sessionId: "big", lines)
        XCTAssertGreaterThan(try XCTUnwrap(FileStamp(url)).size, TranscriptFile.tailBytes)

        var file = TranscriptFile(url: url)
        XCTAssertTrue(file.refresh())
        let summary = file.summary
        XCTAssertEqual(summary.customTitle, "Head title", "titles fall back to the head")
        XCTAssertEqual(summary.firstPrompt, "The very first prompt")
        XCTAssertEqual(summary.lastAssistantLine, "Latest answer")
        XCTAssertEqual(summary.lastTurnEndedAt, date("2026-10-08T10:00:01.000Z"))
        let messages = file.messages(limit: 500)
        XCTAssertLessThan(messages.count, 300, "only the tail window is folded")
        XCTAssertFalse(messages.contains { $0.text == "The very first prompt" })
        XCTAssertEqual(messages.last?.text, "Latest answer")
    }

    func testOversizedAppendKeepsWhatTheTailKnew() throws {
        let home = try ClaudeHome()
        let url = try home.writeTranscript(folder: "-w", sessionId: "s1", [
            Line.prompt("Run the build", at: "2026-10-08T10:00:00.000Z", uuid: "u1"),
            Line.aiTitle("Build run"),
            Line.assistant([Line.text("Running it.")], stop: "tool_use", at: "2026-10-08T10:00:01.000Z", uuid: "a1"),
        ])
        var file = TranscriptFile(url: url)
        XCTAssertTrue(file.refresh())

        // One tool result bigger than the whole tail window.
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: jsonl([Line.userBlocks(
            [["type": "tool_result", "tool_use_id": "t1", "content": String(repeating: "y", count: 300_000)]],
            at: "2026-10-08T10:00:02.000Z", uuid: "u2")]))
        try handle.close()
        XCTAssertTrue(file.refresh())

        XCTAssertEqual(file.messages(limit: 20).map(\.text), ["Run the build", "Running it."])
        XCTAssertEqual(file.summary.aiTitle, "Build run")
        XCTAssertEqual(file.summary.lastAssistantLine, "Running it.")
    }
}
