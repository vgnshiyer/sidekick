import Foundation

/// One parsed HTTP/1.x request. Only what the bridge needs: no chunked bodies, no keep-alive.
struct HTTPRequest: Sendable {
    var method: String
    /// The path without the query, e.g. `/claude/poll`.
    var path: String
    /// Percent-decoded query items; the first value wins for a repeated name.
    var query: [String: String]
    /// Header values keyed by lower-cased name.
    var headers: [String: String]
    var body: Data

    static let maxHeaderBytes = 16 * 1024
    static let maxBodyBytes = 1024 * 1024

    enum ParseResult: Sendable {
        case incomplete
        case invalid(String)
        case complete(HTTPRequest)
    }

    /// Parse the bytes received so far.
    static func parse(_ data: Data) -> ParseResult {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerEnd = data.range(of: separator) else {
            return data.count > maxHeaderBytes ? .invalid("header section too large") : .incomplete
        }
        guard headerEnd.lowerBound - data.startIndex <= maxHeaderBytes else { return .invalid("header section too large") }
        guard let head = String(data: data[data.startIndex..<headerEnd.lowerBound], encoding: .utf8) else {
            return .invalid("header section is not UTF-8")
        }

        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: false)
        guard requestLine.count == 3,
              let method = requestLine.first, !method.isEmpty, method.allSatisfy({ $0.isASCII && $0.isUppercase }),
              requestLine[1].hasPrefix("/"),
              requestLine[2] == "HTTP/1.1" || requestLine[2] == "HTTP/1.0",
              let url = URLComponents(string: "http://sidekick" + requestLine[1])
        else { return .invalid("malformed request line") }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex,
                  !line.hasPrefix(" "), !line.hasPrefix("\t")
            else { return .invalid("malformed header") }
            let name = line[..<colon].lowercased()
            guard !name.contains(where: { $0 == " " || $0 == "\t" }) else { return .invalid("malformed header") }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if let previous = headers[name] {
                if name == "content-length" && previous != value { return .invalid("conflicting Content-Length") }
            } else {
                headers[name] = value
            }
        }
        guard headers["transfer-encoding"] == nil else { return .invalid("Transfer-Encoding is not supported") }

        var length = 0
        if let value = headers["content-length"] {
            guard (1...8).contains(value.utf8.count), value.utf8.allSatisfy({ (48...57).contains($0) }),
                  let n = Int(value)
            else { return .invalid("malformed Content-Length") }
            guard n <= maxBodyBytes else { return .invalid("body larger than 1 MiB") }
            length = n
        }
        let bodyStart = headerEnd.upperBound
        guard data.endIndex - bodyStart >= length else { return .incomplete }

        var query: [String: String] = [:]
        for item in url.queryItems ?? [] where query[item.name] == nil {
            query[item.name] = item.value ?? ""
        }
        return .complete(HTTPRequest(
            method: String(method),
            path: url.percentEncodedPath,
            query: query,
            headers: headers,
            body: Data(data[bodyStart..<bodyStart + length])))
    }
}

/// A response the bridge sends before closing the connection.
struct HTTPResponse: Sendable, Equatable {
    var status: Int
    /// JSON body; nil sends no body (204).
    var body: Data?

    static let noContent = HTTPResponse(status: 204, body: nil)

    /// A JSON response; dates are ISO-8601.
    static func json<T: Encodable>(_ value: T, status: Int = 200) -> HTTPResponse {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else {
            return HTTPResponse(status: 500, body: Data(#"{"error":"encoding failed"}"#.utf8))
        }
        return HTTPResponse(status: status, body: data)
    }

    /// `{"error": message}` with the given status.
    static func error(_ status: Int, _ message: String) -> HTTPResponse {
        json(["error": message], status: status)
    }

    /// Wire bytes, always with `Connection: close`.
    func serialized() -> [UInt8] {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\nConnection: close\r\n"
        if let body {
            head += "Content-Type: application/json\r\nContent-Length: \(body.count)\r\n"
        }
        head += "\r\n"
        return Array(head.utf8) + (body.map { Array($0) } ?? [])
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 503: return "Service Unavailable"
        default: return "Internal Server Error"
        }
    }
}
