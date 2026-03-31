import Foundation

/// Defines an unlock criterion for a badge along with its metadata.
struct BadgeDefinition {
  let id: String
  let name: String
  let descriptionText: String
  let hint: String
  let iconName: String
  let tier: BadgeTier

  /// Evaluates progress toward the badge given the full reading history.
  /// Returns a value from 0.0 to 1.0.
  let evaluateProgress: (BadgeEvaluationContext) -> Double

  func makeBadge(earnedDate: Date? = nil, progress: Double = 0) -> Badge {
    Badge(
      id: id,
      name: name,
      descriptionText: descriptionText,
      iconName: iconName,
      tier: tier,
      earnedDate: earnedDate,
      progress: progress
    )
  }
}

/// Context passed to badge evaluation functions.
struct BadgeEvaluationContext {
  let sessions: [ReadingSession]
  let completions: [BookCompletion]
  let streak: ReadingStreak
  let stats: ReadingStats
}

/// The catalog of all available badges.
enum BadgeCatalog {
  static let all: [BadgeDefinition] = [
    firstBookFinished,
    tenBooksClub,
    fiftyBooksClub,
    hundredBooksClub,
    speedReader,
    nightOwl,
    earlyBird,
    marathonReader,
    genreExplorer,
    audiobookAdventurer,
    streakMaster,
    streakLegend,
    streakImmortal,
    libraryExplorer,
    weekendWarrior,
  ]

  static let firstBookFinished = BadgeDefinition(
    id: "first_book_finished",
    name: "First Chapter",
    descriptionText: "Finished your very first book.",
    hint: "Finish reading any book to earn this badge.",
    iconName: "book.closed.fill",
    tier: .bronze,
    evaluateProgress: { ctx in
      min(Double(ctx.completions.count), 1.0)
    }
  )

  static let tenBooksClub = BadgeDefinition(
    id: "ten_books_club",
    name: "10 Books Club",
    descriptionText: "Finished 10 books. You're on a roll!",
    hint: "Finish 10 books to join the club.",
    iconName: "books.vertical.fill",
    tier: .bronze,
    evaluateProgress: { ctx in
      min(Double(ctx.completions.count) / 10.0, 1.0)
    }
  )

  static let fiftyBooksClub = BadgeDefinition(
    id: "fifty_books_club",
    name: "50 Books Club",
    descriptionText: "Finished 50 books. A true bibliophile!",
    hint: "Finish 50 books to join the club.",
    iconName: "books.vertical.fill",
    tier: .silver,
    evaluateProgress: { ctx in
      min(Double(ctx.completions.count) / 50.0, 1.0)
    }
  )

  static let hundredBooksClub = BadgeDefinition(
    id: "hundred_books_club",
    name: "100 Books Club",
    descriptionText: "Finished 100 books. Legendary reader!",
    hint: "Finish 100 books to achieve legendary status.",
    iconName: "books.vertical.fill",
    tier: .gold,
    evaluateProgress: { ctx in
      min(Double(ctx.completions.count) / 100.0, 1.0)
    }
  )

  static let speedReader = BadgeDefinition(
    id: "speed_reader",
    name: "Speed Reader",
    descriptionText: "Finished a book in a single day.",
    hint: "Start and finish a book within the same calendar day.",
    iconName: "hare.fill",
    tier: .silver,
    evaluateProgress: { ctx in
      let calendar = Calendar.current
      let booksByDay = Dictionary(grouping: ctx.completions) { completion in
        calendar.startOfDay(for: completion.completedDate)
      }
      // Check if any book was started and finished on the same day
      for completion in ctx.completions {
        let completionDay = calendar.startOfDay(for: completion.completedDate)
        let sessionsForBook = ctx.sessions.filter { $0.bookID == completion.bookID }
        if let firstSession = sessionsForBook.min(by: { $0.startTime < $1.startTime }) {
          let startDay = calendar.startOfDay(for: firstSession.startTime)
          if startDay == completionDay {
            return 1.0
          }
        }
      }
      // Progress: if they have completions but none in one day, show partial
      return ctx.completions.isEmpty ? 0.0 : 0.5
    }
  )

  static let nightOwl = BadgeDefinition(
    id: "night_owl",
    name: "Night Owl",
    descriptionText: "Read past midnight 5 times.",
    hint: "Start a reading session after midnight to progress.",
    iconName: "moon.stars.fill",
    tier: .bronze,
    evaluateProgress: { ctx in
      let calendar = Calendar.current
      let lateNightSessions = ctx.sessions.filter { session in
        let hour = calendar.component(.hour, from: session.startTime)
        return hour >= 0 && hour < 4
      }
      let uniqueDays = Set(lateNightSessions.map { ReadingStreak.dateKey(for: $0.startTime) })
      return min(Double(uniqueDays.count) / 5.0, 1.0)
    }
  )

  static let earlyBird = BadgeDefinition(
    id: "early_bird",
    name: "Early Bird",
    descriptionText: "Read before 7 AM five times.",
    hint: "Start a reading session before 7 AM to progress.",
    iconName: "sunrise.fill",
    tier: .bronze,
    evaluateProgress: { ctx in
      let calendar = Calendar.current
      let earlyMorningSessions = ctx.sessions.filter { session in
        let hour = calendar.component(.hour, from: session.startTime)
        return hour >= 4 && hour < 7
      }
      let uniqueDays = Set(earlyMorningSessions.map { ReadingStreak.dateKey(for: $0.startTime) })
      return min(Double(uniqueDays.count) / 5.0, 1.0)
    }
  )

