import CoreGraphics
import Foundation

/// An atlas ready for display: frame rectangles plus per-frame alpha masks for hit-testing.
///
/// Unit coordinates follow Core Animation on macOS: the origin is the bottom-left corner.
public final class PetSprite: @unchecked Sendable {
    public let atlas: CGImage
    public let rowCount: Int
    /// Union of the visible bounds of every frame the pet plays in place (all rows but the two
    /// drag rows), in unit coordinates of the cell. Nil when all of them are empty.
    public let statusBounds: CGRect?
    /// Masks for rows 0-8, indexed `[row][frame]`.
    private let masks: [[AlphaMask]]

    /// Alpha above this (0-255) counts as part of the pet.
    static let alphaThreshold: UInt8 = 24

    public init(atlas: CGImage, rowCount: Int) {
        self.atlas = atlas
        self.rowCount = rowCount
        let masks = Self.makeMasks(atlas: atlas, rowCount: rowCount)
        self.masks = masks
        statusBounds = PetRow.allCases
            .filter { $0 != .runningLeft && $0 != .runningRight }
            .flatMap { masks[$0.rawValue].compactMap(\.bounds) }
            .reduce(nil) { union, rect in union?.union(rect) ?? rect }
    }

    public convenience init(pack: PetPack) {
        self.init(atlas: pack.atlas, rowCount: pack.rowCount)
    }

    /// The frame's rectangle in `CALayer.contentsRect` unit space.
    public func contentsRect(row: PetRow, frame: Int) -> CGRect {
        let width = 1 / CGFloat(PetAtlas.columns)
        let height = 1 / CGFloat(rowCount)
        return CGRect(
            x: CGFloat(frame) * width,
            y: CGFloat(rowCount - 1 - row.rawValue) * height,
            width: width,
            height: height)
    }

    /// The frame's cell in atlas pixels, origin top-left.
    public func pixelRect(row: PetRow, frame: Int) -> CGRect {
        let width = atlas.width / PetAtlas.columns
        let height = atlas.height / rowCount
        return CGRect(x: frame * width, y: row.rawValue * height, width: width, height: height)
    }

    /// The frame as its own image.
    public func frameImage(row: PetRow, frame: Int) -> CGImage? {
        atlas.cropping(to: pixelRect(row: row, frame: frame))
    }

    /// True when the frame has a visible pixel at `point`, in unit coordinates of the cell.
    public func isOpaque(row: PetRow, frame: Int, at point: CGPoint) -> Bool {
        mask(row: row, frame: frame)?.contains(point) ?? false
    }

    /// Bounds of the frame's visible pixels in unit coordinates of the cell, or nil when it is empty.
    public func opaqueBounds(row: PetRow, frame: Int) -> CGRect? {
        mask(row: row, frame: frame)?.bounds
    }

    /// What the bubble tray is placed against, in unit coordinates of the cell: the resting frame's
    /// width (the tail points at its center) and the full height of `statusBounds`, so status art
    /// such as a "!" above the head never runs into the nearest bubble.
    public var trayAnchor: CGRect {
        let rest = opaqueBounds(row: .idle, frame: 0) ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        guard let all = statusBounds else { return rest }
        return CGRect(x: rest.minX, y: all.minY, width: rest.width, height: all.height)
    }

    private func mask(row: PetRow, frame: Int) -> AlphaMask? {
        guard frame >= 0, frame < masks[row.rawValue].count else { return nil }
        return masks[row.rawValue][frame]
    }

