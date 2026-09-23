//
//  RatingEligibilityPolicyTests.swift
//  PalaceTests
//
//  Exhaustive behavior tests for the app-rating eligibility policy (PP-4088).
//  Each criterion is exercised individually + at its boundary so a flipped
//  comparison or negated guard in the policy is caught (mutation coverage).
//

import XCTest
@testable import Palace

@MainActor
final class RatingEligibilityPolicyTests: XCTestCase {

  /// Fixed "now" so cooldown math is deterministic.
  private let now = Date(timeIntervalSince1970: 1_000_000_000)
  private let config = RatingConfig.fallback // min5, min1, 90d, cap3

  /// A state that passes every criterion. Individual tests mutate one field.
  private func eligibleState(
    sessionCount: Int = 5,
    booksCompleted: Int = 1,
    lastPromptDate: Date? = nil,
    promptDisplayCount: Int = 0,
    dismissalCount: Int = 0,
    optedOut: Bool = false,
    crashFreeLastSession: Bool = true
  ) -> RatingEngagementState {
    RatingEngagementState(
      sessionCount: sessionCount,
      booksCompleted: booksCompleted,
      lastPromptDate: lastPromptDate,
      promptDisplayCount: promptDisplayCount,
      dismissalCount: dismissalCount,
      optedOut: optedOut,
      crashFreeLastSession: crashFreeLastSession
    )
  }

  private func evaluate(_ state: RatingEngagementState, config: RatingConfig? = nil) -> Bool {
    RatingEligibilityPolicy.evaluate(state: state, config: config ?? self.config, now: now)
  }

  func testEvaluate_allCriteriaMet_isEligible() {
    XCTAssertTrue(evaluate(eligibleState()))
  }

  // MARK: - Opt out

  func testEvaluate_whenOptedOut_isNotEligible() {
    XCTAssertFalse(evaluate(eligibleState(optedOut: true)))
  }

  // MARK: - First session / onboarding

  func testEvaluate_onFirstSession_isNotEligible() {
    // sessionCount 1 → isFirstSession true, even though it clears minSessions=1.
    let firstSessionConfig = RatingConfig(minSessions: 1, minBooksCompleted: 1, cooldownDays: 90, lifetimePromptCap: 3)
    XCTAssertFalse(evaluate(eligibleState(sessionCount: 1), config: firstSessionConfig))
  }

  // MARK: - Minimum sessions (boundary)

  func testEvaluate_sessionsBelowMinimum_isNotEligible() {
    XCTAssertFalse(evaluate(eligibleState(sessionCount: 4)))
  }

  func testEvaluate_sessionsExactlyAtMinimum_isEligible() {
    XCTAssertTrue(evaluate(eligibleState(sessionCount: 5)))
  }

  // MARK: - Minimum books completed (boundary)

  func testEvaluate_noBooksCompleted_isNotEligible() {
    XCTAssertFalse(evaluate(eligibleState(booksCompleted: 0)))
  }

  func testEvaluate_booksExactlyAtMinimum_isEligible() {
    XCTAssertTrue(evaluate(eligibleState(booksCompleted: 1)))
  }

  // MARK: - Crash-free

  func testEvaluate_afterCrashingSession_isNotEligible() {
    XCTAssertFalse(evaluate(eligibleState(crashFreeLastSession: false)))
  }

  // MARK: - Lifetime prompt cap (boundary)

  func testEvaluate_displayCountBelowCap_isEligible() {
    XCTAssertTrue(evaluate(eligibleState(promptDisplayCount: 2)))
  }

  func testEvaluate_displayCountAtCap_isNotEligible() {
    XCTAssertFalse(evaluate(eligibleState(promptDisplayCount: 3)))
  }

  func testEvaluate_displayCountAboveCap_isNotEligible() {
    XCTAssertFalse(evaluate(eligibleState(promptDisplayCount: 4)))
  }

  // MARK: - Cooldown (boundary + clock changes)

  func testEvaluate_neverPrompted_ignoresCooldown() {
    XCTAssertTrue(evaluate(eligibleState(lastPromptDate: nil)))
  }

  func testEvaluate_withinCooldown_isNotEligible() {
    // 89 days ago — one day short of the 90-day cooldown.
    let lastPrompt = now.addingTimeInterval(-89 * 86_400)
    XCTAssertFalse(evaluate(eligibleState(lastPromptDate: lastPrompt)))
  }

  func testEvaluate_exactlyAtCooldownBoundary_isEligible() {
    let lastPrompt = now.addingTimeInterval(-90 * 86_400)
    XCTAssertTrue(evaluate(eligibleState(lastPromptDate: lastPrompt)))
  }

  func testEvaluate_wellPastCooldown_isEligible() {
    let lastPrompt = now.addingTimeInterval(-120 * 86_400)
    XCTAssertTrue(evaluate(eligibleState(lastPromptDate: lastPrompt)))
  }

  func testEvaluate_clockMovedBackwardsPastLastPrompt_isNotEligible() {
    // Device clock set to BEFORE the last prompt (now < lastPromptDate).
    // Must fail closed — a backward clock change cannot unlock the prompt.
    let lastPrompt = now.addingTimeInterval(30 * 86_400) // 30 days in the "future"
    XCTAssertFalse(evaluate(eligibleState(lastPromptDate: lastPrompt)))
  }

  // MARK: - Config tunability

  func testEvaluate_respectsRemoteThresholds() {
    // A stricter remote config raises the session floor above the state's count.
    let stricter = RatingConfig(minSessions: 10, minBooksCompleted: 1, cooldownDays: 90, lifetimePromptCap: 3)
    XCTAssertFalse(evaluate(eligibleState(sessionCount: 5), config: stricter))
    XCTAssertTrue(evaluate(eligibleState(sessionCount: 10), config: stricter))
  }
}
