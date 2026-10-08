import Foundation

/// File locations. Each can be overridden by an environment variable so tests and
/// scratch runs never touch the real ~/.claude or ~/.codex.
public enum Paths {
    public static var home: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    /// CLAUDE_CONFIG_DIR or ~/.claude
    public static var claudeDir: URL {
        if let v = env("CLAUDE_CONFIG_DIR") { return URL(fileURLWithPath: v, isDirectory: true) }
        return home.appendingPathComponent(".claude", isDirectory: true)
    }

    /// CODEX_HOME or ~/.codex
    public static var codexHome: URL {
        if let v = env("CODEX_HOME") { return URL(fileURLWithPath: v, isDirectory: true) }
        return home.appendingPathComponent(".codex", isDirectory: true)
    }

    /// SIDEKICK_HOME or ~/Library/Application Support/Sidekick (created 0700 on first use).
    public static var appSupport: URL {
        let url: URL
        if let v = env("SIDEKICK_HOME") {
            url = URL(fileURLWithPath: v, isDirectory: true)
        } else {
            url = home.appendingPathComponent("Library/Application Support/Sidekick", isDirectory: true)
        }
        try? FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }

    /// The bridge's Unix socket. Must stay under 104 bytes (sun_path limit).
    public static var socketPath: String {
        appSupport.appendingPathComponent("bridge.sock").path
    }

    /// Persisted UI state (acks, pet choice, positions).
    public static var stateFile: URL {
        appSupport.appendingPathComponent("state.json")
    }

    /// User-installed pet packs.
    public static var userPetsDir: URL {
        appSupport.appendingPathComponent("Pets", isDirectory: true)
    }

    private static func env(_ key: String) -> String? {
        guard let v = ProcessInfo.processInfo.environment[key], !v.isEmpty else { return nil }
        return v
    }
}
