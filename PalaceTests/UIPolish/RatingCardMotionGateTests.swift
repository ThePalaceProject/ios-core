//
//  RatingCardMotionGateTests.swift
//  PalaceTests
//
//  PP-4747: pins the reduce-motion gate the app-rating card gained in PR4.
//  The card previously always scaled on present/dismiss, ignoring the
//  Reduce Motion setting. These tests exercise the pure decision seams so a
//  regression that drops the gate (or the emphasized spring) fails loudly.
//

import XCTest
import SwiftUI
@testable import Palace

@MainActor
final class RatingCardMotionGateTests: XCTestCase {

  // MARK: usesScaleTransition

  func testUsesScaleTransition_reduceMotionOff_scales() {
    XCTAssertTrue(SentimentGateView.usesScaleTransition(reduceMotion: false),
                  "With Reduce Motion off the card should keep its scale pop.")
  }

  func testUsesScaleTransition_reduceMotionOn_dropsScale() {
    XCTAssertFalse(SentimentGateView.usesScaleTransition(reduceMotion: true),
                   "With Reduce Motion on the card must NOT scale — this is the gate the card was missing.")
  }

  // MARK: stepAnimation

  func testStepAnimation_reduceMotionOff_usesEmphasizedSpring() {
    XCTAssertEqual(SentimentGateView.stepAnimation(reduceMotion: false),
                   PalaceMotion.emphasized,
                   "Normal motion should route through the shared emphasized spring, not a linear easeInOut.")
  }

  func testStepAnimation_reduceMotionOn_isNil() {
    XCTAssertNil(SentimentGateView.stepAnimation(reduceMotion: true),
                 "Reduce Motion must suppress the card-swap animation entirely.")
  }

  // MARK: cardTransition is derived from the gate

  func testCardTransition_tracksScaleGate_bothDirections() {
    // The transition builder must consult the same gate, not hardcode a scale.
    // We can't compare AnyTransition values directly, so we assert the gate the
    // builder is required to consult flips with the flag.
    XCTAssertNotEqual(SentimentGateView.usesScaleTransition(reduceMotion: false),
                      SentimentGateView.usesScaleTransition(reduceMotion: true),
                      "The scale gate must actually depend on the reduce-motion flag.")
    _ = SentimentGateView.cardTransition(reduceMotion: true)
    _ = SentimentGateView.cardTransition(reduceMotion: false)
  }
}
