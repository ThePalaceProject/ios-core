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
    clock = TestClock()
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suiteName)
    settings = nil; defaults = nil; suiteName = nil
    clock?.drain()
    requester = nil; feedback = nil; clock = nil
    super.tearDown()
  }

  /// Builds a presenter whose service is either forced-eligible or forced-
  /// ineligible, so trigger behavior is deterministic without seeding state.
  /// The trigger delay defaults to 0 so the scheduled gate resolves promptly
  /// in the async combiner tests.
  private func makePresenter(eligible: Bool, delay: UInt64 = 0,
                             drivenClock: Bool = false) -> RatingPromptPresenter {
    let service = AppRatingService(
      tracker: RatingEngagementTracker(settings: settings),
      promptEnabledProvider: { true },
      forceEligibleProvider: { eligible }
    )
    let sleeper: @Sendable (UInt64) async -> Void
    if drivenClock {
      let c = clock!
      sleeper = { ns in await c.sleep(ns) }
    } else {
      sleeper = RatingPromptPresenter.defaultSleep
    }
    return RatingPromptPresenter(
      service: service,
      reviewRequester: requester,
      feedbackPresenter: feedback,
      triggerDelayNanoseconds: delay,
      isModalPresented: {
        self.modalChecks += 1
        if let n = self.modalClearsAfterCheck, self.modalChecks > n { return false }
        return self.modalIsUp
      },
      sleep: sleeper
    )
  }

  /// A clock the TEST drives.
  ///
  /// The deferral behaviour is defined by the order two sleeping hops resume
  /// in, and wall-clock sleeps cannot pin that: hops armed microseconds apart
  /// for the same duration wake in whichever order the scheduler picks. A
  /// reviewer measured the previous wall-clock version passing 2 of 12 runs
  /// against the live defect — which, under `-retry-tests-on-failure`, reports
  /// a run green roughly 40% of the time with the bug present. Every sleeper
  /// now parks here until the test resumes it by name.
  @MainActor
  private final class TestClock {
    private var parked: [CheckedContinuation<Void, Never>] = []
    /// Sleepers currently waiting, in the order they arrived.
    var waiting: Int { parked.count }

    func sleep(_ nanoseconds: UInt64) async {
      await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
        parked.append(c)
      }
    }

    /// Resume the sleeper that has been waiting LONGEST (FIFO).
    func resumeOldest() {
      guard !parked.isEmpty else { return }
      parked.removeFirst().resume()
    }

    /// Resume the sleeper that arrived MOST RECENTLY (LIFO) — this is the wake
    /// order that hides the clobber, and it must be drivable on purpose.
    func resumeNewest() {
      guard !parked.isEmpty else { return }
      parked.removeLast().resume()
    }

    /// Resume everything still parked. A `CheckedContinuation` that is never
    /// resumed leaks its task, and the clobber test parks several per
    /// iteration; draining in tearDown keeps a test that deliberately leaves
    /// hops asleep from accumulating them across the suite.
    func drain() {
      while !parked.isEmpty { parked.removeFirst().resume() }
    }
  }

  private var clock: TestClock!

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
    // And assert the budget was actually SPENT. Without this the test can pass
    // having never exhausted anything, which makes the "restored" claim below
    // vacuous — it would be asserting a fresh budget behaves like a fresh one.
    XCTAssertEqual(modalChecks, 4,
                   "precondition: expected 1 + maxDeferrals(3) checks before the "
                   + "budget ran out, got \(modalChecks)")

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
  /// A positive moment arriving while a re-arm hop is still asleep must not
  /// inherit that hop's exhausted budget.
  ///
  /// THE MODAL STAYS UP THROUGH BOTH WAKEUPS. That is the whole point: on the
  /// show path the budget is never consulted, so clearing the sheet first makes
  /// the clobber invisible and the test vacuous. It must be the BUDGET that
  /// decides whether the new trigger survives, which means the sheet is still
  /// there when it wakes.
  ///
  /// Both wake orders are driven deliberately. When the stale hop wakes first
  /// it writes its exhausted count over the new trigger's reset; when it wakes
  /// second the clobber lands on a chain that is already gone. The wall-clock
  /// version of this test only ever hit one of those by luck — a reviewer
  /// measured it passing 2 of 12 runs against the live defect.
  func testDeferralBudget_newTriggerDuringTheReArmWindow_isNotClobbered() async {
    for staleHopWakesFirst in [true, false] {
      clock = TestClock()
      modalChecks = 0
      modalClearsAfterCheck = nil
      modalIsUp = true
      let presenter = makePresenter(eligible: true, delay: 1, drivenClock: true)

      // Burn this trigger's budget down to its last deferral, leaving one hop
      // parked with a stale count of 0.
      presenter.handleTrigger(.borrowSucceeded)
      await waitUntil { self.clock.waiting > 0 }
      for _ in 0..<2 {
        clock.resumeOldest()
        await waitUntil { self.clock.waiting > 0 }
      }
      XCTAssertEqual(modalChecks, 3, "precondition: 3 modal checks, got \(modalChecks)")
      XCTAssertEqual(clock.waiting, 1, "precondition: one stale hop parked")

      // A new positive moment lands while that hop is still parked: it resets
      // the budget synchronously and parks a hop of its own.
      presenter.noteBorrowSucceeded()
      await waitUntil { self.clock.waiting == 2 }

      // Wake both, sheet STILL UP. The new trigger must defer — which it can
      // only do out of a budget the stale hop did not overwrite.
      if staleHopWakesFirst {
        clock.resumeOldest(); await waitUntil { self.clock.waiting <= 1 }
        clock.resumeOldest()
      } else {
        clock.resumeNewest(); await waitUntil { self.clock.waiting <= 1 }
        clock.resumeOldest()
      }
      await waitUntil { self.clock.waiting > 0 }

      XCTAssertNil(presenter.step, "nothing may be shown while the sheet is up")
      // BOTH chains re-arm: the stale hop also wakes into the budget the new
      // trigger restored, so it defers rather than dying. Under the clobber
      // both read 0 instead and neither re-arms, so this count is 0 — the two
      // are coupled, and the distinction is 2 vs 0, not 2 vs 1.
      XCTAssertEqual(clock.waiting, 2,
                     "staleHopWakesFirst=\(staleHopWakesFirst): expected both "
                     + "chains to defer out of the restored budget; the stale "
                     + "hop's exhausted count was written over that reset and "
                     + "both triggers were dropped")

      // And once the sheet goes, that surviving chain shows the gate.
      modalIsUp = false
      clock.resumeOldest()
      await waitUntil { presenter.step != nil }
      XCTAssertEqual(presenter.step, .sentiment,
                     "staleHopWakesFirst=\(staleHopWakesFirst): the surviving "
                     + "chain never presented the gate")
    }
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
    // Wait for SOMETHING to be presented, then assert it is the right thing.
    // Waiting on `== .sentiment` and then asserting `== .sentiment` cannot
    // distinguish "showed the wrong step" from "showed nothing" — both leave the
    // wait to time out silently and the assertion to report the same nil.
    await waitUntil { presenter.step != nil }
    XCTAssertEqual(presenter.step, .sentiment, "the scheduled trigger shows the gate when eligible")
  }

  func testNoteBorrowSucceeded_schedulesGateWithoutRecordingCompletion() async {
    let presenter = makePresenter(eligible: true)
    presenter.noteBorrowSucceeded()
    XCTAssertEqual(settings.appRatingBooksCompleted, 0, "a borrow is not a book completion")
    await waitUntil { presenter.step != nil }
    XCTAssertEqual(presenter.step, .sentiment,
                   "a borrow should schedule the sentiment gate, not another step")
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
