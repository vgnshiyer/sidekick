import SidekickCore
import XCTest

/// The store's ready rule, with a provider that reports Codex-style unread state.
@MainActor
final class ThreadStoreTests: XCTestCase {
    private final class FakeProvider: ThreadProvider, @unchecked Sendable {
        let platform = Platform.codex
        var threads: [AgentThread] = []

        func snapshot() async -> [AgentThread] { threads }
        func messages(for thread: AgentThread, limit: Int) async -> [ChatMessage] { [] }
        func send(_ text: String, to thread: AgentThread) async -> SendOutcome { .delivered }
        func open(_ thread: AgentThread) async -> Bool { true }
    }

    private func thread(_ status: ThreadStatus, endedAgo seconds: TimeInterval?) -> AgentThread {
        AgentThread(
            platform: .codex, nativeId: "t1", surface: .desktop, title: "T", status: status,
            updatedAt: Date(), lastTurnEndedAt: seconds.map { Date().addingTimeInterval(-$0) })
    }

    func testUnreadThreadStaysReadyUntilAcknowledged() async {
        let provider = FakeProvider()
        provider.threads = [thread(.ready, endedAgo: 3600)]
        let store = ThreadStore(providers: [provider], persist: false)

        await store.refresh()
        XCTAssertEqual(store.threads.map(\.status), [.ready], "an old unread turn is still unread")

        store.acknowledge(store.threads[0])
        await store.refresh()
        XCTAssertEqual(store.threads.map(\.status), [.idle], "acknowledged here, though the tool still lists it unread")

        provider.threads = [thread(.ready, endedAgo: -1)]
        await store.refresh()
        XCTAssertEqual(store.threads.map(\.status), [.ready], "a turn that ends after the ack is ready again")
    }

    func testIdleBecomesReadyOnlyForRecentTurns() async {
        let provider = FakeProvider()
        let store = ThreadStore(providers: [provider], persist: false)

        provider.threads = [thread(.idle, endedAgo: 3600)]
        await store.refresh()
        XCTAssertEqual(store.threads.map(\.status), [.idle], "turns well before first sight count as seen")

        provider.threads = [thread(.idle, endedAgo: 60)]
        await store.refresh()
        XCTAssertEqual(store.threads.map(\.status), [.ready])

        store.acknowledge(store.threads[0])
        XCTAssertEqual(store.threads.map(\.status), [.idle])
        await store.refresh()
        XCTAssertEqual(store.threads.map(\.status), [.idle])
    }
}
