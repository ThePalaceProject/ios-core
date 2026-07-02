//
//  AppRatingService.swift
//  Palace
//
//  Orchestrates app-rating engagement tracking + eligibility (Epic PP-4086).
//  PR 1 scope: recording + eligibility only. Presentation of the sentiment
//  gate, the StoreKit request, and the feedback path land in PR 2
//  (PP-4089 / PP-4090 / PP-4091).
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation

/// The positive moments that may trigger an eligibility check.
enum AppRatingTrigger {
  /// The patron finished reading or listening to a book (primary trigger).
  case bookCompleted
  /// The patron successfully borrowed a book (secondary trigger).
  case borrowSucceeded
}

/// Central entry point for the app-rating feature. Views and lifecycle hooks
/// talk to this service rather than to the tracker or policy directly.
///
/// `@MainActor` because it is reached from UI lifecycle hooks and (in PR 2)
/// drives presentation.
@MainActor
final class AppRatingService {

  private let tracker: RatingEngagementTracker
  private let configProvider: () -> RatingConfig
  private let promptEnabledProvider: () -> Bool
  private let forceEligibleProvider: () -> Bool
  private let crashFreeProbe: () -> Bool
  private let now: () -> Date

  /// - Parameters:
  ///   - tracker: persists/reads engagement signals.
  ///   - configProvider: supplies the (remote-tunable) thresholds on demand.
  ///   - promptEnabledProvider: remote master kill-switch for the whole feature.
  ///   - forceEligibleProvider: QA/simdrive override that forces eligibility so
  ///     the gate can be triggered on demand (bypasses thresholds, cooldown, and
  ///     the master switch). Defaults to off.
  ///   - crashFreeProbe: best-effort "was the previous session crash-free?"
  ///     signal, evaluated once per session.
  ///   - now: injected clock for deterministic cooldown math.
  init(
    tracker: RatingEngagementTracker,
    configProvider: @escaping () -> RatingConfig = { .fallback },
    promptEnabledProvider: @escaping () -> Bool = { true },
    forceEligibleProvider: @escaping () -> Bool = { false },
    crashFreeProbe: @escaping () -> Bool = { true },
    now: @escaping () -> Date = Date.init
  ) {
    self.tracker = tracker
    self.configProvider = configProvider
    self.promptEnabledProvider = promptEnabledProvider
    self.forceEligibleProvider = forceEligibleProvider
    self.crashFreeProbe = crashFreeProbe
    self.now = now
  }

  // MARK: - Recording

  /// Records an app open. Also captures whether the previous session was
  /// crash-free (best-effort). Call once when the app becomes active.
  func recordSession() {
    tracker.recordSession(crashFreeLastSession: crashFreeProbe())
  }

  /// Records that a book was finished.
  func recordBookCompleted() {
    tracker.recordBookCompleted()
  }

  /// Records that the sentiment gate was shown (stamps cooldown + lifetime cap).
  func recordPromptShown() {
    tracker.recordPromptShown(at: now())
  }

  /// Records that the patron dismissed/declined the gate.
  func recordDismissal() {
    tracker.recordDismissal()
  }

  /// Records that the patron chose "Don't ask again".
  func recordOptOut() {
    tracker.recordOptOut()
  }

  /// Clears all engagement signals (QA/simdrive "Reset rating state" action).
  func resetEngagementState() {
    tracker.reset()
  }

  // MARK: - Eligibility

  /// Whether the prompt may be shown for the given trigger right now.
  /// The force-eligible override (QA/simdrive) short-circuits to `true`.
  /// Otherwise returns `false` when the remote master switch is off, regardless
  /// of engagement state.
  func isEligible(for trigger: AppRatingTrigger) -> Bool {
    if forceEligibleProvider() { return true }
    guard promptEnabledProvider() else { return false }
    return RatingEligibilityPolicy.evaluate(
      state: tracker.currentState(),
      config: configProvider(),
      now: now()
    )
  }
}
