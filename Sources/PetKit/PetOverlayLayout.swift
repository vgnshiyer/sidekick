import CoreGraphics

/// Which side of the pet the bubble tray sits on.
public enum TrayPlacement: Sendable, Equatable {
    case above, below
}

/// Which side of the pet's head a quip sits on; its tail points back at the head.
public enum QuipSide: Sendable, Equatable {
    case left, right
}

/// A one-line speech bubble to place beside the pet's head.
public struct QuipRequest: Sendable, Equatable {
    /// The bubble's size, tail included.
    public var size: CGSize
    /// Transparent room around the bubble for its shadow, per side.
    public var margin: CGSize
    /// The pet's resting art in unit coordinates of the pet (origin bottom-left). The bubble sits
    /// beside it, centered at head height: `PetOverlayLayout.headHeight` down from its top.
    public var head: CGRect
    /// Screen rectangles the bubble must not cover, such as the count badge. It drops below them, or
    /// steps past them when that would take it below the art, keeping `PetOverlayLayout.quipClearance`.
    public var avoiding: [CGRect]

    public init(size: CGSize, margin: CGSize, head: CGRect, avoiding: [CGRect] = []) {
        self.size = size
        self.margin = margin
        self.head = head
        self.avoiding = avoiding
    }
}

/// Places the pet, its bubble tray and any quip in one panel, keeping them on screen.
/// All rectangles use AppKit screen coordinates (origin bottom-left).
public struct PetOverlayLayout: Sendable, Equatable {
    /// The panel's frame on screen.
    public var panelFrame: CGRect
    /// The pet's frame inside the panel.
    public var petFrame: CGRect
    /// The tray's frame inside the panel, including its margin, or nil when there is no tray.
    public var trayFrame: CGRect?
    public var placement: TrayPlacement
    /// True when the tray extends rightwards from the pet (the pet is on the left half of the screen).
    public var trayGrowsRight: Bool
    /// Horizontal center of the pet's art, measured from the tray's left edge.
    public var tailX: CGFloat
    /// The quip's frame inside the panel, including its margin, or nil when there is no quip.
    public var quipFrame: CGRect?
    public var quipSide: QuipSide

    /// How far down the resting art a quip's tail points, as a fraction of the art's height.
    public static let headHeight: CGFloat = 0.27
    /// Space a quip keeps from anything it must avoid.
    public static let quipClearance: CGFloat = 4

    /// - Parameters:
    ///   - pet: the pet's frame on screen.
    ///   - art: the part of the pet the tray must clear, in unit coordinates of `pet` (origin
    ///     bottom-left); the tail points at its horizontal center. See `PetSprite.trayAnchor`.
    ///   - tray: the tray's preferred size including `margin`, or nil to show the pet alone.
    ///   - margin: transparent room around the bubbles (shadows), per side.
    ///   - gap: space between the art and the nearest bubble's tail.
    ///   - screen: the visible frame of the pet's screen.
    ///   - petPadding: transparent room kept around the pet, so a badge on its corner isn't clipped.
    ///   - quip: a speech bubble to show beside the pet's head, or nil for none. The panel grows to
    ///     hold it; the pet keeps its place on screen.
    public init(
        pet: CGRect, art: CGRect, tray: CGSize?, margin: CGSize, gap: CGFloat, screen: CGRect, petPadding: CGFloat = 0,
        quip: QuipRequest? = nil
    ) {
        trayGrowsRight = pet.midX < screen.midX
        let artRect = pet.unitRect(art)
        var trayOnScreen: CGRect?
        placement = .above
        tailX = 0
        if let tray {
            let roomAbove = max(0, screen.maxY - (artRect.maxY + gap))
            let roomBelow = max(0, artRect.minY - gap - screen.minY)
            let bubblesHeight = tray.height - 2 * margin.height
            placement = bubblesHeight <= roomAbove || roomAbove >= roomBelow ? .above : .below

            let height = min(tray.height, (placement == .above ? roomAbove : roomBelow) + 2 * margin.height)
            let y = placement == .above
                ? artRect.maxY + gap - margin.height
                : artRect.minY - gap + margin.height - height

            // Grow away from the nearer screen edge, then keep the bubbles on screen.
            var x = trayGrowsRight ? pet.minX - margin.width : pet.maxX + margin.width - tray.width
            x = min(max(x, screen.minX - margin.width), screen.maxX + margin.width - tray.width)

            trayOnScreen = CGRect(x: x, y: y, width: tray.width, height: height)
            tailX = artRect.midX - x
        }

        var quipOnScreen: CGRect?
        quipSide = .right
        if let quip {
            // With a tray, the bubble stays on the pet's side of the art's top (or bottom) edge, so it
            // never reaches the tray's bubbles, whichever side of the pet it ends up on.
            var band = screen
            if trayOnScreen != nil {
                band = placement == .above
                    ? CGRect(x: band.minX, y: band.minY, width: band.width, height: artRect.maxY - band.minY)
                    : CGRect(x: band.minX, y: artRect.minY, width: band.width, height: band.maxY - artRect.minY)
            }
            let preferred: QuipSide = trayOnScreen != nil && trayGrowsRight ? .left : .right
            let bubble: CGRect
            (bubble, quipSide) = Self.place(quip, pet: pet, prefer: preferred, gap: gap, band: band, screen: screen)
            quipOnScreen = bubble.insetBy(dx: -quip.margin.width, dy: -quip.margin.height)
        }

        let panel = [trayOnScreen, quipOnScreen].compactMap { $0 }
            .reduce(pet.insetBy(dx: -petPadding, dy: -petPadding)) { $0.union($1) }
        panelFrame = panel
        petFrame = pet.offsetBy(dx: -panel.minX, dy: -panel.minY)
        trayFrame = trayOnScreen?.offsetBy(dx: -panel.minX, dy: -panel.minY)
        quipFrame = quipOnScreen?.offsetBy(dx: -panel.minX, dy: -panel.minY)
    }

