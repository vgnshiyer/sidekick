import Foundation
import SidekickCore

/// One `sessions/<pid>.json` registry entry, written by every running Claude Code process
/// (terminal, Claude.app Code tab, VS Code). Only the fields Sidekick reads.
struct SessionRecord: Decodable, Equatable, Sendable {
    let pid: Int32
    let sessionId: String
    var cwd: String?
    var procStart: String?
    var kind: String?
    var entrypoint: String?
    /// Claude.app's `local_<uuid>` id; shared by desktop side-fork helpers.
    var hostSessionId: String?
    /// "<session>:@<window>.%<pane>" when running inside tmux.
    var tmux: String?
    var messagingSocketPath: String?
    var name: String?
    var nameSource: String?
    /// busy | waiting | idle | shell
    var status: String?
    var waitingFor: String?
    /// Epoch milliseconds.
    var startedAt: Double?
    var statusUpdatedAt: Double?

    /// Only `^\d+\.json$` names are registry entries.
    static func isRegistryFileName(_ name: String) -> Bool {
        let stem = name.dropLast(5)
        return name.hasSuffix(".json") && !stem.isEmpty && stem.allSatisfy { $0.isASCII && $0.isNumber }
    }

    var isInteractive: Bool {
        kind == nil || kind == "interactive"
    }

    var surface: Surface {
        switch entrypoint {
        case "claude-desktop", "claude-desktop-3p", "local-agent": return .desktop
        case "claude-vscode": return .ide
        default: return .terminal
        }
    }
}
