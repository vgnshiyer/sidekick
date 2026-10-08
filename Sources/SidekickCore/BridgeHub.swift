import Foundation

/// Shared in-memory state between the bridge server (writer) and the providers (readers).
/// BridgeKit's server calls the `server*` methods; ClaudeKit/CodexKit call the rest.
public actor BridgeHub {
    public static let shared = BridgeHub()

    public init() {}

    // MARK: Claude bridge mod

    public struct OutboxItem: Codable, Sendable, Equatable {
        public let id: String
        public let text: String
        public let createdAt: Date

        public init(id: String, text: String, createdAt: Date) {
            self.id = id
            self.text = text
            self.createdAt = createdAt
        }
    }

    public enum Delivery: Sendable, Equatable {
        /// Queued; no mod has taken it yet.
        case pending
        /// The mod called `$.prompt.submit`; the prompt waits for its own turn
        /// (it runs after the current turn or permission dialog).
        case taken
        /// The prompt's turn started.
        case submitted
        case failed(String)
    }

    public struct ClaudeEvent: Sendable, Equatable {
        public let kind: String
        public let date: Date
    }

    /// How long a delivery state is kept; senders stop waiting long before this.
    static let deliveryRetention: TimeInterval = 60
    /// How long per-session and per-thread records are kept after their last event.
    static let eventRetention: TimeInterval = 24 * 3600

    private var outbox: [String: [OutboxItem]] = [:]
    private var deliveries: [String: (state: Delivery, createdAt: Date)] = [:]
    private var lastPoll: [String: Date] = [:]
    private var lastClaudeEvents: [String: ClaudeEvent] = [:]

    /// Queue text for a Claude session's bridge mod. Returns the item id.
    public func enqueueClaude(sessionId: String, text: String) -> String {
        let now = Date()
        deliveries = deliveries.filter { now.timeIntervalSince($0.value.createdAt) < Self.deliveryRetention }
        let item = OutboxItem(id: UUID().uuidString, text: text, createdAt: now)
        outbox[sessionId, default: []].append(item)
        deliveries[item.id] = (.pending, now)
        return item.id
    }

    public func delivery(of itemId: String) -> Delivery? {
        deliveries[itemId]?.state
    }

    /// Drop an item that was never taken (e.g. the send timed out).
    public func cancelClaude(itemId: String) {
        for (sid, items) in outbox {
            outbox[sid] = items.filter { $0.id != itemId }
        }
        if deliveries[itemId]?.state == .pending { deliveries[itemId]?.state = .failed("Cancelled") }
    }

    /// True when the session's mod polled recently.
    public func isClaudeBridgeLive(sessionId: String, within seconds: TimeInterval = 5) -> Bool {
        guard let t = lastPoll[sessionId] else { return false }
        return Date().timeIntervalSince(t) <= seconds
    }

    public var liveClaudeSessionCount: Int {
        let now = Date()
        return lastPoll.values.filter { now.timeIntervalSince($0) <= 5 }.count
    }

    public func lastClaudeEvent(sessionId: String) -> ClaudeEvent? {
        lastClaudeEvents[sessionId]
    }

    /// Server side: the mod polled. Marks the session live and hands out the next item, if any.
    public func serverClaudePoll(sessionId: String) -> OutboxItem? {
        lastPoll[sessionId] = Date()
        guard var items = outbox[sessionId], !items.isEmpty else { return nil }
        let item = items.removeFirst()
        outbox[sessionId] = items
        deliveries[item.id]?.state = .taken
        return item
    }

    /// Server side: the mod reports the result of `$.prompt.submit`.
    public func serverClaudeAck(itemId: String, ok: Bool, error: String?) {
        deliveries[itemId]?.state = ok ? .submitted : .failed(error ?? "Rejected by Claude Code")
    }

    /// Server side: turn.start / turn.complete / session.start / session.end from the mod.
    /// `session.end` stops the session counting as bridge-live.
    public func serverClaudeEvent(sessionId: String, kind: String) {
        let now = Date()
        lastPoll = lastPoll.filter { now.timeIntervalSince($0.value) < Self.eventRetention }
        lastClaudeEvents = lastClaudeEvents.filter { now.timeIntervalSince($0.value.date) < Self.eventRetention }
        lastPoll[sessionId] = kind == "session.end" ? nil : now
        lastClaudeEvents[sessionId] = ClaudeEvent(kind: kind, date: now)
    }

    // MARK: Codex hooks

    public struct CodexHookEvent: Codable, Sendable, Equatable {
        /// Hook event name, e.g. "PermissionRequest", "Stop", "UserPromptSubmit".
        public let event: String
        /// Codex thread id (hook payload `session_id`).
        public let threadId: String
        public let toolName: String?
        public let cwd: String?
        public let date: Date

        public init(event: String, threadId: String, toolName: String?, cwd: String?, date: Date) {
            self.event = event
            self.threadId = threadId
            self.toolName = toolName
            self.cwd = cwd
            self.date = date
        }
    }

    private var codexEvents: [String: [CodexHookEvent]] = [:]
    private var codexHookSeenAt: Date?

    /// Server side: one hook invocation's payload, already decoded.
    public func serverCodexHook(_ event: CodexHookEvent) {
        let now = Date()
        codexHookSeenAt = now
        codexEvents = codexEvents.filter { now.timeIntervalSince($0.value.last?.date ?? .distantPast) < Self.eventRetention }
        var list = codexEvents[event.threadId, default: []]
        list.append(event)
        if list.count > 50 { list.removeFirst(list.count - 50) }
        codexEvents[event.threadId] = list
    }

    /// Hook events for a thread, oldest first.
    public func codexHookEvents(threadId: String) -> [CodexHookEvent] {
        codexEvents[threadId] ?? []
    }

    public func codexThreadIdsWithHooks(since: Date) -> [String] {
        codexEvents.compactMap { id, list in
            (list.last?.date ?? .distantPast) >= since ? id : nil
        }
    }

    /// When any Codex hook last reached us (nil = never this run).
    public var lastCodexHookAt: Date? { codexHookSeenAt }
}
