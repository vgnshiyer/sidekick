import Combine
import Foundation

/// Merges all providers, derives `ready` from acknowledgements, sorts by urgency,
/// and publishes the list the UI renders. Also serves the CLI API.
@MainActor
public final class ThreadStore: ObservableObject {
    @Published public private(set) var threads: [AgentThread] = []

    public let providers: [ThreadProvider]
    private var acks: [String: Date] = [:]
    /// Threads the user hid, and when. Each stays hidden until it shows new activity.
    private var hidden: [String: Date] = [:]
    /// When each thread was first and last returned by a provider.
    private var sightings: [String: (first: Date, last: Date)] = [:]
    private var timer: Timer?
    private var refreshing = false
    private let persist: Bool
    /// The thread open in Sidekick's chat, if any: replies that land in it are seen as they arrive.
    public var onScreen: String?

    /// - Parameter persist: save acknowledgements to `Paths.stateFile` (off for demo/tests).
    public init(providers: [ThreadProvider], persist: Bool = true) {
        self.providers = providers
        self.persist = persist
        if persist { loadAcks() }
    }

    public func start(interval: TimeInterval = 1.5) {
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        t.tolerance = interval / 10
        RunLoop.main.add(t, forMode: .common)
        timer = t
        Task { await refresh() }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// The most urgent status across all threads, or nil when there are none.
    public var topStatus: ThreadStatus? {
        threads.first?.status
    }

    public var attentionCount: Int {
        threads.filter { $0.status.wantsAttention }.count
    }

    public func refresh() async {
        if refreshing { return }
        refreshing = true
        defer { refreshing = false }

        var all: [AgentThread] = []
        await withTaskGroup(of: [AgentThread].self) { group in
            for p in providers {
                group.addTask { await p.snapshot() }
            }
            for await list in group { all.append(contentsOf: list) }
        }

        let now = Date()
        var result: [AgentThread] = []
        var acked = false
        var unhid = false
        for var t in all {
            if let at = hidden[t.id] {
                // Back once you chat in it again, it needs you, or a new reply lands.
                let active = t.status == .running || t.status == .needsInput || (t.lastTurnEndedAt ?? .distantPast) > at
                guard active else { continue }
                hidden[t.id] = nil
                unhid = true
            }
            if t.id == onScreen, let end = t.lastTurnEndedAt, (acks[t.id] ?? .distantPast) < end {
                acks[t.id] = end
                acked = true
            }
            let firstSeen = sightings[t.id]?.first ?? now
            sightings[t.id] = (firstSeen, now)
            // Seen here (acknowledged) or in the tool itself, whichever is later.
            let seen = [acks[t.id], t.seenAt].compactMap { $0 }.max()
            switch t.status {
            case .idle:
                // Turns that ended before Sidekick first saw the thread count as seen, unless recent.
                let since = seen ?? firstSeen.addingTimeInterval(-15 * 60)
                if let end = t.lastTurnEndedAt, end > since { t.status = .ready }
            case .ready:
                // The tool's own unread state stands until the thread is seen after its last turn.
                if let seen, (t.lastTurnEndedAt ?? .distantPast) <= seen { t.status = .idle }
            default:
                break
            }
            result.append(t)
        }
        if acked || unhid { saveAcks() }
        sightings = sightings.filter { now.timeIntervalSince($0.value.last) < 24 * 3600 }
        result.sort {
            if $0.status.rank != $1.status.rank { return $0.status.rank < $1.status.rank }
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id < $1.id
        }
        if result != threads { threads = result }
    }

    public func thread(id: String) -> AgentThread? {
        threads.first { $0.id == id }
    }

    /// Mark a thread as seen: `ready` becomes `idle` until its next finished turn.
    public func acknowledge(_ thread: AgentThread) {
        acks[thread.id] = Date()
        if let i = threads.firstIndex(where: { $0.id == thread.id }), threads[i].status == .ready {
            threads[i].status = .idle
            threads.sort {
                if $0.status.rank != $1.status.rank { return $0.status.rank < $1.status.rank }
                if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
                return $0.id < $1.id
            }
        }
        saveAcks()
    }

    /// Take a thread off the list (and the count) until it shows new activity.
    public func hide(_ thread: AgentThread) {
        hidden[thread.id] = Date()
        threads.removeAll { $0.id == thread.id }
        saveAcks()
    }

    public func messages(for thread: AgentThread, limit: Int = 20) async -> [ChatMessage] {
        guard let p = provider(for: thread) else { return [] }
        return await p.messages(for: thread, limit: limit)
    }

    public func send(_ text: String, to thread: AgentThread) async -> SendOutcome {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failed("Nothing to send") }
        guard let p = provider(for: thread) else { return .failed("No provider for \(thread.platform.displayName)") }
        acknowledge(thread)
        let outcome = await p.send(trimmed, to: thread)
        Task { await refresh() }
        return outcome
    }

    @discardableResult
    public func open(_ thread: AgentThread) async -> Bool {
        acknowledge(thread)
        guard let p = provider(for: thread) else { return false }
        return await p.open(thread)
    }

    private func provider(for thread: AgentThread) -> ThreadProvider? {
        providers.first { $0.platform == thread.platform }
    }

    // MARK: persistence

    private struct AckFile: Codable {
        var acks: [String: Date]
        var hidden: [String: Date]?
    }

    private func loadAcks() {
        guard let data = try? Data(contentsOf: Paths.stateFile.deletingLastPathComponent().appendingPathComponent("acks.json")),
              let file = try? JSONDecoder().decode(AckFile.self, from: data) else { return }
        acks = file.acks
        hidden = file.hidden ?? [:]
    }

    private func saveAcks() {
        guard persist else { return }
        let cutoff = Date().addingTimeInterval(-14 * 24 * 3600)
        acks = acks.filter { $0.value > cutoff }
        hidden = hidden.filter { $0.value > cutoff }
        if let data = try? JSONEncoder().encode(AckFile(acks: acks, hidden: hidden)) {
            try? data.write(
                to: Paths.stateFile.deletingLastPathComponent().appendingPathComponent("acks.json"),
                options: .atomic)
        }
    }
}

extension ThreadStore: SidekickAPI {
    nonisolated public func apiThreads() async -> [AgentThread] {
        await MainActor.run { threads }
    }

    /// Reading a thread's messages (the phone's open chat polls this) counts as seeing it.
    nonisolated public func apiMessages(threadId: String, limit: Int) async -> [ChatMessage] {
        guard let t = await MainActor.run(body: { () -> AgentThread? in
            guard let t = thread(id: threadId) else { return nil }
            if t.status == .ready { acknowledge(t) }
            return t
        }) else { return [] }
        return await messages(for: t, limit: limit)
    }

    nonisolated public func apiSend(threadId: String, text: String) async -> SendOutcome {
        guard let t = await MainActor.run(body: { thread(id: threadId) }) else { return .failed("Unknown thread \(threadId)") }
        return await send(text, to: t)
    }

    nonisolated public func apiOpen(threadId: String) async -> Bool {
        guard let t = await MainActor.run(body: { thread(id: threadId) }) else { return false }
        return await open(t)
    }
}
