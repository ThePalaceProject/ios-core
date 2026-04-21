import Foundation

/// Actor-based badge evaluation service.
/// Evaluates badge criteria against reading history and tracks progress.
actor BadgeService: BadgeServiceProtocol {
  private let statsService: ReadingStatsServiceProtocol
  private let store: ReadingStatsStoreProtocol
  private var cachedBadges: [Badge] = []
  private var earnedBadgeDates: [String: Date]

  init(statsService: ReadingStatsServiceProtocol, store: ReadingStatsStoreProtocol = ReadingStatsStore()) {
    self.statsService = statsService
    self.store = store
    self.earnedBadgeDates = store.loadEarnedBadges()
  }

  func evaluateAllBadges() async -> [Badge] {
    let context = await buildContext()
    var badges: [Badge] = []

    for definition in BadgeCatalog.all {
      let progress = definition.evaluateProgress(context)
      var badge = definition.makeBadge(
        earnedDate: earnedBadgeDates[definition.id],
        progress: progress
      )

      // Check if newly earned
      if progress >= 1.0 && earnedBadgeDates[definition.id] == nil {
        let now = Date()
        earnedBadgeDates[definition.id] = now
        badge.earnedDate = now
        badge.progress = 1.0
        store.saveEarnedBadges(earnedBadgeDates)

        // Post notification on main thread
        let earnedBadge = badge
        Task { @MainActor in
          NotificationCenter.default.post(
            name: .badgeEarned,
            object: earnedBadge
          )
        }
      }

      badges.append(badge)
    }

    cachedBadges = badges
    return badges
  }

  func earnedBadges() async -> [Badge] {
    let all = await evaluateAllBadges()
    return all.filter(\.isEarned).sorted { ($0.earnedDate ?? .distantPast) > ($1.earnedDate ?? .distantPast) }
  }

  func inProgressBadges() async -> [Badge] {
    let all = await evaluateAllBadges()
    return all.filter(\.isInProgress).sorted { $0.progress > $1.progress }
  }

  func lockedBadges() async -> [Badge] {
    let all = await evaluateAllBadges()
    return all.filter { !$0.isEarned && !$0.isInProgress }
  }

  func refresh() async {
    _ = await evaluateAllBadges()
  }

  // MARK: - Private

  private func buildContext() async -> BadgeEvaluationContext {
    let sessions = await statsService.sessions(in: .all)
    let completions = await statsService.completions()
    let streak = await statsService.currentStreak()
    let stats = await statsService.aggregateStats(for: .all)
    return BadgeEvaluationContext(
      sessions: sessions,
      completions: completions,
      streak: streak,
      stats: stats
    )
  }
}
