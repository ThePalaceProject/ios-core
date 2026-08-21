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
import UIKit

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
  private let isModalPresented: () -> Bool
  private let sleep: @Sendable (UInt64) async -> Void

  /// How many times ONE trigger will re-arm itself while a modal is on screen
  /// before giving up. Bounded so a sheet the patron leaves open forever cannot
  /// leave a task re-arming for the life of the process.
  ///
  /// Reset per trigger, in `scheduleTrigger` — NOT only on a successful show.
  ///
  /// "Per trigger" is approximate, and worth saying so rather than leaving the
  /// stronger reading. This is ONE counter on the instance, so a new positive
  /// moment restores the budget for every re-arm chain currently in flight, not
  /// just its own. The bound therefore holds per-instance and not per-chain:
  /// overlapping triggers can keep chains alive longer than `maxDeferrals`
  /// hops. `testDeferralBudget_newTriggerDuringTheReArmWindow_isNotClobbered`
  /// asserts exactly that multiplication (two chains parked, not one). It never
  /// latches at zero — which was the shipped defect — and it cannot spin
  /// unboundedly while a sheet stays up, because each hop still decrements.
  /// Resetting only on success latches the counter at zero: the first positive
  /// moment that burns all three deferrals leaves every LATER positive moment
  /// dropped immediately, for the life of the presenter, until one happens to
  /// fire with nothing presented. That is a per-instance budget wearing
  /// per-trigger documentation, and it silently stops asking.
  private static let maxDeferrals = 3
  private var deferralsRemaining = maxDeferrals

  /// - Parameter triggerDelayNanoseconds: the "brief delay" before the gate
  ///   appears after a positive moment (PP-4088, ~2s), so it doesn't feel
  ///   jarring. Injected as 0 in tests that drive `handleTrigger` directly.
  /// - Parameter sleep: the delay primitive. Injected because the deferral
  ///   behaviour is defined by the ORDER two sleeping continuations resume in,
  ///   and wall-clock sleeps cannot pin an order: two hops armed microseconds
  ///   apart for the same duration wake in whichever order the scheduler picks.
  ///   A test that races them passes some fraction of the time against a live
  ///   defect, which under `-retry-tests-on-failure` reports the run green.
  ///   Tests inject a controllable clock and resume the hops deliberately.
  /// - Parameter isModalPresented: whether a sheet/alert is currently on screen.
  ///   The gate is a ZStack overlay inside `AppTabHostView`, so anything
  ///   presented modally renders ABOVE it; showing the gate then puts a question
  ///   on screen whose buttons the patron cannot reach. Injected so the
  ///   deferral is unit-testable without a window.
  init(
    service: AppRatingService,
    reviewRequester: ReviewRequesting,
    feedbackPresenter: FeedbackPresenting,
    triggerDelayNanoseconds: UInt64 = 2_000_000_000,
    isModalPresented: @escaping () -> Bool = RatingPromptPresenter.defaultIsModalPresented,
    sleep: @escaping @Sendable (UInt64) async -> Void = RatingPromptPresenter.defaultSleep
  ) {
    self.service = service
    self.reviewRequester = reviewRequester
    self.feedbackPresenter = feedbackPresenter
    self.triggerDelayNanoseconds = triggerDelayNanoseconds
    self.isModalPresented = isModalPresented
    self.sleep = sleep
  }

  static let defaultSleep: @Sendable (UInt64) async -> Void = { nanoseconds in
    guard nanoseconds > 0 else { return }
    try? await Task.sleep(nanoseconds: nanoseconds)
  }

  /// True when the key window's root has anything presented above it.
  static let defaultIsModalPresented: () -> Bool = {
    MainActor.assumeIsolated {
      UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .first(where: { $0.activationState == .foregroundActive })?
        .windows
        .first(where: { $0.isKeyWindow })?
        .rootViewController?
        .presentedViewController != nil
    }
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
    // The reset is the ONLY difference between this and a re-arm hop. Keeping
    // the hop itself in one place means the two can never drift apart on the
    // axis this fix is about.
    deferralsRemaining = Self.maxDeferrals
    armHop(trigger)
  }

  /// Wait the trigger delay, then re-enter `handleTrigger`.
  ///
  /// Deliberately does NOT touch `deferralsRemaining` after waking. The budget
  /// is instance state, and a positive moment arriving during the delay window
  /// performs its own synchronous reset in `scheduleTrigger`; writing this
  /// chain's decremented value back afterwards would clobber that reset and
  /// hand the NEW trigger an old chain's exhausted budget — the same bug this
  /// fix exists to remove, reintroduced for the width of the delay.
  private func armHop(_ trigger: AppRatingTrigger) {
    let delay = triggerDelayNanoseconds
    Task { @MainActor in
      await self.sleep(delay)
      self.handleTrigger(trigger)
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

    // F-RATING-01. The gate is a ZStack overlay inside AppTabHostView; a sheet
    // or alert presents in a window ABOVE that hierarchy. Showing the gate now
    // puts the question on screen with its buttons occluded — observed on the
    // 3.3.0 candidate, where a borrow's success half-sheet covered it.
    //
    // DEFER, do not drop: the patron reached a genuine positive moment and the
    // prompt should still be offered once the sheet goes away. Critically, do
    // NOT call recordPromptShown() here — that stamps the cooldown and the
    // lifetime cap, and burning the one chance to ask on a prompt nobody saw is
    // worse than the occlusion.
    if isModalPresented() {
      guard deferralsRemaining > 0 else { return }
      deferralsRemaining -= 1
      // Re-arm WITHOUT going through scheduleTrigger, or the reset there would
      // restore the budget every hop and the bound would be decorative. armHop
      // deliberately does not touch the budget after waking; see the reasoning
      // there.
      armHop(trigger)
      return
    }

    // NOT reset here. `scheduleTrigger` restores the budget for every positive
    // moment, so resetting again on the way out is a second encoding of the
    // same rule that no test can tell from the first — and two encodings of one
    // invariant is how the original defect survived: the reset lived ONLY here,
    // on the path that showed the gate, so a fully-occluded moment never got it
    // back.
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
