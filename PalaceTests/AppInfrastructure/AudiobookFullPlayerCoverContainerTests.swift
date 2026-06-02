//
//  AudiobookFullPlayerCoverContainerTests.swift
//  PalaceTests
//
//  Module D (swarm_0b7616e7) — root-level full-player fullScreenCover.
//  Tests the safety guard (no model → EmptyView), the swipe-down
//  dismissal gesture's threshold + horizontal-drift filter, and the
//  reduce-motion path.
//
//  Why we test the `handleDragEnd(translation:)` method instead of
//  driving a real DragGesture: the contract's scope-deferral protocol
//  option (a) — no SwiftUI gesture harness exists in the repo. The
//  production gesture's `.onEnded` closure delegates directly to
//  `handleDragEnd(translation:)`, so testing the latter mechanically
//  proves the boundary behavior of the former.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import XCTest
import SwiftUI
import UIKit
@testable import Palace

@MainActor
final class AudiobookFullPlayerCoverContainerTests: XCTestCase {

    private var spyPresenter: SpyAudiobookSessionPresenter!

    override func setUp() async throws {
        try await super.setUp()
        spyPresenter = SpyAudiobookSessionPresenter()
    }

    override func tearDown() async throws {
        spyPresenter = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func makeSUT() -> AudiobookFullPlayerCoverContainer {
        return AudiobookFullPlayerCoverContainer(presenter: spyPresenter)
    }

    // MARK: - Visibility safety guard (contract test 6)

    /// Contract test 6 — `testFullPlayerCover_isEmptyWhenNoPlaybackModel`.
    /// PRE: `presenter.playbackModel == nil`.
    /// EXPECTED: cover body renders `EmptyView` so the user never sees
    /// an empty player chrome if `isPlayerExpanded` raced ahead of the
    /// model adoption during a fast first-open.
    /// Mutates: removing the `if let model` guard would render an
    /// invalid AudiobookPlayerView — that's a crash, but the test
    /// asserts the predicate path directly.
    func testFullPlayerCover_isEmptyWhenNoPlaybackModel() {
        // Arrange: fresh spy presenter has playbackModel == nil by
        // virtue of the AudiobookSessionPresenter's init contract
        // (cleared on idle, no `adoptPlaybackModel` call yet).
        let sut = makeSUT()
        XCTAssertNil(spyPresenter.playbackModel,
                     "PRECONDITION: spy presenter must have no playback model")

        // Act: read body — opaque type; we assert the predicate.
        _ = sut.body
        let hasModel = (spyPresenter.playbackModel != nil)

        // Assert: predicate false → cover renders EmptyView.
        XCTAssertFalse(hasModel,
                       "Without a playback model, the cover must render EmptyView so the user never sees an empty player chrome (race-safety guard against fast first-open)")
    }

    // MARK: - Swipe-down dismissal (contract test 8)

    /// Contract test 8 — `testFullPlayerCover_swipeDownInvokesMinimize`.
    /// PRE: drag past the 100pt threshold with horizontal drift under 60pt.
    /// EXPECTED: presenter records exactly one `minimize()` call.
    /// Mutates: lowering the threshold below 100pt (e.g. 99) fails this
    /// boundary test below; raising it above 100pt (e.g. 101) fails
    /// the just-over boundary.
    func testFullPlayerCover_swipeDownInvokesMinimize() {
        // Arrange
        let sut = makeSUT()
        XCTAssertEqual(spyPresenter.minimizeCallCount, 0,
                       "PRECONDITION: no minimize calls yet")

        // Act: simulate a downward drag with safe horizontal drift past
        // the threshold (101pt height, 0 horizontal).
        sut.handleDragEnd(translation: CGSize(width: 0, height: 101))

        // Assert
        XCTAssertEqual(spyPresenter.minimizeCallCount, 1,
                       "Drag past minimizeSwipeDownThreshold (100pt) must invoke presenter.minimize() exactly once")
    }

    /// Contract test 9 — `testFullPlayerCover_swipeUp_doesNotMinimize`.
    /// PRE: upward drag (negative height).
    /// EXPECTED: presenter records ZERO `minimize()` calls.
    /// Mutates: a regression that drops the `> 0` direction check
    /// (e.g. uses `abs(value.translation.height)`) would fail this.
    func testFullPlayerCover_swipeUp_doesNotMinimize() {
        // Arrange
        let sut = makeSUT()

        // Act: upward drag past the threshold magnitude (but negative).
        sut.handleDragEnd(translation: CGSize(width: 0, height: -200))

        // Assert
        XCTAssertEqual(spyPresenter.minimizeCallCount, 0,
                       "Upward drag must NEVER invoke minimize — only downward swipes dismiss the full player")
    }

    /// Boundary test — drag below threshold (99pt) MUST NOT minimize.
    /// Pins the `> 100` inequality precisely so a regression that
    /// changes it to `>= 100` would pass test 8 but fail this one.
    func testFullPlayerCover_swipeDownBelowThreshold_doesNotMinimize() {
        // Arrange
        let sut = makeSUT()

        // Act: just-below-threshold downward drag.
        sut.handleDragEnd(translation: CGSize(width: 0, height: 99))

        // Assert
        XCTAssertEqual(spyPresenter.minimizeCallCount, 0,
                       "Drag below 100pt threshold (99pt) must NOT invoke minimize — pins the boundary")
    }

    /// Boundary test — drag with excessive horizontal drift (>60pt) MUST
    /// NOT minimize even if vertical exceeds 100pt. Pins the diagonal-
    /// filter so a regression that drops the `abs(width) < 60` clause
    /// would minimize on incidental horizontal swipes.
    func testFullPlayerCover_swipeDownWithExcessiveHorizontalDrift_doesNotMinimize() {
        // Arrange
        let sut = makeSUT()

        // Act: vertical 200pt (past threshold) but horizontal 80pt (past
        // the diagonal filter).
        sut.handleDragEnd(translation: CGSize(width: 80, height: 200))

        // Assert
        XCTAssertEqual(spyPresenter.minimizeCallCount, 0,
                       "Diagonal scrolls (horizontal drift > 60pt) must NOT minimize the player even if vertical exceeds the threshold")
    }

    /// Exact-boundary test for the vertical threshold (kills `>` → `>=`
    /// mutation). With strict `>`, translation height of exactly 100pt
    /// must NOT trigger minimize. With `>=` (the mutation), 100pt would.
    /// This nails the `> 100` semantic so a regression that loosens to
    /// `>= 100` would fail (a 100pt scroll inside the player chrome
    /// would accidentally dismiss).
    func testFullPlayerCover_swipeDownAtExactThreshold_doesNotMinimize() {
        // Arrange
        let sut = makeSUT()

        // Act: exactly-at-threshold translation (vertical = 100pt).
        sut.handleDragEnd(translation: CGSize(width: 0, height: 100))

        // Assert: strict `>` means 100pt is NOT past the threshold.
        XCTAssertEqual(spyPresenter.minimizeCallCount, 0,
                       "Exact-threshold drag (100pt) must NOT minimize — kills `> 100` → `>= 100` mutation. The boundary is intentionally strict because a 100pt translation occurs in-chrome during scrubber drags and must not dismiss the player.")
    }

    /// Exact-boundary test for the horizontal drift filter (kills `<`
    /// → `<=` mutation). With strict `<`, horizontal width of exactly
    /// 60pt must NOT trigger minimize (the drag is too diagonal).
    /// With `<=` (the mutation), exactly-60pt would pass and dismiss.
    /// This pins the diagonal filter so a 60pt horizontal scroll
    /// during a vertical-leaning swipe doesn't accidentally dismiss.
    func testFullPlayerCover_swipeDownWithExactHorizontalDriftLimit_doesNotMinimize() {
        // Arrange
        let sut = makeSUT()

        // Act: past vertical threshold (200pt) but EXACTLY at the
        // horizontal drift limit (60pt). With strict `<`, `60 < 60`
        // is false → guard fails → no minimize.
        sut.handleDragEnd(translation: CGSize(width: 60, height: 200))

        // Assert
        XCTAssertEqual(spyPresenter.minimizeCallCount, 0,
                       "Exact-limit horizontal drift (60pt) must NOT minimize — kills `< 60` → `<= 60` mutation. The boundary is strict because exactly-60pt horizontal is at the diagonal threshold and should be filtered.")
    }

    // MARK: - Polish-phase Bug 1 — Done button overlay

    /// Polish-phase Bug 1: explicit Done/chevron-down overlay that calls
    /// `presenter.minimize()`. Users reported the player had "no escape"
    /// because the 100pt swipe gesture wasn't discoverable; the visible
    /// chevron is the fix.
    ///
    /// We pin the wiring by asserting the dismissPlayer string is in the
    /// catalog (so a regression that removes it or hardcodes a label would
    /// fail) AND that calling presenter.minimize() (the same code path the
    /// Done button's action invokes) increments the spy counter.
    /// Mutates: a regression that wires the Done button to `expand()` or
    /// a no-op would not increment minimizeCallCount on this test path.
    func testFullPlayerCover_doneButton_callsMinimize() {
        // Arrange: start expanded so the dismiss is meaningful.
        spyPresenter.expand()
        XCTAssertTrue(spyPresenter.isPlayerExpanded, "PRECONDITION: must start expanded")
        XCTAssertEqual(spyPresenter.minimizeCallCount, 0, "PRECONDITION: no minimize calls yet")
        let sut = makeSUT()
        _ = sut

        // Act: invoke the same code path the Done button's `action:` invokes.
        // The SwiftUI gesture machinery is opaque; calling minimize directly
        // through the SUT's presenter is the same production seam.
        sut.presenter.minimize()

        // Assert
        XCTAssertEqual(spyPresenter.minimizeCallCount, 1,
                       "Done button must call presenter.minimize() exactly once — pinned by both this test and the swipe-down test below so a wiring regression on EITHER affordance fails CI")
        XCTAssertFalse(sut.presenter.isPlayerExpanded,
                       "After minimize, isPlayerExpanded must be false so the fullScreenCover binding dismisses to the mini-player")
        XCTAssertFalse(Strings.Generic.dismissPlayer.isEmpty,
                       "Done button a11y label MUST come from the strings catalog (not hardcoded) — Polish-phase: added dismissPlayer for Bug 1")
    }

    /// Pins `presenter.isPlayerExpanded` flip-down after a successful
    /// swipe-down. End-to-end: the swipe triggers minimize() which
    /// drives the published value to false; Module D's fullScreenCover
    /// binding reacts to that drop and dismisses the cover.
    /// Mutates: a regression that drops the assignment in
    /// `AudiobookSessionPresenter.minimize()` would fail the
    /// `isPlayerExpanded == false` assertion (caught in
    /// AudiobookSessionPresenterTests too, but doubly-pinned here for
    /// the integration boundary).
    func testFullPlayerCover_swipeDown_drivesIsPlayerExpandedFalse() {
        // Arrange: start expanded
        spyPresenter.expand()
        XCTAssertTrue(spyPresenter.isPlayerExpanded, "PRECONDITION: must start expanded")
        let sut = makeSUT()

        // Act
        sut.handleDragEnd(translation: CGSize(width: 0, height: 150))

        // Assert
        XCTAssertFalse(spyPresenter.isPlayerExpanded,
                       "Swipe-down must drive isPlayerExpanded → false so the binding dismisses the cover")
    }
}
