//
//  RatingPromptPresenter.swift
//  Palace
//
//  Drives the sentiment-gate overlay (PP-4089) and routes the patron's
//  response to the native review request (PP-4090) or the feedback path
//  (PP-4091). Owns the published UI state; delegates recording/eligibility to
//  AppRatingService and the terminal actions to injected protocols so the
//  routing is fully unit-testable.
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
import Combine

/// Which step of the rating flow is currently on screen. `nil` = nothing shown.
enum RatingPromptStep: Equatable {
  /// "Are you enjoying The Palace Project?" — Yes / Not really / Ask me later.
  case sentiment
  /// "We're sorry to hear that. Would you like to share feedback?" follow-up.
  case feedbackFollowup
}

@MainActor
final class RatingPromptPresenter: ObservableObject {

  /// The overlay observes this; setting it non-nil shows the gate, nil hides it.
  @Published private(set) var step: RatingPromptStep?

  private let service: AppRatingService
  private let reviewRequester: ReviewRequesting
  private let feedbackPresenter: FeedbackPresenting
  private let triggerDelayNanoseconds: UInt64

  /// - Parameter triggerDelayNanoseconds: the "brief delay" before the gate
  ///   appears after a positive moment (PP-4088, ~2s), so it doesn't feel
  ///   jarring. Injected as 0 in tests that drive `handleTrigger` directly.
  init(
    service: AppRatingService,
    reviewRequester: ReviewRequesting,
    feedbackPresenter: FeedbackPresenting,
    triggerDelayNanoseconds: UInt64 = 2_000_000_000
  ) {
    self.service = service
    self.reviewRequester = reviewRequester
    self.feedbackPresenter = feedbackPresenter
    self.triggerDelayNanoseconds = triggerDelayNanoseconds
  }

  // MARK: - Positive-moment entry points

  /// A book was finished. Counts the completion (an eligibility input) then
  /// schedules the sentiment gate after the brief delay.
  func noteBookCompleted() {
    service.recordBookCompleted()
    scheduleTrigger(.bookCompleted)
  }

  /// A borrow succeeded. Schedules the sentiment gate after the brief delay.
  func noteBorrowSucceeded() {
    scheduleTrigger(.borrowSucceeded)
  }

  private func scheduleTrigger(_ trigger: AppRatingTrigger) {
    Task { @MainActor in
      if triggerDelayNanoseconds > 0 {
        try? await Task.sleep(nanoseconds: triggerDelayNanoseconds)
      }
      handleTrigger(trigger)
    }
  }

  // MARK: - Trigger

  /// Shows the sentiment gate only when the patron is eligible, and records the
  /// display (stamping the cooldown + lifetime cap) as it appears. A gate
  /// already on screen is never replaced. The testable seam driven directly by
  /// unit tests.
  func handleTrigger(_ trigger: AppRatingTrigger) {
    guard step == nil else { return }
    guard service.isEligible(for: trigger) else { return }
    service.recordPromptShown()
    step = .sentiment
  }

  // MARK: - Sentiment responses

  /// "Yes, I love it!" — request the native App Store prompt and dismiss.
  func respondPositive() {
    guard step == .sentiment else { return }
    reviewRequester.requestReview()
    step = nil
  }

  /// "Not really" — record the dissatisfaction and offer the feedback path.
  func respondNegative() {
    guard step == .sentiment else { return }
    service.recordDismissal()
    step = .feedbackFollowup
  }

  /// "Ask me later" (or an outside/back dismissal of the sentiment step). The
  /// cooldown was already reset when the gate was shown, so this just hides it.
  func respondAskLater() {
    guard step == .sentiment else { return }
    step = nil
  }

  // MARK: - Feedback follow-up responses

  /// The patron opted to share feedback — open the feedback path (never the
  /// App Store) and dismiss.
  func confirmFeedback() {
    guard step == .feedbackFollowup else { return }
    feedbackPresenter.presentFeedback()
    step = nil
  }

  /// The patron declined to share feedback — just dismiss.
  func declineFeedback() {
    guard step == .feedbackFollowup else { return }
    step = nil
  }

  // MARK: - Dismissal

  /// A tap-outside / back gesture. Treated as "Ask me later" on the sentiment
  /// step and as "decline" on the follow-up step.
  func dismiss() {
    switch step {
    case .sentiment: respondAskLater()
    case .feedbackFollowup: declineFeedback()
    case nil: break
    }
  }
}
