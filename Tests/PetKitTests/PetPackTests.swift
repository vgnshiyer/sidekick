import XCTest
@testable import PetKit

final class PetPackTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        root = Fixtures.temporaryDirectory()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    func testLoadsV1Pack() throws {
        let dir = Fixtures.makePack(in: root, folder: "blob", manifest: [
            "id": "blob", "displayName": "Blob", "description": "A blob.",
            "spriteVersionNumber": 1, "spritesheetPath": "spritesheet.png",
        ])
        let pack = try XCTUnwrap(PetPack.load(from: dir))
        XCTAssertEqual(pack.id, "blob")
        XCTAssertEqual(pack.displayName, "Blob")
        XCTAssertEqual(pack.description, "A blob.")
        XCTAssertEqual(pack.spriteVersion, 1)
        XCTAssertEqual(pack.rowCount, 9)
        XCTAssertEqual(pack.atlas.width, 1536)
        XCTAssertEqual(pack.atlas.height, 1872)
    }

    func testLoadsV2PackByAtlasHeight() throws {
        let dir = Fixtures.makePack(
            in: root, folder: "tall", manifest: ["id": "tall", "spriteVersionNumber": 2], size: (1536, 2288))
        let pack = try XCTUnwrap(PetPack.load(from: dir))
        XCTAssertEqual(pack.spriteVersion, 2)
        XCTAssertEqual(pack.rowCount, 11)
    }

    func testRejectsAtlasOfWrongSize() {
        for size in [(1536, 1800), (1024, 1872), (1536, 2080), (192, 208)] {
            let dir = Fixtures.makePack(in: root, folder: "bad-\(size.0)x\(size.1)", manifest: ["id": "x"], size: size)
            XCTAssertNil(PetPack.load(from: dir), "\(size)")
        }
    }

    func testRejectsMissingOrMalformedManifest() throws {
        XCTAssertNil(PetPack.load(from: Fixtures.makePack(in: root, folder: "none", manifest: nil)))

        let dir = Fixtures.makePack(in: root, folder: "broken", manifest: nil)
        try Data("{not json".utf8).write(to: dir.appendingPathComponent("pet.json"))
        XCTAssertNil(PetPack.load(from: dir))
    }

    func testRejectsMissingSpritesheet() {
        let dir = Fixtures.makePack(in: root, folder: "nosheet", manifest: ["id": "x"], size: nil)
        XCTAssertNil(PetPack.load(from: dir))
    }

    func testRejectsUnknownSpriteVersion() {
        let dir = Fixtures.makePack(in: root, folder: "v3", manifest: ["id": "x", "spriteVersionNumber": 3])
        XCTAssertNil(PetPack.load(from: dir))
    }

    func testRejectsSpritesheetOutsideFolder() {
        Fixtures.writePNG(Fixtures.makeImage(width: 1536, height: 1872), to: root.appendingPathComponent("outside.png"))
        let dir = Fixtures.makePack(
            in: root, folder: "escape", manifest: ["id": "x", "spritesheetPath": "../outside.png"], size: nil)
        XCTAssertNil(PetPack.load(from: dir))
    }

    func testRejectsNonImageSpritesheet() throws {
        let dir = Fixtures.makePack(in: root, folder: "text", manifest: ["id": "x"], size: nil)
        try Data("hello".utf8).write(to: dir.appendingPathComponent("spritesheet.png"))
        XCTAssertNil(PetPack.load(from: dir))
    }

    func testDefaultsToFolderNameAndSpritesheetPNG() throws {
        let dir = Fixtures.makePack(in: root, folder: "quiet-fox", manifest: ["displayName": "  "])
        let pack = try XCTUnwrap(PetPack.load(from: dir))
        XCTAssertEqual(pack.id, "quiet-fox")
        XCTAssertEqual(pack.displayName, "quiet-fox")
        XCTAssertEqual(pack.description, "")
        XCTAssertEqual(pack.spriteVersion, 1)
    }

    func testUsesCustomSpritesheetPath() throws {
        let dir = Fixtures.makePack(
            in: root, folder: "custom", manifest: ["id": "custom", "spritesheetPath": "art/sheet.png"], size: nil)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("art"), withIntermediateDirectories: true)
        Fixtures.writePNG(
            Fixtures.makeImage(width: 1536, height: 1872), to: dir.appendingPathComponent("art/sheet.png"))
        XCTAssertNotNil(PetPack.load(from: dir))
    }

    func testReadsQuips() throws {
        let dir = Fixtures.makePack(in: root, folder: "talker", manifest: [
            "id": "talker", "quips": ["sent": "  Ooooh, can do!\n", "working": "On it"],
        ])
        let quips = try XCTUnwrap(PetPack.load(from: dir)?.quips)
        XCTAssertEqual(quips, PetQuips(sent: "Ooooh, can do!", working: "On it"))
        XCTAssertEqual(quips.text(for: .sent), "Ooooh, can do!")
        XCTAssertEqual(quips.text(for: .working), "On it")
    }

    func testAbsentOrMalformedQuipsMeanNoneAndKeepThePack() throws {
        let cases: [(String, Any?)] = [
            ("absent", nil), ("null", NSNull()), ("string", "hi"), ("array", ["hi"]),
            ("wrong-types", ["sent": 3, "working": ["x"]]), ("blank", ["sent": "  ", "working": ""]),
        ]
        for (folder, quips) in cases {
            var manifest: [String: Any] = ["id": folder]
            manifest["quips"] = quips
            let pack = try XCTUnwrap(PetPack.load(from: Fixtures.makePack(in: root, folder: folder, manifest: manifest)), folder)
            XCTAssertNil(pack.quips, folder)
        }

        let partial = Fixtures.makePack(
            in: root, folder: "partial", manifest: ["id": "partial", "quips": ["sent": "Hi", "working": 7, "extra": "x"]])
        XCTAssertEqual(PetPack.load(from: partial)?.quips, PetQuips(sent: "Hi"))
    }

    func testQuipThrottleAllowsOneQuipPerInterval() {
        var throttle = QuipThrottle()
        XCTAssertTrue(throttle.allow(at: 100))
        XCTAssertFalse(throttle.allow(at: 101))
        XCTAssertFalse(throttle.allow(at: 100 + QuipThrottle.interval - 0.1))
        XCTAssertTrue(throttle.allow(at: 100 + QuipThrottle.interval))
        // A refused quip doesn't restart the wait.
        XCTAssertFalse(throttle.allow(at: 100 + 1.5 * QuipThrottle.interval))
        XCTAssertTrue(throttle.allow(at: 100 + 2 * QuipThrottle.interval))
    }

    func testLibraryKeepsRootOrderSortsByNameAndSkipsDuplicates() throws {
        let first = root.appendingPathComponent("bundled")
        let second = root.appendingPathComponent("user")
        Fixtures.makePack(in: first, folder: "z", manifest: ["id": "zed", "displayName": "Zed"])
        Fixtures.makePack(in: first, folder: "a", manifest: ["id": "ace", "displayName": "Ace"])
        Fixtures.makePack(in: first, folder: "broken", manifest: ["id": "broken"], size: (10, 10))
        Fixtures.makePack(in: second, folder: "dup", manifest: ["id": "ace", "displayName": "Other Ace"])
        Fixtures.makePack(in: second, folder: "b", manifest: ["id": "bee", "displayName": "Bee"])
        try Data().write(to: second.appendingPathComponent("stray-file.json"))

        let packs = PetLibrary.loadAll(from: [first, second, root.appendingPathComponent("missing")])
        XCTAssertEqual(packs.map(\.id), ["ace", "zed", "bee"])
        XCTAssertEqual(packs.first?.displayName, "Ace")
    }
}
