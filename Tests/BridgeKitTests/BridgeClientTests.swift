import Foundation
import XCTest
@testable import BridgeKit

final class BridgeClientTests: XCTestCase {
    func testUnreachableSocketIsNil() {
        XCTAssertNil(BridgeClient.request(method: "GET", path: "/health", socketPath: scratchSocketPath(), timeout: 1))
        XCTAssertNil(BridgeClient.request(method: "GET", path: "/health", socketPath: "", timeout: 1))
    }

    func testTimesOutWhenNobodyAnswers() throws {
        // A listener that never accepts: connect succeeds via the backlog, no response ever comes.
        let path = scratchSocketPath()
        let fd = try XCTUnwrap(UnixSocket.makeStream())
        defer {
            close(fd)
            unlink(path)
        }
        XCTAssertTrue(UnixSocket.bind(fd, try XCTUnwrap(UnixSocket.address(path))))
        XCTAssertEqual(listen(fd, 4), 0)

        let started = Date()
        XCTAssertNil(BridgeClient.request(method: "GET", path: "/health", socketPath: path, timeout: 0.5))
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertGreaterThanOrEqual(elapsed, 0.45)
        XCTAssertLessThan(elapsed, 2)
    }

    func testParseHonoursContentLength() throws {
        let raw = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 11\r\n\r\n{\"ok\":true}trailing".utf8)
        let (status, body) = try XCTUnwrap(BridgeClient.parse(raw))
        XCTAssertEqual(status, 200)
        XCTAssertEqual(String(decoding: body, as: UTF8.self), #"{"ok":true}"#)
    }

    func testParseNoContent() throws {
        let (status, body) = try XCTUnwrap(BridgeClient.parse(Data("HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n".utf8)))
        XCTAssertEqual(status, 204)
        XCTAssertTrue(body.isEmpty)
    }

    func testParseRejectsTruncatedOrGarbage() {
        XCTAssertNil(BridgeClient.parse(Data("HTTP/1.1 200 OK\r\nContent-Length: 50\r\n\r\n{}".utf8)))
        XCTAssertNil(BridgeClient.parse(Data("hello".utf8)))
        XCTAssertNil(BridgeClient.parse(Data("SMTP 200 OK\r\n\r\n".utf8)))
    }
}

final class HTTPRequestTests: XCTestCase {
    func testIncompleteUntilBodyArrives() {
        let head = "POST /claude/ack HTTP/1.1\r\nContent-Length: 4\r\n\r\n"
        guard case .incomplete = HTTPRequest.parse(Data("POST /claude/ack HTTP/1.1\r\n".utf8)) else { return XCTFail("headers") }
        guard case .incomplete = HTTPRequest.parse(Data((head + "{}").utf8)) else { return XCTFail("body") }
        guard case .complete(let request) = HTTPRequest.parse(Data((head + "{}{}").utf8)) else { return XCTFail("complete") }
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/claude/ack")
        XCTAssertEqual(String(decoding: request.body, as: UTF8.self), "{}{}")
    }

    func testQueryAndHeaders() {
        let raw = "GET /api/messages?thread=claude%3Aabc&limit=5&limit=9 HTTP/1.0\r\nHost: Sidekick\r\nX-Thing:  spaced  \r\n\r\n"
        guard case .complete(let request) = HTTPRequest.parse(Data(raw.utf8)) else { return XCTFail("parse") }
        XCTAssertEqual(request.path, "/api/messages")
        XCTAssertEqual(request.query, ["thread": "claude:abc", "limit": "5"])
        XCTAssertEqual(request.headers["host"], "Sidekick")
        XCTAssertEqual(request.headers["x-thing"], "spaced")
        XCTAssertTrue(request.body.isEmpty)
    }

    func testResponseSerialization() {
        let ok = String(decoding: HTTPResponse.json(["ok": true]).serialized(), as: UTF8.self)
        XCTAssertEqual(ok, "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Type: application/json\r\nContent-Length: 11\r\n\r\n{\"ok\":true}")
        let empty = String(decoding: HTTPResponse.noContent.serialized(), as: UTF8.self)
        XCTAssertEqual(empty, "HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n")
    }
}
