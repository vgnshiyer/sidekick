import Foundation
import SidekickCore
import TerminalKit

/// Claude Code sessions in a terminal, Claude.app's Code tab and VS Code, read from the session
/// registry and transcripts under the Claude config dir (never written). Sends go through the
/// `sidekick-bridge` mod when it is connected, and fall back to the clipboard plus Open.
public final class ClaudeProvider: ThreadProvider {
    public let platform: Platform = .claude
    private let hub: BridgeHub
    private let index: SessionIndex
    private let readState: DesktopReadState
    private let actions: Actions
    private let sendTimeout: TimeInterval

    /// - Parameters:
    ///   - hub: bridge state shared with the server the mod polls.
    ///   - claudeDir: the Claude config dir to read (CLAUDE_CONFIG_DIR or ~/.claude by default).
    public convenience init(hub: BridgeHub = .shared, claudeDir: URL = Paths.claudeDir) {
        self.init(hub: hub, claudeDir: claudeDir, actions: .live, sendTimeout: 15)
    }

    init(
        hub: BridgeHub, claudeDir: URL, actions: Actions, sendTimeout: TimeInterval,
        readState: DesktopReadState = DesktopReadState()
    ) {
        self.hub = hub
        self.index = SessionIndex(claudeDir: claudeDir)
        self.readState = readState
        self.actions = actions
        self.sendTimeout = sendTimeout
    }

    /// Side effects of send and open, swapped out in tests.
    struct Actions: Sendable {
        var copy: @Sendable (String) async -> Void
        var openURL: @Sendable (URL) async -> Bool
        var focusTerminal: @Sendable (_ pid: Int32?, _ cwd: String?, _ titleHint: String?, _ tmux: String?) async -> Bool
        var frontmostApp: @Sendable () async -> String? = { nil }

        static let live = Actions(
            copy: { await SystemActions.copyToClipboard($0) },
            openURL: { await SystemActions.open($0) },
            focusTerminal: { await TerminalFocus.focus(pid: $0, cwd: $1, titleHint: $2, tmux: $3) },
            frontmostApp: { await SystemActions.frontmostBundleIdentifier() })
    }

    static let desktopAppId = "com.anthropic.claudefordesktop"

    public func snapshot() async -> [AgentThread] {
        let read = readState.entries()
        // With Claude.app in front, the session on screen is the one you switched to last.
        let onScreen = await actions.frontmostApp() == Self.desktopAppId
            ? read.max { ($0.value.focusedAt ?? .distantPast) < ($1.value.focusedAt ?? .distantPast) }?.key
            : nil
        var threads: [AgentThread] = []
        for session in await index.sessions() {
            let live = await hub.isClaudeBridgeLive(sessionId: session.record.sessionId)
            var seenAt: Date?
            if let host = session.record.hostSessionId, let entry = read[host] {
                seenAt = entry.seenAt
                // On screen now: its latest reply is being seen as it lands.
                if host == onScreen, let end = session.summary?.lastTurnEndedAt { seenAt = max(seenAt ?? end, end) }
            }
            threads.append(session.thread(canSendLive: live, seenAt: seenAt))
        }
        return threads
    }

    public func messages(for thread: AgentThread, limit: Int) async -> [ChatMessage] {
        await index.messages(
            sessionId: thread.nativeId, transcriptPath: thread.extra["transcriptPath"], cwd: thread.cwd, limit: limit)
    }

    public func send(_ text: String, to thread: AgentThread) async -> SendOutcome {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/") {
            return await copyAndOpen(text, thread, reason: "Slash commands can't be sent from Sidekick — copied instead")
        }
        guard await hub.isClaudeBridgeLive(sessionId: thread.nativeId) else {
            return await copyAndOpen(text, thread, reason: Self.copiedReason)
        }
        let itemId = await hub.enqueueClaude(sessionId: thread.nativeId, text: text)
        switch await waitForDelivery(of: itemId) {
        case .submitted:
            return .delivered
        case .taken:
            return .queued("Runs after the current turn")
        case .pending, .failed, nil:
            return await copyAndOpen(text, thread, reason: Self.copiedReason)
        }
    }

    public func open(_ thread: AgentThread) async -> Bool {
        if let url = Self.deepLink(for: thread) { return await actions.openURL(url) }
        let pid = thread.extra["pid"].flatMap { Int32($0) }
        return await actions.focusTerminal(pid, thread.cwd, thread.title, thread.extra["tmux"])
    }

    /// Claude.app and VS Code threads open by URL; terminal threads (nil) go through `TerminalFocus`.
    static func deepLink(for thread: AgentThread) -> URL? {
        var components = URLComponents()
        switch thread.surface {
        case .desktop:
            guard let host = thread.extra["hostSessionId"] else { return nil }
            components.scheme = "claude"
            components.host = "code"
            components.path = thread.status == .needsInput ? "/needs-input" : "/continue"
            components.queryItems = [URLQueryItem(name: "session", value: host)]
        case .ide:
            components.scheme = "vscode"
            components.host = "anthropic.claude-code"
            components.path = "/open"
            components.queryItems = [URLQueryItem(name: "session", value: thread.nativeId)]
        case .terminal, .unknown:
            return nil
        }
        return components.url
    }

    private static let copiedReason = "Copied — paste it into the session"

    /// How long a taken item may wait for its turn to start before the send reports it as queued.
    /// An idle session starts the turn about 50 ms after taking it; a busy one only when its turn ends.
    static let queuedAfter: TimeInterval = 1.5

    /// Polls the hub every 100 ms until the mod acks or fails the item, the item has sat taken
    /// (queued behind a running turn) for `queuedAfter`, or `sendTimeout` passes.
    /// An item nobody took by then is cancelled.
    private func waitForDelivery(of itemId: String) async -> BridgeHub.Delivery? {
        let deadline = Date().addingTimeInterval(sendTimeout)
        var takenAt: Date?
        while Date() < deadline {
            switch await hub.delivery(of: itemId) {
            case .submitted: return .submitted
            case .failed(let reason): return .failed(reason)
            case .taken:
                let since = takenAt ?? Date()
                takenAt = since
                if Date().timeIntervalSince(since) >= Self.queuedAfter { return .taken }
            default: break
            }
            do { try await Task.sleep(nanoseconds: 100_000_000) } catch { break }
        }
        await hub.cancelClaude(itemId: itemId)
        return await hub.delivery(of: itemId)
    }

    private func copyAndOpen(_ text: String, _ thread: AgentThread, reason: String) async -> SendOutcome {
        await actions.copy(text)
        _ = await open(thread)
        return .copiedToClipboard(reason)
    }
}
