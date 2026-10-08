import Darwin

/// Small helpers around BSD Unix-domain stream sockets, shared by the server and the client.
enum UnixSocket {
    /// A `sockaddr_un` for `path`, or nil when the path is empty or does not fit `sun_path` (104 bytes).
    static func address(_ path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        let bytes = Array(path.utf8)
        guard !bytes.isEmpty, !bytes.contains(0), bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            return nil
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
        return addr
    }

    /// A new stream socket with close-on-exec and no SIGPIPE, or nil on failure.
    static func makeStream() -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        configure(fd)
        return fd
    }

    /// Close-on-exec and no SIGPIPE: a peer that hangs up must never kill the app.
    static func configure(_ fd: Int32) {
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    static func setNonBlocking(_ fd: Int32, _ nonBlocking: Bool) {
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0 else { return }
        _ = fcntl(fd, F_SETFL, nonBlocking ? flags | O_NONBLOCK : flags & ~O_NONBLOCK)
    }

    static func setSendTimeout(_ fd: Int32, _ seconds: Double) {
        var tv = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - Double(Int(seconds))) * 1_000_000))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    static func bind(_ fd: Int32, _ addr: sockaddr_un) -> Bool {
        withSockaddr(addr) { Darwin.bind(fd, $0, $1) == 0 }
    }

    static func connect(_ fd: Int32, _ addr: sockaddr_un) -> Bool {
        withSockaddr(addr) { Darwin.connect(fd, $0, $1) == 0 }
    }

    /// Write every byte, retrying on EINTR. False when the peer is gone or the send timeout expires.
    static func writeAll(_ fd: Int32, _ data: [UInt8]) -> Bool {
        var offset = 0
        while offset < data.count {
            let n = data[offset...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                offset += n
            } else if n < 0 && errno == EINTR {
                continue
            } else {
                return false
            }
        }
        return true
    }

    private static func withSockaddr<T>(_ addr: sockaddr_un, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
        var addr = addr
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }
}
