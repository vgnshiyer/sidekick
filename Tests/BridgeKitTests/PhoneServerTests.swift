import Foundation
import SidekickCore
import XCTest
@testable import BridgeKit

final class PhoneServerTests: XCTestCase {
    private let key = "k3yK3yk3yK3yk3yK3yk3yA"
    private var api: FakeAPI!
    private var server: PhoneServer!

    override func setUp() {
        api = FakeAPI()
        server = PhoneServer(api: api, key: key, port: 47900)
        server.update(assets: PhoneAssets(
            html: Data("<html>pet</html>".utf8), serviceWorker: Data("// sw".utf8), appIcon: Data([1]), petSheet: Data([2]), petId: "cat",
            petName: "Cat", badges: ["claude": Data([3])], macName: "Test Mac"))
    }

    private func get(_ path: String, query: [String: String] = [:]) async -> HTTPResponse {
        await server.respond(to: HTTPRequest(method: "GET", path: path, query: query, headers: [:], body: Data()))
    }

    private func post(_ path: String, _ json: [String: Any]) async throws -> HTTPResponse {
        let body = try JSONSerialization.data(withJSONObject: json)
        return await server.respond(to: HTTPRequest(method: "POST", path: path, query: [:], headers: [:], body: body))
    }

    private func object(_ response: HTTPResponse) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(response.body)) as? [String: Any])
    }

    func testWrongOrMissingKeyIsNotFound() async {
        for path in ["/", "/p/", "/p/wrong/", "/p/\(key)x/", "/p/\(key.dropLast())/api/threads", "/api/threads"] {
            let response = await get(path)
            XCTAssertEqual(response.status, 404, path)
        }
    }

    func testPageAndAssets() async throws {
        let redirect = await get("/p/\(key)")
        XCTAssertEqual(redirect.status, 301)
        XCTAssertEqual(redirect.headers["Location"], "/p/\(key)/")

        let page = await get("/p/\(key)/")
        XCTAssertEqual(page.status, 200)
        XCTAssertEqual(page.contentType, "text/html; charset=utf-8")
        XCTAssertEqual(page.headers["Referrer-Policy"], "no-referrer")
        XCTAssertEqual(page.body, Data("<html>pet</html>".utf8))

        let pet = await get("/p/\(key)/pet.png")
        XCTAssertEqual(pet.contentType, "image/png")
        let badge = await get("/p/\(key)/badge/claude.png")
        XCTAssertEqual(badge.body, Data([3]))
        let missingBadge = await get("/p/\(key)/badge/codex.png")
        XCTAssertEqual(missingBadge.status, 404)
        let manifest = try object(await get("/p/\(key)/manifest.webmanifest"))
        XCTAssertEqual(manifest["start_url"] as? String, "./")
    }

    func testThreadsMessagesSendOpen() async throws {
        let status = try object(await get("/p/\(key)/api/threads"))
        XCTAssertEqual((status["threads"] as? [Any])?.count, 2)
        XCTAssertEqual(status["mac"] as? String, "Test Mac")
        XCTAssertEqual((status["pet"] as? [String: Any])?["id"] as? String, "cat")

        let missing = await get("/p/\(key)/api/messages")
        XCTAssertEqual(missing.status, 400)
        let messages = try object(await get("/p/\(key)/api/messages", query: ["thread": "claude:s-1", "limit": "5"]))
        XCTAssertEqual((messages["messages"] as? [Any])?.count, 5)

        let sent = try object(try await post("/p/\(key)/api/send", ["threadId": "claude:s-1", "text": "hi"]))
        XCTAssertNotNil(sent["message"])
        XCTAssertEqual(api.sent.first?.1, "hi")

        let opened = try object(try await post("/p/\(key)/api/open", ["threadId": "claude:s-1"]))
        XCTAssertEqual(opened["ok"] as? Bool, true)

        let empty = try await post("/p/\(key)/api/send", ["threadId": "claude:s-1", "text": ""])
        XCTAssertEqual(empty.status, 400)
    }

    func testOnlyLoopbackPeers() {
        func peer(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) -> sockaddr_storage {
            var storage = sockaddr_storage()
            withUnsafeMutablePointer(to: &storage) {
                $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    $0.pointee.sin_family = sa_family_t(AF_INET)
                    $0.pointee.sin_addr.s_addr = (UInt32(a) << 24 | UInt32(b) << 16 | UInt32(c) << 8 | UInt32(d)).bigEndian
                }
            }
            return storage
        }
        XCTAssertTrue(PhoneServer.isLoopback(peer(127, 0, 0, 1)))
        XCTAssertFalse(PhoneServer.isLoopback(peer(10, 0, 0, 169)))
        XCTAssertFalse(PhoneServer.isLoopback(peer(100, 101, 1, 1)))
        XCTAssertFalse(PhoneServer.isLoopback(peer(192, 168, 1, 4)))
    }

    func testPortInUseIsReported() throws {
        try server.start()
        defer { server.stop() }
        let second = PhoneServer(api: api, key: key, port: server.port)
        XCTAssertThrowsError(try second.start()) { error in
            XCTAssertEqual(error as? PhoneServer.StartError, .portInUse(server.port))
        }
    }

    func testListensAndAnswersOverTCP() throws {
        try server.start()
        defer { server.stop() }
        let port = server.port
        XCTAssertEqual(port, 47900)
        let done = expectation(description: "response")
        var status = 0
        URLSession.shared.dataTask(with: URL(string: "http://127.0.0.1:\(port)/p/\(key)/api/threads")!) { _, response, _ in
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 5)
        XCTAssertEqual(status, 200)
    }

    func testRetryWithTheSameClientIdSendsOnce() async throws {
        let body: [String: Any] = ["threadId": "claude:s-1", "text": "once", "clientId": "abc-123"]
        async let first = post("/p/\(key)/api/send", body)
        async let second = post("/p/\(key)/api/send", body)
        _ = try await (first, second)
        _ = try await post("/p/\(key)/api/send", body)
        XCTAssertEqual(api.sent.filter { $0.1 == "once" }.count, 1)

        _ = try await post("/p/\(key)/api/send", ["threadId": "claude:s-1", "text": "once", "clientId": "other"])
        XCTAssertEqual(api.sent.filter { $0.1 == "once" }.count, 2)
    }

    func testConstantTimeEqual() {
        XCTAssertTrue(PhoneServer.equal("abc", "abc"))
        XCTAssertFalse(PhoneServer.equal("abc", "abd"))
        XCTAssertFalse(PhoneServer.equal("abc", "abcd"))
    }
}
