import Foundation
import XCTest
@testable import CodexKit

final class CodexMascotTests: XCTestCase {
    private var app: URL!

    override func setUpWithError() throws {
        app = FileManager.default.temporaryDirectory.appendingPathComponent("mascot-\(UUID().uuidString)/ChatGPT.app")
        try FileManager.default.createDirectory(
            at: app.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: app.deletingLastPathComponent())
    }

    /// Writes an asar holding `files` (name to bytes) under webview/assets.
    private func writeArchive(_ files: [(String, Data)]) throws {
        var offset = 0, entries: [String: Any] = [:], payload = Data()
        for (name, data) in files {
            entries[name] = ["size": data.count, "offset": String(offset)]
            payload += data
            offset += data.count
        }
        let tree = ["files": ["webview": ["files": ["assets": ["files": entries]]]]]
        let json = try JSONSerialization.data(withJSONObject: tree)
        let padded = (json.count + 3) & ~3
        func word(_ value: Int) -> Data { withUnsafeBytes(of: UInt32(value).littleEndian) { Data($0) } }
        var archive = word(4) + word(8 + padded) + word(4 + padded) + word(json.count) + json
        archive += Data(count: padded - json.count)
        archive += payload
        try archive.write(to: app.appendingPathComponent("Contents/Resources/app.asar"))
    }

    func testReadsTheNewestSheet() throws {
        try writeArchive([
            ("other-spritesheet-v9-aa.webp", Data("other".utf8)),
            ("codex-spritesheet-v5-0f.webp", Data("old".utf8)),
            ("codex-spritesheet-v6-51045ae208c0.webp", Data("new".utf8)),
        ])
        XCTAssertEqual(CodexMascot.spritesheet(inApp: app), Data("new".utf8))
    }

    func testMissingSheetOrArchive() throws {
        XCTAssertNil(CodexMascot.spritesheet(inApp: app))
        try writeArchive([("codex-logo.png", Data([1]))])
        XCTAssertNil(CodexMascot.spritesheet(inApp: app))
        try Data("not an archive".utf8).write(to: app.appendingPathComponent("Contents/Resources/app.asar"))
        XCTAssertNil(CodexMascot.spritesheet(inApp: app))
    }
}
