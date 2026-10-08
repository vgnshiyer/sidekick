import Foundation
import SidekickCore
import XCTest
@testable import TerminalKit

final class TerminalFocusTests: XCTestCase {
    // MARK: Process ancestry

    private let ps = """
          1     0 ??       /sbin/launchd
        500     1 ??       /Applications/Ghostty.app/Contents/MacOS/ghostty
        501   500 ttys001  /usr/bin/login
        502   501 ttys001  -zsh
        503   502 ttys001  /Users/me/Library/Application Support/Claude/claude-code/2.1.293/claude
        700     1 ??       tmux
        701   700 ttys004  -zsh
        702   701 ttys004  claude
        800   801 ??       loop-a
        801   800 ??       loop-b
        garbage line
        """

    func testProcessTableParsesCommandsWithSpacesAndTTYs() {
        let table = ProcessTable(psOutput: ps)
        let claude = table.entry(503)
        XCTAssertEqual(claude?.ppid, 502)
        XCTAssertEqual(claude?.tty, "ttys001")
        XCTAssertEqual(claude?.command, "/Users/me/Library/Application Support/Claude/claude-code/2.1.293/claude")
        XCTAssertEqual(claude?.name, "claude")
        XCTAssertNil(table.entry(500)?.tty)
        XCTAssertEqual(table.entry(700)?.name, "tmux")
    }

    func testAncestryWalksUpToLaunchd() {
        let table = ProcessTable(psOutput: ps)
        XCTAssertEqual(table.ancestry(of: 503).map(\.pid), [503, 502, 501, 500])
        XCTAssertEqual(table.ancestry(of: 702).map(\.name), ["claude", "-zsh", "tmux"])
        XCTAssertEqual(table.ancestry(of: 800).map(\.pid), [800, 801], "cycles stop")
        XCTAssertEqual(table.ancestry(of: 999), [])
    }

    // MARK: tmux

    func testTmuxRegistryField() {
        let pane = TmuxPane(registryField: "probe:@0.%3")
        XCTAssertEqual(pane, TmuxPane(session: "probe", window: "probe:@0", pane: "%3"))
        XCTAssertEqual(TmuxPane(registryField: "work.2:1.0"), TmuxPane(session: "work.2", window: "work.2:1", pane: "work.2:1.0"))
        XCTAssertNil(TmuxPane(registryField: "no window"))
        XCTAssertNil(TmuxPane(registryField: "a;b:@0.%1"))
        XCTAssertNil(TmuxPane(registryField: ""))
    }

    func testTmuxSocketFromServerArguments() {
        let dir = "/private/tmp/tmux-501"
        func socket(_ args: String) -> String { TmuxServer.socketPath(serverArgs: args, uid: 501) }
        XCTAssertEqual(socket("tmux"), "\(dir)/default")
        XCTAssertEqual(socket("tmux new-session -s work"), "\(dir)/default")
        XCTAssertEqual(socket("tmux -L petprobe new-session -d -s probe claude"), "\(dir)/petprobe")
        XCTAssertEqual(socket("tmux -Lpetprobe attach"), "\(dir)/petprobe")
        XCTAssertEqual(socket("tmux -2u -L other"), "\(dir)/other")
        XCTAssertEqual(socket("tmux -f /etc/tmux.conf -L conf new"), "\(dir)/conf")
        XCTAssertEqual(socket("tmux -S /tmp/shared.sock attach"), "/tmp/shared.sock")
        XCTAssertEqual(socket("/opt/homebrew/bin/tmux -S/tmp/x"), "/tmp/x")
        XCTAssertEqual(socket("tmux new -L ignored-after-command"), "\(dir)/default")
    }

    func testTmuxListParsing() {
        let panes = TmuxServer.parsePanes("/dev/ttys004 @1 %2 my session\n/dev/ttys005 @1 %3 my session\nbad\n")
        XCTAssertEqual(panes["/dev/ttys004"], TmuxPane(session: "my session", window: "@1", pane: "%2"))
        XCTAssertEqual(panes.count, 2)
        XCTAssertEqual(TmuxServer.parseClients("4242 /dev/ttys007\n\nx /dev/ttys008\n4343 /dev/ttys009\n"), [4242, 4343])
    }

    /// Runs the tmux step against a private, detached server: panes get selected, no client means no app to activate.
    func testFocusSelectsThePaneOnTheOwningServer() async throws {
        guard let tmux = TmuxServer.fallbackExecutables.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("tmux is not installed")
        }
        let name = "sk-test-\(getpid())"
        func run(_ args: [String]) async -> ShellResult {
            await Shell.run(tmux, ["-L", name] + args, env: ["TMUX": ""])
        }
        let created = await run(["new-session", "-d", "-s", "focus", "sleep 60"])
        addTeardownBlock {
            _ = await Shell.run(tmux, ["-L", name, "kill-server"])
            try? FileManager.default.removeItem(atPath: TmuxServer.socketPath(serverArgs: "tmux -L \(name)", uid: getuid()))
        }
        let split = await run(["split-window", "-t", "focus", "sleep 60"])
        XCTAssertTrue(created.ok && split.ok, created.stderr + split.stderr)

