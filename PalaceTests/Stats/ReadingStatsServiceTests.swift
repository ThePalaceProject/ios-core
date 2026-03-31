import XCTest
@testable import Palace

final class ReadingStatsServiceTests: XCTestCase {

  private var store: MockStatsStore!
  private var service: ReadingStatsService!

  override func setUp() async throws {
    try await super.setUp()
    store = MockStatsStore()
    service = ReadingStatsService(store: store)
  }

  // MARK: - Session Recording

  func testRecordSession() async {
    let session = makeSession(bookID: "b1", durationMinutes: 30)
    await service.recordSession(session)

    let sessions = await service.sessions(in: .all)
    XCTAssertEqual(sessions.count, 1)
    XCTAssertEqual(sessions.first?.bookID, "b1")
  }

  func testRecordSessionIgnoresZeroDuration() async {
    let session = ReadingSession(
      bookID: "b1",
      bookTitle: "Test",
      format: .epub,
      startTime: Date(),
      endTime: Date(), // zero duration
      pagesRead: 0
    )
    await service.recordSession(session)

    let sessions = await service.sessions(in: .all)
    XCTAssertTrue(sessions.isEmpty)
  }

  func testRecordMultipleSessions() async {
    for i in 1...5 {
      await service.recordSession(makeSession(bookID: "b\(i)", durationMinutes: 15))
    }
    let sessions = await service.sessions(in: .all)
    XCTAssertEqual(sessions.count, 5)
  }

  // MARK: - Streak

  func testStreakUpdatesOnSession() async {
    await service.recordSession(makeSession(bookID: "b1", durationMinutes: 30))
    let streak = await service.currentStreak()
    XCTAssertEqual(streak.currentStreakDays, 1)
    XCTAssertFalse(streak.activeDates.isEmpty)
  }

  func testStreakRecalculation() async {
    // Manually create sessions on consecutive days
    let calendar = Calendar.current
    let today = Date()
    for daysAgo in 0..<5 {
      guard let date = calendar.date(byAdding: .day, value: -daysAgo, to: today) else { continue }
      let session = ReadingSession(
        bookID: "b1",
        bookTitle: "Test",
        format: .epub,
        startTime: date,
        endTime: date.addingTimeInterval(1800),
        pagesRead: 10
      )
      await service.recordSession(session)
    }

    let streak = await service.recalculateStreak()
    XCTAssertEqual(streak.currentStreakDays, 5)
    XCTAssertGreaterThanOrEqual(streak.longestStreakDays, 5)
  }

  func testStreakResetsAfterGap() async {
    let calendar = Calendar.current
    let today = Date()

    // Session today
    await service.recordSession(makeSession(bookID: "b1", durationMinutes: 30, date: today))

    // Session 3 days ago (gap of 1 day)
    if let threeDaysAgo = calendar.date(byAdding: .day, value: -3, to: today) {
      await service.recordSession(makeSession(bookID: "b2", durationMinutes: 30, date: threeDaysAgo))
    }

    let streak = await service.recalculateStreak()
    // Should only count today's streak (not bridged with 3 days ago)
    XCTAssertEqual(streak.currentStreakDays, 1)
  }

  // MARK: - Aggregate Stats

  func testAggregateStats() async {
    await service.recordSession(makeSession(bookID: "b1", durationMinutes: 30, pages: 20))
    await service.recordSession(makeSession(bookID: "b2", durationMinutes: 45, pages: 30))

    let completion = BookCompletion(
      bookID: "b1", bookTitle: "Test", format: .epub,
      genres: ["Fiction"], completedDate: Date(), libraryAccount: "lib1"
    )
    await service.recordBookCompletion(completion)

    let stats = await service.aggregateStats(for: .all)
    XCTAssertEqual(stats.totalBooksFinished, 1)
    XCTAssertEqual(stats.totalPagesRead, 50)
    XCTAssertEqual(stats.sessionsCount, 2)
    XCTAssertGreaterThan(stats.averageSessionMinutes, 0)
  }

