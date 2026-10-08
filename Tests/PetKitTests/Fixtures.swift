import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

/// Builds pet packs and atlases on disk for tests.
enum Fixtures {
    static func makeImage(width: Int, height: Int, paint: (CGContext) -> Void = { _ in }) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        paint(context)
        return context.makeImage()!
    }

    static func writePNG(_ image: CGImage, to url: URL) {
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    /// Writes `<root>/<folder>/pet.json` (unless `manifest` is nil) and an empty atlas of the given size.
    @discardableResult
    static func makePack(
        in root: URL, folder: String, manifest: [String: Any]?,
        sheet: String = "spritesheet.png", size: (Int, Int)? = (1536, 1872)
    ) -> URL {
        let dir = root.appendingPathComponent(folder, isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let manifest {
            let data = try! JSONSerialization.data(withJSONObject: manifest)
            try! data.write(to: dir.appendingPathComponent("pet.json"))
        }
        if let size {
            writePNG(makeImage(width: size.0, height: size.1), to: dir.appendingPathComponent(sheet))
        }
        return dir
    }

    static func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("petkit-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
