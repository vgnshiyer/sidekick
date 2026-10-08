import Darwin
import Foundation
import SidekickCore

/// One row of `ps -A -o pid=,ppid=,tty=,comm=`.
struct ProcessEntry: Equatable, Sendable {
    let pid: Int32
    let ppid: Int32
    /// Controlling terminal without "/dev/" (e.g. "ttys003"), nil for "??".
    let tty: String?
    let command: String

    /// The executable's file name, e.g. "tmux" for "/opt/homebrew/bin/tmux".
    var name: String {
        (command as NSString).lastPathComponent
    }
}

/// A snapshot of the process table, used to walk a process's ancestry.
struct ProcessTable: Sendable {
    private let entries: [Int32: ProcessEntry]

    init(_ entries: [ProcessEntry]) {
        self.entries = Dictionary(entries.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Parses `ps -A -o pid=,ppid=,tty=,comm=` output. The command is the rest of the line and may contain spaces.
    init(psOutput: String) {
        self.init(psOutput.split(whereSeparator: \.isNewline).compactMap(Self.parse(line:)))
    }

    static func current() async -> ProcessTable {
        let result = await Shell.run("/bin/ps", ["-A", "-o", "pid=,ppid=,tty=,comm="])
        return ProcessTable(psOutput: result.stdout)
    }

    func entry(_ pid: Int32) -> ProcessEntry? {
        entries[pid]
    }

    /// `pid` itself followed by its parent, grandparent, ... up to (not including) launchd.
    func ancestry(of pid: Int32) -> [ProcessEntry] {
        var chain: [ProcessEntry] = []
        var seen = Set<Int32>()
        var current = pid
        while current > 1, seen.insert(current).inserted, let entry = entries[current] {
            chain.append(entry)
            current = entry.ppid
        }
        return chain
    }

    private static func parse(line: Substring) -> ProcessEntry? {
        var rest = line[...]
        func token() -> Substring? {
            rest = rest.drop(while: \.isWhitespace)
            guard !rest.isEmpty else { return nil }
            let end = rest.firstIndex(where: \.isWhitespace) ?? rest.endIndex
            defer { rest = rest[end...] }
            return rest[..<end]
        }
        guard let pid = token().flatMap({ Int32($0) }),
              let ppid = token().flatMap({ Int32($0) }),
              let tty = token() else { return nil }
        let command = rest.trimmingCharacters(in: .whitespaces)
        guard !command.isEmpty else { return nil }
        return ProcessEntry(pid: pid, ppid: ppid, tty: tty == "??" ? nil : String(tty), command: command)
    }
}

/// The absolute path of a running process's executable.
func executablePath(of pid: Int32) -> String? {
    var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
    return String(cString: buffer)
}
