import ClaudeKit
import CodexKit
import Foundation
import SidekickCore

// sidekick-cli — inspect threads without the app; send/open through the running app.
//
//   sidekick-cli list [--json]
//   sidekick-cli messages <threadId> [--limit N]
//   sidekick-cli send <threadId> <text...>     (needs Sidekick running)
//   sidekick-cli open <threadId>               (needs Sidekick running)

let usage = """
usage: sidekick-cli list [--json]
       sidekick-cli messages <threadId> [--limit N]
       sidekick-cli send <threadId> <text...>
       sidekick-cli open <threadId>
"""

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
    exit(1)
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { fail(usage) }

let providers: [ThreadProvider] = [ClaudeProvider(), CodexProvider()]
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
encoder.dateEncodingStrategy = .iso8601

func snapshotAll() async -> [AgentThread] {
    var all: [AgentThread] = []
    for p in providers { all += await p.snapshot() }
    return all.sorted {
        $0.status.rank != $1.status.rank ? $0.status.rank < $1.status.rank : $0.updatedAt > $1.updatedAt
    }
}

func pad(_ s: String, _ n: Int) -> String {
    let c = s.count
    return c >= n ? String(s.prefix(n - 1)) + "…" : s + String(repeating: " ", count: n - c)
}

/// Call the running app over the bridge socket (BridgeKit is not linked here; plain BSD sockets).
func callApp(_ method: String, _ path: String, _ body: [String: Any]?) -> (Int, [String: Any])? {
    let sockPath = Paths.socketPath
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(sockPath.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
    withUnsafeMutableBytes(of: &addr.sun_path) { buf in
        for (i, b) in bytes.enumerated() { buf[i] = b }
    }
    let ok = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
        }
    }
    guard ok else { return nil }
    var tv = timeval(tv_sec: 30, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    let payload = body.flatMap { try? JSONSerialization.data(withJSONObject: $0) } ?? Data()
    var req = "\(method) \(path) HTTP/1.1\r\nHost: sidekick\r\nConnection: close\r\n"
    req += "Content-Type: application/json\r\nContent-Length: \(payload.count)\r\n\r\n"
    let data = Data(req.utf8) + payload
    _ = data.withUnsafeBytes { write(fd, $0.baseAddress, data.count) }
    var resp = Data()
    var buf = [UInt8](repeating: 0, count: 65536)
    while true {
        let n = read(fd, &buf, buf.count)
        if n <= 0 { break }
        resp.append(buf, count: n)
    }
    guard let sep = resp.range(of: Data("\r\n\r\n".utf8)) else { return nil }
    let head = String(decoding: resp[..<sep.lowerBound], as: UTF8.self)
    let status = Int(head.split(separator: " ").dropFirst().first ?? "") ?? 0
    let json = (try? JSONSerialization.jsonObject(with: resp[sep.upperBound...])) as? [String: Any] ?? [:]
    return (status, json)
}

switch command {
case "list":
    let threads = await snapshotAll()
    if args.contains("--json") {
        print(String(decoding: try encoder.encode(threads), as: UTF8.self))
    } else if threads.isEmpty {
        print("No active threads.")
    } else {
        for t in threads {
            let where_ = [t.platform.displayName, t.surface.displayName].joined(separator: "/")
            print("\(pad(t.status.label, 12)) \(pad(where_, 20)) \(pad(t.title, 44)) \(t.id)")
            if let d = t.detail ?? t.subtitle { print(String(repeating: " ", count: 13) + "↳ " + d.prefix(100)) }
        }
    }

case "messages":
    guard args.count >= 2 else { fail(usage) }
    var limit = 20
    if let i = args.firstIndex(of: "--limit"), i + 1 < args.count, let n = Int(args[i + 1]) { limit = n }
    let threads = await snapshotAll()
    guard let t = threads.first(where: { $0.id == args[1] || $0.nativeId == args[1] }) else { fail("Unknown thread \(args[1])") }
    let p = providers.first { $0.platform == t.platform }!
    for m in await p.messages(for: t, limit: limit) {
        print("[\(m.role.rawValue)] \(m.text)\n")
    }

case "send":
    guard args.count >= 3 else { fail(usage) }
    let text = args.dropFirst(2).joined(separator: " ")
    guard let (status, json) = callApp("POST", "/api/send", ["threadId": args[1], "text": text]) else {
        fail("Sidekick isn't running (no bridge at \(Paths.socketPath)).")
    }
    print(status == 200 ? (json["message"] as? String ?? "ok") : "error \(status): \(json)")

case "open":
    guard args.count >= 2 else { fail(usage) }
    guard let (status, json) = callApp("POST", "/api/open", ["threadId": args[1]]) else {
        fail("Sidekick isn't running (no bridge at \(Paths.socketPath)).")
    }
    if status != 200 {
        print("error \(status): \(json)")
    } else {
        print(json["ok"] as? Bool == true ? "opened" : "couldn't open \(args[1])")
    }

default:
    fail(usage)
}
