//
//  RatingEngagementTrackerTests.swift
//  PalaceTests
//
//  Tests for the app-rating engagement tracker (PP-4087): increment/read
//  behavior and app-update-surviving persistence through TPPSettings.
//

import XCTest
@testable import Palace

final class RatingEngagementTrackerTests: XCTestCase {

  private var suiteName: String!
  private var defaults: UserDefaults!
  private var settings: TPPSettings!
  private var tracker: RatingEngagementTracker!

  override func setUp() {
    super.setUp()
    suiteName = "RatingEngagementTrackerTests-\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)
    settings = TPPSettings(defaults: defaults)
    tracker = RatingEngagementTracker(settings: settings)
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suiteName)
    tracker = nil
    settings = nil
    defaults = nil
    suiteName = nil
    super.tearDown()
  }

  // MARK: - Fresh state

  func testCurrentState_freshInstall_hasZeroCountsAndIsFirstSession() {
    let state = tracker.currentState()
    XCTAssertEqual(state.sessionCount, 0)
    XCTAssertEqual(state.booksCompleted, 0)
    XCTAssertNil(state.lastPromptDate)
    XCTAssertEqual(state.promptDisplayCount, 0)
    XCTAssertEqual(state.dismissalCount, 0)
    XCTAssertFalse(state.optedOut)
    XCTAssertTrue(state.crashFreeLastSession, "absent crash signal should default to crash-free")
    XCTAssertTrue(state.isFirstSession)
  }

  // MARK: - Sessions

  func testRecordSession_incrementsSessionCountAndStoresCrashSignal() {
    tracker.recordSession(crashFreeLastSession: false)
    let state = tracker.currentState()
    XCTAssertEqual(state.sessionCount, 1)
    XCTAssertFalse(state.crashFreeLastSession)
  }

  func testRecordSession_calledTwice_accumulatesAndIsNoLongerFirstSession() {
    tracker.recordSession(crashFreeLastSession: true)
    tracker.recordSession(crashFreeLastSession: true)
    let state = tracker.currentState()
    XCTAssertEqual(state.sessionCount, 2)
    XCTAssertFalse(state.isFirstSession)
  }

  func testRecordSession_updatesCrashSignalEachSession() {
    tracker.recordSession(crashFreeLastSession: false)
    XCTAssertFalse(tracker.currentState().crashFreeLastSession)
    tracker.recordSession(crashFreeLastSession: true)
    XCTAssertTrue(tracker.currentState().crashFreeLastSession)
  }

  // MARK: - Books

  func testRecordBookCompleted_incrementsCount() {
    tracker.recordBookCompleted()
    tracker.recordBookCompleted()
    XCTAssertEqual(tracker.currentState().booksCompleted, 2)
  }

  // MARK: - Prompt shown

  func testRecordPromptShown_stampsDateAndIncrementsDisplayCount() {
    let shownAt = Date(timeIntervalSince1970: 1_234_567_890)
    tracker.recordPromptShown(at: shownAt)
    let state = tracker.currentState()
    XCTAssertEqual(state.lastPromptDate, shownAt)
    XCTAssertEqual(state.promptDisplayCount, 1)

    let laterShownAt = shownAt.addingTimeInterval(100 * 86_400)
    tracker.recordPromptShown(at: laterShownAt)
    let state2 = tracker.currentState()
    XCTAssertEqual(state2.lastPromptDate, laterShownAt, "most recent display date should win")
    XCTAssertEqual(state2.promptDisplayCount, 2)
  }

  // MARK: - Dismissal / opt out

  func testRecordDismissal_incrementsDismissalCount() {
    tracker.recordDismissal()
    XCTAssertEqual(tracker.currentState().dismissalCount, 1)
  }

  func testRecordOptOut_setsOptedOut() {
    XCTAssertFalse(tracker.currentState().optedOut)
    tracker.recordOptOut()
    XCTAssertTrue(tracker.currentState().optedOut)
  }

  // MARK: - Persistence across "app update"

  func testState_survivesAppUpdate_viaPersistentDefaults() {
    tracker.recordSession(crashFreeLastSession: true)
    tracker.recordSession(crashFreeLastSession: true)
    tracker.recordBookCompleted()
    tracker.recordPromptShown(at: Date(timeIntervalSince1970: 42))

    // Simulate an app relaunch/update: a brand-new settings+tracker reading the
    // same persistent UserDefaults must see the previously recorded values.
    let reloadedSettings = TPPSettings(defaults: UserDefaults(suiteName: suiteName)!)
    let reloadedTracker = RatingEngagementTracker(settings: reloadedSettings)
    let state = reloadedTracker.currentState()

    XCTAssertEqual(state.sessionCount, 2, "session count must NOT reset across an app update")
    XCTAssertEqual(state.booksCompleted, 1)
    XCTAssertEqual(state.promptDisplayCount, 1)
    XCTAssertEqual(state.lastPromptDate, Date(timeIntervalSince1970: 42))
  }
}
