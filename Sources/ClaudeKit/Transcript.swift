import Foundation
import SidekickCore

/// Transcript conventions: `projects/<encoded cwd>/<sessionId>.jsonl`, one JSON object per line.
enum Transcript {
    /// Claude Code's project folder name: every non-alphanumeric UTF-16 unit of the cwd becomes "-".
    static func projectDirectoryName(for cwd: String) -> String {
        let units = cwd.utf16.map { unit -> UInt16 in
            switch unit {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: return unit
            default: return 0x2D
            }
        }
        return String(decoding: units, as: UTF16.self)
    }

    /// Parses the ISO-8601 `timestamp` of a transcript line.
    static func date(_ stamp: String?) -> Date? {
        guard let stamp else { return nil }
        return (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(stamp))
            ?? (try? Date.ISO8601FormatStyle().parse(stamp))
    }

    /// How a `user` line counts towards prompts and turns.
    enum UserLine: Equatable {
        /// Typed by the user (or submitted by a plugin as the user): starts a turn and is shown in chat.
        case prompt(String)
        /// "[Request interrupted by user]": ends the turn without a reply.
        case interruption
        /// Tool results, meta lines, sidechains, compact summaries and injected notices.
        case other
    }

    /// Injected user strings that the user never typed.
    static let injectedPrefixes = ["<task-notification", "<command-name>", "<local-command-stdout>", "<bash-input>", "<ci-monitor-event"]

    static func classifyUser(_ line: [String: Any]) -> UserLine {
        let isPlugin = (line["origin"] as? [String: Any])?["kind"] as? String == "plugin"
        if line["isSidechain"] as? Bool == true || line["isCompactSummary"] as? Bool == true { return .other }
        if line["isMeta"] as? Bool == true, !isPlugin { return .other }
        let text: String
        switch (line["message"] as? [String: Any])?["content"] {
        case let string as String:
            text = string
        case let blocks as [[String: Any]]:
            if blocks.contains(where: { $0["type"] as? String == "tool_result" }) { return .other }
            text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
        default:
            return .other
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || injectedPrefixes.contains(where: trimmed.hasPrefix) { return .other }
        if trimmed.hasPrefix("[Request interrupted by user") { return .interruption }
        return .prompt(trimmed)
    }
}

/// What Sidekick needs from a stretch of transcript, folded line by line in file order.
struct TranscriptFold: Sendable {
    /// Messages kept for the chat window.
    static let messageLimit = 100

    struct Message: Sendable {
        let id: String
        let role: ChatMessage.Role
        let text: String
        let stamp: String?
    }

    private(set) var customTitle: String?
    private(set) var aiTitle: String?
    private(set) var lastPrompt: String?
    private(set) var firstPrompt: String?
    private(set) var gitBranch: String?
    /// The last assistant text block as one capped display line.
    private(set) var lastAssistantLine: String?
    /// The last turn ended in a synthetic API error message.
    private(set) var lastTurnFailed = false
    /// The main thread is between turns: its last reply ended the turn, or the user interrupted it.
    private(set) var mainTurnEnded = false
    /// Timestamp of the last `end_turn` reply after the last real prompt.
    private(set) var lastEndTurnStamp: String?
    private(set) var lastStamp: String?
    private(set) var messages: [Message] = []
    private var lineCount = 0

    /// Folds every newline-terminated line in `data`; a trailing partial line is ignored.
    mutating func consume(lines data: Data) {
        var start = data.startIndex
        while let newline = data[start...].firstIndex(of: 0x0A) {
            if newline > start { consume(line: data[start..<newline]) }
            start = newline + 1
        }
    }

    mutating func consume(line: Data) {
        lineCount += 1
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let type = object["type"] as? String else { return }
        let stamp = object["timestamp"] as? String
        if let stamp { lastStamp = stamp }
        if let branch = object["gitBranch"] as? String, !branch.isEmpty { gitBranch = branch }

        switch type {
        case "custom-title":
            customTitle = nonEmpty(object["customTitle"]) ?? customTitle
        case "ai-title":
            aiTitle = nonEmpty(object["aiTitle"]) ?? aiTitle
        case "last-prompt":
            lastPrompt = nonEmpty(object["lastPrompt"]) ?? lastPrompt
        case "user":
            consumeUser(object, stamp: stamp)
        case "assistant":
            consumeAssistant(object, stamp: stamp)
        default:
            break
        }
    }

    private mutating func consumeUser(_ object: [String: Any], stamp: String?) {
        switch Transcript.classifyUser(object) {
        case .prompt(let text):
            if firstPrompt == nil { firstPrompt = text }
            lastEndTurnStamp = nil
            lastTurnFailed = false
            mainTurnEnded = false
            append(Message(id: lineID(object), role: .user, text: text, stamp: stamp))
        case .interruption:
            mainTurnEnded = true
        case .other:
            break
        }
    }

    private mutating func consumeAssistant(_ object: [String: Any], stamp: String?) {
        guard object["isSidechain"] as? Bool != true, let message = object["message"] as? [String: Any] else { return }
        let blocks = message["content"] as? [[String: Any]] ?? []
        for (index, block) in blocks.enumerated() where block["type"] as? String == "text" {
            guard let text = (block["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
            else { continue }
            lastAssistantLine = DisplayLine.collapsed(text)
            append(Message(id: "\(lineID(object))#\(index)", role: .assistant, text: text, stamp: stamp))
        }
        let stopReason = message["stop_reason"] as? String
        lastTurnFailed = object["isApiErrorMessage"] as? Bool == true
        mainTurnEnded = lastTurnFailed || stopReason == "end_turn" || stopReason == "stop_sequence"
        if stopReason == "end_turn", !lastTurnFailed { lastEndTurnStamp = stamp }
    }

    private mutating func append(_ message: Message) {
        messages.append(message)
        if messages.count > 2 * Self.messageLimit { messages.removeFirst(messages.count - Self.messageLimit) }
    }

    private func lineID(_ object: [String: Any]) -> String {
        object["uuid"] as? String ?? "line-\(lineCount)"
    }

    private func nonEmpty(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}

/// The transcript facts behind a thread, merged from the head (read once) and the tail.
struct TranscriptSummary: Equatable, Sendable {
    var customTitle: String?
    var aiTitle: String?
    var lastPrompt: String?
    var firstPrompt: String?
    var gitBranch: String?
    var lastAssistantLine: String?
    var lastTurnFailed = false
    var mainTurnEnded = false
    var lastTurnEndedAt: Date?
    var lastActivity: Date?
}

extension TranscriptSummary {
    /// Titles and prompts prefer the tail and fall back to the head; turn state comes from the tail.
    init(head: TranscriptFold?, tail: TranscriptFold) {
        self.init(
            customTitle: tail.customTitle ?? head?.customTitle,
            aiTitle: tail.aiTitle ?? head?.aiTitle,
            lastPrompt: tail.lastPrompt ?? head?.lastPrompt,
            firstPrompt: head?.firstPrompt ?? tail.firstPrompt,
            gitBranch: tail.gitBranch ?? head?.gitBranch,
            lastAssistantLine: tail.lastAssistantLine,
            lastTurnFailed: tail.lastTurnFailed,
            mainTurnEnded: tail.mainTurnEnded,
            lastTurnEndedAt: Transcript.date(tail.lastEndTurnStamp),
            lastActivity: Transcript.date(tail.lastStamp ?? head?.lastStamp))
    }
}
