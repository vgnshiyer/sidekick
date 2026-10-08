import Foundation
import SidekickCore
import XCTest
@testable import ClaudeKit

/// Synthetic transcript lines shaped like Claude Code's JSONL.
enum Line {
    static func prompt(_ text: String, at stamp: String, uuid: String, _ extra: [String: Any] = [:]) -> [String: Any] {
        message("user", content: text, at: stamp, uuid: uuid, extra)
    }

    static func userBlocks(_ blocks: [[String: Any]], at stamp: String, uuid: String, _ extra: [String: Any] = [:]) -> [String: Any] {
        message("user", content: blocks, at: stamp, uuid: uuid, extra)
    }

    static func assistant(_ blocks: [[String: Any]], stop: String?, at stamp: String, uuid: String,
                          _ extra: [String: Any] = [:]) -> [String: Any] {
        var line = message("assistant", content: blocks, at: stamp, uuid: uuid, extra)
        var body = line["message"] as? [String: Any] ?? [:]
        body["stop_reason"] = stop ?? NSNull()
        body["model"] = extra["isApiErrorMessage"] != nil ? "<synthetic>" : "claude-test"
        line["message"] = body
        return line
    }

    static func text(_ text: String) -> [String: Any] { ["type": "text", "text": text] }
    static func thinking() -> [String: Any] { ["type": "thinking", "thinking": "hmm", "signature": "x"] }
    static func toolUse(_ id: String) -> [String: Any] { ["type": "tool_use", "id": id, "name": "Bash", "input": ["command": "ls"]] }
    static func toolResult(_ id: String) -> [String: Any] { ["type": "tool_result", "tool_use_id": id, "content": "ok"] }

    static func customTitle(_ title: String) -> [String: Any] { ["type": "custom-title", "customTitle": title, "sessionId": "s"] }
    static func aiTitle(_ title: String) -> [String: Any] { ["type": "ai-title", "aiTitle": title, "sessionId": "s"] }
    static func lastPrompt(_ text: String) -> [String: Any] { ["type": "last-prompt", "lastPrompt": text, "leafUuid": "u", "sessionId": "s"] }
    static func attachment(at stamp: String) -> [String: Any] {
        ["type": "attachment", "timestamp": stamp, "attachment": ["type": "hook_success"], "isSidechain": false, "uuid": UUID().uuidString]
    }
    static func system(_ subtype: String, at stamp: String) -> [String: Any] {
        ["type": "system", "subtype": subtype, "timestamp": stamp, "isSidechain": false, "uuid": UUID().uuidString]
    }
    static let snapshot: [String: Any] = ["type": "file-history-snapshot", "messageId": "m", "snapshot": [:], "isSnapshotUpdate": false]
    static let queued: [String: Any] = ["type": "queue-operation", "operation": "enqueue", "content": "later", "timestamp": "2026-10-08T10:00:00.000Z"]

    private static func message(_ role: String, content: Any, at stamp: String, uuid: String, _ extra: [String: Any]) -> [String: Any] {
        var line: [String: Any] = [
            "type": role, "uuid": uuid, "timestamp": stamp, "isSidechain": false, "sessionId": "s",
            "cwd": "/w", "gitBranch": "main", "message": ["role": role, "content": content],
        ]
        line.merge(extra) { _, new in new }
        return line
    }
}

func jsonl(_ lines: [[String: Any]]) -> Data {
    var data = Data()
    for line in lines {
        data.append(try! JSONSerialization.data(withJSONObject: line))
        data.append(0x0A)
    }
    return data
}

func fold(_ lines: [[String: Any]]) -> TranscriptFold {
    var fold = TranscriptFold()
    fold.consume(lines: jsonl(lines))
    return fold
}

func date(_ stamp: String) -> Date {
    Transcript.date(stamp)!
}

/// A throwaway Claude config dir: `sessions/` and `projects/` under a temp folder.
final class ClaudeHome {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("sk-claude-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("projects"), withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func writeRegistry(_ fileName: String, _ fields: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: fields)
        try data.write(to: root.appendingPathComponent("sessions/\(fileName)"))
    }

    @discardableResult
    func writeTranscript(folder: String, sessionId: String, _ lines: [[String: Any]]) throws -> URL {
        let dir = root.appendingPathComponent("projects/\(folder)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(sessionId).jsonl")
        try jsonl(lines).write(to: url)
        return url
    }
}

/// `LC_ALL=C TZ=UTC ps -o lstart= -p <pid>`, the value Claude Code stores as `procStart`.
func processStart(_ pid: Int32) async -> String {
    await Shell.run("/bin/ps", ["-o", "lstart=", "-p", "\(pid)"], env: ["LC_ALL": "C", "TZ": "UTC"])
        .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// A pid with no running process.
func deadPID() -> Int32 {
    var pid: Int32 = 99_999
    while kill(pid, 0) == 0 || errno != ESRCH { pid -= 1 }
    return pid
}
