//
//  SkeletonTests.swift
//  PalaceTests
//
//  PP-4752 — pins the pure geometry seams of the unified skeleton system:
//  the diagonal sweep translation across phase, the text last-line fraction,
//  and the reduce-motion sweep gate. These are the parts that render the
//  "great" bar mechanical + regression-proof without a SwiftUI host.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import SwiftUI
@testable import Palace

final class SkeletonTests: XCTestCase {

  // MARK: - sweepTranslationX — the diagonal band actually travels

  private let angle = Skeleton.angle

  /// A moving phase MUST change the offset — a constant offset is the
  /// static-wash regression the whole system exists to avoid.
  func testSweepTranslation_movesWithPhase() {
    let w: CGFloat = 200, h: CGFloat = 150
    let band = Skeleton.bandWidth(contentWidth: w)
    let start = Skeleton.sweepTranslationX(phase: -1, width: w, height: h, angle: angle, bandWidth: band)
    let end = Skeleton.sweepTranslationX(phase: 1, width: w, height: h, angle: angle, bandWidth: band)
    XCTAssertNotEqual(start, end, accuracy: 0.001,
                      "Offset must change across phase — constant offset = static wash")
    XCTAssertLessThan(start, end, "Phase -1 parks left of phase +1")
  }

  /// Mid-phase the band is centered on the content (offset 0). Catches an
  /// off-center `phase * travel` vs `phase * travel + k` mutant.
  func testSweepTranslation_centeredAtMidPhase() {
    let band = Skeleton.bandWidth(contentWidth: 200)
    XCTAssertEqual(
      Skeleton.sweepTranslationX(phase: 0, width: 200, height: 150, angle: angle, bandWidth: band),
      0, accuracy: 0.001)
  }

  /// The travel is symmetric about center: +phase and -phase are mirror offsets.
  func testSweepTranslation_symmetricAboutCenter() {
    let band = Skeleton.bandWidth(contentWidth: 120)
    let neg = Skeleton.sweepTranslationX(phase: -0.5, width: 120, height: 90, angle: angle, bandWidth: band)
    let pos = Skeleton.sweepTranslationX(phase: 0.5, width: 120, height: 90, angle: angle, bandWidth: band)
    XCTAssertEqual(neg, -pos, accuracy: 0.001)
  }

  /// The band must fully clear the content at the extremes: at phase ±1 the
  /// absolute offset must exceed half the content width plus half the band, so
  /// no sheen is left parked on-screen at the loop seam.
  func testSweepTranslation_fullyClearsContentAtExtremes() {
    let w: CGFloat = 200, h: CGFloat = 150
    let band = Skeleton.bandWidth(contentWidth: w)
    let end = Skeleton.sweepTranslationX(phase: 1, width: w, height: h, angle: angle, bandWidth: band)
    XCTAssertGreaterThan(end, w / 2 + band / 2,
                         "At phase 1 the band must be fully off the trailing edge")
  }

  /// The diagonal tilt widens the required travel vs a purely horizontal band:
  /// taller content ⇒ more travel (the height casts a horizontal shadow across
  /// the tilt). A zero-angle mutant would make height irrelevant.
  func testSweepTranslation_tiltMakesTallerContentTravelFarther() {
    let w: CGFloat = 200
    let band = Skeleton.bandWidth(contentWidth: w)
    let shortEnd = Skeleton.sweepTranslationX(phase: 1, width: w, height: 20, angle: angle, bandWidth: band)
    let tallEnd = Skeleton.sweepTranslationX(phase: 1, width: w, height: 400, angle: angle, bandWidth: band)
    XCTAssertGreaterThan(tallEnd, shortEnd,
                         "A diagonal sweep must travel farther over taller content")
  }

  // MARK: - bandWidth — soft + wide, with a floor

  func testBandWidth_isFractionOfWideContent() {
    XCTAssertEqual(Skeleton.bandWidth(contentWidth: 400),
                   400 * Skeleton.highlightWidthFraction, accuracy: 0.001)
  }

  func testBandWidth_floorsForTinyContent() {
    XCTAssertEqual(Skeleton.bandWidth(contentWidth: 10), Skeleton.minBandWidth, accuracy: 0.001,
                   "Tiny elements still get a visible band via the floor")
  }

  // MARK: - SkeletonText.lineWidth — last line is shorter

  /// A multi-line block's last line is `lastLineFraction` of the width; all
  /// earlier lines are full width. This is what makes the block read as prose.
  func testLineWidth_lastLineIsShorter() {
    let full = SkeletonText.lineWidth(index: 0, count: 3, totalWidth: 300, lastLineFraction: 0.6)
    let last = SkeletonText.lineWidth(index: 2, count: 3, totalWidth: 300, lastLineFraction: 0.6)
    XCTAssertEqual(full, 300, accuracy: 0.001)
    XCTAssertEqual(last, 180, accuracy: 0.001, "Last line = 0.6 * width")
    XCTAssertLessThan(last, full)
  }

  /// A middle line is full width (only the terminal line shortens).
  func testLineWidth_middleLineIsFullWidth() {
    XCTAssertEqual(SkeletonText.lineWidth(index: 1, count: 3, totalWidth: 300, lastLineFraction: 0.6),
                   300, accuracy: 0.001)
  }

  /// A single-line block does NOT shorten — a lone short bar looks broken, not
  /// like prose. Guards the `count > 1` condition.
  func testLineWidth_singleLineIsFullWidth() {
    XCTAssertEqual(SkeletonText.lineWidth(index: 0, count: 1, totalWidth: 300, lastLineFraction: 0.6),
                   300, accuracy: 0.001,
                   "A single line must stay full width, not shrink")
  }

