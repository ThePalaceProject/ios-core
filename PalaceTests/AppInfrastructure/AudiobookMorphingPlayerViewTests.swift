//
//  AudiobookMorphingPlayerViewTests.swift
//  PalaceTests
//
//  Unit coverage for the pure, mutation-testable seams of the custom morphing
//  audiobook player: the bookmark-error → localized-toast mapping (restores the
//  toolkit's `BookmarkError.localizedDescription`, which is module-internal and
//  unreachable from the app), the toast error/success classifier, the adaptive
//  control metrics (toolkit `controlPanelView` / `playbackControlsView` tiers),
//  and the rubber-band resistance curve for the interactive pull-down.
//
//  The SwiftUI body itself is opaque to XCTest; these static helpers carry the
//  logic that would otherwise hide inside it, so they are asserted directly.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import XCTest
import PalaceAudiobookToolkit
@testable import Palace

@MainActor
final class AudiobookMorphingPlayerViewTests: XCTestCase {

    typealias V = AudiobookMorphingPlayerView

    // MARK: - Bookmark error → localized toast (item 1)

    /// The two public `BookmarkError` cases map to the faithful app-side copy,
    /// NOT the raw `Error.localizedDescription` ("operation couldn't be
    /// completed"). Kills a switch-arm swap.
    func testBookmarkErrorMessage_mapsPublicCasesToLocalizedCopy() {
        XCTAssertEqual(V.bookmarkErrorMessage(for: BookmarkError.bookmarkAlreadyExists),
                       Strings.Generic.bookmarkAlreadyExists,
                       "`.bookmarkAlreadyExists` must map to the already-saved-here copy")
        XCTAssertEqual(V.bookmarkErrorMessage(for: BookmarkError.bookmarkFailedToSave),
                       Strings.Generic.bookmarkFailedToSave,
                       "`.bookmarkFailedToSave` must map to the couldn't-be-saved copy")
        // The two arms must be distinct — a mutation collapsing them is caught.
        XCTAssertNotEqual(V.bookmarkErrorMessage(for: BookmarkError.bookmarkAlreadyExists),
                          V.bookmarkErrorMessage(for: BookmarkError.bookmarkFailedToSave),
                          "The two BookmarkError cases must surface different copy")
    }