  static let marathonReader = BadgeDefinition(
    id: "marathon_reader",
    name: "Marathon Reader",
    descriptionText: "Read for over 2 hours in a single session.",
    hint: "Keep a reading session going for more than 2 hours.",
    iconName: "timer",
    tier: .silver,
    evaluateProgress: { ctx in
      let maxDuration = ctx.sessions.map(\.durationMinutes).max() ?? 0
      return min(maxDuration / 120.0, 1.0)
    }
  )

  static let genreExplorer = BadgeDefinition(
    id: "genre_explorer",
    name: "Genre Explorer",
    descriptionText: "Read books from 5 different genres.",
    hint: "Branch out and try books from different genres.",
    iconName: "globe.americas.fill",
    tier: .silver,
    evaluateProgress: { ctx in
      let genres = Set(ctx.completions.flatMap(\.genres))
      return min(Double(genres.count) / 5.0, 1.0)
    }
  )

  static let audiobookAdventurer = BadgeDefinition(
    id: "audiobook_adventurer",
    name: "Audiobook Adventurer",
    descriptionText: "Finished 5 audiobooks.",
    hint: "Listen to and complete audiobooks.",
    iconName: "headphones",
    tier: .silver,
    evaluateProgress: { ctx in
      let audiobooks = ctx.completions.filter { $0.format == .audiobook }
      return min(Double(audiobooks.count) / 5.0, 1.0)
    }
  )

  static let streakMaster = BadgeDefinition(
    id: "streak_master",
    name: "Streak Master",
    descriptionText: "Maintained a 7-day reading streak.",
    hint: "Read every day for a week straight.",
    iconName: "flame.fill",
    tier: .bronze,
    evaluateProgress: { ctx in
      let best = max(ctx.streak.currentStreakDays, ctx.streak.longestStreakDays)
      return min(Double(best) / 7.0, 1.0)
    }
  )

  static let streakLegend = BadgeDefinition(
    id: "streak_legend",
    name: "Streak Legend",
    descriptionText: "Maintained a 30-day reading streak.",
    hint: "Read every day for a full month.",
    iconName: "flame.fill",
    tier: .silver,
    evaluateProgress: { ctx in
      let best = max(ctx.streak.currentStreakDays, ctx.streak.longestStreakDays)
      return min(Double(best) / 30.0, 1.0)
    }
  )

  static let streakImmortal = BadgeDefinition(
    id: "streak_immortal",
    name: "Streak Immortal",
    descriptionText: "Maintained a 100-day reading streak.",
    hint: "Read every single day for 100 days. Incredible dedication!",
    iconName: "flame.fill",
    tier: .gold,
    evaluateProgress: { ctx in
      let best = max(ctx.streak.currentStreakDays, ctx.streak.longestStreakDays)
      return min(Double(best) / 100.0, 1.0)
    }
  )

  static let libraryExplorer = BadgeDefinition(
    id: "library_explorer",
    name: "Library Explorer",
    descriptionText: "Borrowed from 3 or more libraries.",
    hint: "Add and borrow books from different library systems.",
    iconName: "building.columns.fill",
    tier: .silver,
    evaluateProgress: { ctx in
      min(Double(ctx.stats.uniqueLibraries.count) / 3.0, 1.0)
    }
  )

  static let weekendWarrior = BadgeDefinition(
    id: "weekend_warrior",
    name: "Weekend Warrior",
    descriptionText: "Read every weekend for a month (4 consecutive weekends).",
    hint: "Read on both Saturday and Sunday for 4 weekends in a row.",
    iconName: "calendar.badge.checkmark",
    tier: .silver,
    evaluateProgress: { ctx in
      let calendar = Calendar.current
      // Get all weekend dates with reading activity
      let weekendDates = ctx.sessions.compactMap { session -> Date? in
        let weekday = calendar.component(.weekday, from: session.startTime)
        guard weekday == 1 || weekday == 7 else { return nil }
        return calendar.startOfDay(for: session.startTime)
      }
      let uniqueWeekendDates = Set(weekendDates.map { ReadingStreak.dateKey(for: $0) })

      // Count consecutive weekends (Sat+Sun pairs)
      var consecutiveWeekends = 0
      var maxConsecutiveWeekends = 0
      let now = Date()

      // Check last 20 weeks
      for weeksAgo in 0..<20 {
        guard let weekStart = calendar.date(byAdding: .weekOfYear, value: -weeksAgo, to: now) else { continue }
        let weekComps = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: weekStart)
        guard let saturday = calendar.nextDate(
          after: calendar.date(from: weekComps) ?? now,
          matching: DateComponents(weekday: 7),
          matchingPolicy: .nextTime,
          direction: .forward
        ) else { continue }
        guard let sunday = calendar.date(byAdding: .day, value: 1, to: saturday) else { continue }

        let satKey = ReadingStreak.dateKey(for: saturday)
        let sunKey = ReadingStreak.dateKey(for: sunday)

        if uniqueWeekendDates.contains(satKey) || uniqueWeekendDates.contains(sunKey) {
          consecutiveWeekends += 1
          maxConsecutiveWeekends = max(maxConsecutiveWeekends, consecutiveWeekends)
        } else {
          consecutiveWeekends = 0
        }
      }

      return min(Double(maxConsecutiveWeekends) / 4.0, 1.0)
    }
  )
}
