import Foundation
import Combine

/// ViewModel for the main stats screen.
@MainActor
final class StatsViewModel: ObservableObject {
  @Published private(set) var currentStreak = ReadingStreak()
  @Published private(set) var stats = ReadingStats()
  @Published private(set) var recentBadges: [Badge] = []
  @Published var selectedTimePeriod: TimePeriod = .week
  @Published private(set) var chartData: [ChartDataPoint] = []
  @Published private(set) var isLoading = false

  private let statsService: ReadingStatsServiceProtocol
  private let badgeService: BadgeServiceProtocol
  private var cancellables = Set<AnyCancellable>()

  init(statsService: ReadingStatsServiceProtocol, badgeService: BadgeServiceProtocol) {
    self.statsService = statsService
    self.badgeService = badgeService

    // React to time period changes
    $selectedTimePeriod
      .dropFirst()
      .sink { [weak self] _ in
        guard let self else { return }
        Task { await self.loadStats() }
      }
      .store(in: &cancellables)
  }

  func load() async {
    isLoading = true
    defer { isLoading = false }

    // Recalculate streak on load
    _ = await statsService.recalculateStreak()

    await loadStats()

    // Load recent badges (last 5 earned)
    let earned = await badgeService.earnedBadges()
    recentBadges = Array(earned.prefix(5))
  }

  func loadStats() async {
    async let streakTask = statsService.currentStreak()
    async let statsTask = statsService.aggregateStats(for: selectedTimePeriod)
    async let chartTask = statsService.chartData(for: selectedTimePeriod)

    currentStreak = await streakTask
    stats = await statsTask
    chartData = await chartTask
  }

  /// Formatted display for the streak count.
  var streakDisplayText: String {
    if currentStreak.currentStreakDays == 0 {
      return "Start your streak!"
    }
    let days = currentStreak.currentStreakDays
    return "\(days) day\(days == 1 ? "" : "s")"
  }

  var longestStreakText: String {
    let days = currentStreak.longestStreakDays
    return "Best: \(days) day\(days == 1 ? "" : "s")"
  }
}
