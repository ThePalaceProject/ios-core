//
//  SeekSliderHoldTests.swift
//  PalaceTests
//
//  The scrubber's position hold, cell by cell (PP-5293): idle, dragging and
//  holding (after a drag or a VoiceOver step) against drag start, move, lift,
//  step, live tick and safety timer. `live` is the player's chapter progress,
//  which a commit never writes, because the slider's binding setter is a no-op.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

/// Untested cells: dragging x drag start (the gesture begins a drag only when
/// none is in progress) and idle/holding x move (the first report of a
/// zero-distance drag is the touch-down, so it is always a drag start).
final class SeekSliderHoldTests: XCTestCase {

    // MARK: - PP-5293: a drag that starts during a pending hold

    /// The previous seek is still landing when the finger goes down. A live
    /// tick at the finger's position must not clear it, so lifting without
    /// moving still seeks there.
    func testDragStartedDuringAHold_survivesALiveTickAndLiftsToItsSeek() throws {
        let live = 0.2
        var hold = Self.holding(afterDragTo: 0.6, live: live)

        hold.beginDrag()
        hold.drag(to: 0.205)
        hold.liveTick(0.205)
        let commit = try XCTUnwrap(hold.endDrag(live: 0.205), "lifting must commit the drag")

        XCTAssertEqual(commit.target, 0.205)
    }

    /// The previous commit's 2 s timer fires while the finger is down. It must
    /// not clear the finger's position.
    func testDragStartedDuringAHold_survivesThePreviousCommitsTimerAndLiftsToItsSeek() throws {
        let live = 0.2
        var hold = SeekSliderHold()
        hold.beginDrag()
        hold.drag(to: 0.6)
        let first = try XCTUnwrap(hold.endDrag(live: live))

        hold.beginDrag()
        hold.drag(to: 0.3)
        hold.timerFired(generation: first.generation)
        let second = try XCTUnwrap(hold.endDrag(live: live), "lifting must commit the drag")

        XCTAssertEqual(second.target, 0.3)
        XCTAssertNotEqual(second.generation, first.generation)
    }

    /// The same two events after a VoiceOver step rather than a drag.
    func testDragStartedDuringAStepHold_survivesATickAndTheStepsTimer() throws {
        var hold = SeekSliderHold()
        let step = try XCTUnwrap(hold.step(to: 0.55, live: 0.5))

        hold.beginDrag()
        hold.drag(to: 0.502)
        hold.liveTick(0.502)
        hold.timerFired(generation: step.generation)

        XCTAssertEqual(hold.heldPosition, 0.502)
        XCTAssertEqual(hold.endDrag(live: 0.502)?.target, 0.502)
    }

    /// Starting a drag takes ownership: the thumb stays where the hold had it
    /// until the finger's position arrives, and nothing the old hold does
    /// afterwards releases the new one.
    func testDragStart_duringAHold_keepsTheHeldPositionUntilTheFingerMoves() {
        var hold = Self.holding(afterDragTo: 0.6, live: 0.2)

        hold.beginDrag()

        XCTAssertTrue(hold.isDragging)
        XCTAssertEqual(hold.displayed(live: 0.2), 0.6)
    }

    // MARK: - Idle

    func testIdle_liveTick_holdsNothingSoTheThumbFollowsPlayback() {
        var hold = SeekSliderHold()

        hold.liveTick(0.4)

        XCTAssertNil(hold.heldPosition)
        XCTAssertEqual(hold.displayed(live: 0.4), 0.4)
    }

    func testIdle_timer_releasesNothingAndHoldsNothing() {
        var hold = SeekSliderHold()

        hold.timerFired(generation: 0)

        XCTAssertEqual(hold, SeekSliderHold())
    }

    func testIdle_liftWithoutADrag_commitsNothing() {
        var hold = SeekSliderHold()

        XCTAssertNil(hold.endDrag(live: 0.4))
        XCTAssertFalse(hold.isDragging)
    }

    func testIdle_step_holdsTheTargetMeasuredFromTheLivePosition() throws {
        var hold = SeekSliderHold()

        let commit = try XCTUnwrap(hold.step(to: 0.505, live: 0.5))

        XCTAssertEqual(commit.target, 0.505)
        XCTAssertEqual(hold.displayed(live: 0.5), 0.505)
        hold.liveTick(0.502) // within 1%, but not within half the move from 0.5
        XCTAssertEqual(hold.heldPosition, 0.505, "the hold measures the move from 0.5")
    }

    func testIdle_dragStart_isDraggingAndHoldsNothingUntilTheFingerPositionArrives() {
        var hold = SeekSliderHold()

        hold.beginDrag()

        XCTAssertTrue(hold.isDragging)
        XCTAssertEqual(hold.displayed(live: 0.3), 0.3)
    }

    /// A touch that ends before its first position report commits nothing and
    /// leaves the slider following playback.
    func testIdle_dragStartThenLiftWithNoPosition_commitsNothingAndReturnsToIdle() {
        var hold = SeekSliderHold()
        hold.beginDrag()

        XCTAssertNil(hold.endDrag(live: 0.3))
        XCTAssertFalse(hold.isDragging)
        XCTAssertEqual(hold.displayed(live: 0.35), 0.35)
    }

    // MARK: - Dragging

