import Foundation
import SidekickCore

/// HTTP/1.1 over a Unix socket at `socketPath` (0600, parent dir created 0700).
/// One request per connection. Routes are documented in docs/BRIDGE.md.
public final class BridgeServer: @unchecked Sendable {
    public enum StartError: Error, Equatable {
        /// Another process answers `GET /health` on the socket.
        case alreadyRunning
        /// The path is empty or longer than `sun_path` allows (104 bytes).
        case invalidPath
        /// A system call failed; `call` names it.
        case system(call: String, errno: Int32)
    }

    private let socketPath: String
    private let router: BridgeRouter
    private let acceptQueue = DispatchQueue(label: "sidekick.bridge.accept")
    private let workQueue = DispatchQueue(label: "sidekick.bridge.work", attributes: .concurrent)
    private let lock = NSLock()
    private var listener: DispatchSourceRead?
    private var connections: [ObjectIdentifier: BridgeConnection] = [:]

    public init(hub: BridgeHub = .shared, socketPath: String = Paths.socketPath, api: SidekickAPI? = nil) {
        self.socketPath = socketPath
        self.router = BridgeRouter(hub: hub, api: api)
    }

    deinit {
        stop()
    }

    /// Bind and start serving. Throws `alreadyRunning` when a live server owns the socket;
    /// a stale socket file that nobody answers on is removed first.
    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard listener == nil else { return }
        guard let address = UnixSocket.address(socketPath) else { throw StartError.invalidPath }

        let directory = (socketPath as NSString).deletingLastPathComponent
        if !FileManager.default.fileExists(atPath: directory) {
            do {
                try FileManager.default.createDirectory(
                    atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            } catch {
                let posix = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
                throw StartError.system(call: "mkdir", errno: Int32(posix?.code ?? Int(EIO)))
            }
        }
        var info = stat()
        if lstat(socketPath, &info) == 0 {
            if BridgeClient.request(method: "GET", path: "/health", socketPath: socketPath, timeout: 1) != nil {
                throw StartError.alreadyRunning
            }
            unlink(socketPath)
        }

        guard let fd = UnixSocket.makeStream() else { throw StartError.system(call: "socket", errno: errno) }
        func failure(_ call: String, bound: Bool) -> StartError {
            let code = errno
            close(fd)
            if bound { unlink(socketPath) }
            return .system(call: call, errno: code)
        }
        guard UnixSocket.bind(fd, address) else { throw failure("bind", bound: false) }
        guard chmod(socketPath, 0o600) == 0 else { throw failure("chmod", bound: true) }
        guard listen(fd, 128) == 0 else { throw failure("listen", bound: true) }
        UnixSocket.setNonBlocking(fd, true)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        source.setEventHandler { [weak self] in self?.acceptPending(fd, source) }
        source.setCancelHandler { close(fd) }
        listener = source
        source.resume()
    }

    /// Stop accepting, drop open connections and remove the socket file. Safe to call twice.
    public func stop() {
        lock.lock()
        guard let source = listener else {
            lock.unlock()
            return
        }
        listener = nil
        let open = Array(connections.values)
        connections.removeAll()
        lock.unlock()

        unlink(socketPath)
        source.cancel()
        open.forEach { $0.cancel() }
    }

    private func acceptPending(_ fd: Int32, _ source: DispatchSourceRead) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                switch errno {
                case EINTR, ECONNABORTED:
                    continue
                case EMFILE, ENFILE:
                    // Out of descriptors: pause instead of spinning on a still-readable listener.
                    source.suspend()
                    acceptQueue.asyncAfter(deadline: .now() + 0.1) { source.resume() }
                    return
                default:
                    return
                }
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
                queue: DispatchQueue(label: "sidekick.bridge.connection", target: workQueue),
                router: router
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
}

/// One client connection: read a single request, answer it, close.
final class BridgeConnection: @unchecked Sendable {
    /// How long a client may take to send its whole request.
    static let readTimeout: TimeInterval = 10
    /// How long a client may take to accept the response.
    static let writeTimeout: Double = 5

    private let fd: Int32
    private let queue: DispatchQueue
    private let router: BridgeRouter
    private let onClose: (BridgeConnection) -> Void
    private let reader: DispatchSourceRead
    private let deadline: DispatchSourceTimer
    // All state below is touched only on `queue`.
    private var buffer = Data()
    private var readerCancelled = false
    private var finished = false
    private var closed = false

    init(fd: Int32, queue: DispatchQueue, router: BridgeRouter, onClose: @escaping (BridgeConnection) -> Void) {
        self.fd = fd
        self.queue = queue
        self.router = router
        self.onClose = onClose
        reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        deadline = DispatchSource.makeTimerSource(queue: queue)
    }

    func start() {
        reader.setEventHandler { [self] in readAvailable() }
        reader.setCancelHandler { [self] in
            readerCancelled = true
            closeIfDone()
        }
        deadline.setEventHandler { [self] in finish() }
        deadline.schedule(deadline: .now() + Self.readTimeout)
        reader.resume()
        deadline.resume()
    }

    /// Abandon the connection (server stopping).
    func cancel() {
        queue.async { [self] in finish() }
    }

    private func readAvailable() {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        let n = read(fd, &chunk, chunk.count)
        if n < 0 && (errno == EAGAIN || errno == EINTR) { return }
        guard n > 0 else { return finish() }
        buffer.append(contentsOf: chunk[0..<n])

        switch HTTPRequest.parse(buffer) {
        case .incomplete:
            return
        case .invalid(let reason):
            stopReading()
            send(.error(400, reason))
        case .complete(let request):
            stopReading()
            let router = router
            Task { [self] in
                let response = await router.respond(to: request)
                queue.async { self.send(response) }
            }
        }
    }

    private func stopReading() {
        deadline.cancel()
        if !reader.isCancelled { reader.cancel() }
    }

    private func send(_ response: HTTPResponse) {
        guard !finished else { return }
        UnixSocket.setNonBlocking(fd, false)
        UnixSocket.setSendTimeout(fd, Self.writeTimeout)
        _ = UnixSocket.writeAll(fd, response.serialized())
        finish()
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        stopReading()
        closeIfDone()
    }

    /// The descriptor may only be closed once the read source's cancel handler has run.
    private func closeIfDone() {
        guard finished, readerCancelled, !closed else { return }
        closed = true
        close(fd)
        onClose(self)
    }
}
