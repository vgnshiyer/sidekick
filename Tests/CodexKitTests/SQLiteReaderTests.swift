import Foundation
import SQLite3
import XCTest
@testable import CodexKit

final class SQLiteReaderTests: XCTestCase {
    /// Codex closing its WAL database removes the -wal and -shm files; reads must still work.
    func testReadsAWALDatabaseNobodyHasOpen() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("state.sqlite").path

        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &writer), SQLITE_OK)
        for sql in ["PRAGMA journal_mode=WAL", "CREATE TABLE t(x TEXT)", "INSERT INTO t VALUES ('a'), ('b')"] {
            XCTAssertEqual(sqlite3_exec(writer, sql, nil, nil, nil), SQLITE_OK, sql)
        }

        // While the writer has it open, the reader sees rows through the WAL.
        let live = try XCTUnwrap(SQLiteReader(path: path))
        XCTAssertEqual(live.rows("SELECT x FROM t ORDER BY x") { $0.string(0) }, ["a", "b"])

        sqlite3_close(writer)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path + "-wal"), "a clean close removes the WAL")
        let closed = try XCTUnwrap(SQLiteReader(path: path))
        XCTAssertEqual(closed.rows("SELECT x FROM t ORDER BY x") { $0.string(0) }, ["a", "b"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: path + "-shm"), "reading leaves no files behind")
    }
}
