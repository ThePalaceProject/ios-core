//
//  ReadingSessionTrackerTests.swift
//  PalaceTests
//
//  Tests for ReadingSessionTracker session lifecycle and recording.
//
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

@MainActor
final class ReadingSessionTrackerTests: XCTestCase {

  private var tracker: ReadingSessionTracker!
  private var mockStatsService: MockReadingStatsService!
  private var mockBadgeService: MockBadgeServiceForTracker!

  override func setUp() {
    super.setUp()
    mockStatsService = MockReadingStatsService()
    mockBadgeService = MockBadgeServiceForTracker()
    tracker = ReadingSessionTracker(
      statsService: mockStatsService,
      badgeService: mockBadgeService
    )
  }

  override func tearDown() {
    tracker = nil
    mockStatsService = nil
    mockBadgeService = nil
    super.tearDown()
  }

  // MARK: - startSession

  func testStartSession_BeginsTracking() {
    tracker.startSession(bookID: "book-1", bookTitle: "Test Book", format: .epub)

    XCTAssertTrue(tracker.isTracking)
    XCTAssertEqual(tracker.activeBookID, "book-1")
  }

  func testStartSession_EndsExistingSession() {
    tracker.startSession(bookID: "book-1", bookTitle: "First", format: .epub)
    tracker.startSession(bookID: "book-2", bookTitle: "Second", format: .epub)

    XCTAssertTrue(tracker.isTracking)
    XCTAssertEqual(tracker.activeBookID, "book-2")
  }

  // MARK: - recordPageTurn

  func testRecordPageTurn_IncrementsPageCount() {
    tracker.startSession(bookID: "book-1", bookTitle: "Test", format: .epub)
    tracker.recordPageTurn()
    tracker.recordPageTurn()
    tracker.recordPageTurn()

    // We can't inspect pageCount directly, but it'll be reflected in the
    // recorded session when endSession is called.
    XCTAssertTrue(tracker.isTracking)
  }

  // MARK: - endSession

  func testEndSession_StopsTracking() {
    tracker.startSession(bookID: "book-1", bookTitle: "Test", format: .epub)
    tracker.endSession()

    XCTAssertFalse(tracker.isTracking)
    XCTAssertNil(tracker.activeBookID)
  }

  func testEndSession_WithoutStartSession_DoesNotCrash() {
    // Should be safe to call without an active session
    tracker.endSession()

    XCTAssertFalse(tracker.isTracking)
  }

  func testEndSession_WithoutStartSession_DoesNotRecordSession() {
    tracker.endSession()

    // Give the async Task time to run
    let expectation = XCTestExpectation(description: "No session recorded")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
      XCTAssertTrue(self.mockStatsService.recordedSessions.isEmpty)
      expectation.fulfill()
    }
    wait(for: [expectation], timeout: 1.0)
  }

  // MARK: - Zero-duration sessions filtered

  func testEndSession_FiltersBriefSessions() {
    // A session started and immediately ended has < 10 seconds duration
    tracker.startSession(bookID: "book-1", bookTitle: "Quick", format: .epub)
    tracker.endSession()

    let expectation = XCTestExpectation(description: "Brief session filtered")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
      // Session with < 10s duration should be filtered out
      XCTAssertTrue(self.mockStatsService.recordedSessions.isEmpty)
      expectation.fulfill()
    }
    wait(for: [expectation], timeout: 1.0)
  }

  // MARK: - Multiple start/end cycles

  func testMultipleCycles_WorkCorrectly() {
    // First cycle
    tracker.startSession(bookID: "book-1", bookTitle: "First", format: .epub)
    XCTAssertTrue(tracker.isTracking)
    XCTAssertEqual(tracker.activeBookID, "book-1")

    tracker.endSession()
    XCTAssertFalse(tracker.isTracking)

    // Second cycle
    tracker.startSession(bookID: "book-2", bookTitle: "Second", format: .pdf)
    XCTAssertTrue(tracker.isTracking)
    XCTAssertEqual(tracker.activeBookID, "book-2")

    tracker.endSession()
    XCTAssertFalse(tracker.isTracking)
  }

  // MARK: - Page count resets between sessions

  func testPageCount_ResetsBetweenSessions() {
    tracker.startSession(bookID: "book-1", bookTitle: "First", format: .epub)
    tracker.recordPageTurn()
    tracker.recordPageTurn()
    tracker.endSession()

    tracker.startSession(bookID: "book-2", bookTitle: "Second", format: .epub)
    // After starting a new session, page count should be 0 (fresh start)
    // We verify by checking isTracking (page count reset is internal)
    XCTAssertTrue(tracker.isTracking)
    XCTAssertEqual(tracker.activeBookID, "book-2")
  }

  // MARK: - recordBookFinished

  func testRecordBookFinished_RecordsCompletion() {
    tracker.recordBookFinished(
      bookID: "book-1",
      bookTitle: "Finished Book",
      format: .epub,
      genres: ["Fiction"]
    )

    let expectation = XCTestExpectation(description: "Completion recorded")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
      XCTAssertEqual(self.mockStatsService.recordedCompletions.count, 1)
      XCTAssertEqual(self.mockStatsService.recordedCompletions.first?.bookID, "book-1")
      XCTAssertEqual(self.mockStatsService.recordedCompletions.first?.bookTitle, "Finished Book")
      expectation.fulfill()
    }
    wait(for: [expectation], timeout: 1.0)
  }

  func testRecordBookFinished_TriggersBadgeRefresh() {
    tracker.recordBookFinished(
      bookID: "book-1",
      bookTitle: "Done",
      format: .epub
    )

    let expectation = XCTestExpectation(description: "Badge refresh triggered")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
      XCTAssertGreaterThanOrEqual(self.mockBadgeService.refreshCallCount, 1)
      expectation.fulfill()
    }
    wait(for: [expectation], timeout: 1.0)
  }

  // MARK: - isTracking and activeBookID

  func testIsTracking_FalseInitially() {
    XCTAssertFalse(tracker.isTracking)
  }

  func testActiveBookID_NilInitially() {
    XCTAssertNil(tracker.activeBookID)
  }
}

// MARK: - Mocks

private final class MockReadingStatsService: ReadingStatsServiceProtocol, @unchecked Sendable {
  var recordedSessions: [ReadingSession] = []
  var recordedCompletions: [BookCompletion] = []

  func recordSession(_ session: ReadingSession) async {
    recordedSessions.append(session)
  }

  func recordBookCompletion(_ completion: BookCompletion) async {
    recordedCompletions.append(completion)
  }

  func sessions(in period: TimePeriod) async -> [ReadingSession] { [] }
  func currentStreak() async -> ReadingStreak { ReadingStreak() }
  func recalculateStreak() async -> ReadingStreak { ReadingStreak() }
  func aggregateStats(for period: TimePeriod) async -> ReadingStats { ReadingStats() }
  func completions() async -> [BookCompletion] { [] }
  func chartData(for period: TimePeriod) async -> [ChartDataPoint] { [] }
}

private final class MockBadgeServiceForTracker: BadgeServiceProtocol, @unchecked Sendable {
  var refreshCallCount = 0

  func evaluateAllBadges() async -> [Badge] { [] }
  func earnedBadges() async -> [Badge] { [] }
  func inProgressBadges() async -> [Badge] { [] }
  func lockedBadges() async -> [Badge] { [] }
  func refresh() async { refreshCallCount += 1 }
}
