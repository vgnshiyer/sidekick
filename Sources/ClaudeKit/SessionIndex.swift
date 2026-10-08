import Darwin
import Foundation
import SidekickCore

/// Reads the session registry and transcripts under one Claude config dir, read-only, caching
/// registry parses by mtime, process start times per pid and transcripts by size and mtime.
actor SessionIndex {
    private let sessionsDir: URL
    private let projectsDir: URL
    private var records: [String: (stamp: FileStamp, record: SessionRecord)] = [:]
    private var processStarts: [Int32: String] = [:]
    private var transcriptURLs: [String: URL] = [:]
    private var transcripts: [URL: TranscriptFile] = [:]

    init(claudeDir: URL) {
        sessionsDir = claudeDir.appendingPathComponent("sessions", isDirectory: true)
        projectsDir = claudeDir.appendingPathComponent("projects", isDirectory: true)
    }

    /// Live interactive sessions joined with their transcripts, one per thread.
    func sessions() async -> [ClaudeSession] {
        let live = await liveRecords()
        let sessions = live.map { record in
            let url = transcriptURL(sessionId: record.sessionId, cwd: record.cwd)
            return ClaudeSession(record: record, transcriptURL: url, summary: url.flatMap(summary(at:)))
        }
        let sessionIds = Set(live.map(\.sessionId))
        transcriptURLs = transcriptURLs.filter { sessionIds.contains($0.key) }
        let urls = Set(sessions.compactMap(\.transcriptURL))
        transcripts = transcripts.filter { urls.contains($0.key) }
        return ClaudeSession.dedupe(sessions)
    }

    /// The last `limit` chat messages of a session's transcript.
    func messages(sessionId: String, transcriptPath: String?, cwd: String?, limit: Int) -> [ChatMessage] {
        guard let url = transcriptPath.map({ URL(fileURLWithPath: $0) }) ?? transcriptURL(sessionId: sessionId, cwd: cwd),
              let file = refreshed(url) else { return [] }
        return file.messages(limit: limit)
    }

    // MARK: Registry

    /// Registry rows whose process is alive and is the same process that wrote the row:
    /// `kill(pid, 0)` succeeds and `procStart` equals `ps -o lstart=` (checked once per pid).
    private func liveRecords() async -> [SessionRecord] {
        let names = Set((try? FileManager.default.contentsOfDirectory(atPath: sessionsDir.path)) ?? [])
            .filter(SessionRecord.isRegistryFileName)
        records = records.filter { names.contains($0.key) }
        let candidates = names.sorted().compactMap(record(named:)).filter { $0.isInteractive && Self.isRunning($0.pid) }

        let unchecked = candidates.map(\.pid).filter { processStarts[$0] == nil }
        if !unchecked.isEmpty {
            processStarts.merge(await Self.processStarts(of: unchecked)) { _, new in new }
        }
        let pids = Set(candidates.map(\.pid))
        processStarts = processStarts.filter { pids.contains($0.key) }

        return candidates.filter { record in
            guard let expected = record.procStart?.trimmingCharacters(in: .whitespaces) else { return false }
            return processStarts[record.pid] == expected
        }
    }

    private func record(named name: String) -> SessionRecord? {
        let url = sessionsDir.appendingPathComponent(name)
        guard let stamp = FileStamp(url) else { return nil }
        if let cached = records[name], cached.stamp == stamp { return cached.record }
        // A file caught mid-write fails to decode; it is retried on the next poll.
        guard stamp.size <= 256 * 1024, let data = try? Data(contentsOf: url),
              let record = try? JSONDecoder().decode(SessionRecord.self, from: data) else { return nil }
        records[name] = (stamp, record)
        return record
    }

    private static func isRunning(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// `LC_ALL=C TZ=UTC ps -o lstart=` for several pids in one call, trimmed.
    private static func processStarts(of pids: [Int32]) async -> [Int32: String] {
        let list = pids.map(String.init).joined(separator: ",")
        let result = await Shell.run("/bin/ps", ["-o", "pid=,lstart=", "-p", list], env: ["LC_ALL": "C", "TZ": "UTC"])
        return parseProcessStarts(result.stdout)
    }

    /// Parses `ps -o pid=,lstart=` lines such as " 4469 Thu Oct  8 03:45:45 2026   ".
    static func parseProcessStarts(_ output: String) -> [Int32: String] {
        var starts: [Int32: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let space = trimmed.firstIndex(of: " "), let pid = Int32(trimmed[..<space]) else { continue }
            let start = trimmed[space...].trimmingCharacters(in: .whitespaces)
            if !start.isEmpty { starts[pid] = start }
        }
        return starts
    }

    // MARK: Transcripts

    /// `projects/<encoded cwd>/<sessionId>.jsonl`, or the same file name in any project folder when the
    /// encoded folder doesn't exist (long cwds are truncated and hashed).
    private func transcriptURL(sessionId: String, cwd: String?) -> URL? {
        let fileManager = FileManager.default
        if let url = transcriptURLs[sessionId], fileManager.fileExists(atPath: url.path) { return url }
        transcriptURLs[sessionId] = nil

        var folders: [URL] = []
        if let cwd {
            let folder = projectsDir.appendingPathComponent(Transcript.projectDirectoryName(for: cwd), isDirectory: true)
            if fileManager.fileExists(atPath: folder.path) { folders = [folder] }
        }
        if folders.isEmpty {
            folders = (try? fileManager.contentsOfDirectory(at: projectsDir, includingPropertiesForKeys: nil)) ?? []
        }
        let url = folders.lazy
            .map { $0.appendingPathComponent("\(sessionId).jsonl") }
            .first { fileManager.fileExists(atPath: $0.path) }
        transcriptURLs[sessionId] = url
        return url
    }

    private func summary(at url: URL) -> TranscriptSummary? {
        refreshed(url)?.summary
    }

    private func refreshed(_ url: URL) -> TranscriptFile? {
        var file = transcripts[url] ?? TranscriptFile(url: url)
        guard file.refresh() else {
            transcripts[url] = nil
            return nil
        }
        transcripts[url] = file
        return file
    }
}
