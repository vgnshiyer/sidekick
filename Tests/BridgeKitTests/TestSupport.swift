import Foundation
import SidekickCore
import XCTest
@testable import BridgeKit

/// A short, unique socket path (sun_path is 104 bytes at most).
func scratchSocketPath() -> String {
    "/tmp/sk-\(UUID().uuidString.prefix(8).lowercased()).sock"
}

/// One request through `BridgeClient`, with the body decoded as a JSON object when there is one.
func call(_ method: String, _ path: String, json: Any? = nil, socket: String,
          file: StaticString = #filePath, line: UInt = #line) throws -> (status: Int, json: [String: Any]) {
    let body = try json.map { try JSONSerialization.data(withJSONObject: $0) }
    let (status, data) = try XCTUnwrap(
        BridgeClient.request(method: method, path: path, body: body, socketPath: socket, timeout: 5),
        "no response for \(method) \(path)", file: file, line: line)
    let object = data.isEmpty ? [:] : try XCTUnwrap(
        JSONSerialization.jsonObject(with: data) as? [String: Any], file: file, line: line)
    return (status, object)
}

/// Write raw bytes to the socket and return everything the server sends back before closing.
func rawExchange(_ bytes: [UInt8], socket: String, timeout: TimeInterval = 5) -> String? {
    guard let address = UnixSocket.address(socket), let fd = UnixSocket.makeStream() else { return nil }
    defer { close(fd) }
    guard UnixSocket.connect(fd, address), UnixSocket.writeAll(fd, bytes) else { return nil }
    var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    var out = [UInt8]()
    var chunk = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = read(fd, &chunk, chunk.count)
        if n <= 0 { break }
        out += chunk[0..<n]
    }
    return String(decoding: out, as: UTF8.self)
}

/// A `SidekickAPI` with canned threads that records what it was asked to do.
final class FakeAPI: SidekickAPI, @unchecked Sendable {
    static let date = Date(timeIntervalSince1970: 1_790_000_000)

    let threads = [
        AgentThread(platform: .claude, nativeId: "s-1", surface: .terminal, title: "Fix the build",
                    status: .running, cwd: "/tmp/work", updatedAt: date, lastTurnEndedAt: date),
        AgentThread(platform: .codex, nativeId: "t-2", surface: .desktop, title: "Write docs",
                    status: .needsInput, detail: "Needs permission", updatedAt: date),
    ]
    private let lock = NSLock()
    private var _sent: [(String, String)] = []
    private var _opened: [String] = []

    var sent: [(String, String)] { lock.withLock { _sent } }
    var opened: [String] { lock.withLock { _opened } }

    func apiThreads() async -> [AgentThread] { threads }

    func apiMessages(threadId: String, limit: Int) async -> [ChatMessage] {
        let all = (1...30).map {
            ChatMessage(id: "\(threadId)-\($0)", role: $0 % 2 == 0 ? .assistant : .user, text: "message \($0)", date: Self.date)
        }
        return Array(all.suffix(limit))
    }

    func apiSend(threadId: String, text: String) async -> SendOutcome {
        lock.withLock { _sent.append((threadId, text)) }
        return threadId == "codex:t-2" ? .queued("Runs when Codex is idle (up to ~10 s)") : .delivered
    }

    func apiOpen(threadId: String) async -> Bool {
        lock.withLock { _opened.append(threadId) }
        return threads.contains { $0.id == threadId }
    }
}
