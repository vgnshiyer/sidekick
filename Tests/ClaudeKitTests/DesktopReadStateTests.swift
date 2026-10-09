import Foundation
import XCTest
@testable import ClaudeKit

final class DesktopReadStateTests: XCTestCase {
    func testReadsFocusAndSendTimesPerSession() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("desktop-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let org = root.appendingPathComponent("account/org")
        try FileManager.default.createDirectory(at: org, withIntermediateDirectories: true)
        let file = org.appendingPathComponent("local_abc.json")
        try Data(#"{"sessionId":"local_abc","lastFocusedAt":1790000000000,"latestUserFrameAt":1790000060000}"#.utf8).write(to: file)
        try Data("{}".utf8).write(to: org.appendingPathComponent("other.json"))

        let state = DesktopReadState(root: root)
        let entry = try XCTUnwrap(state.entries()["local_abc"])
        XCTAssertEqual(entry.focusedAt, Date(timeIntervalSince1970: 1_790_000_000))
        XCTAssertEqual(entry.seenAt, Date(timeIntervalSince1970: 1_790_000_060))
        XCTAssertEqual(state.entries().count, 1)

        // A rewrite is picked up.
        try Data(#"{"lastFocusedAt":1790000120000}"#.utf8).write(to: file)
        XCTAssertEqual(state.entries()["local_abc"]?.seenAt, Date(timeIntervalSince1970: 1_790_000_120))
    }

    func testMissingFolderIsEmpty() {
        XCTAssertTrue(DesktopReadState(root: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")).entries().isEmpty)
    }
}
