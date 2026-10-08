import SidekickCore
import XCTest
@testable import CodexKit

final class CodexCLITests: XCTestCase {
    func testQueueCommandLine() {
        XCTAssertEqual(
            CodexCLI.queueArguments(threadId: "01a11d34-3367-7d61-8a6a-68dc1d91d5f8", text: "-v please\nand more"),
            ["queue", "--thread=01a11d34-3367-7d61-8a6a-68dc1d91d5f8", "--message=-v please\nand more"])
    }

    func testVersionParsingAndNewest() {
        XCTAssertEqual(CodexCLI.version(from: "codex-cli 0.160.1\n"), [0, 160, 1])
        XCTAssertEqual(CodexCLI.version(from: "codex-cli 1.2.0-beta.3"), [1, 2, 0, 3])
        XCTAssertNil(CodexCLI.version(from: "codex-cli"))

        XCTAssertEqual(CodexCLI.newest([("desktop", [0, 160, 1]), ("brew", [0, 159, 0])]), "desktop")
        XCTAssertEqual(CodexCLI.newest([("desktop", [0, 159, 0]), ("brew", [0, 160, 0])]), "brew")
        XCTAssertEqual(CodexCLI.newest([("desktop", [0, 160, 1]), ("brew", [0, 160, 1])]), "desktop")
        XCTAssertNil(CodexCLI.newest([]))
    }

    func testQueueOutcome() async {
        let ok = await Shell.run("/usr/bin/true")
        XCTAssertEqual(CodexCLI.queueOutcome(ok, lastTurnInterrupted: false), .queued("Runs when Codex is idle (up to ~10 s)"))
        XCTAssertEqual(CodexCLI.queueOutcome(ok, lastTurnInterrupted: true), .queued("Paused in Codex — open to resume"))

        let failed = await Shell.run("/bin/sh", ["-c", "printf '\\nError: no rollout found\\nmore\\n' >&2; exit 1"])
        XCTAssertEqual(CodexCLI.queueOutcome(failed, lastTurnInterrupted: false), .failed("Error: no rollout found"))
        let silent = await Shell.run("/usr/bin/false")
        XCTAssertEqual(CodexCLI.queueOutcome(silent, lastTurnInterrupted: false), .failed("codex queue failed"))
    }

    func testThreadURL() {
        XCTAssertEqual(
            CodexCLI.threadURL(id: "01a11d34-3367-7d61-8a6a-68dc1d91d5f8")?.absoluteString,
            "codex://threads/01a11d34-3367-7d61-8a6a-68dc1d91d5f8")
    }

    func testTerminalProcessesFromPS() {
        let ps = """
              101 ??       /Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex app-server --analytics-default-enabled
              102 ttys001  /opt/homebrew/bin/codex
              103 ttys002  codex resume 01a11d34-3367-7d61-8a6a-68dc1d91d5f8
              104 ttys003  /opt/homebrew/bin/codex app-server --listen unix://
              105 ttys004  -fish
              106 ??       /opt/homebrew/bin/codex queue --thread=x
              107 ttys005  /usr/bin/vim codex
            """
        XCTAssertEqual(CodexCLI.terminalProcesses(fromPS: ps), [
            CodexCLI.Process(pid: 102, args: "/opt/homebrew/bin/codex"),
            CodexCLI.Process(pid: 103, args: "codex resume 01a11d34-3367-7d61-8a6a-68dc1d91d5f8"),
        ])
    }

    func testOwnerSelection() {
        let processes = [
            CodexCLI.Process(pid: 102, args: "/opt/homebrew/bin/codex"),
            CodexCLI.Process(pid: 103, args: "codex resume abc"),
        ]
        XCTAssertEqual(CodexCLI.owner(of: "abc", among: processes, lockHolders: [102]), 102)
        XCTAssertEqual(CodexCLI.owner(of: "abc", among: processes, lockHolders: [999]), 103)
        XCTAssertNil(CodexCLI.owner(of: "zzz", among: processes, lockHolders: []))
    }

    func testLsofParsing() {
        XCTAssertEqual(CodexCLI.pids(fromLsof: "123\n456\n"), [123, 456])
        XCTAssertEqual(CodexCLI.pids(fromLsof: ""), [])
        XCTAssertEqual(CodexCLI.cwd(fromLsof: "p123\nfcwd\nn/Users/me/project\n"), "/Users/me/project")
        XCTAssertNil(CodexCLI.cwd(fromLsof: ""))
    }

    func testFirstLine() {
        XCTAssertEqual(CodexCLI.firstLine("\n  Error: boom  \nnext"), "Error: boom")
        XCTAssertNil(CodexCLI.firstLine(" \n"))
    }
}