  // MARK: - phase(at:duration:) — the shared time-driven clock

  /// The phase is a pure function of wall-clock time so every skeleton shares
  /// ONE OS clock (a TimelineView) instead of N repeatForever timers. It must
  /// move with time — a constant would be the static-wash regression again.
  func testPhase_movesWithTime() {
    let d = Skeleton.duration
    let a = Skeleton.phase(at: 0, duration: d)
    let b = Skeleton.phase(at: d * 0.5, duration: d)
    XCTAssertNotEqual(a, b, accuracy: 0.0001, "Phase must advance with time")
    XCTAssertLessThan(a, b, "Phase ramps upward within a cycle")
  }

  /// The phase starts fully off the leading edge and ramps toward the trailing
  /// edge over one duration: t=0 → -1, t≈duration → ≈+1.
  func testPhase_rampsFromMinusOneTowardPlusOne() {
    let d = Skeleton.duration
    XCTAssertEqual(Skeleton.phase(at: 0, duration: d), -1, accuracy: 0.0001)
    XCTAssertEqual(Skeleton.phase(at: d * 0.999, duration: d), 1, accuracy: 0.01)
  }

  /// The clock loops seamlessly: the phase at time T equals the phase at T + one
  /// full duration (so 30 skeletons stay in sync forever without drift).
  func testPhase_loopsWithPeriodEqualToDuration() {
    let d = Skeleton.duration
    let t: TimeInterval = 0.37
    XCTAssertEqual(Skeleton.phase(at: t, duration: d),
                   Skeleton.phase(at: t + d, duration: d), accuracy: 0.0001)
    XCTAssertEqual(Skeleton.phase(at: t, duration: d),
                   Skeleton.phase(at: t + d * 5, duration: d), accuracy: 0.0001)
  }

  /// A zero/negative duration must not divide-by-zero — it parks the band.
  func testPhase_zeroDurationIsSafe() {
    XCTAssertEqual(Skeleton.phase(at: 3, duration: 0), -1, accuracy: 0.0001)
  }

  // MARK: - shouldAnimateSweep — reduce-motion / low-power / active gate

  /// Reduce Motion ⇒ no sweep, even when active: a calm static base.
  func testShouldAnimateSweep_reduceMotionOn_returnsFalse() {
    XCTAssertFalse(Skeleton.shouldAnimateSweep(active: true, reduceMotion: true, lowPower: false),
                   "Reduce Motion must suppress the sweep")
  }

  /// Low Power Mode ⇒ no sweep (spare battery/GPU), even when active + motion on.
  func testShouldAnimateSweep_lowPowerOn_returnsFalse() {
    XCTAssertFalse(Skeleton.shouldAnimateSweep(active: true, reduceMotion: false, lowPower: true),
                   "Low Power Mode must suppress the sweep")
  }

  /// Active + motion allowed + full power ⇒ sweep animates.
  func testShouldAnimateSweep_activeAndMotionAllowed_returnsTrue() {
    XCTAssertTrue(Skeleton.shouldAnimateSweep(active: true, reduceMotion: false, lowPower: false))
  }

  /// Inactive ⇒ no sweep regardless of other settings.
  func testShouldAnimateSweep_inactive_returnsFalse() {
    XCTAssertFalse(Skeleton.shouldAnimateSweep(active: false, reduceMotion: false, lowPower: false))
    XCTAssertFalse(Skeleton.shouldAnimateSweep(active: false, reduceMotion: true, lowPower: true))
  }

  // MARK: - Color tokens read differently per scheme (adaptive by construction)

  /// The base fill MUST differ between light and dark — the core "great in both
  /// appearances" requirement. Equal colors would mean a non-adaptive wash.
  func testBaseColor_differsBetweenSchemes() {
    XCTAssertNotEqual(Skeleton.baseColor(.light), Skeleton.baseColor(.dark),
                      "Base fill must adapt to color scheme")
  }

  func testHighlightColor_differsBetweenSchemes() {
    XCTAssertNotEqual(Skeleton.highlightColor(.light), Skeleton.highlightColor(.dark),
                      "Highlight must adapt to color scheme")
  }

  // MARK: - Catalog entry-point selector placeholder (PP-4752 lane-pop fix)

  /// The initial-load catalog skeleton reserves the entry-point segmented
  /// selector's vertical footprint so the first lane lands at the same y in the
  /// skeleton and the loaded feed — no downward pop when content arrives. The
  /// real control is `EntryPointsSelectorView`'s
  /// `Picker(.segmented).frame(minHeight: 44)` with no vertical padding, so the
  /// placeholder MUST reserve exactly that 44pt. A mutant that zeroes or shrinks
  /// the placeholder reintroduces the lane pop this fix removed.
  func testEntryPointsSkeleton_reservesRealSelectorFootprint() {
    XCTAssertEqual(CatalogEntryPointsSkeletonView.placeholderHeight, 44, accuracy: 0.001,
                   "Placeholder must reserve the selector's 44pt minHeight footprint")
  }

  /// Guards the specific regression: a non-positive placeholder height means no
  /// space is reserved and the lanes pop down when the real selector appears.
  func testEntryPointsSkeleton_footprintIsNonDegenerate() {
    XCTAssertGreaterThan(CatalogEntryPointsSkeletonView.placeholderHeight, 0,
                         "A zero-height placeholder reserves no space — lanes would pop")
  }
}
