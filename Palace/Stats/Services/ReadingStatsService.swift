import Foundation

/// Actor-based implementation of the reading stats service.
/// Thread-safe by design; all mutable state is isolated to the actor.
actor ReadingStatsService: ReadingStatsServiceProtocol {
  private let store: ReadingStatsStoreProtocol
  private var sessions: [ReadingSession]
  private var streak: ReadingStreak
  private var completionsList: [BookCompletion]

  init(store: ReadingStatsStoreProtocol = ReadingStatsStore()) {
    self.store = store
    self.sessions = store.loadSessions()
    self.streak = store.loadStreak()
    self.completionsList = store.loadCompletions()
  }

  // MARK: - Recording

  func recordSession(_ session: ReadingSession) {
    guard session.duration > 0 else { return }
    sessions.append(session)
    store.saveSessions(sessions)
    updateStreakForDate(session.startTime)
  }

  func recordBookCompletion(_ completion: BookCompletion) {
    guard !completionsList.contains(where: { $0.bookID == completion.bookID }) else { return }
    completionsList.append(completion)
    store.saveCompletions(completionsList)
  }

  // MARK: - Queries

  func sessions(in period: TimePeriod) -> [ReadingSession] {
    filterSessions(by: period)
  }

  func currentStreak() -> ReadingStreak {
    streak
  }

  func completions() -> [BookCompletion] {
    completionsList
  }

  func recalculateStreak() -> ReadingStreak {
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: Date())

    guard !streak.activeDates.isEmpty else {
      streak = ReadingStreak()
      store.saveStreak(streak)
      return streak
    }

    // Sort all active dates descending
    let sortedDates = streak.activeDates
      .compactMap { ReadingStreak.dateKeyFormatter.date(from: $0) }
      .map { calendar.startOfDay(for: $0) }
      .sorted(by: >)

    guard let mostRecentDate = sortedDates.first else {
      streak = ReadingStreak()
      store.saveStreak(streak)
      return streak
    }

    // Calculate current streak from today/yesterday backward
    let daysSinceLast = calendar.dateComponents([.day], from: mostRecentDate, to: today).day ?? 0
    var currentDays = 0
    var currentStart: Date?

    if daysSinceLast <= 1 {
      // Streak is active; count backward
      var checkDate = mostRecentDate
      while streak.activeDates.contains(ReadingStreak.dateKey(for: checkDate)) {
        currentDays += 1
        currentStart = checkDate
        guard let prev = calendar.date(byAdding: .day, value: -1, to: checkDate) else { break }
        checkDate = prev
      }
    }

    // Calculate longest streak ever from all dates
    var longestRun = 0
    var currentRun = 0
    var previousDate: Date?
    for date in sortedDates.sorted() {
      if let prev = previousDate {
        let diff = calendar.dateComponents([.day], from: prev, to: date).day ?? 0
        if diff == 1 {
          currentRun += 1
        } else if diff > 1 {
          currentRun = 1
        }
        // diff == 0: duplicate, ignore
      } else {
        currentRun = 1
      }
      longestRun = max(longestRun, currentRun)
      previousDate = date
    }

    streak.currentStreakDays = currentDays
    streak.currentStreakStartDate = currentStart
    streak.longestStreakDays = max(streak.longestStreakDays, longestRun)
    streak.lastActiveDate = mostRecentDate

    store.saveStreak(streak)
    return streak
  }

  func aggregateStats(for period: TimePeriod) -> ReadingStats {
    let filtered = filterSessions(by: period)
    let filteredCompletions = filterCompletions(by: period)

    var stats = ReadingStats()
    stats.totalBooksFinished = filteredCompletions.count
    stats.sessionsCount = filtered.count
    stats.totalPagesRead = filtered.reduce(0) { $0 + $1.pagesRead }
    stats.totalReadingMinutes = filtered.reduce(0.0) { $0 + $1.durationMinutes }
    stats.totalAudiobookMinutes = filtered
      .filter { $0.format == .audiobook }
      .reduce(0.0) { $0 + $1.minutesListened }

    if stats.sessionsCount > 0 {
      stats.averageSessionMinutes = stats.totalReadingMinutes / Double(stats.sessionsCount)
    }

    // Books by genre
    var genreCounts: [String: Int] = [:]
    for completion in filteredCompletions {
      for genre in completion.genres {
        genreCounts[genre, default: 0] += 1
      }
    }
    stats.booksByGenre = genreCounts

    // Unique libraries
    stats.uniqueLibraries = Set(filtered.compactMap(\.libraryAccount))

    return stats
  }

  func chartData(for period: TimePeriod) -> [ChartDataPoint] {
    let calendar = Calendar.current
    let now = Date()
    let filtered = filterSessions(by: period)

    switch period {
    case .week:
      return dailyChartData(sessions: filtered, days: 7, from: now, calendar: calendar)
    case .month:
      return dailyChartData(sessions: filtered, days: 30, from: now, calendar: calendar)
    case .year:
      return monthlyChartData(sessions: filtered, months: 12, from: now, calendar: calendar)
    case .all:
      if sessions.isEmpty { return [] }
      let earliest = sessions.map(\.startTime).min() ?? now
      let monthsBetween = calendar.dateComponents([.month], from: earliest, to: now).month ?? 1
      return monthlyChartData(sessions: filtered, months: max(monthsBetween, 1), from: now, calendar: calendar)
    }
  }

  // MARK: - Private Helpers

  private func updateStreakForDate(_ date: Date) {
    let dateKey = ReadingStreak.dateKey(for: date)
    guard !streak.activeDates.contains(dateKey) else {
      store.saveStreak(streak)
      return
    }

    streak.activeDates.insert(dateKey)
    streak.lastActiveDate = date
    _ = recalculateStreak()
  }

  private func filterSessions(by period: TimePeriod) -> [ReadingSession] {
    guard let startDate = period.startDate() else { return sessions }
    return sessions.filter { $0.startTime >= startDate }
  }

  private func filterCompletions(by period: TimePeriod) -> [BookCompletion] {
    guard let startDate = period.startDate() else { return completionsList }
    return completionsList.filter { $0.completedDate >= startDate }
  }

  private func dailyChartData(sessions: [ReadingSession], days: Int, from now: Date, calendar: Calendar) -> [ChartDataPoint] {
    let dayFormatter = DateFormatter()
    dayFormatter.dateFormat = "EEE"

    var points: [ChartDataPoint] = []
    for daysAgo in (0..<days).reversed() {
      guard let date = calendar.date(byAdding: .day, value: -daysAgo, to: now) else { continue }
      let dayStart = calendar.startOfDay(for: date)
      guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { continue }

      let daySessions = sessions.filter { $0.startTime >= dayStart && $0.startTime < dayEnd }
      let totalMinutes = daySessions.reduce(0.0) { $0 + $1.durationMinutes }

      points.append(ChartDataPoint(
        label: dayFormatter.string(from: date),
        date: dayStart,
        value: totalMinutes,
        format: nil
      ))
    }
    return points
  }

  private func monthlyChartData(sessions: [ReadingSession], months: Int, from now: Date, calendar: Calendar) -> [ChartDataPoint] {
    let monthFormatter = DateFormatter()
    monthFormatter.dateFormat = "MMM"

    var points: [ChartDataPoint] = []
    for monthsAgo in (0..<months).reversed() {
      guard let date = calendar.date(byAdding: .month, value: -monthsAgo, to: now) else { continue }
      let comps = calendar.dateComponents([.year, .month], from: date)
      guard let monthStart = calendar.date(from: comps),
            let monthEnd = calendar.date(byAdding: .month, value: 1, to: monthStart) else { continue }

      let monthSessions = sessions.filter { $0.startTime >= monthStart && $0.startTime < monthEnd }
      let totalMinutes = monthSessions.reduce(0.0) { $0 + $1.durationMinutes }

      points.append(ChartDataPoint(
        label: monthFormatter.string(from: date),
        date: monthStart,
        value: totalMinutes,
        format: nil
      ))
    }
    return points
  }
}
