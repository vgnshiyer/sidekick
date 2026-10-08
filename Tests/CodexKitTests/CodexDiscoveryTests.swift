import XCTest
@testable import CodexKit

final class CodexDiscoveryTests: XCTestCase {
    private let now = Date()
    private func hoursAgo(_ h: Double) -> Date { now.addingTimeInterval(-h * 3600) }

    func testDiscoveryFilters() async throws {
        let fx = try CodexFixture()
        try fx.addThread("recent-desktop", updatedAt: hoursAgo(1))
        try fx.addThread("recent-cli", updatedAt: hoursAgo(2), source: "cli", originator: "codex-tui")
        try fx.addThread("old", updatedAt: hoursAgo(30))
        try fx.addThread("old-locked", updatedAt: hoursAgo(31))
        try fx.addThread("old-running", updatedAt: hoursAgo(32))
        try fx.addThread("old-hooked", updatedAt: hoursAgo(33))
        try fx.addThread("archived", updatedAt: hoursAgo(1), archived: true)
        try fx.addThread("sub-agent", updatedAt: hoursAgo(1), source: #"{"subagent":{"other":"guardian"}}"#)
        try fx.addThread("exec", updatedAt: hoursAgo(1), source: "exec", originator: "codex_exec")
        fx.lock("old-locked")
        fx.lock("archived")
        try fx.addTurn(thread: "old-running", turn: "t1", ordinal: 1, status: "completed")
        try fx.addTurn(thread: "old-running", turn: "t2", ordinal: 2, status: "inProgress")
        try fx.addTurn(thread: "old", turn: "t3", ordinal: 1, status: "completed")

        let index = CodexIndex(home: fx.home)
        let entries = await index.entries(hookedIds: ["old-hooked", "unknown"], now: now)

        XCTAssertEqual(entries.map(\.row.id), ["recent-desktop", "recent-cli", "old-locked", "old-running", "old-hooked"])
        XCTAssertEqual(entries.filter(\.inProgress).map(\.row.id), ["old-running"])
    }

    func testCapsAtTwentyMostRecent() async throws {
        let fx = try CodexFixture()
        for i in 0..<25 {
            try fx.addThread("t\(i)", updatedAt: hoursAgo(Double(i) / 10))
        }
        let entries = await CodexIndex(home: fx.home).entries(hookedIds: [], now: now)
        XCTAssertEqual(entries.map(\.row.id), (0..<20).map { "t\($0)" })
    }

    func testSeesWALWritesAndRequeriesOnChange() async throws {
        let fx = try CodexFixture()
        try fx.addThread("first", updatedAt: hoursAgo(1))
        let index = CodexIndex(home: fx.home)
        let before = await index.entries(hookedIds: [], now: now)
        XCTAssertEqual(before.map(\.row.id), ["first"])

        try fx.addThread("second", updatedAt: hoursAgo(0.5))
        let after = await index.entries(hookedIds: [], now: now)
        XCTAssertEqual(after.map(\.row.id), ["second", "first"])
    }

    func testThreadsAgeOutWithoutRequery() async throws {
        let fx = try CodexFixture()
        try fx.addThread("a", updatedAt: hoursAgo(23))
        let index = CodexIndex(home: fx.home)
        let fresh = await index.entries(hookedIds: [], now: now)
        XCTAssertEqual(fresh.count, 1)
        let later = await index.entries(hookedIds: [], now: now.addingTimeInterval(2 * 3600))
        XCTAssertTrue(later.isEmpty)
    }

    func testUnreadFromBothBuckets() async throws {
        let fx = try CodexFixture()
        try fx.addThread("a", updatedAt: hoursAgo(1))
        try fx.addThread("b", updatedAt: hoursAgo(2))
        try fx.addThread("c", updatedAt: hoursAgo(3))
        try fx.writeGlobalState(local: ["a", "zzz"], durable: ["c"])
        let entries = await CodexIndex(home: fx.home).entries(hookedIds: [], now: now)
        XCTAssertEqual(entries.filter(\.unread).map(\.row.id), ["a", "c"])
    }

    func testTitleFallbacksAndColumns() throws {
        let fx = try CodexFixture()
        try fx.addThread("named", updatedAt: hoursAgo(1), name: "Short  name\n", preview: "Long preview")
        try fx.addThread("preview", updatedAt: hoursAgo(2), name: nil, preview: "Fix the\nbuild ")
        try fx.addThread("empty", updatedAt: hoursAgo(3), name: "", preview: "", cwd: "", branch: nil)

        let rows = try XCTUnwrap(CodexDatabase.threads(
            path: fx.home.appendingPathComponent("state_5.sqlite").path,
            updatedSince: hoursAgo(24), orIn: [], limit: 20))
        XCTAssertEqual(rows.map(\.title), ["Short name", "Fix the build", "New thread"])
        XCTAssertEqual(rows[0].cwd, "/tmp/project")
        XCTAssertEqual(rows[0].branch, "main")
        XCTAssertEqual(rows[0].originator, "Codex Desktop")
        XCTAssertEqual(rows[0].source, "vscode")
        XCTAssertNil(rows[2].cwd)
        XCTAssertNil(rows[2].branch)
        XCTAssertEqual(rows[0].updatedAt.timeIntervalSince1970, hoursAgo(1).timeIntervalSince1970, accuracy: 0.01)
    }

    func testToleratesMissingColumnsAndTables() throws {
        let fx = try CodexFixture(
            threadsSchema: "CREATE TABLE threads (id TEXT PRIMARY KEY, updated_at INTEGER);",
            turnsSchema: "CREATE TABLE other (x);")
        let statePath = fx.home.appendingPathComponent("state_5.sqlite").path
        let historyPath = fx.home.appendingPathComponent("thread_history_1.sqlite").path
        let rows = CodexDatabase.threads(path: statePath, updatedSince: hoursAgo(24), orIn: [], limit: 20)
        XCTAssertEqual(rows, [])
        XCTAssertEqual(CodexDatabase.inProgressThreadIds(path: historyPath), [])
        XCTAssertNil(CodexDatabase.threads(path: "/nonexistent/state_5.sqlite", updatedSince: now, orIn: [], limit: 20))
        XCTAssertEqual(CodexDatabase.threads(path: historyPath, updatedSince: now, orIn: [], limit: 20), [])
    }

    func testMinimalSchemaStillListsThreads() throws {
        let fx = try CodexFixture(threadsSchema: "CREATE TABLE threads (id TEXT PRIMARY KEY, updated_at INTEGER);")
        let statePath = fx.home.appendingPathComponent("state_5.sqlite").path
        let probe = try XCTUnwrap(SQLiteReader(path: statePath))
        XCTAssertEqual(probe.columns(of: "threads"), ["id", "updated_at"])
        XCTAssertEqual(probe.columns(of: "missing"), [])

        try fx.execState("INSERT INTO threads VALUES ('x', \(Int(hoursAgo(1).timeIntervalSince1970)))")
        let rows = try XCTUnwrap(CodexDatabase.threads(path: statePath, updatedSince: hoursAgo(24), orIn: [], limit: 20))
        XCTAssertEqual(rows.map(\.id), ["x"])
        XCTAssertEqual(rows.first?.title, "New thread")
        XCTAssertNil(rows.first?.rolloutPath)
    }
}