    func testDragging_move_tracksTheFingerAndLiftCommitsTheLastPosition() throws {
        var hold = SeekSliderHold()
        hold.beginDrag()
        hold.drag(to: 0.2)
        hold.drag(to: 0.7)

        XCTAssertEqual(hold.displayed(live: 0.1), 0.7)
        let commit = try XCTUnwrap(hold.endDrag(live: 0.1))
        XCTAssertEqual(commit.target, 0.7)
        XCTAssertFalse(hold.isDragging)
    }

    /// Before the first commit, a tick at the finger's position is the case a
    /// pending hold made reachable; it must not clear the finger either.
    func testDragging_liveTickAtTheFingerPosition_doesNotClearIt() {
        var hold = SeekSliderHold()
        hold.beginDrag()
        hold.drag(to: 0.4)

        hold.liveTick(0.4)

        XCTAssertEqual(hold.heldPosition, 0.4)
    }

    /// The finger owns the position while it is down; a VoiceOver step then
    /// neither seeks nor moves the thumb.
    func testDragging_step_isIgnored() {
        var hold = SeekSliderHold()
        hold.beginDrag()
        hold.drag(to: 0.4)

        XCTAssertNil(hold.step(to: 0.45, live: 0.1))
        XCTAssertEqual(hold.heldPosition, 0.4)
        XCTAssertEqual(hold.endDrag(live: 0.1)?.target, 0.4, "the lift still commits the finger's position")
    }

    /// The lift's hold measures the move from the live position, so a tick at
    /// the old playback position does not release it and one at the target does.
    func testDragging_lift_holdsTheFingerPositionUntilPlaybackReachesIt() throws {
        var hold = SeekSliderHold()
        hold.beginDrag()
        hold.drag(to: 0.6)
        _ = try XCTUnwrap(hold.endDrag(live: 0.2))

        hold.liveTick(0.2)
        XCTAssertEqual(hold.displayed(live: 0.2), 0.6)
        hold.liveTick(0.595) // within 1% of a 0.4 move from the live 0.2
        XCTAssertNil(hold.heldPosition)
    }

    // MARK: - Holding (after a drag and after a step)

    func testHoldingAfterADrag_step_accumulatesFromTheHeldTarget() throws {
        var hold = Self.holding(afterDragTo: 0.6, live: 0.2)

        let commit = try XCTUnwrap(hold.step(to: 0.605, live: 0.2))

        XCTAssertEqual(commit.target, 0.605)
        hold.liveTick(0.602) // within 1%, but not within half the 0.6 -> 0.605 move
        XCTAssertEqual(hold.heldPosition, 0.605)
    }

    func testHoldingAfterAStep_step_accumulatesFromTheHeldTarget() throws {
        var hold = SeekSliderHold()
        let first = try XCTUnwrap(hold.step(to: 0.55, live: 0.5))

        let second = try XCTUnwrap(hold.step(to: 0.60, live: 0.5))

        XCTAssertEqual(second.target, 0.60)
        XCTAssertGreaterThan(second.generation, first.generation)
    }

    func testHolding_liveTickAtTheTarget_releases_andAFarTickDoesNot() {
        var afterDrag = Self.holding(afterDragTo: 0.6, live: 0.2)
        afterDrag.liveTick(0.3)
        XCTAssertEqual(afterDrag.heldPosition, 0.6)
        afterDrag.liveTick(0.598)
        XCTAssertNil(afterDrag.heldPosition)

        var afterStep = SeekSliderHold()
        _ = afterStep.step(to: 0.55, live: 0.5)
        afterStep.liveTick(0.5)
        XCTAssertEqual(afterStep.heldPosition, 0.55)
        afterStep.liveTick(0.55)
        XCTAssertNil(afterStep.heldPosition)
    }

    func testHolding_ownTimer_releases_andAnEarlierCommitsTimerDoesNot() throws {
        var hold = SeekSliderHold()
        let first = try XCTUnwrap(hold.step(to: 0.55, live: 0.5))
        let second = try XCTUnwrap(hold.step(to: 0.60, live: 0.5))

        hold.timerFired(generation: first.generation)
        XCTAssertEqual(hold.heldPosition, 0.60)
        hold.timerFired(generation: second.generation)
        XCTAssertNil(hold.heldPosition)
        XCTAssertEqual(hold.displayed(live: 0.5), 0.5)
    }

    /// A lift with no drag in progress commits nothing, even while a target is
    /// held: only a drag's own position is the finger's to commit.
    func testHolding_liftWithoutADrag_commitsNothingAndKeepsTheHold() {
        var hold = Self.holding(afterDragTo: 0.6, live: 0.2)

        XCTAssertNil(hold.endDrag(live: 0.2))
        XCTAssertEqual(hold.heldPosition, 0.6)
    }

    /// After a released hold the next drag starts clean.
    func testReleasedHold_nextDragCommitsItsOwnPosition() throws {
        var hold = Self.holding(afterDragTo: 0.6, live: 0.2)
        hold.liveTick(0.6)

        hold.beginDrag()
        hold.drag(to: 0.1)

        XCTAssertEqual(try XCTUnwrap(hold.endDrag(live: 0.6)).target, 0.1)
    }

    // MARK: - Helpers

    private static func holding(afterDragTo target: Double, live: Double) -> SeekSliderHold {
        var hold = SeekSliderHold()
        hold.beginDrag()
        hold.drag(to: target)
        _ = hold.endDrag(live: live)
        return hold
    }
}
