import Foundation
import SQLite3

/// A read-only connection to one of Codex's WAL databases. Never writes. While Codex has the
/// database open, reads go through its WAL so recent writes are visible; once Codex closes it
/// (no `-wal` file left), a read-only open can't make the `-shm` index, so it reads the main file
/// as `immutable`, which then holds everything.
final class SQLiteReader {
    enum Value {
        case int(Int64)
        case text(String)
    }

    struct Row {
        fileprivate let stmt: OpaquePointer

        func string(_ column: Int32) -> String? {
            sqlite3_column_text(stmt, column).map { String(cString: $0) }
        }

        func int(_ column: Int32) -> Int64? {
            sqlite3_column_type(stmt, column) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, column)
        }
    }

    private let db: OpaquePointer

    /// Opens `path` with `SQLITE_OPEN_READONLY` and a 250 ms busy timeout. Nil if it can't be opened.
    init?(path: String) {
        var handle: OpaquePointer?
        let closed = !FileManager.default.fileExists(atPath: path + "-wal")
        let name = closed ? URL(fileURLWithPath: path).absoluteString + "?immutable=1" : path
        guard sqlite3_open_v2(name, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK, let handle else {
            sqlite3_close(handle)
            return nil
        }
        sqlite3_busy_timeout(handle, 250)
        db = handle
    }

    deinit {
        sqlite3_close(db)
    }

    /// Column names of `table`; empty when the table doesn't exist.
    func columns(of table: String) -> Set<String> {
        Set(rows("SELECT name FROM pragma_table_info(?)", [.text(table)]) { $0.string(0) })
    }

    /// Runs `sql` and maps each row; rows mapped to nil are dropped. Errors yield no rows.
    func rows<T>(_ sql: String, _ args: [Value] = [], _ map: (Row) -> T?) -> [T] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }
        for (i, arg) in args.enumerated() {
            let index = Int32(i + 1)
            switch arg {
            case .int(let v): sqlite3_bind_int64(stmt, index, v)
            case .text(let v): sqlite3_bind_text(stmt, index, v, -1, Self.transient)
            }
        }
        var out: [T] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let value = map(Row(stmt: stmt)) { out.append(value) }
        }
        return out
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}

/// One row of `state_5.sqlite` → `threads`, reduced to what Sidekick shows.
struct CodexThreadRow: Equatable, Sendable {
    var id: String
    var rolloutPath: String?
    var updatedAt: Date
    var source: String?
    var originator: String?
    var cwd: String?
    var branch: String?
    var title: String
}

/// Queries against Codex's state and history databases. Columns that a future schema drops
/// read as NULL, and a missing table reads as empty.
enum CodexDatabase {
    /// Non-archived interactive threads updated since `cutoff` or listed in `ids`, newest first.
    /// Nil when the database can't be opened, e.g. it doesn't exist yet.
    static func threads(path: String, updatedSince cutoff: Date, orIn ids: Set<String>, limit: Int) -> [CodexThreadRow]? {
        guard let db = SQLiteReader(path: path) else { return nil }
        let columns = db.columns(of: "threads")
        guard columns.contains("id") else { return [] }
        func col(_ name: String) -> String { columns.contains(name) ? name : "NULL" }

        let updated: String
        switch (columns.contains("updated_at_ms"), columns.contains("updated_at")) {
        case (true, true): updated = "COALESCE(updated_at_ms, updated_at * 1000)"
        case (true, false): updated = "updated_at_ms"
        case (false, true): updated = "updated_at * 1000"
        case (false, false): updated = "0"
        }

        var filters: [String] = []
        if columns.contains("archived") { filters.append("archived = 0") }
        // Interactive sources only, as Codex's own thread list does: no exec runs or sub-agents.
        if columns.contains("source") { filters.append("source IN ('cli', 'vscode')") }
        let idList = ids.sorted()
        var match = "\(updated) >= ?"
        if !idList.isEmpty {
            match += " OR id IN (\(Array(repeating: "?", count: idList.count).joined(separator: ", ")))"
        }
        filters.append("(\(match))")

        let sql = """
            SELECT id, \(col("rollout_path")), \(updated), \(col("source")), \(col("originator")), \(col("cwd")),
                   \(col("git_branch")), \(col("name")), \(col("preview")), \(col("title")), \(col("first_user_message"))
            FROM threads WHERE \(filters.joined(separator: " AND "))
            ORDER BY \(updated) DESC LIMIT ?
            """
        let args: [SQLiteReader.Value] =
            [.int(Int64(cutoff.timeIntervalSince1970 * 1000))] + idList.map { .text($0) } + [.int(Int64(limit))]
        return db.rows(sql, args) { row in
            guard let id = row.string(0) else { return nil }
            // name, then preview, title, first_user_message.
            let title = ([7, 8, 9, 10] as [Int32]).lazy.compactMap { row.string($0).flatMap { oneLine($0) } }.first
            return CodexThreadRow(
                id: id,
                rolloutPath: nonEmpty(row.string(1)),
                updatedAt: Date(timeIntervalSince1970: Double(row.int(2) ?? 0) / 1000),
                source: row.string(3),
                originator: nonEmpty(row.string(4)),
                cwd: nonEmpty(row.string(5)),
                branch: nonEmpty(row.string(6)),
                title: title ?? "New thread")
        }
    }

    /// Thread ids with a turn whose status is `inProgress` in `thread_history_1.sqlite`.
    static func inProgressThreadIds(path: String) -> Set<String> {
        guard let db = SQLiteReader(path: path) else { return [] }
        let columns = db.columns(of: "thread_turns")
        guard columns.contains("thread_id"), columns.contains("status") else { return [] }
        return Set(db.rows("SELECT DISTINCT thread_id FROM thread_turns WHERE status = 'inProgress'") { $0.string(0) })
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }
}

/// Collapses whitespace runs (including newlines) to single spaces and caps the result at `limit`
/// characters; nil when nothing is left. Only a prefix is examined, so long text costs no more.
func oneLine(_ text: String, limit: Int = 200) -> String? {
    let head = text.prefix(2 * limit)
    let line = head.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    guard !line.isEmpty else { return nil }
    return line.count > limit || head.endIndex != text.endIndex ? String(line.prefix(limit - 1)) + "…" : line
}
