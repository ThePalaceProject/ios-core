import Foundation

/// The tier level of a badge, reflecting increasing difficulty.
enum BadgeTier: String, Codable, CaseIterable, Comparable {
  case bronze
  case silver
  case gold

  static func < (lhs: BadgeTier, rhs: BadgeTier) -> Bool {
    let order: [BadgeTier] = [.bronze, .silver, .gold]
    return (order.firstIndex(of: lhs) ?? 0) < (order.firstIndex(of: rhs) ?? 0)
  }
}

/// An achievement badge the user can earn.
struct Badge: Codable, Identifiable, Equatable {
  let id: String
  let name: String
  let descriptionText: String
  let iconName: String
  let tier: BadgeTier
  var earnedDate: Date?
  var progress: Double

  var isEarned: Bool {
    earnedDate != nil
  }

  var isInProgress: Bool {
    !isEarned && progress > 0
  }

  var progressPercentage: Int {
    Int((progress * 100).rounded())
  }

  init(
    id: String,
    name: String,
    descriptionText: String,
    iconName: String,
    tier: BadgeTier,
    earnedDate: Date? = nil,
    progress: Double = 0
  ) {
    self.id = id
    self.name = name
    self.descriptionText = descriptionText
    self.iconName = iconName
    self.tier = tier
    self.earnedDate = earnedDate
    self.progress = min(max(progress, 0), 1)
  }
}
