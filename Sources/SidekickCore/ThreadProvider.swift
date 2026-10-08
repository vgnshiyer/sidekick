import Foundation

/// A source of threads for one platform. Implementations must be cheap to poll
/// (cache by file size/mtime) and must never write to the tool's own state.
public protocol ThreadProvider: AnyObject, Sendable {
    var platform: Platform { get }

    /// Currently active threads with raw status (`idle` rather than `ready`; the store derives `ready`).
    /// A provider may return `ready` itself when the tool records unread state.
    func snapshot() async -> [AgentThread]

    /// Recent user/assistant text messages, oldest first.
    func messages(for thread: AgentThread, limit: Int) async -> [ChatMessage]

    /// Send text into the thread, preferably the live session the user sees.
    func send(_ text: String, to thread: AgentThread) async -> SendOutcome

    /// Bring the thread's native UI to the front. Returns false if nothing could be focused.
    func open(_ thread: AgentThread) async -> Bool
}

/// The surface the bridge socket exposes to `sidekick-cli` (implemented by `ThreadStore`).
public protocol SidekickAPI: AnyObject, Sendable {
    func apiThreads() async -> [AgentThread]
    func apiMessages(threadId: String, limit: Int) async -> [ChatMessage]
    func apiSend(threadId: String, text: String) async -> SendOutcome
    func apiOpen(threadId: String) async -> Bool
}
