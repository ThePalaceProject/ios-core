//
//  AudiobookCollapsedPillViewTests.swift
//  PalaceTests
//
//  Visibility predicate, restore-wiring, and play/pause-wiring for the
//  compact floating pill that replaces the mini-bar when the user collapses
//  it. Same test posture as `AudiobookMiniPlayerViewTests` — no SwiftUI host
//  harness in the repo, so we pin the static predicate + the injected-
//  dependency call routing via the spy presenter / spy session.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import XCTest
import SwiftUI
import UIKit
import PalaceAudiobookToolkit
@testable import Palace

@MainActor
final class AudiobookCollapsedPillViewTests: XCTestCase {

    private var spyPresenter: SpyAudiobookSessionPresenter!
    private var spySession: SpyShimSession!

    override func setUp() async throws {
        try await super.setUp()
        spyPresenter = SpyAudiobookSessionPresenter()
        spySession = SpyShimSession()
    }

    override func tearDown() async throws {
        spyPresenter = nil
        spySession = nil
        try await super.tearDown()
    }

    private func makeSUT() -> AudiobookCollapsedPillView {
        return AudiobookCollapsedPillView(presenter: spyPresenter, audiobookSession: spySession)
    }

    // MARK: - Visibility predicate (mutation-killing)

    /// `shouldShow` is the exact complement of the mini-bar's
    /// `shouldShowChrome` on the collapsed axis: the pill shows iff active +
    /// not-in-reader + collapsed. The truth table pins every operator.
    func testShouldShow_truthTable_killsBooleanMutations() {
        // Happy path: active + no reader + collapsed → SHOW pill.
        XCTAssertTrue(AudiobookCollapsedPillView.shouldShow(hasActiveSession: true, isReaderActive: false, isCollapsed: true),
                      "active + no reader + collapsed → must SHOW the pill (happy path)")

        // Not collapsed → HIDE (the mini-bar is showing instead). KEY ROW:
        // dropping the `isCollapsed` term flips this true → bar + pill both show.
        XCTAssertFalse(AudiobookCollapsedPillView.shouldShow(hasActiveSession: true, isReaderActive: false, isCollapsed: false),
                       "active + not collapsed → must HIDE the pill (the full bar is showing). Kills a dropped `isCollapsed` term.")

        // Reader active → HIDE even when collapsed (reader suppression wins).
        XCTAssertFalse(AudiobookCollapsedPillView.shouldShow(hasActiveSession: true, isReaderActive: true, isCollapsed: true),
                       "reader active → must HIDE the pill regardless of collapse. Kills a dropped `!isReaderActive`.")

        // No session → HIDE even when collapsed. Distinguishes && from ||.
        XCTAssertFalse(AudiobookCollapsedPillView.shouldShow(hasActiveSession: false, isReaderActive: false, isCollapsed: true),
                       "no session → must HIDE the pill. KEY ROW: distinguishes `&&` from `||`.")
    }

    /// The pill and the mini-bar are mutually exclusive for the same active,
    /// not-in-reader state — exactly one is visible, toggled by `isCollapsed`.
    func testPillAndBar_areMutuallyExclusive_onCollapsedAxis() {
        let collapsed = true
        let barWhenCollapsed = AudiobookMiniPlayerView.shouldShowChrome(hasActiveSession: true, isReaderActive: false, isCollapsed: collapsed)
        let pillWhenCollapsed = AudiobookCollapsedPillView.shouldShow(hasActiveSession: true, isReaderActive: false, isCollapsed: collapsed)
        XCTAssertNotEqual(barWhenCollapsed, pillWhenCollapsed,
                          "When collapsed: pill shows, bar hides — never both")

        let barWhenExpanded = AudiobookMiniPlayerView.shouldShowChrome(hasActiveSession: true, isReaderActive: false, isCollapsed: false)
        let pillWhenExpanded = AudiobookCollapsedPillView.shouldShow(hasActiveSession: true, isReaderActive: false, isCollapsed: false)
        XCTAssertNotEqual(barWhenExpanded, pillWhenExpanded,
                          "When not collapsed: bar shows, pill hides — never both")
    }

    // MARK: - Restore wiring

    /// Tapping the pill's cover restores the full mini-bar via
    /// `presenter.restoreFromCollapsed()` — and does NOT stop playback.
    func testPill_restore_callsRestoreFromCollapsed_withoutStoppingPlayback() {
        spyPresenter.collapse()
        XCTAssertTrue(spyPresenter.isCollapsed, "PRECONDITION: collapsed")
        let restoresBefore = spyPresenter.restoreFromCollapsedCallCount

        // Drive the production seam the cover's tap gesture invokes.
        spyPresenter.restoreFromCollapsed()

        XCTAssertEqual(spyPresenter.restoreFromCollapsedCallCount, restoresBefore + 1,
                       "Tapping the pill must call restoreFromCollapsed() to bring the full bar back")
        XCTAssertFalse(spyPresenter.isCollapsed, "Presenter must leave the collapsed state after restore")
        XCTAssertEqual(spySession.stopPlaybackCallCount, 0,
                       "Restoring must NOT stop playback — the pill keeps audio running")
    }

    // MARK: - Play/pause wiring

    /// The pill's play/pause button routes through the injected session so the
    /// user keeps transport control without restoring the whole bar.
    func testPill_playPauseButton_routesThroughInjectedSession() {
        let sut = makeSUT()
        XCTAssertEqual(spySession.togglePlayPauseCallCount, 0, "PRECONDITION: no toggles yet")

        sut.audiobookSession.togglePlayPause()

        XCTAssertEqual(spySession.togglePlayPauseCallCount, 1,
                       "Pill play/pause must call audiobookSession.togglePlayPause() exactly once")
        XCTAssertTrue(sut.audiobookSession as AnyObject === spySession as AnyObject,
                      "Pill must hold the INJECTED session — proves the wiring isn't a hardcoded singleton")
    }

    // MARK: - Accessibility

    func testPill_accessibilityStringsAreNonEmpty() {
        XCTAssertFalse(Strings.Generic.restoreAudiobookPlayerHint.isEmpty,
                       "Pill a11y hint MUST be non-empty so VoiceOver users hear how to restore the player")
        XCTAssertFalse(Strings.Generic.nowPlayingCompactLabel.isEmpty,
                       "Pill a11y label format MUST come from the strings catalog")
    }
}
