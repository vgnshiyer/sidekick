import Foundation
import SidekickCore

/// What the phone page is served from; the app refreshes it when the pet changes.
public struct PhoneAssets: Sendable {
    /// The single-page app.
    public var html: Data
    /// Its service worker, which shows push notifications.
    public var serviceWorker: Data
    /// Home-screen icon (PNG, 180x180).
    public var appIcon: Data?
    /// The selected pet's atlas (PNG) and its identity, so the page can reload it on a change.
    public var petSheet: Data?
    public var petId: String
    public var petName: String
    /// Platform logos as PNG, keyed by `Platform.rawValue`.
    public var badges: [String: Data]
    /// How the page names this Mac.
    public var macName: String

    public init(html: Data, serviceWorker: Data, appIcon: Data?, petSheet: Data?, petId: String, petName: String,
                badges: [String: Data], macName: String) {
        self.html = html
        self.serviceWorker = serviceWorker
        self.appIcon = appIcon
        self.petSheet = petSheet
        self.petId = petId
        self.petName = petName
        self.badges = badges
        self.macName = macName
    }
}

/// HTTP for the phone page, reachable only through Tailscale.
///
/// The server listens on 127.0.0.1 alone, so nothing on the Wi-Fi or any other network can reach it.
/// `tailscale serve` is the only way in: it terminates HTTPS for devices on the user's tailnet and
/// forwards to this port. Everything lives under `/p/<key>/`, where the key is a 128-bit secret that
/// only reaches the phone through the pairing QR code; a home-screen web app keeps its start URL, so
/// the key travels with it without cookies. Anything without the right key is a plain 404.
public final class PhoneServer: @unchecked Sendable {
    public enum StartError: Error, Equatable {
        /// Another process has the port; `tailscale serve` points at this exact port, so there is no fallback.
        case portInUse(UInt16)
        case system(call: String, errno: Int32)
    }

    private let api: SidekickAPI
    private let push: PushCenter?
    private let key: String
    private let preferredPort: UInt16
    private let acceptQueue = DispatchQueue(label: "sidekick.phone.accept")
    private let workQueue = DispatchQueue(label: "sidekick.phone.work", attributes: .concurrent)
    private let lock = NSLock()
    private var listener: DispatchSourceRead?
    private var connections: [ObjectIdentifier: BridgeConnection] = [:]
    private var assets: PhoneAssets?
    private var boundPort: UInt16 = 0

    public init(api: SidekickAPI, key: String, port: UInt16, push: PushCenter? = nil) {
        self.api = api
        self.push = push
        self.key = key
        self.preferredPort = port
    }

    deinit {
        stop()
    }

    /// The port listened on, 0 when stopped.
    public var port: UInt16 {
        lock.lock()
        defer { lock.unlock() }
        return boundPort
    }

    private func currentAssets() -> PhoneAssets? {
        lock.withLock { assets }
    }

    public func update(assets: PhoneAssets) {
        lock.lock()
        self.assets = assets
        lock.unlock()
    }

