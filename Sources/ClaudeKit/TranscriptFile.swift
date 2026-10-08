import Foundation
import SidekickCore

/// A file's size and modification time (one `stat`), the cache key for every parse.
struct FileStamp: Equatable, Sendable {
    let size: UInt64
    /// Nanoseconds since 1970.
    let modified: Int64

    init?(_ url: URL) {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        size = UInt64(info.st_size)
        modified = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
    }
}

/// A transcript read incrementally: the first 64 KiB once, then only bytes appended since the last
/// refresh, never more than the last 256 KiB.
struct TranscriptFile: Sendable {
    static let headBytes = 64 * 1024
    static let tailBytes: UInt64 = 256 * 1024

    let url: URL
    private var stamp: FileStamp?
    private var head: TranscriptFold?
    private var tail = TranscriptFold()
    /// Next byte of the file to fold into `tail`.
    private var offset: UInt64 = 0
    /// The tail window starts mid-line; skip to the next newline first.
    private var skippingPartialLine = false

    init(url: URL) {
        self.url = url
    }

    var summary: TranscriptSummary {
        TranscriptSummary(head: head, tail: tail)
    }

    /// The last `limit` chat messages in the tail window, oldest first.
    func messages(limit: Int) -> [ChatMessage] {
        tail.messages.suffix(max(limit, 0)).map {
            ChatMessage(id: $0.id, role: $0.role, text: $0.text, date: Transcript.date($0.stamp))
        }
    }

    /// Folds whatever changed since the last call. Returns false when the file can't be read.
    mutating func refresh() -> Bool {
        guard let current = FileStamp(url) else { return false }
        if current == stamp { return true }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }

        if head == nil {
            var fold = TranscriptFold()
            fold.consume(lines: (try? handle.read(upToCount: Self.headBytes)) ?? Data())
            head = fold
        }
        if current.size < offset {
            // Rewritten or truncated: start over.
            tail = TranscriptFold()
            offset = 0
            skippingPartialLine = false
        }
        if current.size - offset > Self.tailBytes {
            // Read only the last 256 KiB. The fold keeps what it learned so far, so an oversized
            // line (a big tool result) can't wipe the messages, titles and turn state.
            offset = current.size - Self.tailBytes
            skippingPartialLine = true
        }
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.read(upToCount: Int(current.size - offset)) ?? Data() else { return false }
        offset += UInt64(consumeCompleteLines(data))
        stamp = current
        return true
    }

    /// Folds the complete lines in `data` and returns how many bytes were used up.
    private mutating func consumeCompleteLines(_ data: Data) -> Int {
        var start = data.startIndex
        if skippingPartialLine {
            guard let newline = data.firstIndex(of: 0x0A) else { return data.count }
            start = newline + 1
            skippingPartialLine = false
        }
        guard let lastNewline = data[start...].lastIndex(of: 0x0A) else { return start - data.startIndex }
        tail.consume(lines: data[start...lastNewline])
        return lastNewline + 1 - data.startIndex
    }
}
