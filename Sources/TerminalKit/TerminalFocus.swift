import AppKit
import Foundation
import SidekickCore

/// Brings the terminal hosting an agent CLI process to the front:
/// tmux pane → Terminal.app tab by tty → Ghostty terminal by working directory → the hosting GUI app.
public enum TerminalFocus {
    private static let terminalBundleID = "com.apple.Terminal"
    private static let ghosttyBundleID = "com.mitchellh.ghostty"

    /// Bring the terminal tab/pane hosting `pid` to the front.
    /// - Parameters:
    ///   - pid: the agent CLI process (claude / codex TUI), if known.
    ///   - cwd: its working directory (used to match Ghostty terminals).
    ///   - titleHint: text expected in the terminal title (thread title or id).
    ///   - tmux: the Claude registry `tmux` field ("<session>:@<window>.%<pane>") when present.
    /// - Returns: true if a specific tab/pane (or at least the hosting app) was focused.
    public static func focus(pid: Int32?, cwd: String?, titleHint: String?, tmux: String?) async -> Bool {
        let table = pid == nil ? ProcessTable([]) : await ProcessTable.current()
        let ancestry = pid.map { table.ancestry(of: $0) } ?? []
        let host = hostApp(in: ancestry)

        if let server = ancestry.first(where: { $0.name == "tmux" }) {
            if await focusTmux(server: server, paneTTY: ancestry.first?.tty, field: tmux, table: table) { return true }
        } else {
            let hostID = host?.bundleIdentifier
            if let tty = ancestry.first?.tty, hostID == nil || hostID == terminalBundleID, isRunning(terminalBundleID),
               await focusTerminalTab(tty: tty) {
                return true
            }
            if let cwd, hostID == nil || hostID == ghosttyBundleID, isRunning(ghosttyBundleID),
               await focusGhostty(cwd: cwd, titleHint: titleHint) {
                return true
            }
        }

        guard let url = host?.bundleURL else { return false }
        return await activate(url)
    }

    /// Selects the pane in its tmux server, then activates the terminal app that hosts a client of that session.
    private static func focusTmux(server process: ProcessEntry, paneTTY: String?, field: String?, table: ProcessTable) async -> Bool {
        guard let server = await TmuxServer.owning(process) else { return false }
        var target = field.flatMap(TmuxPane.init(registryField:))
        if target == nil, let paneTTY { target = await server.pane(tty: paneTTY) }
        guard let target,
              await server.run(["select-window", "-t", target.window]).ok,
              await server.run(["select-pane", "-t", target.pane]).ok else { return false }
        for client in await server.clientPIDs(session: target.session) {
            if let app = hostApp(in: table.ancestry(of: client))?.bundleURL { return await activate(app) }
        }
        return false
    }

    private static func focusTerminalTab(tty: String) async -> Bool {
        let result = await Shell.appleScript(AppleScript.terminalTab(tty: "/dev/\(tty)"))
        return result.ok && result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "ok"
    }

    private static func focusGhostty(cwd: String, titleHint: String?) async -> Bool {
        let list = await Shell.appleScript(AppleScript.ghosttyTerminals)
        guard list.ok,
              let match = GhosttyTerminal.best(in: GhosttyTerminal.parse(list.stdout), cwd: cwd, titleHint: titleHint)
        else { return false }
        return await Shell.appleScript(AppleScript.ghosttyFocus(id: match.id)).ok
    }

    /// The nearest regular (Dock) app among the ancestors, e.g. Ghostty, Terminal, kitty or Claude.
    private static func hostApp(in ancestry: [ProcessEntry]) -> NSRunningApplication? {
        for entry in ancestry {
            if let app = NSRunningApplication(processIdentifier: entry.pid),
               app.activationPolicy == .regular, app.bundleURL != nil {
                return app
            }
        }
        return nil
    }

    private static func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// Activates the running app at `bundleURL` through Launch Services, which works even though
    /// Sidekick itself is never the active app.
    @MainActor
    private static func activate(_ bundleURL: URL) async -> Bool {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        return (try? await NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration)) != nil
    }
}
