import XCTest
@testable import Palace

final class ReadingStatsStoreTests: XCTestCase {
  private var store: ReadingStatsStore!
  private var defaults: UserDefaults!

  override func setUp() {
    super.setUp()
    defaults = UserDefaults(suiteName: "ReadingStatsStoreTests")!
    defaults.removePersistentDomain(forName: "ReadingStatsStoreTests")
    store = ReadingStatsStore(defaults: defaults)
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: "ReadingStatsStoreTests")
    store = nil
    defaults = nil
    super.tearDown()
  }

  // MARK: - Sessions

  func testSaveAndLoadSessions() {
    let session = makeSession(bookID: "book1", duration: 600)
    store.saveSessions([session])

    let loaded = store.loadSessions()
    XCTAssertEqual(loaded.count, 1)
    XCTAssertEqual(loaded.first?.bookID, "book1")
  }

  func testLoadSessionsEmpty() {
    let sessions = store.loadSessions()
    XCTAssertTrue(sessions.isEmpty)
  }

  func testMultipleSessions() {
    let sessions = [
      makeSession(bookID: "book1", duration: 300),
      makeSession(bookID: "book2", duration: 600),
      makeSession(bookID: "book3", duration: 900),
    ]
    store.saveSessions(sessions)
    let loaded = store.loadSessions()
    XCTAssertEqual(loaded.count, 3)
  }

  // MARK: - Streak

  func testSaveAndLoadStreak() {
    var streak = ReadingStreak()
    streak.currentStreakDays = 5
    streak.longestStreakDays = 12
    streak.activeDates = ["2026-03-20", "2026-03-21"]
    store.saveStreak(streak)

    let loaded = store.loadStreak()
    XCTAssertEqual(loaded.currentStreakDays, 5)
    XCTAssertEqual(loaded.longestStreakDays, 12)
    XCTAssertEqual(loaded.activeDates.count, 2)
  }

  func testLoadStreakDefault() {
    let streak = store.loadStreak()
    XCTAssertEqual(streak.currentStreakDays, 0)
  }

  // MARK: - Completions

  func testSaveAndLoadCompletions() {
    let completion = BookCompletion(
      bookID: "book1",
      bookTitle: "Test Book",
      format: .epub,
      genres: ["Fiction"],
      completedDate: Date(),
      libraryAccount: "lib1"
    )
    store.saveCompletions([completion])

    let loaded = store.loadCompletions()
    XCTAssertEqual(loaded.count, 1)
    XCTAssertEqual(loaded.first?.bookTitle, "Test Book")
  }

  // MARK: - Earned Badges

  func testSaveAndLoadEarnedBadges() {
    let now = Date()
    store.saveEarnedBadges(["first_book": now, "ten_books": now])

    let loaded = store.loadEarnedBadges()
    XCTAssertEqual(loaded.count, 2)
    XCTAssertNotNil(loaded["first_book"])
  }

  // MARK: - Clear

  func testClearAll() {
    store.saveSessions([makeSession(bookID: "book1", duration: 300)])
    store.saveEarnedBadges(["test": Date()])
    store.clearAll()

    XCTAssertTrue(store.loadSessions().isEmpty)
    XCTAssertTrue(store.loadEarnedBadges().isEmpty)
    XCTAssertEqual(store.loadStreak().currentStreakDays, 0)
    XCTAssertTrue(store.loadCompletions().isEmpty)
  }

  // MARK: - Migration

  func testMigrationSetsVersion() {
    // A new store should set version 1
    _ = ReadingStatsStore(defaults: defaults)
    let version = defaults.integer(forKey: "palace.stats.schemaVersion")
    XCTAssertEqual(version, 1)
  }

  // MARK: - Helpers

  private func makeSession(bookID: String, duration: TimeInterval) -> ReadingSession {
    let start = Date()
    return ReadingSession(
      bookID: bookID,
      bookTitle: "Test",
      format: .epub,
      startTime: start,
      endTime: start.addingTimeInterval(duration),
      pagesRead: 10
    )
  }
}