        let listed = await run(["list-panes", "-t", "focus", "-F", "#{pane_id} #{pane_pid} #{window_id}"]).stdout
        let panes = listed.split(separator: "\n").map { $0.split(separator: " ").map(String.init) }
        guard panes.count == 2, panes.allSatisfy({ $0.count == 3 }) else { return XCTFail("unexpected panes: \(listed)") }
        let (first, second) = (panes[0], panes[1])

        func activePane() async -> String {
            await run(["display-message", "-p", "-t", "focus", "#{pane_id}"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let byField = await TerminalFocus.focus(pid: Int32(first[1]), cwd: nil, titleHint: nil, tmux: "focus:\(first[2]).\(first[0])")
        XCTAssertFalse(byField, "no client is attached, so nothing is on screen")
        let afterField = await activePane()
        XCTAssertEqual(afterField, first[0])

        _ = await TerminalFocus.focus(pid: Int32(second[1]), cwd: nil, titleHint: nil, tmux: nil)
        let afterTTY = await activePane()
        XCTAssertEqual(afterTTY, second[0], "without a registry field the pane is found by tty")
    }

    // MARK: AppleScript

    func testAppleScriptLiteralEscapesQuotesAndBackslashes() {
        XCTAssertEqual(AppleScript.literal("plain"), #""plain""#)
        XCTAssertEqual(AppleScript.literal(#"say "hi" \ bye"#), #""say \"hi\" \\ bye""#)
        XCTAssertEqual(AppleScript.literal("two\nlines\r\n\ttab"), #""two\nlines\r\n\ttab""#)
        XCTAssertEqual(AppleScript.literal("✳ Fix bug"), "\"✳ Fix bug\"")

        let hostile = #"x" & (do shell script "touch /tmp/pwned") & ""#
        let literal = AppleScript.literal(hostile)
        XCTAssertEqual(literal, #""x\" & (do shell script \"touch /tmp/pwned\") & \"""#)
        XCTAssertTrue(AppleScript.terminalTab(tty: hostile).contains("if tty of t is \(literal) then"))
        XCTAssertTrue(AppleScript.ghosttyFocus(id: hostile).contains("focus terminal id \(literal)"))
    }

    func testAppleScriptLiteralRoundTripsThroughOsascript() async throws {
        let text = #"quote " backslash \ and ✳ glyph"#
        let result = await Shell.appleScript("return \(AppleScript.literal(text))")
        XCTAssertTrue(result.ok, result.stderr)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .newlines), text)
    }

    // MARK: Ghostty

    func testGhosttyParseAndMatch() throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("sk-ghostty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: work) }
        let workPath = work.resolvingSymlinksInPath().path

        let output = "A\u{1F}/Users/me/repo\u{1F}zsh\u{1E}B\u{1F}/Users/me/repo/\u{1F}✳ Fix login bug\u{1E}"
            + "C\u{1F}\u{1F}✳ Fix login bug\u{1E}D\u{1F}\(workPath)\u{1F}claude\u{1E}\n"
        let terminals = GhosttyTerminal.parse(output)
        XCTAssertEqual(terminals.map(\.id), ["A", "B", "C", "D"])
        XCTAssertEqual(terminals[2].workingDirectory, "")

        XCTAssertEqual(GhosttyTerminal.best(in: terminals, cwd: "/Users/me/repo", titleHint: "Fix login bug")?.id, "B")
        XCTAssertEqual(GhosttyTerminal.best(in: terminals, cwd: "/Users/me/repo", titleHint: "fix LOGIN")?.id, "B")
        XCTAssertNil(GhosttyTerminal.best(in: terminals, cwd: "/Users/me/repo", titleHint: "Other"),
                     "two terminals in the folder and no title match: ambiguous")
        XCTAssertNil(GhosttyTerminal.best(in: terminals, cwd: "/Users/me/repo", titleHint: nil))
        XCTAssertEqual(GhosttyTerminal.best(in: terminals, cwd: workPath, titleHint: "Other")?.id, "D",
                       "the only terminal in the folder")
        XCTAssertEqual(GhosttyTerminal.best(in: terminals, cwd: "/private" + workPath, titleHint: nil)?.id, "D",
                       "/var and /private/var name the same folder")
        XCTAssertNil(GhosttyTerminal.best(in: terminals, cwd: "/Users/me/other", titleHint: "Fix login bug"))
    }
}
