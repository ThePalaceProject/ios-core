//
//  RatingPromptPresenterTests.swift
//  PalaceTests
//
//  Routing tests for the sentiment-gate flow (PP-4089/4090/4091): trigger
//  gating, the three sentiment responses, the feedback follow-up, and
//  tap-outside dismissal — all driven through the production seam with spy
//  requester/feedback so each terminal action is asserted.
//

import XCTest
@testable import Palace

@MainActor
final class RatingPromptPresenterTests: XCTestCase {

  private final class SpyReviewRequester: ReviewRequesting {
    private(set) var requestCount = 0
    func requestReview() { requestCount += 1 }
  }

  private final class SpyFeedbackPresenter: FeedbackPresenting {
    private(set) var presentCount = 0
    func presentFeedback() { presentCount += 1 }
  }

  private var suiteName: String!
  private var defaults: UserDefaults!
  private var settings: TPPSettings!
  private var requester: SpyReviewRequester!
  private var feedback: SpyFeedbackPresenter!

  override func setUp() {
    super.setUp()
    suiteName = "RatingPromptPresenterTests-\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)
    settings = TPPSettings(defaults: defaults)
    requester = SpyReviewRequester()
    feedback = SpyFeedbackPresenter()
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suiteName)
    settings = nil; defaults = nil; suiteName = nil
    requester = nil; feedback = nil
    super.tearDown()
  }

  /// Builds a presenter whose service is either forced-eligible or forced-
  /// ineligible, so trigger behavior is deterministic without seeding state.
  /// The trigger delay defaults to 0 so the scheduled gate resolves promptly
  /// in the async combiner tests.
  private func makePresenter(eligible: Bool) -> RatingPromptPresenter {
    let service = AppRatingService(
      tracker: RatingEngagementTracker(settings: settings),
      promptEnabledProvider: { true },
      forceEligibleProvider: { eligible }
    )
    return RatingPromptPresenter(
      service: service,
      reviewRequester: requester,
      feedbackPresenter: feedback,
      triggerDelayNanoseconds: 0
    )
  }

  /// Spins the main run loop until `condition` holds or a short budget elapses,
  /// so the `scheduleTrigger` Task (delay 0) has a chance to run.
  private func waitUntil(_ condition: @escaping () -> Bool) async {
    for _ in 0..<50 {
      if condition() { return }
      await Task.yield()
    }
  }

  // MARK: - Trigger gating

  func testHandleTrigger_whenEligible_showsSentimentAndStampsDisplay() {
    let presenter = makePresenter(eligible: true)
    presenter.handleTrigger(.bookCompleted)
    XCTAssertEqual(presenter.step, .sentiment)
    XCTAssertEqual(settings.appRatingPromptDisplayCount, 1, "showing the gate must stamp the lifetime cap")
    XCTAssertNotNil(settings.appRatingLastPromptDate, "showing the gate must reset the cooldown")
  }

  func testHandleTrigger_whenIneligible_showsNothing() {
    let presenter = makePresenter(eligible: false)
    presenter.handleTrigger(.bookCompleted)
    XCTAssertNil(presenter.step)
    XCTAssertEqual(settings.appRatingPromptDisplayCount, 0)
  }

  func testHandleTrigger_whenAlreadyShowing_doesNotReshowOrRestamp() {
    let presenter = makePresenter(eligible: true)
    presenter.handleTrigger(.bookCompleted)
    presenter.handleTrigger(.borrowSucceeded)
    XCTAssertEqual(presenter.step, .sentiment)
    XCTAssertEqual(settings.appRatingPromptDisplayCount, 1, "a second trigger must not re-stamp while the gate is up")
  }

  // MARK: - Positive-moment combiners (record + scheduled gate)

  func testNoteBookCompleted_recordsCompletionThenSchedulesGate() async {
    let presenter = makePresenter(eligible: true)
    presenter.noteBookCompleted()
    XCTAssertEqual(settings.appRatingBooksCompleted, 1, "completion is recorded synchronously")
    await waitUntil { presenter.step == .sentiment }
    XCTAssertEqual(presenter.step, .sentiment, "the scheduled trigger shows the gate when eligible")
  }

  func testNoteBorrowSucceeded_schedulesGateWithoutRecordingCompletion() async {
    let presenter = makePresenter(eligible: true)
    presenter.noteBorrowSucceeded()
    XCTAssertEqual(settings.appRatingBooksCompleted, 0, "a borrow is not a book completion")
    await waitUntil { presenter.step == .sentiment }
    XCTAssertEqual(presenter.step, .sentiment)
  }

  func testNoteBookCompleted_whenIneligible_recordsButShowsNoGate() async {
    let presenter = makePresenter(eligible: false)
    presenter.noteBookCompleted()
    XCTAssertEqual(settings.appRatingBooksCompleted, 1)
    await waitUntil { presenter.step != nil }
    XCTAssertNil(presenter.step, "ineligible → the scheduled trigger must not show the gate")
  }

  // MARK: - Sentiment responses

  func testRespondPositive_requestsReviewAndDismisses() {
    let presenter = makePresenter(eligible: true)
    presenter.handleTrigger(.bookCompleted)
    presenter.respondPositive()
    XCTAssertEqual(requester.requestCount, 1)
    XCTAssertEqual(feedback.presentCount, 0, "positive path must never open feedback")
    XCTAssertNil(presenter.step)
  }

  func testRespondNegative_recordsDismissalAndShowsFeedbackFollowup() {
    let presenter = makePresenter(eligible: true)
    presenter.handleTrigger(.bookCompleted)
    presenter.respondNegative()
    XCTAssertEqual(presenter.step, .feedbackFollowup)
    XCTAssertEqual(settings.appRatingDismissalCount, 1)
    XCTAssertEqual(requester.requestCount, 0, "negative path must never request App Store review")
  }

  func testRespondAskLater_dismissesWithoutActionOrDismissalCount() {
    let presenter = makePresenter(eligible: true)
    presenter.handleTrigger(.bookCompleted)
    presenter.respondAskLater()
    XCTAssertNil(presenter.step)
    XCTAssertEqual(requester.requestCount, 0)
    XCTAssertEqual(feedback.presentCount, 0)
    XCTAssertEqual(settings.appRatingDismissalCount, 0, "ask-later is not a dismissal-count event")
  }

  // MARK: - Feedback follow-up

  func testConfirmFeedback_presentsFeedbackNotAppStore() {
    let presenter = makePresenter(eligible: true)
    presenter.handleTrigger(.bookCompleted)
    presenter.respondNegative()
    presenter.confirmFeedback()
    XCTAssertEqual(feedback.presentCount, 1)
    XCTAssertEqual(requester.requestCount, 0, "feedback path must never route to the App Store")
    XCTAssertNil(presenter.step)
  }

  func testDeclineFeedback_dismissesWithoutPresenting() {
    let presenter = makePresenter(eligible: true)
    presenter.handleTrigger(.bookCompleted)
    presenter.respondNegative()
    presenter.declineFeedback()
    XCTAssertEqual(feedback.presentCount, 0)
    XCTAssertNil(presenter.step)
  }

  // MARK: - Tap-outside dismissal

  func testDismiss_onSentiment_behavesAsAskLater() {
    let presenter = makePresenter(eligible: true)
    presenter.handleTrigger(.bookCompleted)
    presenter.dismiss()
    XCTAssertNil(presenter.step)
    XCTAssertEqual(settings.appRatingDismissalCount, 0)
  }

  func testDismiss_onFeedbackFollowup_behavesAsDecline() {
    let presenter = makePresenter(eligible: true)
    presenter.handleTrigger(.bookCompleted)
    presenter.respondNegative()   // → feedbackFollowup, dismissalCount now 1
    presenter.dismiss()
    XCTAssertNil(presenter.step)
    XCTAssertEqual(feedback.presentCount, 0, "dismissing the follow-up must not open feedback")
  }

  // MARK: - Response guards (wrong-step calls are no-ops)

  func testRespondPositive_whenNothingShown_isNoOp() {
    let presenter = makePresenter(eligible: true)
    presenter.respondPositive()
    XCTAssertEqual(requester.requestCount, 0)
    XCTAssertNil(presenter.step)
  }

  func testConfirmFeedback_onSentimentStep_isNoOp() {
    let presenter = makePresenter(eligible: true)
    presenter.handleTrigger(.bookCompleted)   // step == .sentiment
    presenter.confirmFeedback()               // wrong step
    XCTAssertEqual(feedback.presentCount, 0)
    XCTAssertEqual(presenter.step, .sentiment, "confirmFeedback on the sentiment step must not change state")
  }
}
