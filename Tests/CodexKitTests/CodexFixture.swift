import Foundation
import SQLite3

/// A throwaway CODEX_HOME with the real table and column names, synthetic rollouts and a
/// synthetic desktop global-state file. The databases stay open in WAL mode, like Codex keeps them.
final class CodexFixture {
    let home: URL
    private var state: OpaquePointer?
    private var history: OpaquePointer?

    static let threadsSchema = """
        CREATE TABLE threads (
            id TEXT PRIMARY KEY, rollout_path TEXT NOT NULL, created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL, source TEXT NOT NULL, model_provider TEXT NOT NULL, cwd TEXT NOT NULL,
            title TEXT NOT NULL, sandbox_policy TEXT NOT NULL, approval_mode TEXT NOT NULL,
            tokens_used INTEGER NOT NULL DEFAULT 0, has_user_event INTEGER NOT NULL DEFAULT 0,
            archived INTEGER NOT NULL DEFAULT 0, archived_at INTEGER, git_sha TEXT, git_branch TEXT,
            git_origin_url TEXT, cli_version TEXT NOT NULL DEFAULT '', first_user_message TEXT NOT NULL DEFAULT '',
            agent_nickname TEXT, agent_role TEXT, memory_mode TEXT NOT NULL DEFAULT 'enabled', model TEXT,
            reasoning_effort TEXT, agent_path TEXT, created_at_ms INTEGER, updated_at_ms INTEGER, thread_source TEXT,
            preview TEXT NOT NULL DEFAULT '', recency_at INTEGER NOT NULL DEFAULT 0,
            recency_at_ms INTEGER NOT NULL DEFAULT 0, history_mode TEXT NOT NULL DEFAULT 'legacy', name TEXT,
            is_pinned INTEGER NOT NULL DEFAULT 0, thread_section_id TEXT, section_position INTEGER,
            section_entered_at_ms INTEGER, project_id TEXT, originator TEXT, daybreak_enabled BOOLEAN,
            creator_user_id TEXT, creator_account_id TEXT);
        """

    static let turnsSchema = """
        CREATE TABLE thread_turns (
            thread_id TEXT NOT NULL, turn_id TEXT NOT NULL, rollout_ordinal INTEGER NOT NULL, status TEXT NOT NULL,
            error_json TEXT, started_at INTEGER, completed_at INTEGER, duration_ms INTEGER, first_user_item_id TEXT,
            final_agent_item_id TEXT, rollout_byte_offset INTEGER, rollout_end_ordinal INTEGER,
            rollout_end_byte_offset INTEGER, PRIMARY KEY (thread_id, turn_id));
        """

    init(threadsSchema: String = CodexFixture.threadsSchema, turnsSchema: String = CodexFixture.turnsSchema) throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("sk-codex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("thread-writer-locks"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: home.appendingPathComponent("thread-writer-locks/.coordination.lock").path, contents: nil)
        state = try Self.open(home.appendingPathComponent("state_5.sqlite").path, schema: threadsSchema)
        history = try Self.open(home.appendingPathComponent("thread_history_1.sqlite").path, schema: turnsSchema)
    }

    deinit {
        sqlite3_close(state)
        sqlite3_close(history)
        try? FileManager.default.removeItem(at: home)
    }

    /// Inserts a thread row; returns its rollout path.
    @discardableResult
    func addThread(
        _ id: String,
        updatedAt: Date,
        source: String = "vscode",
        originator: String? = "Codex Desktop",
        archived: Bool = false,
        name: String? = nil,
        preview: String = "A preview",
        cwd: String = "/tmp/project",
        branch: String? = "main",
        rollout: [String] = []
    ) throws -> String {
        let path = try writeRollout(id, lines: rollout)
        let ms = Int64(updatedAt.timeIntervalSince1970 * 1000)
        try Self.exec(state, """
            INSERT INTO threads (id, rollout_path, created_at, updated_at, updated_at_ms, source, model_provider, cwd,
                                 title, sandbox_policy, approval_mode, archived, git_branch, preview, name, originator,
                                 first_user_message)
            VALUES (\(q(id)), \(q(path)), \(ms / 1000), \(ms / 1000), \(ms), \(q(source)), 'openai', \(q(cwd)),
                    \(q(preview)), '{}', 'on-request', \(archived ? 1 : 0), \(branch.map(q) ?? "NULL"), \(q(preview)),
                    \(name.map(q) ?? "NULL"), \(originator.map(q) ?? "NULL"), \(q(preview)));
            """)
        return path
    }

