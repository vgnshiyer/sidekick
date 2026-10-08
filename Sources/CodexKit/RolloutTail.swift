import Foundation
import SidekickCore

/// What Sidekick reads from the end of a rollout JSONL file: the last turn lifecycle event
/// and the user/agent messages. Unknown line and event types are ignored.
struct RolloutTail: Equatable, Sendable {
    enum TurnEvent: Equatable, Sendable {
        case started
        case completed
        case aborted
    }

    /// The last `task_started`, `task_complete` or `turn_aborted` event.
    struct Lifecycle: Equatable, Sendable {
        var event: TurnEvent
        var date: Date?
        /// `task_complete` carried an `error`.
        var failed: Bool
    }

    var lifecycle: Lifecycle?
    var messages: [ChatMessage] = [] {
        didSet { lastAssistantLine = lastAssistantText.flatMap { oneLine($0) } }
    }
    /// The last agent message as one capped display line, kept so polls don't redo it.
    private(set) var lastAssistantLine: String?

    static let maxBytes = 256 * 1024

    var lastAssistantText: String? {
        messages.last { $0.role == .assistant }?.text
    }

    /// Reads and parses the last 256 KiB of the file at `path`.
    static func read(path: String) -> RolloutTail? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let offset = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.readToEnd() else { return RolloutTail() }
        return parse(data, offset: Int(offset))
    }

    /// Parses JSONL that starts at byte `offset` of the file. When `offset` > 0 the first
    /// line is assumed to be cut and is skipped.
    static func parse(_ data: Data, offset: Int = 0) -> RolloutTail {
        var tail = RolloutTail()
        var lines = data.split(separator: newline, omittingEmptySubsequences: false)[...]
        if offset > 0 { lines = lines.dropFirst() }
        for line in lines where line.containsBytes(eventMarker) && markers.contains(where: { line.containsBytes($0) }) {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  object["type"] as? String == "event_msg",
                  let payload = object["payload"] as? [String: Any] else { continue }
            let date = timestamp(object["timestamp"] as? String)
            let fallbackId = "rollout-\(offset + line.startIndex - data.startIndex)"

            switch payload["type"] as? String {
            case "task_started":
                tail.lifecycle = Lifecycle(event: .started, date: date, failed: false)
            case "task_complete":
                let failed = payload["error"].map { !($0 is NSNull) } ?? false
                tail.lifecycle = Lifecycle(event: .completed, date: date, failed: failed)
            case "turn_aborted":
                tail.lifecycle = Lifecycle(event: .aborted, date: date, failed: false)
            case "item_completed":
                guard let item = payload["item"] as? [String: Any] else { continue }
                let role: ChatMessage.Role
                switch item["type"] as? String {
                case "UserMessage": role = .user
                case "AgentMessage": role = .assistant
                default: continue
                }
                let blocks = item["content"] as? [[String: Any]] ?? []
                let text = blocks
                    .filter { ($0["type"] as? String)?.lowercased().hasSuffix("text") == true }
                    .compactMap { $0["text"] as? String }
                    .joined(separator: "\n")
                tail.append(id: item["id"] as? String ?? fallbackId, role: role, text: text, date: date)
            case "user_message":
                tail.append(id: fallbackId, role: .user, text: payload["message"] as? String ?? "", date: date)
            case "agent_message":
                tail.append(id: fallbackId, role: .assistant, text: payload["message"] as? String ?? "", date: date)
            default:
                continue
            }
        }
        return tail
    }

    private mutating func append(id: String, role: ChatMessage.Role, text: String, date: Date?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        messages.append(ChatMessage(id: id, role: role, text: trimmed, date: date))
    }

    private static let newline = UInt8(ascii: "\n")
    private static let eventMarker = Data(#""event_msg""#.utf8)
    /// Cheap pre-filter so only lines that can matter get JSON-decoded.
    private static let markers = [
        "task_started", "task_complete", "turn_aborted", "UserMessage", "AgentMessage", "user_message", "agent_message",
    ].map { Data("\"\($0)\"".utf8) }

    private static let fractionalISO = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    private static func timestamp(_ s: String?) -> Date? {
        guard let s else { return nil }
        return (try? fractionalISO.parse(s)) ?? (try? Date.ISO8601FormatStyle().parse(s))
    }
}

private extension Data {
    func containsBytes(_ needle: Data) -> Bool {
        guard !isEmpty, !needle.isEmpty else { return false }
        return withUnsafeBytes { hay in
            needle.withUnsafeBytes { n in
                memmem(hay.baseAddress, hay.count, n.baseAddress, n.count) != nil
            }
        }
    }
}
