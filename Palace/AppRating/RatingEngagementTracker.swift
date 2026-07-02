//
//  RatingEngagementTracker.swift
//  Palace
//
//  Local, on-device engagement tracking for the app-rating prompt (PP-4087).
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation

/// An immutable snapshot of the engagement signals that feed the eligibility
/// policy. All values are local/on-device; no PII is captured.
struct RatingEngagementState: Equatable {

  /// Number of times the app has been opened/became active.
  let sessionCount: Int

  /// Number of books the patron has finished (read or listened to).
  let booksCompleted: Int

  /// When the sentiment gate was last shown, or `nil` if never.
  let lastPromptDate: Date?

  /// Lifetime number of times the sentiment gate has been displayed.
  let promptDisplayCount: Int

  /// Number of times the patron dismissed/declined the sentiment gate.
  let dismissalCount: Int

  /// Whether the patron selected "Don't ask again".
  let optedOut: Bool

  /// Whether the most recent previous session ended without a crash.
  let crashFreeLastSession: Bool

  /// The first session is onboarding; never prompt during it.
  var isFirstSession: Bool { sessionCount <= 1 }
}

/// Records and reads the engagement signals used to decide when to show the
/// app-rating prompt. State is persisted through `TPPSettings`
/// (`UserDefaults`-backed), so it survives app updates. This type owns the
/// mutation of those signals; the eligibility decision itself lives in the
/// pure `RatingEligibilityPolicy`.
final class RatingEngagementTracker {

  private let settings: TPPSettingsProviding

  init(settings: TPPSettingsProviding) {
    self.settings = settings
  }

  /// A snapshot of the current engagement state.
  func currentState() -> RatingEngagementState {
    RatingEngagementState(
      sessionCount: settings.appRatingSessionCount,
      booksCompleted: settings.appRatingBooksCompleted,
      lastPromptDate: settings.appRatingLastPromptDate,
      promptDisplayCount: settings.appRatingPromptDisplayCount,
      dismissalCount: settings.appRatingDismissalCount,
      optedOut: settings.appRatingOptedOut,
      crashFreeLastSession: settings.appRatingCrashFreeLastSession
    )
  }

  /// Increments the session count and records whether the previous session was
  /// crash-free. Called once each time the app becomes active.
  func recordSession(crashFreeLastSession: Bool) {
    settings.appRatingSessionCount += 1
    settings.appRatingCrashFreeLastSession = crashFreeLastSession
  }

  /// Increments the completed-book count. Called when a book is finished.
  func recordBookCompleted() {
    settings.appRatingBooksCompleted += 1
  }

  /// Records that the sentiment gate was displayed: stamps the date (for the
  /// cooldown) and increments the lifetime display count (for the cap).
  func recordPromptShown(at date: Date) {
    settings.appRatingLastPromptDate = date
    settings.appRatingPromptDisplayCount += 1
  }

  /// Records that the patron dismissed/declined the gate.
  func recordDismissal() {
    settings.appRatingDismissalCount += 1
  }

  /// Records that the patron selected "Don't ask again".
  func recordOptOut() {
    settings.appRatingOptedOut = true
  }
}
