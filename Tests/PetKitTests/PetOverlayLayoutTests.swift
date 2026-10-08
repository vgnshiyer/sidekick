import CoreGraphics
import XCTest
@testable import PetKit

final class PetOverlayLayoutTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 875)
    private let margin = CGSize(width: 12, height: 10)
    /// Art fills the middle of the cell, from 20% to 70% of its height.
    private let art = CGRect(x: 0.25, y: 0.2, width: 0.5, height: 0.5)

    func testTrayHidesWithNoBubbles() {
        let pet = CGRect(x: 24, y: 24, width: 96, height: 104)
        let layout = PetOverlayLayout(pet: pet, art: art, tray: nil, margin: margin, gap: 4, screen: screen)
        XCTAssertEqual(layout.panelFrame, pet)
        XCTAssertEqual(layout.petFrame, CGRect(x: 0, y: 0, width: 96, height: 104))
        XCTAssertNil(layout.trayFrame)
    }

    func testTraySitsAboveAndGrowsRightFromALeftPet() throws {
        let pet = CGRect(x: 24, y: 24, width: 96, height: 104)
        let layout = PetOverlayLayout(
            pet: pet, art: art, tray: CGSize(width: 324, height: 200), margin: margin, gap: 4, screen: screen)
        XCTAssertEqual(layout.placement, .above)
        XCTAssertTrue(layout.trayGrowsRight)
        let tray = try XCTUnwrap(layout.trayFrame).offsetBy(dx: layout.panelFrame.minX, dy: layout.panelFrame.minY)
        let artTop = pet.minY + 0.7 * pet.height
        XCTAssertEqual(tray.minY, artTop + 4 - margin.height, accuracy: 1e-9)
        XCTAssertEqual(tray.minX, pet.minX - margin.width)
        XCTAssertEqual(tray.height, 200)
        XCTAssertEqual(layout.tailX, pet.midX - tray.minX, accuracy: 1e-9)
        XCTAssertEqual(layout.panelFrame, pet.union(tray))
        XCTAssertEqual(
            layout.petFrame.offsetBy(dx: layout.panelFrame.minX, dy: layout.panelFrame.minY), pet)
    }

    func testTrayGrowsLeftFromARightPet() throws {
        let pet = CGRect(x: 1300, y: 24, width: 96, height: 104)
        let layout = PetOverlayLayout(
            pet: pet, art: art, tray: CGSize(width: 324, height: 200), margin: margin, gap: 4, screen: screen)
        XCTAssertFalse(layout.trayGrowsRight)
        let tray = try XCTUnwrap(layout.trayFrame).offsetBy(dx: layout.panelFrame.minX, dy: layout.panelFrame.minY)
        XCTAssertEqual(tray.maxX, pet.maxX + margin.width)
        XCTAssertEqual(layout.tailX, pet.midX - tray.minX, accuracy: 1e-9)
    }

    func testTrayFlipsBelowNearTheTop() throws {
        let pet = CGRect(x: 600, y: 760, width: 96, height: 104)
        let layout = PetOverlayLayout(
            pet: pet, art: art, tray: CGSize(width: 324, height: 260), margin: margin, gap: 4, screen: screen)
        XCTAssertEqual(layout.placement, .below)
        let tray = try XCTUnwrap(layout.trayFrame).offsetBy(dx: layout.panelFrame.minX, dy: layout.panelFrame.minY)
        let artBottom = pet.minY + 0.2 * pet.height
        XCTAssertEqual(tray.maxY, artBottom - 4 + margin.height, accuracy: 1e-9)
    }

    func testTrayStaysOnANarrowScreen() throws {
        let narrow = CGRect(x: 0, y: 0, width: 300, height: 800)
        let pet = CGRect(x: 40, y: 24, width: 96, height: 104)
        let layout = PetOverlayLayout(
            pet: pet, art: art, tray: CGSize(width: 324, height: 200), margin: margin, gap: 4, screen: narrow)
        let tray = try XCTUnwrap(layout.trayFrame).offsetBy(dx: layout.panelFrame.minX, dy: layout.panelFrame.minY)
        XCTAssertEqual(tray.minX, narrow.minX - margin.width)
    }

    func testTrayHeightIsCappedByTheRoomLeft() throws {
        let short = CGRect(x: 0, y: 0, width: 1440, height: 300)
        let pet = CGRect(x: 24, y: 24, width: 96, height: 104)
        let layout = PetOverlayLayout(
            pet: pet, art: art, tray: CGSize(width: 324, height: 400), margin: margin, gap: 4, screen: short)
        XCTAssertEqual(layout.placement, .above)
        let tray = try XCTUnwrap(layout.trayFrame).offsetBy(dx: layout.panelFrame.minX, dy: layout.panelFrame.minY)
        XCTAssertEqual(tray.maxY, short.maxY + margin.height, accuracy: 1e-9)
    }

    func testPanelOpensBesideTheBubbleOnTheTraySide() {
        let size = CGSize(width: 360, height: 440)
        let bubble = CGRect(x: 26, y: 300, width: 300, height: 54)
        let right = PetOverlayLayout.panelFrame(size: size, beside: bubble, growsRight: true, screen: screen)
        XCTAssertEqual(right.minX, bubble.maxX + 8)
        XCTAssertEqual(right.midY, bubble.midY)

        let leftBubble = CGRect(x: 1100, y: 300, width: 300, height: 54)
        let left = PetOverlayLayout.panelFrame(size: size, beside: leftBubble, growsRight: false, screen: screen)
        XCTAssertEqual(left.maxX, leftBubble.minX - 8)
    }

    func testPanelFlipsSidesAndStaysOnScreen() {
        let size = CGSize(width: 360, height: 440)
        // No room on the right: open on the left instead.
        let bubble = CGRect(x: 1100, y: 20, width: 300, height: 54)
        let frame = PetOverlayLayout.panelFrame(size: size, beside: bubble, growsRight: true, screen: screen)
        XCTAssertEqual(frame.maxX, bubble.minX - 8)
        XCTAssertEqual(frame.minY, screen.minY + 8)

        // No room on either side: clamp inside the screen.
        let small = CGRect(x: 0, y: 0, width: 500, height: 600)
        let clamped = PetOverlayLayout.panelFrame(
            size: size, beside: CGRect(x: 100, y: 500, width: 300, height: 54), growsRight: true, screen: small)
        XCTAssertTrue(small.insetBy(dx: 8, dy: 8).contains(clamped))
    }

    // MARK: quips

    private let quipSize = CGSize(width: 120, height: 28)
    private let quipMargin = CGSize(width: 12, height: 12)
    /// Resting art: the middle half of the cell, from 10% to 70% of its height.
    private let head = CGRect(x: 0.25, y: 0.1, width: 0.5, height: 0.6)

    private func quip(avoiding: [CGRect] = []) -> QuipRequest {
        QuipRequest(size: quipSize, margin: quipMargin, head: head, avoiding: avoiding)
    }

    /// The quip's bubble on screen, without its margin.
    private func bubble(_ layout: PetOverlayLayout) throws -> CGRect {
        try XCTUnwrap(layout.quipFrame)
            .offsetBy(dx: layout.panelFrame.minX, dy: layout.panelFrame.minY)
            .insetBy(dx: quipMargin.width, dy: quipMargin.height)
    }

    func testQuipSitsRightOfTheHeadWhenCollapsedAndThePetStaysPut() throws {
        let pet = CGRect(x: 24, y: 24, width: 96, height: 104)
        let layout = PetOverlayLayout(
            pet: pet, art: art, tray: nil, margin: margin, gap: 2, screen: screen, petPadding: 14, quip: quip())
        let rect = try bubble(layout)
        XCTAssertEqual(layout.quipSide, .right)
        XCTAssertEqual(rect.size, quipSize)
        XCTAssertEqual(rect.minX, pet.minX + 0.75 * pet.width + 2, accuracy: 1e-9)
        let headTop = pet.minY + 0.7 * pet.height
        XCTAssertEqual(rect.midY, headTop - PetOverlayLayout.headHeight * 0.6 * pet.height, accuracy: 1e-9)
        XCTAssertTrue(layout.panelFrame.contains(try XCTUnwrap(layout.quipFrame).offsetBy(
            dx: layout.panelFrame.minX, dy: layout.panelFrame.minY)))
        XCTAssertEqual(layout.petFrame.offsetBy(dx: layout.panelFrame.minX, dy: layout.panelFrame.minY), pet)

        let without = PetOverlayLayout(pet: pet, art: art, tray: nil, margin: margin, gap: 2, screen: screen, petPadding: 14)
        XCTAssertNil(without.quipFrame)
        XCTAssertEqual(without.panelFrame, pet.insetBy(dx: -14, dy: -14))
    }

    func testQuipSitsAwayFromTheTrayAndBelowItsBubbles() throws {
        let pet = CGRect(x: 400, y: 24, width: 96, height: 104)
        let layout = PetOverlayLayout(
            pet: pet, art: art, tray: CGSize(width: 324, height: 200), margin: margin, gap: 2, screen: screen, quip: quip())
        XCTAssertTrue(layout.trayGrowsRight)
        XCTAssertEqual(layout.quipSide, .left)
        let rect = try bubble(layout)
        XCTAssertEqual(rect.maxX, pet.minX + 0.25 * pet.width - 2, accuracy: 1e-9)
        let tray = try XCTUnwrap(layout.trayFrame).offsetBy(dx: layout.panelFrame.minX, dy: layout.panelFrame.minY)
        XCTAssertFalse(rect.intersects(tray.insetBy(dx: margin.width, dy: margin.height)))
        XCTAssertEqual(layout.petFrame.offsetBy(dx: layout.panelFrame.minX, dy: layout.panelFrame.minY), pet)
    }

    func testQuipFlipsSidesToStayOnScreen() throws {
        // The tray grows right, but there is no room on the left.
        let left = PetOverlayLayout(
            pet: CGRect(x: 24, y: 24, width: 96, height: 104), art: art, tray: CGSize(width: 324, height: 200),
            margin: margin, gap: 2, screen: screen, quip: quip())
        XCTAssertEqual(left.quipSide, .right)

        // Collapsed against the right edge: no room on the right.
        let right = PetOverlayLayout(
            pet: CGRect(x: 1330, y: 24, width: 96, height: 104), art: art, tray: nil,
            margin: margin, gap: 2, screen: screen, quip: quip())
        XCTAssertEqual(right.quipSide, .left)
        XCTAssertTrue(screen.contains(try bubble(right)))
    }

    func testQuipDropsBelowOrStepsPastWhatItMustAvoid() throws {
        let pet = CGRect(x: 24, y: 24, width: 96, height: 104)
        let clearance = PetOverlayLayout.quipClearance
        // A badge on the head's top-right corner: the bubble drops below it, still beside the head.
        let badge = CGRect(x: 90, y: 80, width: 22, height: 22)
        let dropped = try bubble(PetOverlayLayout(
            pet: pet, art: art, tray: nil, margin: margin, gap: 2, screen: screen, quip: quip(avoiding: [badge])))
        XCTAssertEqual(dropped.minX, pet.minX + 0.75 * pet.width + 2, accuracy: 1e-9)
        XCTAssertEqual(dropped.maxY, badge.minY - clearance, accuracy: 1e-9)

        // Dropping below this one would take the bubble below the art: it steps past it instead.
        let low = CGRect(x: 90, y: 40, width: 22, height: 40)
        let stepped = try bubble(PetOverlayLayout(
            pet: pet, art: art, tray: nil, margin: margin, gap: 2, screen: screen, quip: quip(avoiding: [low])))
        XCTAssertEqual(stepped.minX, low.maxX + clearance, accuracy: 1e-9)
        XCTAssertFalse(stepped.intersects(low.insetBy(dx: -clearance + 1e-6, dy: -clearance + 1e-6)))
    }

    func testQuipStaysClearOfTheTrayOnASmallPet() throws {
        // The bubble is taller than the pet's head room; it must not rise into the tray above.
        let pet = CGRect(x: 24, y: 24, width: 48, height: 52)
        let tall = QuipRequest(size: CGSize(width: 120, height: 40), margin: quipMargin, head: head)
        let layout = PetOverlayLayout(
            pet: pet, art: art, tray: CGSize(width: 324, height: 200), margin: margin, gap: 2, screen: screen, quip: tall)
        let rect = try bubble(layout)
        XCTAssertLessThanOrEqual(rect.maxY, pet.minY + 0.7 * pet.height + 1e-9)
    }

    func testPositionsRoundTripPerScreen() {
        let size = CGSize(width: 96, height: 104)
        let main = CGRect(x: 0, y: 25, width: 1440, height: 850)
        let origin = CGPoint(x: 400, y: 300)
        let normalized = PetPosition.normalize(origin, size: size, in: main)
        XCTAssertEqual(PetPosition.origin(normalized: normalized, size: size, in: main), origin)

        // The same fraction lands proportionally on a bigger display.
        let big = CGRect(x: 1440, y: 0, width: 2560, height: 1415)
        let moved = PetPosition.origin(normalized: normalized, size: size, in: big)
        XCTAssertEqual(moved.x, big.minX + normalized.x * (big.width - size.width), accuracy: 1e-9)

        XCTAssertEqual(PetPosition.normalize(CGPoint(x: -50, y: 5000), size: size, in: main), CGPoint(x: 0, y: 1))
    }

    func testDefaultAndClamp() {
        let main = CGRect(x: 0, y: 70, width: 1440, height: 805)
        XCTAssertEqual(PetPosition.defaultOrigin(in: main), CGPoint(x: 24, y: 94))
        let size = CGSize(width: 96, height: 104)
        XCTAssertEqual(PetPosition.clamp(CGPoint(x: 1400, y: 0), size: size, in: main), CGPoint(x: 1344, y: 70))
        XCTAssertEqual(PetPosition.clamp(CGPoint(x: 10, y: 100), size: size, in: main), CGPoint(x: 10, y: 100))
    }
}
