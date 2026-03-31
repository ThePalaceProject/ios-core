import Foundation

/// Tracks the user's reading streak: consecutive days with at least one reading session.
struct ReadingStreak: Codable, Equatable {
  /// The date the current streak started.
  var currentStreakStartDate: Date?

  /// The number of consecutive days in the current streak.
  var currentStreakDays: Int

  /// The longest streak ever achieved (in days).
  var longestStreakDays: Int

  /// The last date the user was active (read something).
  var lastActiveDate: Date?

  /// All dates on which reading occurred, stored as "yyyy-MM-dd" strings for fast lookup.
  var activeDates: Set<String>

  var isStreakActive: Bool {
    guard let lastActive = lastActiveDate else { return false }
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: Date())
    let lastDay = calendar.startOfDay(for: lastActive)
    let daysDiff = calendar.dateComponents([.day], from: lastDay, to: today).day ?? 0
    return daysDiff <= 1
  }

  init(
    currentStreakStartDate: Date? = nil,
    currentStreakDays: Int = 0,
    longestStreakDays: Int = 0,
    lastActiveDate: Date? = nil,
    activeDates: Set<String> = []
  ) {
    self.currentStreakStartDate = currentStreakStartDate
    self.currentStreakDays = currentStreakDays
    self.longestStreakDays = longestStreakDays
    self.lastActiveDate = lastActiveDate
    self.activeDates = activeDates
  }

  // MARK: - Date Helpers

  static let dateKeyFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.timeZone = .current
    return f
  }()

  static func dateKey(for date: Date) -> String {
    dateKeyFormatter.string(from: date)
  }

  func wasActiveOn(_ date: Date) -> Bool {
    activeDates.contains(Self.dateKey(for: date))
  }
}
