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

    private func thread(_ status: ThreadStatus, endedAgo seconds: TimeInterval?, seenAgo seen: TimeInterval? = nil) -> AgentThread {
        AgentThread(
            platform: .codex, nativeId: "t1", surface: .desktop, title: "T", status: status,
            updatedAt: Date(), lastTurnEndedAt: seconds.map { Date().addingTimeInterval(-$0) },
            seenAt: seen.map { Date().addingTimeInterval(-$0) })
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

    func testSeenInTheToolCountsAsSeen() async {
        let provider = FakeProvider()
        let store = ThreadStore(providers: [provider], persist: false)

        provider.threads = [thread(.idle, endedAgo: 60, seenAgo: 30)]
        await store.refresh()
        XCTAssertEqual(store.threads.map(\.status), [.idle], "looked at in its own app after the reply")

        provider.threads = [thread(.idle, endedAgo: 60, seenAgo: 90)]
        await store.refresh()
        XCTAssertEqual(store.threads.map(\.status), [.ready], "last looked at before the reply")

        provider.threads = [thread(.ready, endedAgo: 60, seenAgo: 10)]
        await store.refresh()
        XCTAssertEqual(store.threads.map(\.status), [.idle], "the tool's unread state clears once it's seen")
    }

    func testRepliesInTheOpenChatAreSeen() async {
        let provider = FakeProvider()
        let store = ThreadStore(providers: [provider], persist: false)
        store.onScreen = "codex:t1"

        provider.threads = [thread(.idle, endedAgo: 5)]
        await store.refresh()
        XCTAssertEqual(store.threads.map(\.status), [.idle], "the reply landed in the open chat")

        store.onScreen = nil
        provider.threads = [thread(.idle, endedAgo: 1)]
        await store.refresh()
        XCTAssertEqual(store.threads.map(\.status), [.ready], "a later reply after the chat closed is new")
    }

    func testReadingMessagesOverTheAPIAcknowledges() async {
        let provider = FakeProvider()
        provider.threads = [thread(.idle, endedAgo: 60)]
        let store = ThreadStore(providers: [provider], persist: false)
        await store.refresh()
        XCTAssertEqual(store.threads.map(\.status), [.ready])

        _ = await store.apiMessages(threadId: "codex:t1", limit: 5)
        XCTAssertEqual(store.threads.map(\.status), [.idle], "the phone opened the chat")
    }

    func testHiddenThreadComesBackWithNewActivity() async {
        let provider = FakeProvider()
        provider.threads = [thread(.ready, endedAgo: 60)]
        let store = ThreadStore(providers: [provider], persist: false)
        await store.refresh()
        XCTAssertEqual(store.attentionCount, 1)

        store.hide(store.threads[0])
        XCTAssertTrue(store.threads.isEmpty)
        await store.refresh()
        XCTAssertTrue(store.threads.isEmpty, "nothing new: stays hidden, off the count")
        XCTAssertEqual(store.attentionCount, 0)

        provider.threads = [thread(.running, endedAgo: 60)]
        await store.refresh()
        XCTAssertEqual(store.threads.map(\.status), [.running], "you chatted in it again")

        provider.threads = [thread(.idle, endedAgo: 60)]
        await store.refresh()
        XCTAssertEqual(store.threads.count, 1, "and it stays back once the turn is over")

        store.hide(store.threads[0])
        provider.threads = [thread(.idle, endedAgo: -1)]
        await store.refresh()
        XCTAssertEqual(store.threads.map(\.status), [.ready], "a reply that lands after hiding brings it back")
    }
}
