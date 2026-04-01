import Foundation

/// Protocol for the reading stats tracking service.
protocol ReadingStatsServiceProtocol: Sendable {
  /// Records a completed reading session.
  func recordSession(_ session: ReadingSession) async

  /// Records that the user has finished a book.
  func recordBookCompletion(_ completion: BookCompletion) async

  /// Returns all recorded sessions, optionally filtered by time period.
  func sessions(in period: TimePeriod) async -> [ReadingSession]

  /// Returns the current reading streak.
  func currentStreak() async -> ReadingStreak

  /// Recalculates the streak based on stored active dates.
  func recalculateStreak() async -> ReadingStreak

  /// Computes aggregate stats for the given time period.
  func aggregateStats(for period: TimePeriod) async -> ReadingStats

  /// Returns all book completions.
  func completions() async -> [BookCompletion]

  /// Generates chart data points for the given time period.
  func chartData(for period: TimePeriod) async -> [ChartDataPoint]
}
