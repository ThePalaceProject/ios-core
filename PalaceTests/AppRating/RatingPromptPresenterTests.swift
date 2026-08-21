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
import PalacePreferences
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
  private func makePresenter(eligible: Bool, delay: UInt64 = 0) -> RatingPromptPresenter {
    let service = AppRatingService(
      tracker: RatingEngagementTracker(settings: settings),
      promptEnabledProvider: { true },
      forceEligibleProvider: { eligible }
    )
    return RatingPromptPresenter(
      service: service,
      reviewRequester: requester,
      feedbackPresenter: feedback,
      triggerDelayNanoseconds: delay,
      isModalPresented: {
        self.modalChecks += 1
        if let n = self.modalClearsAfterCheck, self.modalChecks > n { return false }
        return self.modalIsUp
      }
    )
  }

  /// Drives the "a sheet is on screen" seam for the deferral tests below.
  private var modalIsUp = false

  /// Number of times the presenter has consulted the modal seam. Each entry to
  /// `handleTrigger` past the eligibility gate checks exactly once, so this is
  /// an observable count of deferral hops — the only window the test has into a
  /// budget the presenter keeps private.
  private var modalChecks = 0

  /// When set, the sheet "goes away" once `modalChecks` passes this value. This
  /// sequences the modal clearing against a specific hop deterministically,
  /// rather than racing `Task.yield()` against the re-arm chain.
  private var modalClearsAfterCheck: Int?

  /// Spins until the presenter stops consulting the modal seam, i.e. the
  /// re-arm chain has come to rest.
  private func settle() async {
    var last = -1
    // Bounded: an unbounded re-arm chain must fail the caller's assertion, not
    // hang the suite waiting for a chain that never comes to rest.
    for _ in 0..<40 where last != modalChecks {
      last = modalChecks
      for _ in 0..<20 { await Task.yield() }
    }
  }

  /// Spins the main run loop until `condition` holds or a short budget elapses,
  /// so the `scheduleTrigger` Task (delay 0) has a chance to run.
  private func waitUntil(_ condition: @escaping () -> Bool) async {
    // Yields alone advance no WALL time, so a presenter built with a non-zero
    // trigger delay would never make progress here. Sleep in small increments
    // as well, bounded so a genuinely stuck condition fails the assertion
    // rather than hanging the suite.
    for _ in 0..<200 {
      if condition() { return }
      await Task.yield()
      try? await Task.sleep(nanoseconds: 2_000_000)  // 2ms
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

  // MARK: - F-RATING-01: the gate must not appear underneath a modal

  /// Observed on the 3.3.0 candidate: a borrow succeeds, the borrow-success
  /// half-sheet slides up, and ~2s later the gate is set visible. The gate is a
  /// ZStack overlay INSIDE AppTabHostView, while the sheet presents in a window
  /// ABOVE that hierarchy — so the patron sees the question with its buttons
  /// occluded. Deferring is the fix; dropping would silently lose the prompt.
  func testHandleTrigger_whileModalPresented_doesNotShowGate() {
    let presenter = makePresenter(eligible: true)
    modalIsUp = true

    presenter.handleTrigger(.borrowSucceeded)

    XCTAssertNil(presenter.step,
                 "gate was shown underneath a presented sheet — it renders occluded")
  }

  /// The cooldown/lifetime cap is stamped by `recordPromptShown`. Deferring must
  /// NOT stamp it, or a prompt the patron never saw burns the one chance to ask.
  func testHandleTrigger_whileModalPresented_doesNotStampTheDisplay() {
    let presenter = makePresenter(eligible: true)
    XCTAssertNil(settings.appRatingLastPromptDate, "precondition: nothing stamped yet")
    modalIsUp = true

    presenter.handleTrigger(.borrowSucceeded)

    // Asserted against the PERSISTED stamp, not against `step`. An earlier
    // version of this test checked `step` after a retry and passed with the
    // guard removed — the retry no-ops on `step != nil`, so it was green for
    // the wrong reason. The cooldown/lifetime cap is the thing that must not be
    // spent on a prompt the patron never saw.
    XCTAssertNil(settings.appRatingLastPromptDate,
                 "a deferred prompt stamped the cooldown — the one chance to ask "
                 + "was burned on a gate that was never visible")
  }

  /// The deferral budget is PER TRIGGER. Resetting it only on a successful show
  /// latches it at zero: the first positive moment that exhausts the budget
  /// leaves every later one dropped for the life of the presenter. Caught in
  /// blast-radius review; the three original tests covered none of the
  /// exhaustion cells.
  func testDeferralBudget_isRestoredForEachNewTrigger() async {
    let presenter = makePresenter(eligible: true)
    modalIsUp = true

    // Burn this trigger's entire budget: it re-arms until it gives up, and the
    // sheet never clears, so nothing is ever shown.
    presenter.noteBorrowSucceeded()
    await settle()
    XCTAssertNil(presenter.step, "precondition: the modal never cleared")

    // A LATER positive moment, with the sheet still up. This is the cell that
    // separates a per-trigger budget from a latched one: the new trigger must
    // get its OWN deferrals, so that when the sheet goes away one hop later the
    // gate still appears.
    modalClearsAfterCheck = modalChecks + 1
    presenter.noteBorrowSucceeded()

    await waitUntil { presenter.step != nil }
    XCTAssertEqual(presenter.step, .sentiment,
                   "the later trigger inherited the exhausted budget and was "
                   + "dropped — after one occluded moment the app stops asking, "
                   + "permanently")
  }

  /// The re-arm hop sleeps for the trigger delay before re-entering
  /// `handleTrigger`. A positive moment landing INSIDE that window resets the
  /// budget synchronously; if the sleeping hop then wrote its own decremented
  /// count back over that reset, the new trigger would inherit an exhausted
  /// budget and be dropped. Every other test in this file runs with delay 0,
  /// which closes the window and makes this cell unreachable — so this one
  /// opens it deliberately.
  func testDeferralBudget_newTriggerDuringTheReArmWindow_isNotClobbered() async {
    let presenter = makePresenter(eligible: true, delay: 30_000_000)  // 30ms
    modalIsUp = true

    // Burn the budget down to its last deferral, then leave a hop sleeping.
    presenter.handleTrigger(.borrowSucceeded)
    await waitUntil { self.modalChecks >= 3 }

    // THE PRECONDITION MUST BE ASSERTED, NOT ASSUMED. This test only exercises
    // its cell if a re-arm hop is still SLEEPING when the next trigger arrives,
    // and that window is ~30ms wide. If the poll arrives late the chain has
    // already come to rest, there is no clobber to observe, and the assertion
    // below passes while proving nothing — the test would go green against the
    // live defect. Pinning the exact count makes a lost race RED instead of a
    // silent success.
    XCTAssertEqual(modalChecks, 3,
                   "the re-arm window had already closed (\(modalChecks) hops) — "
                   + "this run did not reach the cell under test")

    // A new positive moment arrives while that hop is still asleep. The sheet
    // must STAY UP across the new trigger's own first check — otherwise it
    // takes the show path, where the budget is never consulted and the clobber
    // is invisible. Clearing two checks later leaves it needing its deferrals.
    modalClearsAfterCheck = modalChecks + 2
    presenter.noteBorrowSucceeded()

    await waitUntil { presenter.step != nil }
    XCTAssertEqual(presenter.step, .sentiment,
                   "a trigger arriving during the re-arm window inherited the "
                   + "old chain's exhausted budget and was dropped")
  }

  func testDeferralBudget_isBounded_whileTheModalStaysUp() async {
    let presenter = makePresenter(eligible: true)
    modalIsUp = true

    presenter.noteBorrowSucceeded()
    await settle()

    XCTAssertNil(presenter.step, "gate shown while a modal is still presented")
    // One initial check plus a bounded number of re-arms. Without the decrement
    // (or the budget guard) this chain re-arms forever, spinning the main actor
    // for as long as the sheet is up.
    // 1 initial check + maxDeferrals re-arms. This pins the budget VALUE, not
    // just that it is bounded — a "reset to 1" mutant survives a bound-only check.
    XCTAssertEqual(modalChecks, 4,
                   "expected 1 + maxDeferrals(3) modal checks, got \(modalChecks)")
  }

  /// Clean path: with nothing presented the gate shows exactly as before. A
  /// guard only ever tested against the violation is untested against false
  /// positives.
  func testHandleTrigger_withNoModal_stillShowsGate() {
    let presenter = makePresenter(eligible: true)
    modalIsUp = false

    presenter.handleTrigger(.borrowSucceeded)

    XCTAssertEqual(presenter.step, .sentiment,
                   "guard suppressed the gate when no modal was up")
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
