import Foundation

/// The coding tool a thread lives in.
public enum Platform: String, Codable, Sendable, CaseIterable {
    case claude
    case codex

    public var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }
}

/// Where the thread is being driven from, which decides how "Open" jumps to it.
public enum Surface: String, Codable, Sendable {
    case terminal
    case desktop
    case ide
    case unknown

    public var displayName: String {
        switch self {
        case .terminal: return "Terminal"
        case .desktop: return "Desktop app"
        case .ide: return "Editor"
        case .unknown: return "Unknown"
        }
    }
}

/// Thread status, ordered by urgency (lower rank = more urgent).
public enum ThreadStatus: String, Codable, Sendable, CaseIterable {
    case needsInput
    case failed
    case ready
    case running
    case idle

    public var rank: Int {
        switch self {
        case .needsInput: return 0
        case .failed: return 1
        case .ready: return 2
        case .running: return 3
        case .idle: return 4
        }
    }

    public var label: String {
        switch self {
        case .needsInput: return "Needs input"
        case .failed: return "Failed"
        case .ready: return "Ready"
        case .running: return "Running"
        case .idle: return "Idle"
        }
    }

    /// Statuses that count towards the pet's attention badge.
    public var wantsAttention: Bool {
        self == .needsInput || self == .failed || self == .ready
    }
}

public struct ChatMessage: Identifiable, Codable, Sendable, Hashable {
    public enum Role: String, Codable, Sendable { case user, assistant }

    public var id: String
    public var role: Role
    public var text: String
    public var date: Date?

    public init(id: String, role: Role, text: String, date: Date?) {
        self.id = id
        self.role = role
        self.text = text
        self.date = date
    }
}

/// One conversation in one tool, normalised across platforms.
public struct AgentThread: Identifiable, Codable, Sendable, Hashable {
    /// Globally unique: "<platform>:<nativeId>".
    public var id: String
    public var platform: Platform
    public var surface: Surface
    /// Claude sessionId or Codex thread id.
    public var nativeId: String
    public var title: String
    public var status: ThreadStatus
    /// Short status qualifier, e.g. "Needs permission", "Background task running".
    public var detail: String?
    /// Latest assistant line or current activity, one line.
    public var subtitle: String?
    public var cwd: String?
    public var branch: String?
    public var updatedAt: Date
    public var lastTurnEndedAt: Date?
    /// True when a send lands directly in the live session (Claude bridge connected; Codex queue).
    public var canSendLive: Bool
    /// Provider-specific routing data (pid, hostSessionId, transcriptPath, rolloutPath, tmux, entrypoint...).
    public var extra: [String: String]

    public init(
        platform: Platform,
        nativeId: String,
        surface: Surface,
        title: String,
        status: ThreadStatus,
        detail: String? = nil,
        subtitle: String? = nil,
        cwd: String? = nil,
        branch: String? = nil,
        updatedAt: Date,
        lastTurnEndedAt: Date? = nil,
        canSendLive: Bool = false,
        extra: [String: String] = [:]
    ) {
        self.id = "\(platform.rawValue):\(nativeId)"
        self.platform = platform
        self.surface = surface
        self.nativeId = nativeId
        self.title = title
        self.status = status
        self.detail = detail
        self.subtitle = subtitle
        self.cwd = cwd
        self.branch = branch
        self.updatedAt = updatedAt
        self.lastTurnEndedAt = lastTurnEndedAt
        self.canSendLive = canSendLive
        self.extra = extra
    }

    /// Folder name of the working directory, for compact display.
    public var folderName: String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }
}

/// What happened to a message the user sent from the pet.
public enum SendOutcome: Codable, Sendable, Equatable {
    /// Submitted into the live session.
    case delivered
    /// Accepted, will run later; the string explains when.
    case queued(String)
    /// Could not be delivered live; text was copied and the thread opened.
    case copiedToClipboard(String)
    case failed(String)

    public var message: String {
        switch self {
        case .delivered: return "Sent"
        case .queued(let why): return why
        case .copiedToClipboard(let why): return why
        case .failed(let why): return why
        }
    }
}
