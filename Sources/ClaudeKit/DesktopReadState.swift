import Foundation
import SidekickCore

/// When you last looked at each of Claude.app's Code-tab sessions, from the app's own session
/// records: `<root>/<account>/<org>/local_<id>.json` (never written). `lastFocusedAt` moves when you
/// switch to a session and `latestUserFrameAt` when you send in it. Each file is parsed again
/// only when it changes.
final class DesktopReadState: @unchecked Sendable {
    struct Entry: Equatable, Sendable {
        var focusedAt: Date?
        var userFrameAt: Date?

        /// The later of the two.
        var seenAt: Date? { [focusedAt, userFrameAt].compactMap { $0 }.max() }
    }

    static let defaultRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions", isDirectory: true)

    private let root: URL
    private let lock = NSLock()
    private var cache: [String: (stamp: FileStamp, entry: Entry)] = [:]

    init(root: URL = DesktopReadState.defaultRoot) {
        self.root = root
    }

    /// Every session's entry, keyed by its id (the registry's `hostSessionId`, e.g. `local_…`).
    func entries() -> [String: Entry] {
        let fm = FileManager.default
        var files: [URL] = []
        for account in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            for org in (try? fm.contentsOfDirectory(at: account, includingPropertiesForKeys: nil)) ?? [] {
                let names = (try? fm.contentsOfDirectory(atPath: org.path)) ?? []
                files += names.filter { $0.hasPrefix("local_") && $0.hasSuffix(".json") }.map { org.appendingPathComponent($0) }
            }
        }
        return lock.withLock {
            var result: [String: Entry] = [:]
            var kept: [String: (stamp: FileStamp, entry: Entry)] = [:]
            for file in files {
                guard let stamp = FileStamp(file) else { continue }
                let entry: Entry
                if let cached = cache[file.path], cached.stamp == stamp {
                    entry = cached.entry
                } else if let data = try? Data(contentsOf: file), let parsed = Self.parse(data) {
                    entry = parsed
                } else {
                    continue  // mid-write; try again next poll
                }
                kept[file.path] = (stamp, entry)
                result[String(file.deletingPathExtension().lastPathComponent)] = entry
            }
            cache = kept
            return result
        }
    }

    static func parse(_ data: Data) -> Entry? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        func date(_ key: String) -> Date? {
            (root[key] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        }
        return Entry(focusedAt: date("lastFocusedAt"), userFrameAt: date("latestUserFrameAt"))
    }
}