    /// Listen on 127.0.0.1 at the fixed port.
    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard listener == nil else { return }

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw StartError.system(call: "socket", errno: errno) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = preferredPort.bigEndian
        address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        guard bound else {
            let code = errno
            close(fd)
            throw code == EADDRINUSE ? StartError.portInUse(preferredPort) : StartError.system(call: "bind", errno: code)
        }
        guard listen(fd, 64) == 0 else {
            let code = errno
            close(fd)
            throw StartError.system(call: "listen", errno: code)
        }
        UnixSocket.setNonBlocking(fd, true)
        boundPort = preferredPort

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        source.setEventHandler { [weak self] in self?.acceptPending(fd) }
        source.setCancelHandler { close(fd) }
        listener = source
        source.resume()
    }

    public func stop() {
        lock.lock()
        guard let source = listener else {
            lock.unlock()
            return
        }
        listener = nil
        boundPort = 0
        let open = Array(connections.values)
        connections.removeAll()
        lock.unlock()
        source.cancel()
        open.forEach { $0.cancel() }
    }

    private func acceptPending(_ fd: Int32) {
        while true {
            var storage = sockaddr_storage()
            var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let client = withUnsafeMutablePointer(to: &storage) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(fd, $0, &length) }
            }
            if client < 0 {
                if errno == EINTR || errno == ECONNABORTED { continue }
                return
            }
            guard Self.isLoopback(storage) else {
                close(client)
                continue
            }
            UnixSocket.configure(client)
            UnixSocket.setNonBlocking(client, true)
            lock.lock()
            guard listener != nil else {
                lock.unlock()
                close(client)
                return
            }
            let connection = BridgeConnection(
                fd: client,
                queue: DispatchQueue(label: "sidekick.phone.connection", target: workQueue),
                handler: { [weak self] request in
                    await self?.respond(to: request) ?? .error(503, "stopped")
                }
            ) { [weak self] in self?.forget($0) }
            connections[ObjectIdentifier(connection)] = connection
            lock.unlock()
            connection.start()
        }
    }

    private func forget(_ connection: BridgeConnection) {
        lock.lock()
        connections[ObjectIdentifier(connection)] = nil
        lock.unlock()
    }

    // MARK: routes

    private static let pageHeaders = [
        "Cache-Control": "no-store",
        "Referrer-Policy": "no-referrer",
        "X-Content-Type-Options": "nosniff",
        "X-Frame-Options": "DENY",
        "Content-Security-Policy":
            "default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'",
    ]

    private static let notFound = HTTPResponse(
        status: 404, body: Data("Not found".utf8), contentType: "text/plain; charset=utf-8")

    func respond(to request: HTTPRequest) async -> HTTPResponse {
        // /p/<key>/<rest>
        let parts = request.path.split(separator: "/", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 3, parts[0].isEmpty, parts[1] == "p", Self.equal(String(parts[2].prefix(while: { $0 != "/" })), key)
        else { return Self.notFound }
        let afterKey = parts.count == 3 ? String(parts[2].drop(while: { $0 != "/" })) : ""
        let route = afterKey.hasPrefix("/") ? String(afterKey.dropFirst()) : afterKey
        guard route != "" || request.path.hasSuffix("/") else {
            // Relative URLs in the page need the trailing slash.
            return HTTPResponse(status: 301, body: nil, headers: ["Location": request.path + "/"])
        }

        guard let assets = currentAssets() else { return .error(503, "starting") }

        var response: HTTPResponse
        switch (request.method, route) {
        case ("GET", ""):
            response = .data(assets.html, contentType: "text/html; charset=utf-8")
        case ("GET", "manifest.webmanifest"):
            let manifest: [String: Any] = [
                "name": "Sidekick", "short_name": "Sidekick", "start_url": "./", "scope": "./",
                "display": "standalone", "background_color": "#3E44B2", "theme_color": "#F2F2F7",
                "icons": [["src": "icon.png", "sizes": "180x180", "type": "image/png"]],
            ]
            let data = (try? JSONSerialization.data(withJSONObject: manifest)) ?? Data()
            response = .data(data, contentType: "application/manifest+json")
        case ("GET", "sw.js"):
            response = .data(assets.serviceWorker, contentType: "text/javascript; charset=utf-8")
        case ("GET", "api/push/key"):
            guard let push else { return Self.notFound }
            response = .json(["key": push.publicKey])
        case ("POST", "api/push/subscribe"):
            guard let push else { return Self.notFound }
            guard let subscription = try? JSONDecoder().decode(WebPush.Subscription.self, from: request.body)
            else { return .error(400, "a push subscription is required") }
            guard await push.subscribe(subscription) else { return .error(400, "not a push service endpoint") }
            // A first notification right away, so the user sees it works.
            Task { await push.send(PushNotification(title: "Sidekick", body: "Notifications are on", threadId: "", urgent: false)) }
            response = .json(["ok": true])
        case ("POST", "api/push/unsubscribe"):
            guard let push else { return Self.notFound }
            guard let body = try? JSONDecoder().decode(UnsubscribeBody.self, from: request.body)
            else { return .error(400, "endpoint is required") }
            await push.unsubscribe(endpoint: body.endpoint)
            response = .json(["ok": true])
        case ("GET", "icon.png"):
            guard let icon = assets.appIcon else { return Self.notFound }
            response = .data(icon, contentType: "image/png")
        case ("GET", "pet.png"):
            guard let sheet = assets.petSheet else { return Self.notFound }
            response = .data(sheet, contentType: "image/png")
        case ("GET", let path) where path.hasPrefix("badge/") && path.hasSuffix(".png"):
            let name = String(path.dropFirst("badge/".count).dropLast(".png".count))
            guard let badge = assets.badges[name] else { return Self.notFound }
            response = .data(badge, contentType: "image/png")
        case ("GET", "api/threads"):
            response = .json(PhoneStatus(
                threads: await api.apiThreads(), mac: assets.macName,
                pet: .init(id: assets.petId, name: assets.petName)))
        case ("GET", "api/messages"):
            guard let thread = request.query["thread"], !thread.isEmpty else { return .error(400, "thread is required") }
            let limit = request.query["limit"].flatMap(Int.init).map { min(max($0, 1), 100) } ?? 30
            response = .json(["messages": await api.apiMessages(threadId: thread, limit: limit)])
        case ("POST", "api/send"):
            guard let body = try? JSONDecoder().decode(SendBody.self, from: request.body),
                  !body.threadId.isEmpty, !body.text.isEmpty
            else { return .error(400, "threadId and text are required") }
            let outcome = await send(body)
            response = .json(SendReply(outcome: outcome, message: outcome.message))
        case ("POST", "api/open"):
            guard let body = try? JSONDecoder().decode(OpenBody.self, from: request.body), !body.threadId.isEmpty
            else { return .error(400, "threadId is required") }
            response = .json(["ok": await api.apiOpen(threadId: body.threadId)])
        default:
            return Self.notFound
        }
        response.headers.merge(Self.pageHeaders) { current, _ in current }
        return response
    }

    private struct PhoneStatus: Encodable {
        struct Pet: Encodable { let id: String; let name: String }
        let threads: [AgentThread]
        let mac: String
        let pet: Pet
    }

    private struct SendBody: Decodable {
        let threadId: String
        let text: String
        /// Set by the page per message, so a retry after a lost response can't send it twice.
        let clientId: String?
    }

    /// Sends in flight or done recently, by the page's message id.
    private var sends: [String: (task: Task<SendOutcome, Never>, at: Date)] = [:]

    /// Deliver once per `clientId`: a retry joins the first attempt, or gets its result.
    private func send(_ body: SendBody) async -> SendOutcome {
        let api = api
        guard let clientId = body.clientId, !clientId.isEmpty, clientId.count <= 64 else {
            return await api.apiSend(threadId: body.threadId, text: body.text)
        }
        let task: Task<SendOutcome, Never> = lock.withLock {
            let cutoff = Date().addingTimeInterval(-600)
            sends = sends.filter { $0.value.at > cutoff }
            if let existing = sends[clientId] { return existing.task }
            let task = Task { await api.apiSend(threadId: body.threadId, text: body.text) }
            sends[clientId] = (task, Date())
            return task
        }
        let outcome = await task.value
        // Only a send that went somewhere is remembered; a failed one may be retried for real.
        if case .failed = outcome { lock.withLock { _ = sends.removeValue(forKey: clientId) } }
        return outcome
    }
    private struct OpenBody: Decodable { let threadId: String }
    private struct UnsubscribeBody: Decodable { let endpoint: String }
    private struct SendReply: Encodable { let outcome: SendOutcome; let message: String }

    /// Compares in time that doesn't depend on where the strings differ.
    static func equal(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }

    /// Only this Mac: 127.0.0.0/8. The socket is bound to loopback anyway; this is belt and braces.
    static func isLoopback(_ storage: sockaddr_storage) -> Bool {
        var storage = storage
        guard Int32(storage.ss_family) == AF_INET else { return false }
        let address = withUnsafePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
        }
        return address >> 24 == 127
    }
}
