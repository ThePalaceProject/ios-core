//
//  RatingEligibilityPolicy.swift
//  Palace
//
//  Pure eligibility rules for the app-rating prompt (PP-4088).
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation

/// Pure decision function that determines whether a patron is eligible to be
/// shown the app-rating sentiment gate. Every input is passed explicitly
/// (state, config, clock) so the policy has no hidden dependencies and is
/// exhaustively unit- and mutation-testable. It is the single source of truth
/// for the seven eligibility criteria in PP-4088; callers must not re-implement
/// any of them.
enum RatingEligibilityPolicy {

  /// - Parameters:
  ///   - state: the current engagement snapshot.
  ///   - config: the (remote-tunable) thresholds.
  ///   - now: the current time, injected so cooldown math is deterministic.
  /// - Returns: `true` only when ALL criteria pass.
  static func evaluate(state: RatingEngagementState, config: RatingConfig, now: Date) -> Bool {
    // Respect an explicit "Don't ask again" — highest-priority opt-out.
    guard !state.optedOut else { return false }

    // Never prompt on the first session (onboarding).
    guard !state.isFirstSession else { return false }

    // Enough usage to have a meaningful opinion.
    guard state.sessionCount >= config.minSessions else { return false }
    guard state.booksCompleted >= config.minBooksCompleted else { return false }

    // Don't ask right after a bad (crashing) experience.
    guard state.crashFreeLastSession else { return false }

    // Respect Apple's spirit of a small lifetime cap.
    guard state.promptDisplayCount < config.lifetimePromptCap else { return false }

    // Respect the cooldown since the last display. `now >= earliestNext` also
    // makes a backward clock change fail closed: if the clock is set earlier
    // than the last prompt, `now` cannot reach `earliestNext`, so the prompt
    // stays suppressed rather than unlocking.
    if let lastPromptDate = state.lastPromptDate {
      let earliestNext = lastPromptDate.addingTimeInterval(config.cooldownInterval)
      guard now >= earliestNext else { return false }
    }

    return true
  }
}
