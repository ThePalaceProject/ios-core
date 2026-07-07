//
//  PalaceMotionTests.swift
//  PalaceTests
//
//  PP-4745 (PR2) — pins the reduce-motion resolution, the shimmer sweep, and the
//  shared corner-radius tokens introduced by the motion foundations.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import SwiftUI
@testable import Palace

final class PalaceMotionTests: XCTestCase {

    // MARK: - resolved(_:reduceMotion:) — the reduce-motion gate

    /// When Reduce Motion is ON, the resolver must drop the animation (return nil)
    /// so `.animation(nil, value:)` applies no motion.
    func testResolved_reduceMotionOn_returnsNil() {
        XCTAssertNil(PalaceMotion.resolved(PalaceMotion.standard, reduceMotion: true),
                     "Reduce Motion on must suppress the animation")
    }

    /// When Reduce Motion is OFF, the resolver must pass the animation through.
    func testResolved_reduceMotionOff_returnsAnimation() {
        XCTAssertNotNil(PalaceMotion.resolved(PalaceMotion.standard, reduceMotion: false),
                        "Reduce Motion off must keep the animation")
    }

    /// A nil animation stays nil regardless of the flag (no accidental default).
    func testResolved_nilAnimation_staysNil() {
        XCTAssertNil(PalaceMotion.resolved(nil, reduceMotion: false))
        XCTAssertNil(PalaceMotion.resolved(nil, reduceMotion: true))
    }

    // MARK: - shimmerOffset(phase:width:) — proves the shimmer actually moves

    /// The whole shimmer bug was that no visual property read the animated state,
    /// so it rendered static. The fixed shimmer offsets a highlight band by
    /// `shimmerOffset(phase:width:)`. Different phases MUST yield different offsets
    /// — otherwise the band is static again.
    func testShimmerOffset_movesWithPhase() {
        let width: CGFloat = 200
        let start = PalaceMotion.shimmerOffset(phase: -1, width: width)
        let end = PalaceMotion.shimmerOffset(phase: 1, width: width)
        XCTAssertNotEqual(start, end,
                          "Offset must change across the phase — a constant offset is the static-wash regression")
    }

    /// The band must fully clear both edges so the sweep is complete, not a
    /// half-visible static sheen: phase -1 parks it off the leading edge (-width),
    /// phase +1 off the trailing edge (+width).
    func testShimmerOffset_clearsBothEdges() {
        XCTAssertEqual(PalaceMotion.shimmerOffset(phase: -1, width: 200), -200, accuracy: 0.001)
        XCTAssertEqual(PalaceMotion.shimmerOffset(phase: 1, width: 200), 200, accuracy: 0.001)
    }

    /// Mid-phase the band is centered (offset 0). Pins the mapping shape so a
    /// `phase + width` style mutant (off-center) is caught.
    func testShimmerOffset_centeredAtMidPhase() {
        XCTAssertEqual(PalaceMotion.shimmerOffset(phase: 0, width: 200), 0, accuracy: 0.001)
    }

    // MARK: - Radius tokens

    /// The two shared radii are the design tokens PR2 commits to. Layout that
    /// migrates to them depends on these values; a swap or zero would regress
    /// every adopting surface.
    func testRadiusTokens_haveExpectedValuesAndOrdering() {
        XCTAssertEqual(PalaceRadius.card, 12, accuracy: 0.001)
        XCTAssertEqual(PalaceRadius.control, 8, accuracy: 0.001)
        XCTAssertGreaterThan(PalaceRadius.card, PalaceRadius.control,
                             "Cards use a larger radius than controls")
    }
}