    func execState(_ sql: String) throws {
        try Self.exec(state, sql)
    }

    func addTurn(thread: String, turn: String, ordinal: Int, status: String) throws {
        try Self.exec(history, """
            INSERT INTO thread_turns (thread_id, turn_id, rollout_ordinal, status)
            VALUES (\(q(thread)), \(q(turn)), \(ordinal), \(q(status)));
            """)
    }

    func lock(_ id: String) {
        FileManager.default.createFile(atPath: home.appendingPathComponent("thread-writer-locks/\(id).lock").path, contents: nil)
    }

    func writeGlobalState(local: [String], durable: [String] = []) throws {
        let json: [String: Any] = [
            "electron-avatar-overlay-open": false,
            "electron-thread-read-state-v1": [
                "version": 1,
                "unreadByIdentity": [String(repeating: "a", count: 64): ["local:abc": local, "durable:def": durable]],
            ],
        ]
        try JSONSerialization.data(withJSONObject: json).write(to: home.appendingPathComponent(".codex-global-state.json"))
    }

    @discardableResult
    func writeRollout(_ id: String, lines: [String]) throws -> String {
        let dir = home.appendingPathComponent("sessions/2026/10/08")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("rollout-2026-10-08T10-00-00-\(id).jsonl")
        try Data(lines.map { $0 + "\n" }.joined().utf8).write(to: url)
        return url.path
    }

    private func q(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "''") + "'"
    }

    private static func open(_ path: String, schema: String) throws -> OpaquePointer? {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw FixtureError.sqlite("open \(path)") }
        try exec(db, "PRAGMA journal_mode=WAL;")
        if !schema.isEmpty { try exec(db, schema) }
        return db
    }

    private static func exec(_ db: OpaquePointer?, _ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &message) == SQLITE_OK else {
            let text = message.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(message)
            throw FixtureError.sqlite(text)
        }
    }

    enum FixtureError: Error {
        case sqlite(String)
    }
}

/// Synthetic rollout lines shaped like codex-cli 0.159 / 0.160 output.
enum RolloutLine {
    static func iso(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }

    static func event(_ payload: [String: Any], at date: Date) -> String {
        line(["type": "event_msg", "payload": payload], at: date)
    }

    static func line(_ fields: [String: Any], at date: Date) -> String {
        var object = fields
        object["timestamp"] = iso(date)
        object["ordinal"] = 0
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    static func taskStarted(_ turn: String, at date: Date) -> String {
        event(["type": "task_started", "turn_id": turn, "started_at": Int(date.timeIntervalSince1970)], at: date)
    }

    static func taskComplete(_ turn: String, at date: Date, error: Bool = false) -> String {
        var payload: [String: Any] = ["type": "task_complete", "turn_id": turn, "last_agent_message": NSNull()]
        payload["error"] = error ? ["message": "boom", "codex_error_info": "other"] : NSNull()
        return event(payload, at: date)
    }

    static func turnAborted(_ turn: String, at date: Date) -> String {
        event(["type": "turn_aborted", "turn_id": turn, "reason": "interrupted"], at: date)
    }

    static func user(_ text: String, id: String = UUID().uuidString, at date: Date, image: Bool = false) -> String {
        var content: [[String: Any]] = [["type": "text", "text": text, "text_elements": []]]
        if image { content.insert(["type": "local_image", "path": "/tmp/x.png"], at: 0) }
        return event([
            "type": "item_completed", "thread_id": "t", "turn_id": "u",
            "item": ["type": "UserMessage", "id": id, "content": content],
        ], at: date)
    }

    static func agent(_ text: String, id: String = UUID().uuidString, phase: String = "final_answer", at date: Date) -> String {
        event([
            "type": "item_completed", "thread_id": "t", "turn_id": "u",
            "item": ["type": "AgentMessage", "id": id, "content": [["type": "Text", "text": text]], "phase": phase],
        ], at: date)
    }
}
