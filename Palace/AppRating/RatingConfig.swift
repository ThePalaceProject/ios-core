//
//  RatingConfig.swift
//  Palace
//
//  Tunable thresholds for the app-rating eligibility policy (PP-4088).
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation

/// The tunable thresholds that gate the app-rating prompt. Values are sourced
/// from Firebase Remote Config at runtime (see `RemoteFeatureFlags.appRatingConfig`)
/// so they can be re-tuned without an app release; `.fallback` supplies the
/// recommended defaults when Remote Config is unavailable.
struct RatingConfig: Equatable {

  /// Minimum number of app sessions before the prompt is eligible.
  let minSessions: Int

  /// Minimum number of finished books (read or listened) before eligibility.
  let minBooksCompleted: Int

  /// Days that must elapse after a prompt is shown before it may be shown again.
  let cooldownDays: Int

  /// Maximum number of times the prompt may ever be displayed to a patron.
  let lifetimePromptCap: Int

  /// Recommended defaults (PP-4088). Used whenever Remote Config has not
  /// supplied a value.
  static let fallback = RatingConfig(
    minSessions: 5,
    minBooksCompleted: 1,
    cooldownDays: 90,
    lifetimePromptCap: 3
  )

  /// The cooldown expressed as a `TimeInterval` for date arithmetic.
  var cooldownInterval: TimeInterval {
    TimeInterval(cooldownDays) * 86_400
  }
}
