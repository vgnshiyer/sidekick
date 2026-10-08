import Foundation
import SidekickCore

/// Maps bridge requests onto `BridgeHub` and the app's `SidekickAPI`. Routes are documented in docs/BRIDGE.md.
struct BridgeRouter: Sendable {
    let hub: BridgeHub
    let api: SidekickAPI?

    static let claudeEventKinds: Set<String> = ["turn.start", "turn.complete", "session.end"]

    func respond(to request: HTTPRequest) async -> HTTPResponse {
        switch (request.method, request.path) {
        case ("GET", "/health"):
            return .json(Health())
        case ("POST", "/claude/hello"):
            return await claudeHello(request)
        case ("GET", "/claude/poll"):
            return await claudePoll(request)
        case ("POST", "/claude/ack"):
            return await claudeAck(request)
        case ("POST", "/claude/event"):
            return await claudeEvent(request)
        case ("POST", "/codex/hook"):
            return await codexHook(request)
        case ("GET", "/api/threads"), ("GET", "/api/messages"), ("POST", "/api/send"), ("POST", "/api/open"):
            guard let api else { return .error(503, "Sidekick API unavailable") }
            return await appAPI(request, api)
        default:
            return .error(404, "not found")
        }
    }

    // MARK: Claude bridge mod

    private func claudeHello(_ request: HTTPRequest) async -> HTTPResponse {
        guard let body = request.decode(Hello.self), !body.sessionId.isEmpty else { return .error(400, "expected {\"sessionId\"}") }
        await hub.serverClaudeEvent(sessionId: body.sessionId, kind: "session.start")
        return .ok
    }

    private func claudePoll(_ request: HTTPRequest) async -> HTTPResponse {
        guard let session = request.query["session"], !session.isEmpty else { return .error(400, "missing ?session=") }
        guard let item = await hub.serverClaudePoll(sessionId: session) else { return .noContent }
        return .json(PollItem(id: item.id, text: item.text))
    }

    private func claudeAck(_ request: HTTPRequest) async -> HTTPResponse {
        guard let body = request.decode(Ack.self), !body.id.isEmpty else { return .error(400, "expected {\"id\",\"ok\"}") }
        await hub.serverClaudeAck(itemId: body.id, ok: body.ok, error: body.error)
        return .ok
    }

    private func claudeEvent(_ request: HTTPRequest) async -> HTTPResponse {
        guard let body = request.decode(ClaudeEvent.self), !body.sessionId.isEmpty,
              Self.claudeEventKinds.contains(body.kind)
        else { return .error(400, "expected {\"sessionId\",\"kind\"} with a known kind") }
        await hub.serverClaudeEvent(sessionId: body.sessionId, kind: body.kind)
        return .ok
    }

    // MARK: Codex hooks

    private func codexHook(_ request: HTTPRequest) async -> HTTPResponse {
        guard let body = request.decode(CodexHook.self), !body.sessionId.isEmpty, !body.hookEventName.isEmpty else {
            return .error(400, "expected a Codex hook payload with session_id and hook_event_name")
        }
        await hub.serverCodexHook(BridgeHub.CodexHookEvent(
            event: body.hookEventName, threadId: body.sessionId, toolName: body.toolName, cwd: body.cwd, date: Date()))
        return .ok
    }

    // MARK: App API

    private func appAPI(_ request: HTTPRequest, _ api: SidekickAPI) async -> HTTPResponse {
        switch request.path {
        case "/api/threads":
            return .json(Threads(threads: await api.apiThreads()))
        case "/api/messages":
            guard let thread = request.query["thread"], !thread.isEmpty else { return .error(400, "missing ?thread=") }
            var limit = 20
            if let value = request.query["limit"] {
                guard let n = Int(value), n > 0 else { return .error(400, "limit must be a positive integer") }
                limit = n
            }
            return .json(Messages(messages: await api.apiMessages(threadId: thread, limit: limit)))
        case "/api/send":
            guard let body = request.decode(Send.self), !body.threadId.isEmpty else { return .error(400, "expected {\"threadId\",\"text\"}") }
            let outcome = await api.apiSend(threadId: body.threadId, text: body.text)
            return .json(SendResult(outcome: outcome, message: outcome.message))
        case "/api/open":
            guard let body = request.decode(Open.self), !body.threadId.isEmpty else { return .error(400, "expected {\"threadId\"}") }
            return .json(OpenResult(ok: await api.apiOpen(threadId: body.threadId)))
        default:
            return .error(404, "not found")
        }
    }
}

// MARK: Bodies

private struct Hello: Decodable { let sessionId: String }
private struct Ack: Decodable { let id: String; let ok: Bool; let error: String? }
private struct ClaudeEvent: Decodable { let sessionId: String; let kind: String }
private struct Send: Decodable { let threadId: String; let text: String }
private struct Open: Decodable { let threadId: String }

private struct CodexHook: Decodable {
    let sessionId: String
    let hookEventName: String
    let toolName: String?
    let cwd: String?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case hookEventName = "hook_event_name"
        case toolName = "tool_name"
        case cwd
    }
}

private struct OK: Encodable { let ok = true }
private struct Health: Encodable { let ok = true; let app = "Sidekick" }
private struct PollItem: Encodable { let id: String; let text: String }
private struct Threads: Encodable { let threads: [AgentThread] }
private struct Messages: Encodable { let messages: [ChatMessage] }
private struct SendResult: Encodable { let outcome: SendOutcome; let message: String }
private struct OpenResult: Encodable { let ok: Bool }

private extension HTTPRequest {
    func decode<T: Decodable>(_ type: T.Type) -> T? {
        try? JSONDecoder().decode(type, from: body)
    }
}

private extension HTTPResponse {
    static let ok = json(OK())
}