  func testAggregateStatsTimePeriodFilter() async {
    let calendar = Calendar.current
    let today = Date()

    // Recent session
    await service.recordSession(makeSession(bookID: "b1", durationMinutes: 30, date: today))

    // Old session (2 months ago)
    if let twoMonthsAgo = calendar.date(byAdding: .month, value: -2, to: today) {
      await service.recordSession(makeSession(bookID: "b2", durationMinutes: 60, date: twoMonthsAgo))
    }

    let weekStats = await service.aggregateStats(for: .week)
    XCTAssertEqual(weekStats.sessionsCount, 1)

    let allStats = await service.aggregateStats(for: .all)
    XCTAssertEqual(allStats.sessionsCount, 2)
  }

  // MARK: - Book Completion

  func testRecordBookCompletion() async {
    let completion = BookCompletion(
      bookID: "b1", bookTitle: "Test", format: .epub,
      genres: ["Fiction"], completedDate: Date(), libraryAccount: nil
    )
    await service.recordBookCompletion(completion)

    let completions = await service.completions()
    XCTAssertEqual(completions.count, 1)
  }

  func testDuplicateCompletionIgnored() async {
    let completion = BookCompletion(
      bookID: "b1", bookTitle: "Test", format: .epub,
      genres: ["Fiction"], completedDate: Date(), libraryAccount: nil
    )
    await service.recordBookCompletion(completion)
    await service.recordBookCompletion(completion) // duplicate

    let completions = await service.completions()
    XCTAssertEqual(completions.count, 1)
  }

  // MARK: - Chart Data

  func testChartDataWeek() async {
    await service.recordSession(makeSession(bookID: "b1", durationMinutes: 30))
    let data = await service.chartData(for: .week)
    XCTAssertEqual(data.count, 7) // One point per day
    // Today's point should have data
    XCTAssertTrue(data.last?.value ?? 0 > 0)
  }

  func testChartDataEmpty() async {
    let data = await service.chartData(for: .week)
    XCTAssertEqual(data.count, 7)
    XCTAssertTrue(data.allSatisfy { $0.value == 0 })
  }

  // MARK: - Helpers

  private func makeSession(
    bookID: String,
    durationMinutes: Double,
    pages: Int = 10,
    date: Date = Date()
  ) -> ReadingSession {
    ReadingSession(
      bookID: bookID,
      bookTitle: "Test Book",
      format: .epub,
      startTime: date,
      endTime: date.addingTimeInterval(durationMinutes * 60),
      pagesRead: pages
    )
  }
}

// MARK: - Mock Store

final class MockStatsStore: ReadingStatsStoreProtocol, @unchecked Sendable {
  private var sessions: [ReadingSession] = []
  private var streak = ReadingStreak()
  private var completions: [BookCompletion] = []
  private var earnedBadges: [String: Date] = [:]
  private let lock = NSLock()

  func loadSessions() -> [ReadingSession] {
    lock.lock()
    defer { lock.unlock() }
    return sessions
  }

  func saveSessions(_ sessions: [ReadingSession]) {
    lock.lock()
    defer { lock.unlock() }
    self.sessions = sessions
  }

  func loadStreak() -> ReadingStreak {
    lock.lock()
    defer { lock.unlock() }
    return streak
  }

  func saveStreak(_ streak: ReadingStreak) {
    lock.lock()
    defer { lock.unlock() }
    self.streak = streak
  }

  func loadCompletions() -> [BookCompletion] {
    lock.lock()
    defer { lock.unlock() }
    return completions
  }

  func saveCompletions(_ completions: [BookCompletion]) {
    lock.lock()
    defer { lock.unlock() }
    self.completions = completions
  }

  func loadEarnedBadges() -> [String: Date] {
    lock.lock()
    defer { lock.unlock() }
    return earnedBadges
  }

  func saveEarnedBadges(_ badges: [String: Date]) {
    lock.lock()
    defer { lock.unlock() }
    self.earnedBadges = badges
  }

  func clearAll() {
    lock.lock()
    defer { lock.unlock() }
    sessions = []
    streak = ReadingStreak()
    completions = []
    earnedBadges = [:]
  }
}