    /// Any non-`BookmarkError` failure falls back to the generic add-failed
    /// string — never the raw system description. Kills dropping the `default`.
    func testBookmarkErrorMessage_unknownErrorFallsBackToGeneric() {
        let foreign = NSError(domain: "Foo", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "operation couldn't be completed"])
        XCTAssertEqual(V.bookmarkErrorMessage(for: foreign),
                       Strings.Generic.bookmarkAddFailed,
                       "A non-BookmarkError must fall back to the generic add-failed string, not the raw description")
    }

    // MARK: - Toast error/success classifier

    /// The success string (bookmark added) is NOT an error; every failure copy —
    /// the generic plus the two mapped cases plus any 'error'-bearing string — IS.
    func testToastIsError_classifiesSuccessAndFailureCopy() {
        XCTAssertFalse(V.toastIsError(Strings.Generic.bookmarkAdded),
                       "Bookmark-added is a success toast → bookmark glyph, not error")
        XCTAssertTrue(V.toastIsError(Strings.Generic.bookmarkAddFailed),
                      "Generic add-failed is an error toast")
        XCTAssertTrue(V.toastIsError(Strings.Generic.bookmarkAlreadyExists),
                      "Already-exists is an error toast")
        XCTAssertTrue(V.toastIsError(Strings.Generic.bookmarkFailedToSave),
                      "Failed-to-save is an error toast")
        XCTAssertTrue(V.toastIsError("A playback Error occurred"),
                      "Any string containing 'error' (case-insensitive) is an error toast")
        XCTAssertFalse(V.toastIsError("Now playing"),
                       "An arbitrary non-error string is not an error toast")
    }

    // MARK: - Adaptive control metrics (item 2 — toolkit tier parity)

    /// Standard iPhone-portrait tier (width ≥ 370, not landscape) matches the
    /// toolkit `controlPanelView` + `playbackControlsView` "else" values exactly.
    func testControlMetrics_standardPortraitTier_matchesToolkit() {
        let m = V.ControlMetrics(width: 390, landscape: false)
        XCTAssertFalse(m.narrow)
        XCTAssertEqual(m.chipHeight, 40)
        XCTAssertEqual(m.fontSize, 15)
        XCTAssertEqual(m.iconSize, 19)
        XCTAssertEqual(m.chipPadH, 14)
        XCTAssertEqual(m.outerPadH, 20)
        XCTAssertEqual(m.chipSpacing, 12)
        XCTAssertEqual(m.transportSpacing, 40)
        XCTAssertEqual(m.transportHeight, 72)
    }

    /// Narrow tier (SE/Mini, width < 370) matches the toolkit narrow values.
    func testControlMetrics_narrowTier_matchesToolkit() {
        let m = V.ControlMetrics(width: 360, landscape: false)
        XCTAssertTrue(m.narrow)
        XCTAssertEqual(m.chipHeight, 34)
        XCTAssertEqual(m.fontSize, 12)
        XCTAssertEqual(m.iconSize, 15)
        XCTAssertEqual(m.chipPadH, 10)
        XCTAssertEqual(m.outerPadH, 12)
        XCTAssertEqual(m.chipSpacing, 6)
    }

    /// Landscape tier matches the toolkit landscape values and shrinks the
    /// transport row to spacing 25 / height 56.
    func testControlMetrics_landscapeTier_matchesToolkit() {
        let m = V.ControlMetrics(width: 800, landscape: true)
        XCTAssertEqual(m.chipHeight, 34)
        XCTAssertEqual(m.fontSize, 13)
        XCTAssertEqual(m.iconSize, 16)
        XCTAssertEqual(m.chipPadH, 12)
        XCTAssertEqual(m.outerPadH, 16)
        XCTAssertEqual(m.chipSpacing, 8)
        XCTAssertEqual(m.transportSpacing, 25)
        XCTAssertEqual(m.transportHeight, 56)
    }

    /// The narrow boundary is `< 370`: 369 is narrow, 370 is standard. Kills a
    /// `<` → `<=` mutation on the tier threshold.
    func testControlMetrics_narrowBoundary_isStrictlyLessThan370() {
        XCTAssertTrue(V.ControlMetrics(width: 369, landscape: false).narrow,
                      "369pt must be the narrow tier")
        XCTAssertFalse(V.ControlMetrics(width: 370, landscape: false).narrow,
                       "370pt must be the standard tier (kills `<` → `<=`)")
    }

    // MARK: - Rubber-band resistance (item 3)

    /// A non-upward (≥ 0) offset passes through unresisted — the pull-down tracks
    /// the finger 1:1 downward; only the upward direction is rubber-banded.
    func testRubberBand_nonUpwardOffsetPassesThrough() {
        XCTAssertEqual(V.rubberBand(0), 0, accuracy: 0.0001,
                       "Zero offset must pass through (guard boundary)")
        XCTAssertEqual(V.rubberBand(120), 120, accuracy: 0.0001,
                       "A downward (positive) offset is not rubber-banded")
    }

    /// An upward (negative) pull is resisted: the resulting magnitude is strictly
    /// smaller than the input, and the curve asymptotes toward the -72 limit
    /// without ever crossing it. Kills dropping the resistance or the clamp.
    func testRubberBand_upwardPullIsResistedAndClamped() {
        let small = V.rubberBand(-100)
        XCTAssertLessThan(small, 0, "Upward pull stays negative")
        XCTAssertGreaterThan(small, -100, "Resistance: |result| < |input| for a -100 pull")
        XCTAssertGreaterThan(small, -72, "Never past the -72 asymptote limit")

        // Deep pull approaches, but never crosses, the limit.
        let deep = V.rubberBand(-100_000)
        XCTAssertGreaterThan(deep, -72, "Asymptote: even a huge pull stays above -72")
        XCTAssertLessThan(deep, -70, "…but a huge pull gets close to the -72 limit")

        // Monotonic: a deeper pull yields a larger (more negative) magnitude.
        XCTAssertLessThan(V.rubberBand(-400), V.rubberBand(-100),
                          "Deeper upward pull must resist further (monotonic resistance)")
    }
}