    /// The quip's bubble on screen (without margin) and its side: centered at head height beside the
    /// resting art, clear of anything it must avoid, on the preferred side unless only the other fits.
    private static func place(
        _ quip: QuipRequest, pet: CGRect, prefer: QuipSide, gap: CGFloat, band: CGRect, screen: CGRect
    ) -> (CGRect, QuipSide) {
        let head = pet.unitRect(quip.head)
        let size = quip.size
        let centerY = head.maxY - headHeight * head.height
        let y = max(band.minY, min(centerY - size.height / 2, band.maxY - size.height))

        func frame(_ side: QuipSide) -> CGRect {
            let x = side == .right ? head.maxX + gap : head.minX - gap - size.width
            var rect = CGRect(x: x, y: y, width: size.width, height: size.height)
            let obstacles = quip.avoiding.map { $0.insetBy(dx: -quipClearance, dy: -quipClearance) }
            for obstacle in obstacles where obstacle.intersects(rect) {
                // Drop below it while the tail still points at the art, else step past it.
                let below = obstacle.minY - size.height
                if below >= max(head.minY, band.minY) {
                    rect.origin.y = below
                } else {
                    rect.origin.x = side == .right ? obstacle.maxX : obstacle.minX - size.width
                }
            }
            return rect
        }
        func fits(_ rect: CGRect) -> Bool { rect.minX >= screen.minX && rect.maxX <= screen.maxX }

        let other: QuipSide = prefer == .right ? .left : .right
        let side = fits(frame(prefer)) || !fits(frame(other)) ? prefer : other
        var rect = frame(side)
        rect.origin.x = min(max(rect.minX, screen.minX), screen.maxX - size.width)
        return (rect, side)
    }
}

private extension CGRect {
    /// `unit`, given in unit coordinates of this rectangle, in this rectangle's coordinate space.
    func unitRect(_ unit: CGRect) -> CGRect {
        CGRect(
            x: minX + unit.minX * width, y: minY + unit.minY * height,
            width: unit.width * width, height: unit.height * height)
    }
}

/// Pet positions, stored per display as fractions of the room around the pet.
public enum PetPosition {
    /// Bottom-left of `screen`, inset by `inset`.
    public static func defaultOrigin(in screen: CGRect, inset: CGFloat = 24) -> CGPoint {
        CGPoint(x: screen.minX + inset, y: screen.minY + inset)
    }

    /// `origin` as a fraction (0...1 per axis) of the room `screen` leaves around a pet of `size`.
    public static func normalize(_ origin: CGPoint, size: CGSize, in screen: CGRect) -> CGPoint {
        func fraction(_ value: CGFloat, _ start: CGFloat, _ room: CGFloat) -> CGFloat {
            room > 0 ? min(max((value - start) / room, 0), 1) : 0
        }
        return CGPoint(
            x: fraction(origin.x, screen.minX, screen.width - size.width),
            y: fraction(origin.y, screen.minY, screen.height - size.height))
    }

    /// The origin for a normalized position, the inverse of `normalize`.
    public static func origin(normalized point: CGPoint, size: CGSize, in screen: CGRect) -> CGPoint {
        CGPoint(
            x: screen.minX + min(max(point.x, 0), 1) * max(0, screen.width - size.width),
            y: screen.minY + min(max(point.y, 0), 1) * max(0, screen.height - size.height))
    }

    /// Moves `origin` so a pet of `size` lies inside `screen`.
    public static func clamp(_ origin: CGPoint, size: CGSize, in screen: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(origin.x, screen.minX), max(screen.minX, screen.maxX - size.width)),
            y: min(max(origin.y, screen.minY), max(screen.minY, screen.maxY - size.height)))
    }
}

extension PetOverlayLayout {
    /// Frame for a panel of `size` beside `anchor` (a bubble), on the side the tray grows towards
    /// when there is room, kept inside `screen` with an 8 pt inset.
    public static func panelFrame(size: CGSize, beside anchor: CGRect, growsRight: Bool, screen: CGRect) -> CGRect {
        let gap: CGFloat = 8, inset: CGFloat = 8
        let right = anchor.maxX + gap
        let left = anchor.minX - gap - size.width
        var x = growsRight ? right : left
        if growsRight, x + size.width > screen.maxX - inset { x = left }
        if !growsRight, x < screen.minX + inset { x = right }
        x = min(max(x, screen.minX + inset), screen.maxX - inset - size.width)
        let y = min(max(anchor.midY - size.height / 2, screen.minY + inset), screen.maxY - inset - size.height)
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }
}
