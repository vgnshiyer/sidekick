import XCTest
@testable import PetKit

final class PetAnimatorTests: XCTestCase {
    func testIdleLoopsSixTimesSlower() throws {
        var pet = PetAnimator(now: 0)
        XCTAssertEqual(pet.row, .idle)
        XCTAssertEqual(pet.frame, 0)
        XCTAssertEqual(try XCTUnwrap(pet.nextDeadline), 1.68, accuracy: 1e-9)

        assertShows(&pet, at: 1.70, .idle, 1)
        assertShows(&pet, at: 6.55, .idle, 5)
        assertShows(&pet, at: 6.65, .idle, 0)
    }

    func testWaitingPlaysThreeTimesThenRepeatsEveryEightSeconds() {
        var pet = PetAnimator(now: 0)
        pet.setMood(.waiting, at: 10)
        assertShows(&pet, at: 10, .waiting, 0)
        assertShows(&pet, at: 11.05, .waiting, 0)  // second play (one play is 1.01 s)
        assertShows(&pet, at: 13.00, .waiting, 5)
        assertShows(&pet, at: 13.05, .idle, 0)
        assertShows(&pet, at: 17.99, .idle, 5)
        assertShows(&pet, at: 18.00, .waiting, 0)
        assertShows(&pet, at: 21.05, .idle, 0)
        assertShows(&pet, at: 26.00, .waiting, 0)
    }

    func testRunningRepeatsEveryTwentySeconds() {
        var pet = PetAnimator(now: 0)
        pet.setMood(.running, at: 0)
        assertShows(&pet, at: 2.45, .running, 5)
        assertShows(&pet, at: 2.47, .idle, 0)
        assertShows(&pet, at: 19.9, .idle, 4)
        assertShows(&pet, at: 20.0, .running, 0)
    }

    func testFailedPlaysThreeTimesOnly() {
        var pet = PetAnimator(now: 0)
        pet.setMood(.failed, at: 0)
        assertShows(&pet, at: 3.65, .failed, 7)
        assertShows(&pet, at: 3.67, .idle, 0)
        for t in stride(from: 4.0, through: 60, by: 0.5) {
            run(&pet, until: t)
            XCTAssertEqual(pet.row, .idle, "t=\(t)")
        }
    }

    func testReadyJumpsOnceThenReviewsThreeTimes() {
        var pet = PetAnimator(now: 0)
        pet.setMood(.ready, at: 0)
        assertShows(&pet, at: 0.5, .jumping, 3)
        assertShows(&pet, at: 0.85, .review, 0)
        assertShows(&pet, at: 1.88, .review, 0)  // second play
        assertShows(&pet, at: 3.92, .review, 5)
        assertShows(&pet, at: 3.94, .idle, 0)
        assertShows(&pet, at: 30, .idle, nil)
    }

    func testSameMoodDoesNotRestart() {
        var pet = PetAnimator(now: 0)
        pet.setMood(.running, at: 0)
        assertShows(&pet, at: 0.5, .running, 4)
        pet.setMood(.running, at: 0.5)
        XCTAssertEqual(pet.frame, 4)
    }

    func testNewMoodInterruptsTheCurrentSequence() {
        var pet = PetAnimator(now: 0)
        pet.setMood(.running, at: 0)
        run(&pet, until: 1)
        pet.setMood(.waiting, at: 1)
        assertShows(&pet, at: 1, .waiting, 0)

        pet.setMood(.idle, at: 1.5)
        assertShows(&pet, at: 1.5, .idle, 0)
        assertShows(&pet, at: 20, .idle, nil)
    }

    func testHoverWavesOnceWhenResting() {
        var pet = PetAnimator(now: 0)
        pet.hover(at: 1)
        assertShows(&pet, at: 1, .waving, 0)
        pet.hover(at: 1.2)
        assertShows(&pet, at: 1.69, .waving, 3)
        assertShows(&pet, at: 1.71, .idle, 0)
    }

    func testHoverDoesNotInterruptAStatusAnimation() {
        var pet = PetAnimator(now: 0)
        pet.setMood(.failed, at: 0)
        run(&pet, until: 0.3)
        pet.hover(at: 0.3)
        XCTAssertEqual(pet.row, .failed)
    }

    func testDragRunsInTheDragDirection() {
        var pet = PetAnimator(now: 0)
        pet.drag(.right, at: 0)
        assertShows(&pet, at: 0, .runningRight, 0)
        assertShows(&pet, at: 1.0, .runningRight, 7)
        assertShows(&pet, at: 1.1, .runningRight, 0)
        pet.drag(.right, at: 1.15)
        XCTAssertEqual(pet.frame, 0)
        pet.drag(.left, at: 1.2)
        assertShows(&pet, at: 1.3, .runningLeft, 0)
        pet.hover(at: 1.3)
        XCTAssertEqual(pet.row, .runningLeft)
        pet.endDrag(at: 2)
        assertShows(&pet, at: 2, .idle, 0)
    }

    func testMoodChangeDuringDragPlaysAfterTheDrop() {
        var pet = PetAnimator(now: 0)
        pet.drag(.left, at: 0)
        pet.setMood(.waiting, at: 0.5)
        assertShows(&pet, at: 0.6, .runningLeft, nil)
        pet.endDrag(at: 1)
        assertShows(&pet, at: 1, .waiting, 0)
    }

    func testReduceMotionHoldsFrameZero() {
        var pet = PetAnimator(now: 0, reduceMotion: true)
        XCTAssertNil(pet.nextDeadline)
        assertShows(&pet, at: 5, .idle, 0)

        pet.setMood(.ready, at: 5)
        assertShows(&pet, at: 9, .review, 0)
        pet.setMood(.waiting, at: 9)
        assertShows(&pet, at: 30, .waiting, 0)
        pet.hover(at: 30)
        assertShows(&pet, at: 30, .waiting, 0)
        pet.drag(.right, at: 31)
        assertShows(&pet, at: 32, .runningRight, 0)
        pet.endDrag(at: 33)
        assertShows(&pet, at: 34, .waiting, 0)
        XCTAssertNil(pet.nextDeadline)

        pet.setReduceMotion(false, at: 40)
        XCTAssertNotNil(pet.nextDeadline)
    }

    func testLongGapResumesFromNowInsteadOfReplaying() throws {
        var pet = PetAnimator(now: 0)
        pet.setMood(.running, at: 0)
        pet.update(at: 3600)
        XCTAssertEqual(pet.row, .running)
        XCTAssertEqual(pet.frame, 0)
        XCTAssertGreaterThan(try XCTUnwrap(pet.nextDeadline), 3600)
    }

    func testDeadlineAlwaysMovesForward() throws {
        var pet = PetAnimator(now: 0)
        pet.setMood(.waiting, at: 0)
        var now: TimeInterval = 0
        for _ in 0..<200 {
            let deadline = try XCTUnwrap(pet.nextDeadline)
            XCTAssertGreaterThan(deadline, now)
            now = deadline
            pet.update(at: now)
        }
    }

    /// Advances like the app's timer does, waking at every deadline up to `time`.
    private func run(_ pet: inout PetAnimator, until time: TimeInterval) {
        while let deadline = pet.nextDeadline, deadline <= time {
            pet.update(at: deadline)
        }
        pet.update(at: time)
    }

    private func assertShows(
        _ pet: inout PetAnimator, at time: TimeInterval, _ row: PetRow, _ frame: Int?,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        run(&pet, until: time)
        XCTAssertEqual(pet.row, row, "t=\(time)", file: file, line: line)
        if let frame { XCTAssertEqual(pet.frame, frame, "t=\(time)", file: file, line: line) }
    }
}
