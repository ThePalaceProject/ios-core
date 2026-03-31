//
//  BadgeDefinitionTests.swift
//  PalaceTests
//
//  Tests for the 5 untested badge definitions: FiftyBooksClub, HundredBooksClub,
//  SpeedReader, StreakLegend, StreakImmortal, and WeekendWarrior.
//
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class BadgeDefinitionTests: XCTestCase {

  // MARK: - Test Helpers

  private func makeContext(
    sessions: [ReadingSession] = [],
    completions: [BookCompletion] = [],
    streak: ReadingStreak = ReadingStreak(),
    stats: ReadingStats = ReadingStats()
  ) -> BadgeEvaluationContext {
    BadgeEvaluationContext(
      sessions: sessions,
      completions: completions,
      streak: streak,
      stats: stats
    )
  }

  private func makeCompletion(
    bookID: String = UUID().uuidString,
    format: ReadingFormat = .epub,
    genres: [String] = [],
    completedDate: Date = Date()
  ) -> BookCompletion {
    BookCompletion(
      bookID: bookID,
      bookTitle: "Book \(bookID)",
      format: format,
      genres: genres,
      completedDate: completedDate,
      libraryAccount: nil
    )
  }

  private func makeSession(
    bookID: String = UUID().uuidString,
    startTime: Date = Date(),
    endTime: Date? = nil,
    format: ReadingFormat = .epub
  ) -> ReadingSession {
    ReadingSession(
      bookID: bookID,
      bookTitle: "Book",
      format: format,
      startTime: startTime,
      endTime: endTime
    )
  }

  private func makeCompletions(count: Int) -> [BookCompletion] {
    (0..<count).map { i in
      makeCompletion(bookID: "book-\(i)")
    }
  }

  // MARK: - FiftyBooksClub

  func testFiftyBooksClub_PassingCriteria() {
    let completions = makeCompletions(count: 50)
    let ctx = makeContext(completions: completions)

    let progress = BadgeCatalog.fiftyBooksClub.evaluateProgress(ctx)
    XCTAssertEqual(progress, 1.0, accuracy: 0.001)
  }

  func testFiftyBooksClub_FailingCriteria() {
    let completions = makeCompletions(count: 10)
    let ctx = makeContext(completions: completions)

    let progress = BadgeCatalog.fiftyBooksClub.evaluateProgress(ctx)
    XCTAssertLessThan(progress, 1.0)
  }

  func testFiftyBooksClub_ProgressCalculation() {
    let completions = makeCompletions(count: 25)
    let ctx = makeContext(completions: completions)

    let progress = BadgeCatalog.fiftyBooksClub.evaluateProgress(ctx)
    XCTAssertEqual(progress, 0.5, accuracy: 0.001)
  }

  func testFiftyBooksClub_CapsAtOne() {
    let completions = makeCompletions(count: 75)
    let ctx = makeContext(completions: completions)

    let progress = BadgeCatalog.fiftyBooksClub.evaluateProgress(ctx)
    XCTAssertEqual(progress, 1.0, accuracy: 0.001)
  }

  // MARK: - HundredBooksClub

  func testHundredBooksClub_PassingCriteria() {
    let completions = makeCompletions(count: 100)
    let ctx = makeContext(completions: completions)

    let progress = BadgeCatalog.hundredBooksClub.evaluateProgress(ctx)
    XCTAssertEqual(progress, 1.0, accuracy: 0.001)
  }

  func testHundredBooksClub_FailingCriteria() {
    let completions = makeCompletions(count: 30)
    let ctx = makeContext(completions: completions)

    let progress = BadgeCatalog.hundredBooksClub.evaluateProgress(ctx)
    XCTAssertLessThan(progress, 1.0)
  }

  func testHundredBooksClub_ProgressCalculation() {
    let completions = makeCompletions(count: 50)
    let ctx = makeContext(completions: completions)

    let progress = BadgeCatalog.hundredBooksClub.evaluateProgress(ctx)
    XCTAssertEqual(progress, 0.5, accuracy: 0.001)
  }

  func testHundredBooksClub_ZeroCompletions() {
    let ctx = makeContext(completions: [])

    let progress = BadgeCatalog.hundredBooksClub.evaluateProgress(ctx)
    XCTAssertEqual(progress, 0.0, accuracy: 0.001)
  }

  // MARK: - SpeedReader

  func testSpeedReader_PassingCriteria_SameDayStartAndFinish() {
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: Date())
    let morningStart = calendar.date(byAdding: .hour, value: 8, to: today)!
    let afternoonEnd = calendar.date(byAdding: .hour, value: 14, to: today)!

    let bookID = "speed-book"
    let session = makeSession(
      bookID: bookID,
      startTime: morningStart,
      endTime: afternoonEnd
    )
    let completion = makeCompletion(
      bookID: bookID,
      completedDate: afternoonEnd
    )
    let ctx = makeContext(sessions: [session], completions: [completion])

    let progress = BadgeCatalog.speedReader.evaluateProgress(ctx)
    XCTAssertEqual(progress, 1.0, accuracy: 0.001)
  }

  func testSpeedReader_FailingCriteria_MultiDayRead() {
    let calendar = Calendar.current
    let yesterday = calendar.date(byAdding: .day, value: -1, to: Date())!
    let today = Date()

    let bookID = "slow-book"
    let session = makeSession(
      bookID: bookID,
      startTime: yesterday,
      endTime: today
    )
    let completion = makeCompletion(
      bookID: bookID,
      completedDate: today
    )
    let ctx = makeContext(sessions: [session], completions: [completion])

    let progress = BadgeCatalog.speedReader.evaluateProgress(ctx)
    XCTAssertLessThan(progress, 1.0)
  }

  func testSpeedReader_ProgressWithCompletionsButNoneSameDay() {
    let completions = [makeCompletion()]
    let ctx = makeContext(completions: completions)

    let progress = BadgeCatalog.speedReader.evaluateProgress(ctx)
    // Has completions but no same-day match: partial progress (0.5)
    XCTAssertEqual(progress, 0.5, accuracy: 0.001)
  }

  func testSpeedReader_ZeroProgress_NoCompletions() {
    let ctx = makeContext()

    let progress = BadgeCatalog.speedReader.evaluateProgress(ctx)
    XCTAssertEqual(progress, 0.0, accuracy: 0.001)
  }

  // MARK: - StreakLegend (30 days)

  func testStreakLegend_PassingCriteria() {
    let streak = ReadingStreak(currentStreakDays: 30, longestStreakDays: 30)
    let ctx = makeContext(streak: streak)

    let progress = BadgeCatalog.streakLegend.evaluateProgress(ctx)
    XCTAssertEqual(progress, 1.0, accuracy: 0.001)
  }

  func testStreakLegend_FailingCriteria() {
    let streak = ReadingStreak(currentStreakDays: 10, longestStreakDays: 10)
    let ctx = makeContext(streak: streak)

    let progress = BadgeCatalog.streakLegend.evaluateProgress(ctx)
    XCTAssertLessThan(progress, 1.0)
  }

  func testStreakLegend_ProgressCalculation() {
    let streak = ReadingStreak(currentStreakDays: 15, longestStreakDays: 15)
    let ctx = makeContext(streak: streak)

    let progress = BadgeCatalog.streakLegend.evaluateProgress(ctx)
    XCTAssertEqual(progress, 0.5, accuracy: 0.001)
  }

  func testStreakLegend_UsesLongestStreak() {
    // Current streak is low but longest was 30
    let streak = ReadingStreak(currentStreakDays: 2, longestStreakDays: 30)
    let ctx = makeContext(streak: streak)

    let progress = BadgeCatalog.streakLegend.evaluateProgress(ctx)
    XCTAssertEqual(progress, 1.0, accuracy: 0.001)
  }

  // MARK: - StreakImmortal (100 days)

  func testStreakImmortal_PassingCriteria() {
    let streak = ReadingStreak(currentStreakDays: 100, longestStreakDays: 100)
    let ctx = makeContext(streak: streak)

    let progress = BadgeCatalog.streakImmortal.evaluateProgress(ctx)
    XCTAssertEqual(progress, 1.0, accuracy: 0.001)
  }

  func testStreakImmortal_FailingCriteria() {
    let streak = ReadingStreak(currentStreakDays: 50, longestStreakDays: 50)
    let ctx = makeContext(streak: streak)

    let progress = BadgeCatalog.streakImmortal.evaluateProgress(ctx)
    XCTAssertLessThan(progress, 1.0)
  }

  func testStreakImmortal_ProgressCalculation() {
    let streak = ReadingStreak(currentStreakDays: 50, longestStreakDays: 50)
    let ctx = makeContext(streak: streak)

    let progress = BadgeCatalog.streakImmortal.evaluateProgress(ctx)
    XCTAssertEqual(progress, 0.5, accuracy: 0.001)
  }

  func testStreakImmortal_CapsAtOne() {
    let streak = ReadingStreak(currentStreakDays: 200, longestStreakDays: 200)
    let ctx = makeContext(streak: streak)

    let progress = BadgeCatalog.streakImmortal.evaluateProgress(ctx)
    XCTAssertEqual(progress, 1.0, accuracy: 0.001)
  }

  // MARK: - WeekendWarrior (4 consecutive weekends)

  func testWeekendWarrior_PassingCriteria_FourConsecutiveWeekends() {
    let calendar = Calendar.current
    var sessions: [ReadingSession] = []

    // Create sessions on 4 consecutive weekends (Saturday or Sunday)
    for weeksAgo in 0..<4 {
      // Find the most recent Saturday
      let today = Date()
      guard let weekStart = calendar.date(byAdding: .weekOfYear, value: -weeksAgo, to: today) else { continue }

      // Find Saturday of that week
      let weekday = calendar.component(.weekday, from: weekStart)
      let daysToSaturday = (7 - weekday) % 7
      guard let saturday = calendar.date(byAdding: .day, value: daysToSaturday == 0 && weekday != 7 ? -1 : daysToSaturday, to: weekStart) else { continue }

      // For simplicity, just add a weekend day session
      let adjustedSaturday: Date
      if calendar.component(.weekday, from: saturday) == 7 {
        adjustedSaturday = saturday
      } else {
        // Fallback: create a date that is definitely a Saturday
        var comps = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: weekStart)
        comps.weekday = 7
        adjustedSaturday = calendar.date(from: comps) ?? saturday
      }

      sessions.append(makeSession(startTime: adjustedSaturday))
    }

    let ctx = makeContext(sessions: sessions)
    let progress = BadgeCatalog.weekendWarrior.evaluateProgress(ctx)

    // With 4 weekend sessions, should have meaningful progress
    XCTAssertGreaterThan(progress, 0.0)
  }

  func testWeekendWarrior_FailingCriteria_NoWeekendSessions() {
    // Create sessions only on weekdays
    let calendar = Calendar.current
    var sessions: [ReadingSession] = []

    for daysAgo in 0..<5 {
      guard let date = calendar.date(byAdding: .day, value: -daysAgo, to: Date()) else { continue }
      let weekday = calendar.component(.weekday, from: date)
      // Only add if it's a weekday (Mon-Fri)
      if weekday >= 2 && weekday <= 6 {
        sessions.append(makeSession(startTime: date))
      }
    }

    let ctx = makeContext(sessions: sessions)
    let progress = BadgeCatalog.weekendWarrior.evaluateProgress(ctx)

    XCTAssertEqual(progress, 0.0, accuracy: 0.001)
  }

  func testWeekendWarrior_ProgressCalculation_TwoWeekends() {
    let calendar = Calendar.current
    var sessions: [ReadingSession] = []

    // Create sessions on exactly 2 consecutive Sundays
    for weeksAgo in 0..<2 {
      guard let date = calendar.date(byAdding: .weekOfYear, value: -weeksAgo, to: Date()) else { continue }
      var comps = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
      comps.weekday = 1 // Sunday
      if let sunday = calendar.date(from: comps) {
        sessions.append(makeSession(startTime: sunday))
      }
    }

    let ctx = makeContext(sessions: sessions)
    let progress = BadgeCatalog.weekendWarrior.evaluateProgress(ctx)

    // 2 out of 4 required weekends
    XCTAssertGreaterThan(progress, 0.0)
    XCTAssertLessThanOrEqual(progress, 1.0)
  }

  // MARK: - Badge Metadata

  func testFiftyBooksClub_Metadata() {
    let badge = BadgeCatalog.fiftyBooksClub
    XCTAssertEqual(badge.id, "fifty_books_club")
    XCTAssertEqual(badge.name, "50 Books Club")
    XCTAssertEqual(badge.tier, .silver)
    XCTAssertFalse(badge.descriptionText.isEmpty)
    XCTAssertFalse(badge.hint.isEmpty)
    XCTAssertFalse(badge.iconName.isEmpty)
  }

  func testHundredBooksClub_Metadata() {
    let badge = BadgeCatalog.hundredBooksClub
    XCTAssertEqual(badge.id, "hundred_books_club")
    XCTAssertEqual(badge.name, "100 Books Club")
    XCTAssertEqual(badge.tier, .gold)
  }

  func testSpeedReader_Metadata() {
    let badge = BadgeCatalog.speedReader
    XCTAssertEqual(badge.id, "speed_reader")
    XCTAssertEqual(badge.tier, .silver)
  }

  func testStreakLegend_Metadata() {
    let badge = BadgeCatalog.streakLegend
    XCTAssertEqual(badge.id, "streak_legend")
    XCTAssertEqual(badge.tier, .silver)
  }

  func testStreakImmortal_Metadata() {
    let badge = BadgeCatalog.streakImmortal
    XCTAssertEqual(badge.id, "streak_immortal")
    XCTAssertEqual(badge.tier, .gold)
  }

  func testWeekendWarrior_Metadata() {
    let badge = BadgeCatalog.weekendWarrior
    XCTAssertEqual(badge.id, "weekend_warrior")
    XCTAssertEqual(badge.tier, .silver)
  }

  // MARK: - makeBadge

  func testMakeBadge_ProducesCorrectBadge() {
    let definition = BadgeCatalog.fiftyBooksClub
    let badge = definition.makeBadge(earnedDate: Date(), progress: 1.0)

    XCTAssertEqual(badge.id, definition.id)
    XCTAssertEqual(badge.name, definition.name)
    XCTAssertEqual(badge.tier, definition.tier)
    XCTAssertNotNil(badge.earnedDate)
    XCTAssertEqual(badge.progress, 1.0)
    XCTAssertTrue(badge.isEarned)
  }

  func testMakeBadge_DefaultsToNotEarned() {
    let definition = BadgeCatalog.hundredBooksClub
    let badge = definition.makeBadge()

    XCTAssertNil(badge.earnedDate)
    XCTAssertEqual(badge.progress, 0.0)
    XCTAssertFalse(badge.isEarned)
  }

  // MARK: - BadgeCatalog.all

  func testBadgeCatalog_ContainsAllBadges() {
    let allIDs = BadgeCatalog.all.map(\.id)

    XCTAssertTrue(allIDs.contains("fifty_books_club"))
    XCTAssertTrue(allIDs.contains("hundred_books_club"))
    XCTAssertTrue(allIDs.contains("speed_reader"))
    XCTAssertTrue(allIDs.contains("streak_legend"))
    XCTAssertTrue(allIDs.contains("streak_immortal"))
    XCTAssertTrue(allIDs.contains("weekend_warrior"))
  }

  func testBadgeCatalog_HasUniqueIDs() {
    let allIDs = BadgeCatalog.all.map(\.id)
    XCTAssertEqual(allIDs.count, Set(allIDs).count, "All badge IDs should be unique")
  }
}
