import Foundation
import SidekickCore
import XCTest
@testable import BridgeKit

final class BridgeServerTests: XCTestCase {
    private var socket = ""
    private var hub = BridgeHub()
    private var api = FakeAPI()
    private var server: BridgeServer?

    override func setUpWithError() throws {
        socket = scratchSocketPath()
        hub = BridgeHub()
        api = FakeAPI()
        let server = BridgeServer(hub: hub, socketPath: socket, api: api)
        try server.start()
        self.server = server
    }

    override func tearDown() {
        server?.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: socket), "stop() must remove the socket")
    }

    // MARK: Basics

    func testHealth() throws {
        let r = try call("GET", "/health", socket: socket)
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(r.json["ok"] as? Bool, true)
        XCTAssertEqual(r.json["app"] as? String, "Sidekick")
    }

    func testSocketIsPrivate() throws {
        var info = stat()
        XCTAssertEqual(lstat(socket, &info), 0)
        XCTAssertEqual(info.st_mode & S_IFMT, S_IFSOCK)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
    }

    func testCreatesMissingParentDirectoryPrivately() throws {
        let dir = "/tmp/sk-\(UUID().uuidString.prefix(6).lowercased())"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let nested = BridgeServer(hub: hub, socketPath: dir + "/b.sock")
        try nested.start()
        defer { nested.stop() }
        let attributes = try FileManager.default.attributesOfItem(atPath: dir)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual(try call("GET", "/health", socket: dir + "/b.sock").status, 200)
    }

    func testUnknownRoutesAre404() throws {
        for (method, path) in [("GET", "/nope"), ("POST", "/health"), ("GET", "/claude/ack"), ("DELETE", "/api/threads")] {
            let r = try call(method, path, socket: socket)
            XCTAssertEqual(r.status, 404, "\(method) \(path)")
            XCTAssertEqual(r.json["error"] as? String, "not found")
        }
    }

    // MARK: Claude bridge mod

    func testHelloMarksSessionLive() async throws {
        let r = try call("POST", "/claude/hello", json: ["sessionId": "s-1", "pid": 42, "cwd": "/tmp", "surfaces": ["terminal"]],
                         socket: socket)
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(r.json["ok"] as? Bool, true)
        let live = await hub.isClaudeBridgeLive(sessionId: "s-1")
        XCTAssertTrue(live)
        let event = await hub.lastClaudeEvent(sessionId: "s-1")
        XCTAssertEqual(event?.kind, "session.start")
        XCTAssertEqual(try call("POST", "/claude/hello", json: ["pid": 42], socket: socket).status, 400)
    }

    func testPollAckLifecycle() async throws {
        let empty = try XCTUnwrap(BridgeClient.request(method: "GET", path: "/claude/poll?session=s-1", socketPath: socket))
        XCTAssertEqual(empty.0, 204)
        XCTAssertTrue(empty.1.isEmpty)
        let live = await hub.isClaudeBridgeLive(sessionId: "s-1")
        XCTAssertTrue(live, "a poll marks the bridge live")

        let first = await hub.enqueueClaude(sessionId: "s-1", text: "run the tests")
        let second = await hub.enqueueClaude(sessionId: "s-1", text: "then commit")
        let other = await hub.enqueueClaude(sessionId: "s-2", text: "not yours")

        let taken = try call("GET", "/claude/poll?session=s-1", socket: socket)
        XCTAssertEqual(taken.status, 200)
        XCTAssertEqual(taken.json["id"] as? String, first)
        XCTAssertEqual(taken.json["text"] as? String, "run the tests")
        var delivery = await hub.delivery(of: first)
        XCTAssertEqual(delivery, .taken)

        XCTAssertEqual(try call("POST", "/claude/ack", json: ["id": first, "ok": true], socket: socket).status, 200)
        delivery = await hub.delivery(of: first)
        XCTAssertEqual(delivery, .submitted)

        XCTAssertEqual(try call("GET", "/claude/poll?session=s-1", socket: socket).json["id"] as? String, second)
        let failed = try call("POST", "/claude/ack", json: ["id": second, "ok": false, "error": "HooksError: refused"], socket: socket)
        XCTAssertEqual(failed.status, 200)
        delivery = await hub.delivery(of: second)
        XCTAssertEqual(delivery, .failed("HooksError: refused"))

        XCTAssertEqual(try call("GET", "/claude/poll?session=s-1", socket: socket).status, 204, "each item is handed out once")
        delivery = await hub.delivery(of: other)
        XCTAssertEqual(delivery, .pending, "other sessions' items stay queued")
    }

    func testPollDecodesPercentEncodedSession() async throws {
        let id = await hub.enqueueClaude(sessionId: "a b/c", text: "hi")
        let r = try call("GET", "/claude/poll?session=a%20b%2Fc", socket: socket)
        XCTAssertEqual(r.json["id"] as? String, id)
    }

    func testPollWithoutSessionIs400() throws {
        XCTAssertEqual(try call("GET", "/claude/poll", socket: socket).status, 400)
        XCTAssertEqual(try call("GET", "/claude/poll?session=", socket: socket).status, 400)
    }

    func testClaudeEvents() async throws {
        for kind in ["turn.start", "turn.complete", "session.end"] {
            let r = try call("POST", "/claude/event", json: ["sessionId": "s-1", "kind": kind], socket: socket)
            XCTAssertEqual(r.status, 200)
            let event = await hub.lastClaudeEvent(sessionId: "s-1")
            XCTAssertEqual(event?.kind, kind)
        }
        let live = await hub.isClaudeBridgeLive(sessionId: "s-1")
        XCTAssertFalse(live, "session.end stops the session counting as live")
        XCTAssertEqual(try call("POST", "/claude/event", json: ["sessionId": "s-1", "kind": "turn.maybe"], socket: socket).status, 400)
        XCTAssertEqual(try call("POST", "/claude/event", json: ["kind": "turn.start"], socket: socket).status, 400)
    }

    // MARK: Codex hooks

    func testCodexHookDecoding() async throws {
        let permission: [String: Any] = [
            "session_id": "019a-thread", "transcript_path": "/tmp/rollout.jsonl", "cwd": "/tmp/work",
            "hook_event_name": "PermissionRequest", "model": "gpt-5", "turn_id": "turn-1",
            "permission_mode": "default", "tool_name": "Bash",
            "tool_input": ["command": "touch x", "description": "Create a file"],
        ]
        XCTAssertEqual(try call("POST", "/codex/hook", json: permission, socket: socket).json["ok"] as? Bool, true)
        let stop: [String: Any] = [
            "session_id": "019a-thread", "cwd": "/tmp/work", "hook_event_name": "Stop",
            "last_assistant_message": "Done.", "stop_hook_active": false,
        ]
        XCTAssertEqual(try call("POST", "/codex/hook", json: stop, socket: socket).status, 200)

        let events = await hub.codexHookEvents(threadId: "019a-thread")
        XCTAssertEqual(events.map(\.event), ["PermissionRequest", "Stop"])
        XCTAssertEqual(events[0].threadId, "019a-thread")
        XCTAssertEqual(events[0].toolName, "Bash")
        XCTAssertEqual(events[0].cwd, "/tmp/work")
        XCTAssertNil(events[1].toolName)
        let seen = await hub.lastCodexHookAt
        XCTAssertNotNil(seen)
        let threads = await hub.codexThreadIdsWithHooks(since: Date().addingTimeInterval(-60))
        XCTAssertEqual(threads, ["019a-thread"])
    }

    func testCodexHookWithoutIdentityIs400() throws {
        XCTAssertEqual(try call("POST", "/codex/hook", json: ["hook_event_name": "Stop"], socket: socket).status, 400)
        XCTAssertEqual(try call("POST", "/codex/hook", json: ["session_id": "t"], socket: socket).status, 400)
        XCTAssertEqual(try call("POST", "/codex/hook", json: ["session_id": 7, "hook_event_name": "Stop"], socket: socket).status, 400)
    }

    // MARK: App API

    func testThreads() throws {
        let (status, data) = try XCTUnwrap(BridgeClient.request(method: "GET", path: "/api/threads", socketPath: socket))
        XCTAssertEqual(status, 200)
        struct Body: Decodable { let threads: [AgentThread] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(Body.self, from: data).threads, api.threads)
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let first = try XCTUnwrap((raw["threads"] as? [[String: Any]])?.first)
        XCTAssertEqual(first["updatedAt"] as? String, "2026-09-21T14:13:20Z")
    }

    func testMessages() throws {
        let r = try call("GET", "/api/messages?thread=claude:s-1&limit=3", socket: socket)
        XCTAssertEqual(r.status, 200)
        let messages = try XCTUnwrap(r.json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.map { $0["text"] as? String }, ["message 28", "message 29", "message 30"])
        XCTAssertEqual(try call("GET", "/api/messages?thread=claude:s-1", socket: socket).json["messages"].map { ($0 as? [Any])?.count }, 20)
        XCTAssertEqual(try call("GET", "/api/messages?thread=claude:s-1&limit=zero", socket: socket).status, 400)
        XCTAssertEqual(try call("GET", "/api/messages", socket: socket).status, 400)
    }

    func testSend() throws {
        let delivered = try call("POST", "/api/send", json: ["threadId": "claude:s-1", "text": "hello"], socket: socket)
        XCTAssertEqual(delivered.status, 200)
        XCTAssertEqual(delivered.json["message"] as? String, "Sent")
        XCTAssertNotNil((delivered.json["outcome"] as? [String: Any])?["delivered"])

        let queued = try call("POST", "/api/send", json: ["threadId": "codex:t-2", "text": "later"], socket: socket)
        XCTAssertEqual(queued.json["message"] as? String, "Runs when Codex is idle (up to ~10 s)")
        let outcome = try JSONSerialization.data(withJSONObject: try XCTUnwrap(queued.json["outcome"]))
        XCTAssertEqual(try JSONDecoder().decode(SendOutcome.self, from: outcome), .queued("Runs when Codex is idle (up to ~10 s)"))

        XCTAssertEqual(api.sent.map(\.0), ["claude:s-1", "codex:t-2"])
        XCTAssertEqual(try call("POST", "/api/send", json: ["text": "no thread"], socket: socket).status, 400)
    }

    func testOpen() throws {
        XCTAssertEqual(try call("POST", "/api/open", json: ["threadId": "codex:t-2"], socket: socket).json["ok"] as? Bool, true)
        XCTAssertEqual(try call("POST", "/api/open", json: ["threadId": "codex:gone"], socket: socket).json["ok"] as? Bool, false)
        XCTAssertEqual(api.opened, ["codex:t-2", "codex:gone"])
    }

    func testAPIRoutesWithoutAPIAre503() throws {
        let path = scratchSocketPath()
        let bare = BridgeServer(hub: hub, socketPath: path)
        try bare.start()
        defer { bare.stop() }
        XCTAssertEqual(try call("GET", "/api/threads", socket: path).status, 503)
        XCTAssertEqual(try call("POST", "/api/send", json: ["threadId": "x", "text": "y"], socket: path).status, 503)
        XCTAssertEqual(try call("GET", "/health", socket: path).status, 200)
    }

    // MARK: Malformed input

    func testMalformedJSONIs400() throws {
        let (status, data) = try XCTUnwrap(BridgeClient.request(
            method: "POST", path: "/claude/ack", body: Data("{not json".utf8), socketPath: socket))
        XCTAssertEqual(status, 400)
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testMalformedHTTPIs400() throws {
        let cases = [
            "GARBAGE\r\n\r\n",
            "GET /health\r\n\r\n",
            "get /health HTTP/1.1\r\n\r\n",
            "GET health HTTP/1.1\r\n\r\n",
            "GET /health HTTP/2\r\n\r\n",
            "GET /health HTTP/1.1\r\nno-colon-here\r\n\r\n",
            "POST /claude/ack HTTP/1.1\r\nContent-Length: -1\r\n\r\n",
            "POST /claude/ack HTTP/1.1\r\nContent-Length: 2\r\nContent-Length: 3\r\n\r\n{}",
            "POST /claude/ack HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n2\r\n{}\r\n0\r\n\r\n",
            "POST /claude/ack HTTP/1.1\r\nContent-Length: \(HTTPRequest.maxBodyBytes + 1)\r\n\r\n",
        ]
        for request in cases {
            let response = try XCTUnwrap(rawExchange(Array(request.utf8), socket: socket), request)
            XCTAssertTrue(response.hasPrefix("HTTP/1.1 400 Bad Request\r\n"), "\(request.debugDescription) → \(response)")
        }
    }

    func testOversizedHeadersAre400() throws {
        let request = "GET /health HTTP/1.1\r\nX-Pad: " + String(repeating: "a", count: HTTPRequest.maxHeaderBytes) + "\r\n\r\n"
        let response = try XCTUnwrap(rawExchange(Array(request.utf8), socket: socket))
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 400"), response)
    }

    func testBodyUpToOneMiBIsAccepted() async throws {
        let text = String(repeating: "x", count: HTTPRequest.maxBodyBytes - 64)
        let body = try JSONSerialization.data(withJSONObject: ["session_id": "big", "hook_event_name": "Stop", "pad": text])
        XCTAssertLessThanOrEqual(body.count, HTTPRequest.maxBodyBytes)
        let (status, _) = try XCTUnwrap(BridgeClient.request(method: "POST", path: "/codex/hook", body: body, socketPath: socket))
        XCTAssertEqual(status, 200)
        let events = await hub.codexHookEvents(threadId: "big")
        XCTAssertEqual(events.count, 1)
    }

    func testRequestSplitAcrossWrites() throws {
        guard let address = UnixSocket.address(socket), let fd = UnixSocket.makeStream() else { return XCTFail("socket") }
        defer { close(fd) }
        XCTAssertTrue(UnixSocket.connect(fd, address))
        let body = #"{"sessionId":"s-9","kind":"turn.start"}"#
        let request = "POST /claude/event HTTP/1.1\r\nContent-Length: \(body.utf8.count)\r\n\r\n" + body
        for byte in request.utf8 {
            XCTAssertTrue(UnixSocket.writeAll(fd, [byte]))
        }
        var chunk = [UInt8](repeating: 0, count: 1024)
        let n = read(fd, &chunk, chunk.count)
        XCTAssertTrue(String(decoding: chunk[0..<max(n, 0)], as: UTF8.self).hasPrefix("HTTP/1.1 200 OK"))
    }

    // MARK: Concurrency

    func testManyConcurrentConnections() async throws {
        // Clients block, so each gets its own thread: in-process they must not starve GCD or the task pool.
        let socket = socket
        let statuses = await withCheckedContinuation { continuation in
            let group = DispatchGroup()
            let lock = NSLock()
            var all: [Int?] = []
            for i in 0..<200 {
                group.enter()
                Thread.detachNewThread {
                    let path = i % 2 == 0 ? "/health" : "/claude/poll?session=c-\(i)"
                    let status = BridgeClient.request(method: "GET", path: path, socketPath: socket, timeout: 10)?.0
                    lock.withLock { all.append(status) }
                    group.leave()
                }
            }
            group.notify(queue: .global()) { continuation.resume(returning: all) }
        }
        XCTAssertEqual(statuses.filter { $0 == 200 }.count, 100)
        XCTAssertEqual(statuses.filter { $0 == 204 }.count, 100)
        let live = await hub.liveClaudeSessionCount
        XCTAssertEqual(live, 100)
    }

    func testStalledClientDoesNotBlockOthers() throws {
        guard let address = UnixSocket.address(socket), let fd = UnixSocket.makeStream() else { return XCTFail("socket") }
        defer { close(fd) }
        XCTAssertTrue(UnixSocket.connect(fd, address))
        XCTAssertTrue(UnixSocket.writeAll(fd, Array("GET /health HTTP/1.1\r\nHost: x\r\n".utf8)))
        let started = Date()
        XCTAssertEqual(try call("GET", "/health", socket: socket).status, 200)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    // MARK: Lifecycle

    func testSecondServerOnSamePathIsAlreadyRunning() throws {
        let second = BridgeServer(hub: BridgeHub(), socketPath: socket)
        XCTAssertThrowsError(try second.start()) { XCTAssertEqual($0 as? BridgeServer.StartError, .alreadyRunning) }
        second.stop()
        XCTAssertEqual(try call("GET", "/health", socket: socket).status, 200, "a failed start must not unlink the live socket")
    }

    func testStaleSocketIsReplaced() throws {
        server?.stop()
        // A socket file left behind by a crashed app: bound, then closed without unlinking.
        let fd = try XCTUnwrap(UnixSocket.makeStream())
        XCTAssertTrue(UnixSocket.bind(fd, try XCTUnwrap(UnixSocket.address(socket))))
        close(fd)
        XCTAssertTrue(FileManager.default.fileExists(atPath: socket))
        XCTAssertNil(BridgeClient.request(method: "GET", path: "/health", socketPath: socket, timeout: 1))

        let fresh = BridgeServer(hub: hub, socketPath: socket)
        try fresh.start()
        server = fresh
        XCTAssertEqual(try call("GET", "/health", socket: socket).status, 200)
    }

    func testLeftoverRegularFileIsReplaced() throws {
        server?.stop()
        XCTAssertTrue(FileManager.default.createFile(atPath: socket, contents: Data("junk".utf8)))
        let fresh = BridgeServer(hub: hub, socketPath: socket)
        try fresh.start()
        server = fresh
        XCTAssertEqual(try call("GET", "/health", socket: socket).status, 200)
    }

    func testStopAndRestart() throws {
        server?.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: socket))
        XCTAssertNil(BridgeClient.request(method: "GET", path: "/health", socketPath: socket, timeout: 1))
        server?.stop()
        try server?.start()
        XCTAssertEqual(try call("GET", "/health", socket: socket).status, 200)
    }

    func testPathTooLongIsRejected() {
        let long = "/tmp/" + String(repeating: "x", count: 120) + ".sock"
        XCTAssertThrowsError(try BridgeServer(hub: hub, socketPath: long).start()) {
            XCTAssertEqual($0 as? BridgeServer.StartError, .invalidPath)
        }
    }
}
