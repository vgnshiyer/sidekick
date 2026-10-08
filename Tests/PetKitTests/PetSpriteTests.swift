import CoreGraphics
import QuartzCore
import XCTest
@testable import PetKit

final class PetSpriteTests: XCTestCase {
    func testRowSpecsMatchTheCodexContract() {
        XCTAssertEqual(PetRow.allCases.map(\.frameCount), [6, 8, 8, 4, 5, 8, 6, 6, 6])
        XCTAssertEqual(PetRow.allCases.map(\.name), [
            "idle", "running-right", "running-left", "waving", "jumping",
            "failed", "waiting", "running", "review",
        ])
        XCTAssertEqual(PetRow.idle.frameDurations, [0.28, 0.11, 0.11, 0.14, 0.14, 0.32])
        XCTAssertEqual(PetRow.runningRight.frameDurations, Array(repeating: 0.12, count: 7) + [0.22])
        XCTAssertEqual(PetRow.waving.frameDurations, [0.14, 0.14, 0.14, 0.28])
        XCTAssertEqual(PetRow.jumping.frameDurations.last, 0.28)
        XCTAssertEqual(PetRow.failed.frameDurations.last, 0.24)
        XCTAssertEqual(PetRow.waiting.frameDurations, [0.15, 0.15, 0.15, 0.15, 0.15, 0.26])
        XCTAssertEqual(PetRow.running.frameDurations.last, 0.22)
        XCTAssertEqual(PetRow.review.playDuration, 1.03, accuracy: 1e-9)
    }

    func testAtlasRowCounts() {
        XCTAssertEqual(PetAtlas.rowCount(width: 1536, height: 1872), 9)
        XCTAssertEqual(PetAtlas.rowCount(width: 1536, height: 2288), 11)
        XCTAssertNil(PetAtlas.rowCount(width: 1536, height: 2080))
        XCTAssertNil(PetAtlas.rowCount(width: 1537, height: 1872))
    }

    func testContentsRectCountsRowsFromTheTop() {
        let v1 = PetSprite(atlas: Fixtures.makeImage(width: 1536, height: 1872), rowCount: 9)
        assertRect(v1.contentsRect(row: .idle, frame: 0), CGRect(x: 0, y: 8.0 / 9, width: 0.125, height: 1.0 / 9))
        assertRect(v1.contentsRect(row: .review, frame: 5), CGRect(x: 0.625, y: 0, width: 0.125, height: 1.0 / 9))

        let v2 = PetSprite(atlas: Fixtures.makeImage(width: 1536, height: 2288), rowCount: 11)
        assertRect(v2.contentsRect(row: .idle, frame: 0), CGRect(x: 0, y: 10.0 / 11, width: 0.125, height: 1.0 / 11))
        assertRect(v2.contentsRect(row: .review, frame: 0), CGRect(x: 0, y: 2.0 / 11, width: 0.125, height: 1.0 / 11))
    }

    /// The layer must show the cell the row names, whatever Core Animation's unit-space origin.
    func testLayerShowsTheRequestedCell() {
        let atlas = Fixtures.makeImage(width: 1536, height: 1872) { context in
            for row in PetRow.allCases {
                // Encode the row in red and the frame in green; context origin is bottom-left.
                for frame in 0..<8 {
                    context.setFillColor(CGColor(
                        srgbRed: CGFloat(row.rawValue) / 8, green: CGFloat(frame) / 7, blue: 0, alpha: 1))
                    context.fill(CGRect(x: frame * 192, y: (8 - row.rawValue) * 208, width: 192, height: 208))
                }
            }
        }
        let sprite = PetSprite(atlas: atlas, rowCount: 9)
        for (row, frame) in [(PetRow.idle, 0), (.waving, 2), (.review, 5)] {
            let layer = CALayer()
            layer.frame = CGRect(x: 0, y: 0, width: 8, height: 8)
            layer.contents = atlas
            layer.contentsRect = sprite.contentsRect(row: row, frame: frame)
            let (red, green) = centerColor(of: layer)
            XCTAssertEqual(red, Double(row.rawValue) / 8, accuracy: 0.02, "\(row)")
            XCTAssertEqual(green, Double(frame) / 7, accuracy: 0.02, "\(row) frame \(frame)")
        }
    }