    private static func makeMasks(atlas: CGImage, rowCount: Int) -> [[AlphaMask]] {
        // Gray + alpha, two bytes per pixel with alpha second; rows run top to bottom.
        let width = atlas.width, height = atlas.height
        var pixels = [UInt8](repeating: 0, count: width * height * 2)
        pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 2, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            context.draw(atlas, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        let cellWidth = width / PetAtlas.columns
        let cellHeight = height / rowCount
        return pixels.withUnsafeBufferPointer { buffer in
            PetRow.allCases.map { row in
                (0..<row.frameCount).map { frame in
                    AlphaMask(
                        grayAlpha: buffer, imageWidth: width,
                        origin: (frame * cellWidth, row.rawValue * cellHeight),
                        width: cellWidth, height: cellHeight, threshold: alphaThreshold)
                }
            }
        }
    }
}

/// One frame's visible pixels as a bitset, rows top to bottom.
struct AlphaMask {
    let width: Int
    let height: Int
    private var bits: [UInt64]
    /// Visible bounds in unit coordinates (origin bottom-left), nil when nothing is visible.
    private(set) var bounds: CGRect?

    /// Reads one cell of a gray + alpha bitmap (two bytes per pixel, rows top to bottom).
    init(
        grayAlpha pixels: UnsafeBufferPointer<UInt8>, imageWidth: Int, origin: (x: Int, y: Int),
        width: Int, height: Int, threshold: UInt8
    ) {
        self.width = width
        self.height = height
        bits = [UInt64](repeating: 0, count: (width * height + 63) / 64)
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            let rowStart = ((origin.y + y) * imageWidth + origin.x) * 2 + 1
            for x in 0..<width where pixels[rowStart + 2 * x] > threshold {
                let index = y * width + x
                bits[index >> 6] |= 1 << UInt64(index & 63)
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        if maxX >= 0 {
            let w = CGFloat(width), h = CGFloat(height)
            bounds = CGRect(
                x: CGFloat(minX) / w, y: 1 - CGFloat(maxY + 1) / h,
                width: CGFloat(maxX - minX + 1) / w, height: CGFloat(maxY - minY + 1) / h)
        }
    }

    /// Whether the pixel under `point` (unit coordinates, origin bottom-left) is visible.
    func contains(_ point: CGPoint) -> Bool {
        guard point.x >= 0, point.x < 1, point.y > 0, point.y <= 1 else { return false }
        let x = Int(point.x * CGFloat(width))
        let y = Int((1 - point.y) * CGFloat(height))
        guard x < width, y < height else { return false }
        let index = y * width + x
        return bits[index >> 6] & (1 << UInt64(index & 63)) != 0
    }
}

extension PetSprite {
    /// A neutral rounded blob shown when no pet packs are installed.
    public static func placeholder() -> PetSprite {
        let cell = PetAtlas.logicalCellSize
        let width = Int(cell.width) * PetAtlas.columns
        let height = Int(cell.height) * 9
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setShouldAntialias(false)

        let outline = CGColor(srgbRed: 0.33, green: 0.36, blue: 0.41, alpha: 1)
        let body = CGColor(srgbRed: 0.66, green: 0.70, blue: 0.75, alpha: 1)
        let eye = CGColor(srgbRed: 0.15, green: 0.16, blue: 0.19, alpha: 1)
        for row in PetRow.allCases {
            for frame in 0..<row.frameCount {
                // Context origin is bottom-left; atlas rows count from the top.
                let origin = CGPoint(
                    x: CGFloat(frame) * cell.width,
                    y: CGFloat(8 - row.rawValue) * cell.height)
                let blob = CGRect(x: origin.x + 10, y: origin.y + 6, width: 28, height: 24)
                context.setFillColor(outline)
                context.addPath(CGPath(roundedRect: blob, cornerWidth: 9, cornerHeight: 9, transform: nil))
                context.fillPath()
                context.setFillColor(body)
                context.addPath(CGPath(roundedRect: blob.insetBy(dx: 1, dy: 1), cornerWidth: 8, cornerHeight: 8, transform: nil))
                context.fillPath()
                context.setFillColor(eye)
                context.fill(CGRect(x: blob.minX + 8, y: blob.minY + 12, width: 2, height: 4))
                context.fill(CGRect(x: blob.maxX - 10, y: blob.minY + 12, width: 2, height: 4))
            }
        }
        return PetSprite(atlas: context.makeImage()!, rowCount: 9)
    }
}
