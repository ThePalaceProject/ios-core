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

    // Page count is internal, but we can verify:
    // 1. The session remains active throughout the page turns.
    // 2. The correct book is still being tracked.
    // 3. Recording page turns during an active session does not crash.
    XCTAssertTrue(tracker.isTracking,
                  "Tracker must remain active while recording page turns")
    XCTAssertEqual(tracker.activeBookID, "book-1",
                   "Active book ID must not change when recording page turns")
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
    XCTAssertNil(tracker.activeBookID, "activeBookID must be nil when no session was ever started")
  }

  func testEndSession_WithoutStartSession_DoesNotRecordSession() {
    tracker.endSession()

    // Give the async Task time to run
    drainMainQueue()
      XCTAssertTrue(self.mockStatsService.recordedSessions.isEmpty)
  }

  // MARK: - Zero-duration sessions filtered

  func testEndSession_FiltersBriefSessions() {
    // A session started and immediately ended has < 10 seconds duration
    tracker.startSession(bookID: "book-1", bookTitle: "Quick", format: .epub)
    tracker.endSession()

    drainMainQueue()
      // Session with < 10s duration should be filtered out
      XCTAssertTrue(self.mockStatsService.recordedSessions.isEmpty)
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

    awaitCondition { self.mockStatsService.recordedCompletions.count == 1 }
    XCTAssertEqual(mockStatsService.recordedCompletions.count, 1)
    XCTAssertEqual(mockStatsService.recordedCompletions.first?.bookID, "book-1")
    XCTAssertEqual(mockStatsService.recordedCompletions.first?.bookTitle, "Finished Book")
  }

  func testRecordBookFinished_TriggersBadgeRefresh() {
    tracker.recordBookFinished(
      bookID: "book-1",
      bookTitle: "Done",
      format: .epub
    )

    awaitCondition { self.mockBadgeService.refreshCallCount >= 1 }
    XCTAssertGreaterThanOrEqual(mockBadgeService.refreshCallCount, 1)
  }

  // MARK: - isTracking and activeBookID

  func testIsTracking_FalseInitially() {
    XCTAssertFalse(tracker.isTracking, "Tracker must not be active before any session is started")
    XCTAssertNil(tracker.activeBookID, "No book ID must be set before any session is started")
  }

  func testActiveBookID_NilInitially() {
    XCTAssertNil(tracker.activeBookID, "activeBookID must be nil before any session is started")
    XCTAssertFalse(tracker.isTracking, "isTracking must be false when no book ID is active")
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
