//
//  BadgeUnlockPhaseTests.swift
//  PalaceTests
//
//  PP-4747: pins the badge-unlock PhaseAnimator sequence that replaced the
//  fragile `asyncAfter` reset in BadgesView. The phase enum is the pure driver:
//  its scale mapping IS the pop, and its animation mapping IS the reduce-motion
//  gate, so a regression in either fails here without a SwiftUI host.
//

import XCTest
import SwiftUI
@testable import Palace

final class BadgeUnlockPhaseTests: XCTestCase {

  func testPhaseOrder_isIdleThenPopThenSettle() {
    XCTAssertEqual(BadgeUnlockPhase.allCases, [.idle, .pop, .settle],
                   "The animator relies on this declaration order to run idle -> pop -> settle once.")
  }

  func testPop_scalesUp_whileIdleAndSettleRestAtUnitScale() {
    XCTAssertEqual(BadgeUnlockPhase.pop.scale, 1.2, accuracy: 0.0001,
                   "Pop must overshoot so the unlock is visible.")
    XCTAssertEqual(BadgeUnlockPhase.idle.scale, 1.0, accuracy: 0.0001)
    // The whole point of a settle phase: it must return to the SAME scale as
    // idle so the medallion rests un-scaled after the pop (no dangling reset).
    XCTAssertEqual(BadgeUnlockPhase.settle.scale, BadgeUnlockPhase.idle.scale, accuracy: 0.0001,
                   "Settle must rest at idle's scale, otherwise badges stay enlarged.")
    XCTAssertGreaterThan(BadgeUnlockPhase.pop.scale, BadgeUnlockPhase.settle.scale)
  }

  func testAnimation_idleRestsWithoutAnimation() {
    XCTAssertNil(BadgeUnlockPhase.idle.animation,
                 "The initial/resting phase must not animate on first appearance.")
  }

  func testAnimation_popAndSettle_useSharedMotion() {
    XCTAssertEqual(BadgeUnlockPhase.pop.animation, PalaceMotion.emphasized)
    XCTAssertEqual(BadgeUnlockPhase.settle.animation, PalaceMotion.gentle)
  }
}
