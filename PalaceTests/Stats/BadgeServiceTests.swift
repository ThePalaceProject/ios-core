import XCTest
@testable import Palace

final class BadgeServiceTests: XCTestCase {
  private var statsStore: MockStatsStore!
  private var statsService: ReadingStatsService!
  private var badgeService: BadgeService!

  override func setUp() async throws {
    try await super.setUp()
    statsStore = MockStatsStore()
    statsService = ReadingStatsService(store: statsStore)
    badgeService = BadgeService(statsService: statsService, store: statsStore)
  }

  // MARK: - First Book Finished

  func testFirstBookFinishedBadge() async {
    let completion = BookCompletion(
      bookID: "b1", bookTitle: "Test", format: .epub,
      genres: ["Fiction"], completedDate: Date(), libraryAccount: nil
    )
    await statsService.recordBookCompletion(completion)

    let earned = await badgeService.earnedBadges()
    XCTAssertTrue(earned.contains(where: { $0.id == "first_book_finished" }))
  }

  func testFirstBookNotEarnedWithNoCompletions() async {
    let all = await badgeService.evaluateAllBadges()
    let firstBook = all.first(where: { $0.id == "first_book_finished" })
    XCTAssertNotNil(firstBook)
    XCTAssertFalse(firstBook!.isEarned)
    XCTAssertEqual(firstBook!.progress, 0.0)
  }

  // MARK: - Ten Books Club

  func testTenBooksClubProgress() async {
    for i in 1...6 {
      let completion = BookCompletion(
        bookID: "b\(i)", bookTitle: "Book \(i)", format: .epub,
        genres: ["Fiction"], completedDate: Date(), libraryAccount: nil
      )
      await statsService.recordBookCompletion(completion)
    }

    let all = await badgeService.evaluateAllBadges()
    let tenBooks = all.first(where: { $0.id == "ten_books_club" })
    XCTAssertNotNil(tenBooks)
    XCTAssertEqual(tenBooks!.progress, 0.6, accuracy: 0.01)
    XCTAssertFalse(tenBooks!.isEarned)
  }

  func testTenBooksClubEarned() async {
    for i in 1...10 {
      let completion = BookCompletion(
        bookID: "b\(i)", bookTitle: "Book \(i)", format: .epub,
        genres: ["Fiction"], completedDate: Date(), libraryAccount: nil
      )
      await statsService.recordBookCompletion(completion)
    }

    let earned = await badgeService.earnedBadges()
    XCTAssertTrue(earned.contains(where: { $0.id == "ten_books_club" }))
  }

  // MARK: - Night Owl

  func testNightOwlBadge() async {
    let calendar = Calendar.current
    for i in 0..<5 {
      guard let date = calendar.date(byAdding: .day, value: -i, to: Date()) else { continue }
      var comps = calendar.dateComponents([.year, .month, .day], from: date)
      comps.hour = 1 // 1 AM
      comps.minute = 30
      guard let lateNight = calendar.date(from: comps) else { continue }

      let session = ReadingSession(
        bookID: "b1", bookTitle: "Test", format: .epub,
        startTime: lateNight, endTime: lateNight.addingTimeInterval(1800), pagesRead: 5
      )
      await statsService.recordSession(session)
    }

    let all = await badgeService.evaluateAllBadges()
    let nightOwl = all.first(where: { $0.id == "night_owl" })
    XCTAssertNotNil(nightOwl)
    XCTAssertEqual(nightOwl!.progress, 1.0, accuracy: 0.01)
  }

  // MARK: - Early Bird

  func testEarlyBirdBadge() async {
    let calendar = Calendar.current
    for i in 0..<5 {
      guard let date = calendar.date(byAdding: .day, value: -i, to: Date()) else { continue }
      var comps = calendar.dateComponents([.year, .month, .day], from: date)
      comps.hour = 5 // 5 AM
      comps.minute = 30
      guard let earlyMorning = calendar.date(from: comps) else { continue }

      let session = ReadingSession(
        bookID: "b1", bookTitle: "Test", format: .epub,
        startTime: earlyMorning, endTime: earlyMorning.addingTimeInterval(1800), pagesRead: 5
      )
      await statsService.recordSession(session)
    }

    let all = await badgeService.evaluateAllBadges()
    let earlyBird = all.first(where: { $0.id == "early_bird" })
    XCTAssertNotNil(earlyBird)
    XCTAssertEqual(earlyBird!.progress, 1.0, accuracy: 0.01)
  }

  // MARK: - Marathon Reader

  func testMarathonReaderProgress() async {
    // 1 hour session = 50% progress
    let session = ReadingSession(
      bookID: "b1", bookTitle: "Test", format: .epub,
      startTime: Date(), endTime: Date().addingTimeInterval(3600), pagesRead: 40
    )
    await statsService.recordSession(session)

    let all = await badgeService.evaluateAllBadges()
    let marathon = all.first(where: { $0.id == "marathon_reader" })
    XCTAssertNotNil(marathon)
    XCTAssertEqual(marathon!.progress, 0.5, accuracy: 0.05)
  }

  func testMarathonReaderEarned() async {
    // 2.5 hour session
    let session = ReadingSession(
      bookID: "b1", bookTitle: "Test", format: .epub,
      startTime: Date(), endTime: Date().addingTimeInterval(9000), pagesRead: 100
    )
    await statsService.recordSession(session)

    let earned = await badgeService.earnedBadges()
    XCTAssertTrue(earned.contains(where: { $0.id == "marathon_reader" }))
  }