    func testMasksFollowEachFrame() throws {
        // An opaque 40x60 px block in waving frame 2, at x 50..<90 and y 100..<160 from the cell's top.
        let atlas = Fixtures.makeImage(width: 1536, height: 1872) { context in
            context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
            let cellTop = 1872 - 3 * 208
            context.fill(CGRect(x: 2 * 192 + 50, y: cellTop - 160, width: 40, height: 60))
            // A faint pixel below the threshold elsewhere in the cell.
            context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.05))
            context.fill(CGRect(x: 2 * 192 + 10, y: cellTop - 20, width: 4, height: 4))
        }
        let sprite = PetSprite(atlas: atlas, rowCount: 9)

        let inside = CGPoint(x: 70.0 / 192, y: 1 - 130.0 / 208)
        XCTAssertTrue(sprite.isOpaque(row: .waving, frame: 2, at: inside))
        XCTAssertFalse(sprite.isOpaque(row: .waving, frame: 1, at: inside))
        XCTAssertFalse(sprite.isOpaque(row: .idle, frame: 2, at: inside))
        XCTAssertFalse(sprite.isOpaque(row: .waving, frame: 2, at: CGPoint(x: 0.1, y: 0.9)))
        XCTAssertFalse(sprite.isOpaque(row: .waving, frame: 2, at: CGPoint(x: 12.0 / 192, y: 1 - 18.0 / 208)))
        XCTAssertFalse(sprite.isOpaque(row: .waving, frame: 9, at: inside))
        XCTAssertFalse(sprite.isOpaque(row: .waving, frame: 2, at: CGPoint(x: 1.5, y: 0.5)))

        let bounds = try XCTUnwrap(sprite.opaqueBounds(row: .waving, frame: 2))
        assertRect(bounds, CGRect(x: 50.0 / 192, y: 1 - 160.0 / 208, width: 40.0 / 192, height: 60.0 / 208))
        XCTAssertNil(sprite.opaqueBounds(row: .idle, frame: 0))
    }

    func testTrayAnchorSpansEveryInPlaceFrame() {
        // Cell-relative blocks, y from the cell's top: idle body, a "!" above it while waiting,
        // and a drag frame that reaches higher still but must not count.
        func block(_ row: PetRow, _ frame: Int, x: Int, y: Int, width: Int, height: Int) -> CGRect {
            CGRect(x: frame * 192 + x, y: 1872 - row.rawValue * 208 - y - height, width: width, height: height)
        }
        let atlas = Fixtures.makeImage(width: 1536, height: 1872) { context in
            context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
            context.fill(block(.idle, 0, x: 40, y: 100, width: 100, height: 80))
            context.fill(block(.waiting, 3, x: 90, y: 60, width: 10, height: 30))
            context.fill(block(.runningLeft, 1, x: 0, y: 0, width: 10, height: 10))
        }
        let sprite = PetSprite(atlas: atlas, rowCount: 9)
        assertRect(sprite.trayAnchor, CGRect(x: 40.0 / 192, y: 1 - 180.0 / 208, width: 100.0 / 192, height: 120.0 / 208))
    }

    func testFrameImageIsOneCell() throws {
        let sprite = PetSprite(atlas: Fixtures.makeImage(width: 1536, height: 2288), rowCount: 11)
        let image = try XCTUnwrap(sprite.frameImage(row: .review, frame: 3))
        XCTAssertEqual(image.width, 192)
        XCTAssertEqual(image.height, 208)
        XCTAssertEqual(sprite.pixelRect(row: .review, frame: 3), CGRect(x: 576, y: 1664, width: 192, height: 208))
    }

    func testPlaceholderHasAVisibleBodyInEveryFrame() throws {
        let sprite = PetSprite.placeholder()
        XCTAssertEqual(sprite.rowCount, 9)
        for row in PetRow.allCases {
            for frame in 0..<row.frameCount {
                XCTAssertTrue(sprite.isOpaque(row: row, frame: frame, at: CGPoint(x: 0.5, y: 0.3)), "\(row) \(frame)")
                XCTAssertFalse(sprite.isOpaque(row: row, frame: frame, at: CGPoint(x: 0.05, y: 0.95)))
            }
        }
        let bounds = try XCTUnwrap(sprite.opaqueBounds(row: .idle, frame: 0))
        XCTAssertLessThan(bounds.maxY, 0.8)
    }

    // MARK: helpers

    private func centerColor(of layer: CALayer) -> (Double, Double) {
        var pixels = [UInt8](repeating: 0, count: 8 * 8 * 4)
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            layer.render(in: context)
        }
        let i = (4 * 8 + 4) * 4
        return (Double(pixels[i]) / 255, Double(pixels[i + 1]) / 255)
    }

    private func assertRect(_ a: CGRect, _ b: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.minX, b.minX, accuracy: 1e-6, file: file, line: line)
        XCTAssertEqual(a.minY, b.minY, accuracy: 1e-6, file: file, line: line)
        XCTAssertEqual(a.width, b.width, accuracy: 1e-6, file: file, line: line)
        XCTAssertEqual(a.height, b.height, accuracy: 1e-6, file: file, line: line)
    }
}
