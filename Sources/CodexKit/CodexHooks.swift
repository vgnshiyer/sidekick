import Foundation
import SidekickCore

/// Whether Sidekick's Codex hooks are installed, read from CODEX_HOME's hooks.json (never written).
public enum CodexHooks {
    /// The script the installer copies and registers.
    public static var hookScript: URL {
        Paths.appSupport.appendingPathComponent("bin/codex-hook")
    }

    /// True when `hooks.json` in `codexHome` runs `script` for some event and the script is executable.
    public static func isInstalled(codexHome: URL = Paths.codexHome, script: URL = hookScript) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: script.path),
              let data = try? Data(contentsOf: codexHome.appendingPathComponent("hooks.json")) else { return false }
        return commands(inHooksJSON: data).contains { $0.contains(script.path) }
    }

    /// Every handler command in a hooks.json document.
    static func commands(inHooksJSON data: Data) -> [String] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let events = root["hooks"] as? [String: Any] else { return [] }
        var commands: [String] = []
        for case let groups as [[String: Any]] in events.values {
            for case let handlers as [[String: Any]] in groups.map({ $0["hooks"] }) {
                commands += handlers.compactMap { $0["command"] as? String }
            }
        }
        return commands
    }
}