  // MARK: - Genre Explorer

  func testGenreExplorerProgress() async {
    let genres = ["Fiction", "Science", "History"]
    for (i, genre) in genres.enumerated() {
      let completion = BookCompletion(
        bookID: "b\(i)", bookTitle: "Book \(i)", format: .epub,
        genres: [genre], completedDate: Date(), libraryAccount: nil
      )
      await statsService.recordBookCompletion(completion)
    }

    let all = await badgeService.evaluateAllBadges()
    let explorer = all.first(where: { $0.id == "genre_explorer" })
    XCTAssertNotNil(explorer)
    XCTAssertEqual(explorer!.progress, 0.6, accuracy: 0.01)
  }

  // MARK: - Audiobook Adventurer

  func testAudiobookAdventurerEarned() async {
    for i in 1...5 {
      let completion = BookCompletion(
        bookID: "ab\(i)", bookTitle: "Audio \(i)", format: .audiobook,
        genres: ["Fiction"], completedDate: Date(), libraryAccount: nil
      )
      await statsService.recordBookCompletion(completion)
    }

    let earned = await badgeService.earnedBadges()
    XCTAssertTrue(earned.contains(where: { $0.id == "audiobook_adventurer" }))
  }

  // MARK: - Streak Badges

  func testStreakMasterProgress() async {
    let calendar = Calendar.current
    let today = Date()
    for daysAgo in 0..<4 {
      guard let date = calendar.date(byAdding: .day, value: -daysAgo, to: today) else { continue }
      let session = ReadingSession(
        bookID: "b1", bookTitle: "Test", format: .epub,
        startTime: date, endTime: date.addingTimeInterval(1800), pagesRead: 10
      )
      await statsService.recordSession(session)
    }

    let all = await badgeService.evaluateAllBadges()
    let streakMaster = all.first(where: { $0.id == "streak_master" })
    XCTAssertNotNil(streakMaster)
    // 4/7 days
    XCTAssertGreaterThan(streakMaster!.progress, 0.5)
  }

  // MARK: - Library Explorer

  func testLibraryExplorerProgress() async {
    let libraries = ["lib1", "lib2"]
    for (i, lib) in libraries.enumerated() {
      let session = ReadingSession(
        bookID: "b\(i)", bookTitle: "Test \(i)", format: .epub,
        startTime: Date(), endTime: Date().addingTimeInterval(1800),
        pagesRead: 10, libraryAccount: lib
      )
      await statsService.recordSession(session)
    }

    let all = await badgeService.evaluateAllBadges()
    let explorer = all.first(where: { $0.id == "library_explorer" })
    XCTAssertNotNil(explorer)
    XCTAssertEqual(explorer!.progress, 2.0 / 3.0, accuracy: 0.01)
  }

  // MARK: - Badge Categories

  func testInProgressBadges() async {
    // Record some activity but not enough for any badge
    let session = ReadingSession(
      bookID: "b1", bookTitle: "Test", format: .epub,
      startTime: Date(), endTime: Date().addingTimeInterval(1800), pagesRead: 10
    )
    await statsService.recordSession(session)

    let inProgress = await badgeService.inProgressBadges()
    // Should have some badges showing partial progress
    XCTAssertFalse(inProgress.isEmpty)
    for badge in inProgress {
      XCTAssertGreaterThan(badge.progress, 0)
      XCTAssertLessThan(badge.progress, 1.0)
    }
  }

  func testLockedBadges() async {
    let locked = await badgeService.lockedBadges()
    // With no activity, all badges should be locked
    XCTAssertEqual(locked.count, BadgeCatalog.all.count)
  }

  // MARK: - Badge Notification

  func testBadgeEarnedNotificationFires() async {
    let expectation = expectation(forNotification: .badgeEarned, object: nil)

    let completion = BookCompletion(
      bookID: "b1", bookTitle: "Test", format: .epub,
      genres: ["Fiction"], completedDate: Date(), libraryAccount: nil
    )
    await statsService.recordBookCompletion(completion)
    _ = await badgeService.evaluateAllBadges()

    await fulfillment(of: [expectation], timeout: 2.0)
  }

  // MARK: - All 15 Badges Exist

  func testAllBadgesAreDefined() {
    XCTAssertEqual(BadgeCatalog.all.count, 15)
    let ids = Set(BadgeCatalog.all.map(\.id))
    XCTAssertTrue(ids.contains("first_book_finished"))
    XCTAssertTrue(ids.contains("ten_books_club"))
    XCTAssertTrue(ids.contains("fifty_books_club"))
    XCTAssertTrue(ids.contains("hundred_books_club"))
    XCTAssertTrue(ids.contains("speed_reader"))
    XCTAssertTrue(ids.contains("night_owl"))
    XCTAssertTrue(ids.contains("early_bird"))
    XCTAssertTrue(ids.contains("marathon_reader"))
    XCTAssertTrue(ids.contains("genre_explorer"))
    XCTAssertTrue(ids.contains("audiobook_adventurer"))
    XCTAssertTrue(ids.contains("streak_master"))
    XCTAssertTrue(ids.contains("streak_legend"))
    XCTAssertTrue(ids.contains("streak_immortal"))
    XCTAssertTrue(ids.contains("library_explorer"))
    XCTAssertTrue(ids.contains("weekend_warrior"))
  }
}
