import XCTest
@testable import CodexKit

final class CodexHooksTests: XCTestCase {
    func testInstalledWhenHooksJSONRunsTheScript() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sk-hooks-\(UUID().uuidString)")
        let home = root.appendingPathComponent("codex"), script = root.appendingPathComponent("App Support/bin/codex-hook")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let hooks = home.appendingPathComponent("hooks.json")

        func write(_ commands: [String]) throws {
            let groups = commands.map { ["hooks": [["type": "command", "command": $0]]] }
            try JSONSerialization.data(withJSONObject: ["hooks": ["Stop": groups]]).write(to: hooks)
        }

        XCTAssertFalse(CodexHooks.isInstalled(codexHome: home, script: script), "no hooks.json")
        try write(["echo other", "'\(script.path)'"])
        XCTAssertFalse(CodexHooks.isInstalled(codexHome: home, script: script), "no script")

        try Data("#!/bin/sh\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        XCTAssertTrue(CodexHooks.isInstalled(codexHome: home, script: script))

        try write(["echo other"])
        XCTAssertFalse(CodexHooks.isInstalled(codexHome: home, script: script), "only other hooks")
        try Data("{not json".utf8).write(to: hooks)
        XCTAssertFalse(CodexHooks.isInstalled(codexHome: home, script: script))
    }
}
