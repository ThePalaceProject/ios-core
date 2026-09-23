//
//  MarqueeTextTests.swift
//  PalaceTests
//
//  Unit coverage for the pure, mutation-testable seam of `MarqueeText`: the
//  decision of WHETHER to scroll. The SwiftUI body (measurement, offset
//  animation) is opaque to XCTest, so the gate that decides scroll-vs-static —
//  and its Reduce-Motion suppression — is factored into a static function and
//  asserted directly here.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class MarqueeTextTests: XCTestCase {

    // MARK: - shouldScroll: overflow gate

    /// Text WIDER than its container scrolls — the whole reason the marquee
    /// exists (the truncated title/author must be readable end-to-end).
    func testShouldScroll_overflowingTextScrolls() {
        XCTAssertTrue(
            MarqueeText.shouldScroll(textWidth: 320, containerWidth: 180, reduceMotion: false),
            "Text wider than the container must marquee-scroll")
    }

    /// Text that FITS never scrolls — a short title sits still (kills a mutation
    /// that always animates, which would jitter every mini-player title).
    func testShouldScroll_fittingTextIsStatic() {
        XCTAssertFalse(
            MarqueeText.shouldScroll(textWidth: 120, containerWidth: 180, reduceMotion: false),
            "Text narrower than the container must stay static")
    }

    /// The boundary is strict overflow: equal widths do NOT scroll (kills a
    /// `>` → `>=` mutation that would animate text that exactly fits).
    func testShouldScroll_exactFitDoesNotScroll() {
        XCTAssertFalse(
            MarqueeText.shouldScroll(textWidth: 180, containerWidth: 180, reduceMotion: false),
            "Text exactly as wide as the container must not scroll")
    }

    // MARK: - shouldScroll: Reduce Motion suppression (AC + a11y)

    /// Reduce Motion suppresses the scroll even when the text overflows — the
    /// AC requires the marquee to respect the setting. Static-truncated instead.
    /// Kills a mutation that drops the reduceMotion guard.
    func testShouldScroll_reduceMotionSuppressesOverflowScroll() {
        XCTAssertFalse(
            MarqueeText.shouldScroll(textWidth: 320, containerWidth: 180, reduceMotion: true),
            "Reduce Motion must suppress the marquee even for overflowing text")
    }

    // MARK: - degenerate measurements

    /// Before layout has measured a width (0), nothing scrolls — a zero-width
    /// container must not be treated as "everything overflows" and animate.
    /// The `textWidth: 100, containerWidth: 0` case is the important one: a
    /// measured text with an UN-measured (0) container must NOT scroll — this
    /// kills the `containerWidth > 0` → `>= 0` mutation, which would otherwise
    /// let `100 > 0` fire a scroll into a zero-width slot on first layout.
    func testShouldScroll_unmeasuredContainerDoesNotScroll() {
        XCTAssertFalse(
            MarqueeText.shouldScroll(textWidth: 0, containerWidth: 0, reduceMotion: false),
            "Unmeasured (0-width) layout must not scroll")
        XCTAssertFalse(
            MarqueeText.shouldScroll(textWidth: 100, containerWidth: 0, reduceMotion: false),
            "A measured text in a not-yet-measured (0-width) container must not scroll")
    }
}
