import Foundation
import SidekickCore

/// A live registry row joined with its transcript, and how it maps to an `AgentThread`.
struct ClaudeSession: Sendable {
    let record: SessionRecord
    let transcriptURL: URL?
    let summary: TranscriptSummary?

    /// Raw status and detail from the registry, refined by the transcript.
    var status: (status: ThreadStatus, detail: String?) {
        switch record.status {
        case "waiting":
            return (.needsInput, record.waitingFor == "permission prompt" ? "Needs permission" : "Waiting for you")
        case "busy":
            // Desktop sessions stay busy while background agents or workflows run after the reply.
            let background = record.surface == .desktop && summary?.mainTurnEnded == true
            return (.running, background ? "Background work running" : nil)
        case "shell":
            return (.running, "Background task running")
        default:
            return (summary?.lastTurnFailed == true ? .failed : .idle, nil)
        }
    }

    /// custom title → AI title → registry name (desktop, or user-named) → last prompt → first prompt.
    var title: String {
        let registryName = record.surface == .desktop || record.nameSource == "user" ? record.name : nil
        let candidates = [summary?.customTitle, summary?.aiTitle, registryName, summary?.lastPrompt, summary?.firstPrompt]
        return candidates.lazy.compactMap { $0.flatMap(DisplayLine.first) }.first ?? "New session"
    }

    func thread(canSendLive: Bool, seenAt: Date? = nil) -> AgentThread {
        let (status, detail) = status
        var extra = ["pid": String(record.pid)]
        extra["entrypoint"] = record.entrypoint
        extra["hostSessionId"] = record.hostSessionId
        extra["transcriptPath"] = transcriptURL?.path
        extra["tmux"] = record.tmux
        let dates = [summary?.lastActivity, record.statusUpdatedAt.map(Self.date), record.startedAt.map(Self.date)]
        return AgentThread(
            platform: .claude,
            nativeId: record.sessionId,
            surface: record.surface,
            title: title,
            status: status,
            detail: detail,
            subtitle: summary?.lastAssistantLine,
            cwd: record.cwd,
            branch: summary?.gitBranch,
            updatedAt: dates.compactMap { $0 }.max() ?? .distantPast,
            lastTurnEndedAt: summary?.lastTurnEndedAt,
            seenAt: seenAt,
            canSendLive: canSendLive,
            extra: extra)
    }

    /// One row per session. Rows sharing a `hostSessionId` (desktop side-fork helpers) or a `sessionId`
    /// collapse to the one with a transcript and a messaging socket, then the oldest. Order is kept.
    static func dedupe(_ sessions: [ClaudeSession]) -> [ClaudeSession] {
        collapse(collapse(sessions, by: { $0.hostSessionId }), by: { $0.sessionId })
    }

    private static func collapse(_ sessions: [ClaudeSession], by key: (SessionRecord) -> String?) -> [ClaudeSession] {
        var winners: [String: Int] = [:]
        for (i, session) in sessions.enumerated() {
            guard let k = key(session.record) else { continue }
            if let j = winners[k], !session.isPreferred(over: sessions[j]) { continue }
            winners[k] = i
        }
        return sessions.enumerated().compactMap { i, session in
            guard let k = key(session.record) else { return session }
            return winners[k] == i ? session : nil
        }
    }

    private func isPreferred(over other: ClaudeSession) -> Bool {
        let rank = { (s: ClaudeSession) in (s.transcriptURL != nil ? 2 : 0) + (s.record.messagingSocketPath != nil ? 1 : 0) }
        if rank(self) != rank(other) { return rank(self) > rank(other) }
        let (mine, theirs) = (record.startedAt ?? .infinity, other.record.startedAt ?? .infinity)
        return mine != theirs ? mine < theirs : record.pid < other.record.pid
    }

    private static func date(_ epochMilliseconds: Double) -> Date {
        Date(timeIntervalSince1970: epochMilliseconds / 1000)
    }
}

/// One-line display strings for bubbles, capped at `limit` characters. Only a prefix of the
/// input is examined, so a long reply or prompt costs no more than a short one.
enum DisplayLine {
    static let limit = 200

    /// The first non-empty line, trimmed and capped.
    static func first(_ text: String) -> String? {
        let head = text.prefix(2 * limit)
        var line: String?
        String(head).enumerateLines { candidate, stop in
            let trimmed = candidate.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                line = trimmed
                stop = true
            }
        }
        return line.map { capped($0, more: false) }
    }

    /// Whitespace runs, newlines included, collapsed to single spaces, then capped.
    static func collapsed(_ text: String) -> String? {
        let head = text.prefix(2 * limit)
        let words = head.split(whereSeparator: \.isWhitespace)
        return words.isEmpty ? nil : capped(words.joined(separator: " "), more: head.endIndex != text.endIndex)
    }

    /// `more`: the text went on past what was examined.
    private static func capped(_ text: String, more: Bool) -> String {
        text.count > limit || more ? String(text.prefix(limit - 1)) + "…" : text
    }
}
