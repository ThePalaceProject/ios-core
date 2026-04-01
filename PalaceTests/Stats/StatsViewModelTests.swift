import XCTest
import Combine
@testable import Palace

@MainActor
final class StatsViewModelTests: XCTestCase {
  private var statsStore: MockStatsStore!
  private var statsService: ReadingStatsService!
  private var badgeService: BadgeService!
  private var viewModel: StatsViewModel!
  private var cancellables = Set<AnyCancellable>()

  override func setUp() async throws {
    try await super.setUp()
    statsStore = MockStatsStore()
    statsService = ReadingStatsService(store: statsStore)
    badgeService = BadgeService(statsService: statsService, store: statsStore)
    viewModel = StatsViewModel(statsService: statsService, badgeService: badgeService)
  }

  override func tearDown() async throws {
    cancellables.removeAll()
    try await super.tearDown()
  }

  // MARK: - Initial State

  func testInitialState() {
    XCTAssertEqual(viewModel.currentStreak.currentStreakDays, 0)
    XCTAssertEqual(viewModel.stats.totalBooksFinished, 0)
    XCTAssertTrue(viewModel.recentBadges.isEmpty)
    XCTAssertEqual(viewModel.selectedTimePeriod, .week)
    XCTAssertTrue(viewModel.chartData.isEmpty)
  }

  // MARK: - Load

  func testLoadPopulatesStats() async {
    // Record a session
    let session = ReadingSession(
      bookID: "b1", bookTitle: "Test", format: .epub,
      startTime: Date(), endTime: Date().addingTimeInterval(1800), pagesRead: 20
    )
    await statsService.recordSession(session)

    await viewModel.load()

    XCTAssertEqual(viewModel.stats.totalPagesRead, 20)
    XCTAssertEqual(viewModel.stats.sessionsCount, 1)
    XCTAssertGreaterThan(viewModel.stats.totalReadingMinutes, 0)
  }

  func testLoadPopulatesStreak() async {
    let session = ReadingSession(
      bookID: "b1", bookTitle: "Test", format: .epub,
      startTime: Date(), endTime: Date().addingTimeInterval(1800), pagesRead: 10
    )
    await statsService.recordSession(session)

    await viewModel.load()

    XCTAssertEqual(viewModel.currentStreak.currentStreakDays, 1)
  }

  func testLoadPopulatesChartData() async {
    let session = ReadingSession(
      bookID: "b1", bookTitle: "Test", format: .epub,
      startTime: Date(), endTime: Date().addingTimeInterval(1800), pagesRead: 10
    )
    await statsService.recordSession(session)

    await viewModel.load()

    XCTAssertFalse(viewModel.chartData.isEmpty)
  }

  // MARK: - Time Period Filtering

  func testTimePeriodChangeUpdatesData() async {
    let calendar = Calendar.current
    let today = Date()

    // Session today
    let recentSession = ReadingSession(
      bookID: "b1", bookTitle: "Test", format: .epub,
      startTime: today, endTime: today.addingTimeInterval(1800), pagesRead: 10
    )
    await statsService.recordSession(recentSession)

    // Session 2 months ago
    if let oldDate = calendar.date(byAdding: .month, value: -2, to: today) {
      let oldSession = ReadingSession(
        bookID: "b2", bookTitle: "Test2", format: .epub,
        startTime: oldDate, endTime: oldDate.addingTimeInterval(3600), pagesRead: 20
      )
      await statsService.recordSession(oldSession)
    }

    // Load with week view
    await viewModel.load()
    let weekPages = viewModel.stats.totalPagesRead

    // Switch to all time
    viewModel.selectedTimePeriod = .all
    // Wait for the sink to fire
    try? await Task.sleep(nanoseconds: 200_000_000)

    XCTAssertGreaterThanOrEqual(viewModel.stats.totalPagesRead, weekPages)
  }

  // MARK: - Display Formatting

  func testStreakDisplayTextNoStreak() {
    XCTAssertEqual(viewModel.streakDisplayText, "Start your streak!")
  }

  func testStreakDisplayTextActive() async {
    let session = ReadingSession(
      bookID: "b1", bookTitle: "Test", format: .epub,
      startTime: Date(), endTime: Date().addingTimeInterval(1800), pagesRead: 10
    )
    await statsService.recordSession(session)
    await viewModel.load()

    XCTAssertEqual(viewModel.streakDisplayText, "1 day")
  }

  func testLongestStreakText() {
    XCTAssertEqual(viewModel.longestStreakText, "Best: 0 days")
  }

  // MARK: - Recent Badges

  func testRecentBadgesAfterCompletion() async {
    let completion = BookCompletion(
      bookID: "b1", bookTitle: "Test", format: .epub,
      genres: ["Fiction"], completedDate: Date(), libraryAccount: nil
    )
    await statsService.recordBookCompletion(completion)
    // Force badge evaluation
    await badgeService.refresh()

    await viewModel.load()

    XCTAssertFalse(viewModel.recentBadges.isEmpty)
    XCTAssertTrue(viewModel.recentBadges.contains(where: { $0.id == "first_book_finished" }))
  }

  func testRecentBadgesLimitedToFive() async {
    // Complete 10 books + audiobooks to earn multiple badges
    for i in 1...10 {
      let completion = BookCompletion(
        bookID: "b\(i)", bookTitle: "Book \(i)", format: .epub,
        genres: ["Fiction", "Science", "History", "Art", "Music"].prefix(min(i, 5)).map { String($0) },
        completedDate: Date(), libraryAccount: "lib\(i % 4)"
      )
      await statsService.recordBookCompletion(completion)
    }
    await badgeService.refresh()

    await viewModel.load()

    XCTAssertLessThanOrEqual(viewModel.recentBadges.count, 5)
  }
}
