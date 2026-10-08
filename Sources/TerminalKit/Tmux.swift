import Foundation
import SidekickCore

/// A tmux pane to select: window and pane targets plus the session they belong to.
struct TmuxPane: Equatable, Sendable {
    let session: String
    let window: String
    let pane: String

    /// Parses the Claude registry `tmux` field, "<session>:@<window>.%<pane>".
    init?(registryField field: String) {
        guard let match = field.wholeMatch(of: #/([A-Za-z0-9_.-]{1,64}):(@?\d{1,6})\.(%?\d{1,6})/#) else { return nil }
        let (session, window, pane) = (String(match.1), String(match.2), String(match.3))
        self.session = session
        self.window = "\(session):\(window)"
        self.pane = pane.hasPrefix("%") ? pane : "\(session):\(window).\(pane)"
    }

    init(session: String, window: String, pane: String) {
        self.session = session
        self.window = window
        self.pane = pane
    }
}

/// A tmux server reached through its socket, so `-L`/`-S` servers work as well as the default one.
struct TmuxServer: Sendable {
    let executable: String
    let socket: String

    static let fallbackExecutables = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/opt/local/bin/tmux", "/usr/bin/tmux"]

    /// The server that owns `process` (an ancestor whose executable is tmux).
    static func owning(_ process: ProcessEntry) async -> TmuxServer? {
        let executable = executablePath(of: process.pid)
            ?? fallbackExecutables.first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let executable else { return nil }
        let args = await Shell.run("/bin/ps", ["-o", "args=", "-p", "\(process.pid)"]).stdout
        return TmuxServer(executable: executable, socket: socketPath(serverArgs: args, uid: getuid()))
    }

    /// The socket a server listens on, from the command line it was started with
    /// (`-S path`, `-L name`, or the default socket).
    static func socketPath(serverArgs: String, uid: uid_t) -> String {
        let directory = "/private/tmp/tmux-\(uid)"
        var name = "default"
        var args = serverArgs.split(whereSeparator: \.isWhitespace).dropFirst().map(String.init)[...]
        while let arg = args.first, arg.hasPrefix("-"), arg != "-", arg != "--" {
            args = args.dropFirst()
            var flags = arg.dropFirst()
            while let flag = flags.first {
                flags = flags.dropFirst()
                guard "cfLST".contains(flag) else { continue }
                let value = flags.isEmpty ? args.popFirst() ?? "" : String(flags)
                if flag == "S" { return value }
                if flag == "L" { name = value }
                break
            }
        }
        return "\(directory)/\(name)"
    }

    func run(_ args: [String]) async -> ShellResult {
        await Shell.run(executable, ["-S", socket] + args, timeout: 3)
    }

    /// The pane whose tty is `tty` (without "/dev/").
    func pane(tty: String) async -> TmuxPane? {
        let result = await run(["list-panes", "-a", "-F", "#{pane_tty} #{window_id} #{pane_id} #{session_name}"])
        guard result.ok else { return nil }
        return Self.parsePanes(result.stdout)["/dev/\(tty)"]
    }

    /// Client processes attached to `session`, falling back to every client of the server.
    func clientPIDs(session: String) async -> [Int32] {
        let format = "#{client_pid} #{client_tty}"
        let attached = await run(["list-clients", "-t", session, "-F", format])
        let clients = attached.ok ? Self.parseClients(attached.stdout) : []
        if !clients.isEmpty { return clients }
        return Self.parseClients(await run(["list-clients", "-F", format]).stdout)
    }

    /// Parses `list-panes -F "#{pane_tty} #{window_id} #{pane_id} #{session_name}"`, keyed by tty.
    static func parsePanes(_ output: String) -> [String: TmuxPane] {
        var panes: [String: TmuxPane] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ", maxSplits: 3).map(String.init)
            guard fields.count == 4 else { continue }
            panes[fields[0]] = TmuxPane(session: fields[3], window: fields[1], pane: fields[2])
        }
        return panes
    }

    /// Client pids from `list-clients -F "#{client_pid} #{client_tty}"`.
    static func parseClients(_ output: String) -> [Int32] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            line.split(separator: " ").first.flatMap { Int32($0) }
        }
    }
}
