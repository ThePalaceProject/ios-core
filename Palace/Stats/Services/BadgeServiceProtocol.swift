import Foundation

/// Notification posted when a new badge is earned. The `object` is the `Badge`.
extension Notification.Name {
  static let badgeEarned = Notification.Name("palace.stats.badgeEarned")
}

/// Protocol for the badge evaluation service.
protocol BadgeServiceProtocol: Sendable {
  /// Evaluates all badge criteria and returns the current state of all badges.
  func evaluateAllBadges() async -> [Badge]

  /// Returns only earned badges, sorted by earned date descending.
  func earnedBadges() async -> [Badge]

  /// Returns badges the user is making progress toward but hasn't earned yet.
  func inProgressBadges() async -> [Badge]

  /// Returns badges the user has made no progress toward.
  func lockedBadges() async -> [Badge]

  /// Force re-evaluation of badges (e.g., after a session ends).
  func refresh() async
}
