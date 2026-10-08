import Foundation

/// AppleScript sources for the terminals Sidekick can focus. Every interpolated value goes through `literal`.
enum AppleScript {
    /// `text` as a double-quoted AppleScript string literal.
    static func literal(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    /// Selects the Terminal.app tab whose tty is `tty` (e.g. "/dev/ttys003"), brings its window forward and
    /// activates Terminal. Returns "ok" when a tab matched.
    static func terminalTab(tty: String) -> String {
        """
        tell application id "com.apple.Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is \(literal(tty)) then
                        set selected tab of w to t
                        set frontmost of w to true
                        activate
                        return "ok"
                    end if
                end repeat
            end repeat
        end tell
        return "none"
        """
    }

    /// Lists Ghostty terminals as `id US working-directory US title RS` records (ASCII 31/30 separators).
    static let ghosttyTerminals = """
        tell application id "com.mitchellh.ghostty"
            set out to ""
            repeat with t in terminals
                set wd to ""
                set nm to ""
                try
                    set wd to (working directory of t) as text
                end try
                try
                    set nm to (name of t) as text
                end try
                set out to out & (id of t) & (character id 31) & wd & (character id 31) & nm & (character id 30)
            end repeat
            return out
        end tell
        """

    /// Focuses one Ghostty terminal by id and activates Ghostty.
    static func ghosttyFocus(id: String) -> String {
        """
        tell application id "com.mitchellh.ghostty"
            focus terminal id \(literal(id))
            activate
        end tell
        """
    }
}

/// One Ghostty terminal surface as reported by its AppleScript dictionary.
struct GhosttyTerminal: Equatable, Sendable {
    let id: String
    let workingDirectory: String
    let title: String

    /// Parses the output of `AppleScript.ghosttyTerminals`.
    static func parse(_ output: String) -> [GhosttyTerminal] {
        output.split(separator: "\u{1E}").compactMap { record in
            let fields = record.split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init)
            let id = fields.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard fields.count == 3, !id.isEmpty else { return nil }
            return GhosttyTerminal(id: id, workingDirectory: fields[1], title: fields[2])
        }
    }

    /// The terminal whose working directory is `cwd` and whose title contains `titleHint`, or the only
    /// terminal in `cwd`. Nil when the choice is ambiguous, so the caller falls back to the hosting app.
    static func best(in terminals: [GhosttyTerminal], cwd: String, titleHint: String?) -> GhosttyTerminal? {
        let target = normalized(cwd)
        let candidates = terminals.filter { !$0.workingDirectory.isEmpty && normalized($0.workingDirectory) == target }
        if let hint = titleHint?.trimmingCharacters(in: .whitespacesAndNewlines), !hint.isEmpty,
           let titled = candidates.first(where: { $0.title.localizedCaseInsensitiveContains(hint) }) {
            return titled
        }
        return candidates.count == 1 ? candidates.first : nil
    }

    /// Compares /tmp and /private/tmp (and trailing slashes) as the same directory.
    private static func normalized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
}
