//
//  ReaderChromeToggleFadeTests.swift
//  PalaceTests
//
//  PR3 (PP-4746) — reader chrome toggle choreography + bookmark-add bounce gate.
//
//  These pin the pure decision seams extracted from
//  `TPPBaseReaderViewController`. The VC itself is a UIKit view controller whose
//  `init` reaches into the live app dependency graph (navigator + publication),
//  so it is not cheaply constructible in a unit test — the presentation logic
//  is therefore extracted into `static` functions that carry the branch behavior
//  and are exercised directly here (a static call is the sanctioned alternative
//  to instantiation for behavior-bearing seams).
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class ReaderChromeToggleFadeTests: XCTestCase {

    // MARK: - overlayLabelsHidden truth table

    /// The overlay chrome (book title + position) belongs to immersive reading:
    /// visible when the nav bar is HIDDEN, hidden when it is SHOWN, and always
    /// hidden under VoiceOver. This table kills the `||` → `&&` and drop-`!`
    /// mutations of the decision.
    func test_overlayLabelsHidden_truthTable() {
        // Immersive (bar hidden), VoiceOver off → labels VISIBLE (not hidden).
        XCTAssertFalse(
            TPPBaseReaderViewController.overlayLabelsHidden(navigationBarHidden: true, voiceOverRunning: false),
            "Bar hidden + VoiceOver off is immersive mode: the overlay labels must be visible.")

        // Bar shown, VoiceOver off → labels HIDDEN (the nav bar carries the title).
        // KEY ROW distinguishing `||` from `&&`: with `&&` this would flip to false.
        XCTAssertTrue(
            TPPBaseReaderViewController.overlayLabelsHidden(navigationBarHidden: false, voiceOverRunning: false),
            "Bar shown + VoiceOver off: overlay labels must hide so they don't duplicate the nav bar. KEY ROW for the || operator.")

        // VoiceOver on, bar hidden → HIDDEN (kills drop-`!`: without `!`, bar
        // hidden would force visible even under VoiceOver).
        XCTAssertTrue(
            TPPBaseReaderViewController.overlayLabelsHidden(navigationBarHidden: true, voiceOverRunning: true),
            "VoiceOver on must hide the overlay labels even in immersive mode — kills the drop-`!` mutation.")

        // VoiceOver on, bar shown → HIDDEN.
        XCTAssertTrue(
            TPPBaseReaderViewController.overlayLabelsHidden(navigationBarHidden: false, voiceOverRunning: true),
            "VoiceOver on always hides the overlay labels regardless of bar state.")
    }

    /// Both labels share ONE decision, so a toggle flips them together — the
    /// property the choreography depends on (title + position in lockstep).
    func test_overlayLabelsHidden_flipsWithBarState() {
        let immersive = TPPBaseReaderViewController.overlayLabelsHidden(navigationBarHidden: true, voiceOverRunning: false)
        let chromeShown = TPPBaseReaderViewController.overlayLabelsHidden(navigationBarHidden: false, voiceOverRunning: false)
        XCTAssertNotEqual(immersive, chromeShown,
                          "Toggling the nav bar must flip the overlay visibility — the labels reveal/conceal together.")
    }

    // MARK: - bookmark-add bounce gate

    /// The add-confirmation bounce respects Reduce Motion.
    func test_shouldAnimateBookmarkBounce_respectsReduceMotion() {
        XCTAssertTrue(TPPBaseReaderViewController.shouldAnimateBookmarkBounce(reduceMotion: false),
                      "Bounce plays when Reduce Motion is off.")
        XCTAssertFalse(TPPBaseReaderViewController.shouldAnimateBookmarkBounce(reduceMotion: true),
                       "Bounce is suppressed when Reduce Motion is on — kills the negation mutation.")
    }
}
