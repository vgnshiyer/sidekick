import Foundation
import SidekickCore

/// Client used by `sidekick-cli` and tests to call a running Sidekick app.
public enum BridgeClient {
    /// Perform one request against the bridge socket. Returns (status, body) or nil if unreachable,
    /// if the response is malformed, or if no full response arrives within `timeout` seconds.
    public static func request(method: String, path: String, body: Data? = nil,
                               socketPath: String = Paths.socketPath, timeout: TimeInterval = 20) -> (Int, Data)? {
        guard let address = UnixSocket.address(socketPath), let fd = UnixSocket.makeStream() else { return nil }
        defer { close(fd) }
        guard UnixSocket.connect(fd, address) else { return nil }

        let deadline = Date().addingTimeInterval(timeout)
        var head = "\(method) \(path) HTTP/1.1\r\nHost: sidekick\r\nConnection: close\r\n"
        if let body {
            head += "Content-Type: application/json\r\nContent-Length: \(body.count)\r\n"
        }
        head += "\r\n"
        UnixSocket.setSendTimeout(fd, max(timeout, 0.001))
        guard UnixSocket.writeAll(fd, Array(head.utf8) + (body.map { Array($0) } ?? [])) else { return nil }

        var response = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return nil }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, Int32(min(remaining * 1000, Double(Int32.max)).rounded(.up)))
            if ready < 0 && errno == EINTR { continue }
            guard ready > 0 else { return nil }
            let n = read(fd, &chunk, chunk.count)
            if n < 0 && errno == EINTR { continue }
            guard n >= 0 else { return nil }
            if n == 0 { break }
            response.append(contentsOf: chunk[0..<n])
        }
        return parse(response)
    }

    /// Split a full `Connection: close` response into status and body (honouring Content-Length when present).
    static func parse(_ response: Data) -> (Int, Data)? {
        guard let separator = response.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: response[..<separator.lowerBound], encoding: .utf8)
        else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let statusLine = lines[0].split(separator: " ")
        guard statusLine.count >= 2, statusLine[0].hasPrefix("HTTP/1."), let status = Int(statusLine[1]) else { return nil }

        var body = Data(response[separator.upperBound...])
        let lengthLine = lines.dropFirst().first { $0.lowercased().hasPrefix("content-length:") }
        if let lengthLine, let length = Int(lengthLine.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) {
            guard body.count >= length else { return nil }
            body = body.prefix(length)
        }
        return (status, body)
    }
}
