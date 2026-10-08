import Foundation

/// Reads CODEX_HOME for the provider and caches every source by file stamp, so a poll where
/// nothing changed costs a handful of `stat` calls.
actor CodexIndex {
    struct Entry: Sendable {
        var row: CodexThreadRow
        var tail: RolloutTail?
        var inProgress: Bool
        var unread: Bool
    }

    static let window: TimeInterval = 24 * 3600
    static let limit = 20

    private let home: URL
    private var threadsKey: ThreadsKey?
    private var rows: [CodexThreadRow] = []
    private var turnsStamp: [FileStamp?]?
    private var inProgress: Set<String> = []
    private var globalStateStamp: FileStamp?
    private var unread: Set<String> = []
    private var tails: [String: (stamp: FileStamp, tail: RolloutTail)] = [:]

    private struct ThreadsKey: Equatable {
        var stamps: [FileStamp?]
        var extraIds: Set<String>
    }

    init(home: URL) {
        self.home = home
    }

    /// Threads worth showing: non-archived and updated within 24 h, or with a turn in progress,
    /// a writer lock, or a hook event (`hookedIds`). At most 20, most recent first.
    func entries(hookedIds: Set<String>, now: Date) -> [Entry] {
        refreshInProgress()
        let extraIds = inProgress.union(lockedThreadIds()).union(hookedIds)
        let cutoff = now.addingTimeInterval(-Self.window)

        let statePath = path("state_5.sqlite")
        let key = ThreadsKey(stamps: stamps(ofDatabase: statePath), extraIds: extraIds)
        // When the database can't be opened, keep the last rows and try again next poll.
        if key != threadsKey,
           let fresh = CodexDatabase.threads(path: statePath, updatedSince: cutoff, orIn: extraIds, limit: Self.limit) {
            rows = fresh
            threadsKey = key
        }
        let selected = rows.filter { $0.updatedAt >= cutoff || extraIds.contains($0.id) }

        refreshUnread()
        let paths = Set(selected.compactMap(\.rolloutPath))
        tails = tails.filter { paths.contains($0.key) }
        return selected.map { row in
            Entry(
                row: row,
                tail: row.rolloutPath.flatMap(tail(path:)),
                inProgress: inProgress.contains(row.id),
                unread: unread.contains(row.id))
        }
    }

    /// The parsed tail of a rollout file, re-read only when its size or mtime changes.
    func tail(path: String) -> RolloutTail? {
        guard let stamp = FileStamp(path: path) else {
            tails[path] = nil
            return nil
        }
        if let cached = tails[path], cached.stamp == stamp { return cached.tail }
        guard let tail = RolloutTail.read(path: path) else { return nil }
        tails[path] = (stamp, tail)
        return tail
    }

    private func refreshInProgress() {
        let historyPath = path("thread_history_1.sqlite")
        let stamps = stamps(ofDatabase: historyPath)
        guard stamps != turnsStamp else { return }
        inProgress = CodexDatabase.inProgressThreadIds(path: historyPath)
        turnsStamp = stamps
    }

    private func refreshUnread() {
        let statePath = path(".codex-global-state.json")
        let stamp = FileStamp(path: statePath)
        guard stamp != globalStateStamp else { return }
        guard let stamp else {
            unread = []
            globalStateStamp = nil
            return
        }
        // A file caught mid-write fails to parse; keep the last good set and retry next poll.
        guard let data = FileManager.default.contents(atPath: statePath),
              let ids = CodexStatus.unreadThreadIds(globalState: data) else { return }
        unread = ids
        globalStateStamp = stamp
    }

    private func lockedThreadIds() -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: path("thread-writer-locks"))) ?? []
        return Set(names.filter { !$0.hasPrefix(".") && $0.hasSuffix(".lock") }.map { String($0.dropLast(5)) })
    }

    private func stamps(ofDatabase path: String) -> [FileStamp?] {
        [FileStamp(path: path), FileStamp(path: path + "-wal")]
    }

    private func path(_ name: String) -> String {
        home.appendingPathComponent(name).path
    }
}

/// Size and modification time of a file, for cheap change detection.
struct FileStamp: Equatable, Sendable {
    var size: Int64
    var modified: Int64

    init?(path: String) {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        size = Int64(info.st_size)
        modified = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
    }
}
