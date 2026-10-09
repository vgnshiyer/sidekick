import Foundation
import SidekickCore

/// Pure rules that turn Codex's on-disk state and hook events into an `AgentThread`.
enum CodexStatus {
    /// Where a thread is driven from, by `originator` (then `source`).
    static func surface(originator: String?, source: String?) -> Surface {
        let origin = originator?.lowercased() ?? ""
        if origin == "codex desktop" { return .desktop }
        if origin == "codex-tui" || source == "cli" { return .terminal }
        if ["vscode", "vs code", "cursor", "windsurf"].contains(where: { origin.contains($0) }) { return .ide }
        return .unknown
    }

    /// The `PermissionRequest` still waiting on the user: no later `PostToolUse`, `Stop` or
    /// `UserPromptSubmit`, and no turn lifecycle event after it.
    static func pendingApproval(
        _ events: [BridgeHub.CodexHookEvent], turnChangedAt: Date?
    ) -> BridgeHub.CodexHookEvent? {
        guard let index = events.lastIndex(where: { $0.event == "PermissionRequest" }) else { return nil }
        let request = events[index]
        let clearing: Set = ["PostToolUse", "Stop", "UserPromptSubmit"]
        if events[(index + 1)...].contains(where: { clearing.contains($0.event) }) { return nil }
        if let changed = turnChangedAt, changed > request.date { return nil }
        return request
    }

    /// Raw status and detail, in precedence order: needsInput, running, failed, ready (unread), idle.
    /// The rollout's last lifecycle event decides the turn state; `inProgress` (thread_turns)
    /// stands in only when the rollout tail has none.
    static func resolve(
        pending: BridgeHub.CodexHookEvent?,
        lifecycle: RolloutTail.Lifecycle?,
        inProgress: Bool,
        unread: Bool
    ) -> (ThreadStatus, String?) {
        if let pending {
            if let tool = pending.toolName, !tool.isEmpty { return (.needsInput, "Needs approval: \(tool)") }
            return (.needsInput, "Waiting for you")
        }
        if let lifecycle {
            if lifecycle.event == .started { return (.running, nil) }
            if lifecycle.failed { return (.failed, nil) }
        } else if inProgress {
            return (.running, nil)
        }
        return (unread ? .ready : .idle, nil)
    }

    static func thread(
        row: CodexThreadRow,
        tail: RolloutTail?,
        hookEvents: [BridgeHub.CodexHookEvent],
        inProgress: Bool,
        unread: Bool,
        canSend: Bool
    ) -> AgentThread {
        let lifecycle = tail?.lifecycle
        let pending = pendingApproval(hookEvents, turnChangedAt: lifecycle?.date)
        let (status, detail) = resolve(pending: pending, lifecycle: lifecycle, inProgress: inProgress, unread: unread)
        var extra: [String: String] = [:]
        extra["rolloutPath"] = row.rolloutPath
        extra["originator"] = row.originator
        extra["source"] = row.source
        let surface = surface(originator: row.originator, source: row.source)
        let turnEnded = lifecycle?.event == .completed ? lifecycle?.date : nil
        return AgentThread(
            platform: .codex,
            nativeId: row.id,
            surface: surface,
            title: row.title,
            status: status,
            detail: detail,
            subtitle: tail?.lastAssistantLine,
            cwd: row.cwd,
            branch: row.branch,
            updatedAt: row.updatedAt,
            lastTurnEndedAt: turnEnded,
            // The desktop app keeps read state for its own threads: read there means seen through the last turn.
            seenAt: surface == .desktop && !unread ? turnEnded ?? row.updatedAt : nil,
            canSendLive: canSend,
            extra: extra)
    }

    /// Thread ids the desktop app marks unread: `electron-thread-read-state-v1.unreadByIdentity`,
    /// every identity's `local:` and `durable:` buckets. Nil when the JSON can't be parsed.
    static func unreadThreadIds(globalState data: Data) -> Set<String>? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let readState = root["electron-thread-read-state-v1"] as? [String: Any]
        let identities = readState?["unreadByIdentity"] as? [String: Any] ?? [:]
        var ids = Set<String>()
        for case let buckets as [String: Any] in identities.values {
            for (key, value) in buckets where key.hasPrefix("local:") || key.hasPrefix("durable:") {
                ids.formUnion(value as? [String] ?? [])
            }
        }
        return ids
    }
}
