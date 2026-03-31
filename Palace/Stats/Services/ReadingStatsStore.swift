import Foundation

/// Versioned schema for stats persistence, enabling future migrations.
private enum StatsStoreVersion {
  static let current = 1
}

/// Keys used for UserDefaults persistence.
private enum StatsStoreKey {
  static let sessions = "palace.stats.sessions"
  static let streak = "palace.stats.streak"
  static let completions = "palace.stats.completions"
  static let earnedBadges = "palace.stats.earnedBadges"
  static let schemaVersion = "palace.stats.schemaVersion"
}

/// Protocol for stats persistence, enabling test injection.
protocol ReadingStatsStoreProtocol: Sendable {
  func loadSessions() -> [ReadingSession]
  func saveSessions(_ sessions: [ReadingSession])
  func loadStreak() -> ReadingStreak
  func saveStreak(_ streak: ReadingStreak)
  func loadCompletions() -> [BookCompletion]
  func saveCompletions(_ completions: [BookCompletion])
  func loadEarnedBadges() -> [String: Date]
  func saveEarnedBadges(_ badges: [String: Date])
  func clearAll()
}

/// Persists reading stats data using UserDefaults with JSON encoding.
final class ReadingStatsStore: ReadingStatsStoreProtocol, @unchecked Sendable {
  private let defaults: UserDefaults
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()
  private let queue = DispatchQueue(label: "palace.stats.store", qos: .utility)

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    migrateIfNeeded()
  }

  // MARK: - Migration

  private func migrateIfNeeded() {
    let version = defaults.integer(forKey: StatsStoreKey.schemaVersion)
    if version < StatsStoreVersion.current {
      // Version 0 -> 1: initial schema, no migration needed
      defaults.set(StatsStoreVersion.current, forKey: StatsStoreKey.schemaVersion)
    }
  }

  // MARK: - Sessions

  func loadSessions() -> [ReadingSession] {
    queue.sync {
      guard let data = defaults.data(forKey: StatsStoreKey.sessions) else { return [] }
      return (try? decoder.decode([ReadingSession].self, from: data)) ?? []
    }
  }

  func saveSessions(_ sessions: [ReadingSession]) {
    queue.sync {
      guard let data = try? encoder.encode(sessions) else { return }
      defaults.set(data, forKey: StatsStoreKey.sessions)
    }
  }

  // MARK: - Streak

  func loadStreak() -> ReadingStreak {
    queue.sync {
      guard let data = defaults.data(forKey: StatsStoreKey.streak) else { return ReadingStreak() }
      return (try? decoder.decode(ReadingStreak.self, from: data)) ?? ReadingStreak()
    }
  }

  func saveStreak(_ streak: ReadingStreak) {
    queue.sync {
      guard let data = try? encoder.encode(streak) else { return }
      defaults.set(data, forKey: StatsStoreKey.streak)
    }
  }

  // MARK: - Completions

  func loadCompletions() -> [BookCompletion] {
    queue.sync {
      guard let data = defaults.data(forKey: StatsStoreKey.completions) else { return [] }
      return (try? decoder.decode([BookCompletion].self, from: data)) ?? []
    }
  }

  func saveCompletions(_ completions: [BookCompletion]) {
    queue.sync {
      guard let data = try? encoder.encode(completions) else { return }
      defaults.set(data, forKey: StatsStoreKey.completions)
    }
  }

  // MARK: - Earned Badges

  func loadEarnedBadges() -> [String: Date] {
    queue.sync {
      guard let data = defaults.data(forKey: StatsStoreKey.earnedBadges) else { return [:] }
      return (try? decoder.decode([String: Date].self, from: data)) ?? [:]
    }
  }

  func saveEarnedBadges(_ badges: [String: Date]) {
    queue.sync {
      guard let data = try? encoder.encode(badges) else { return }
      defaults.set(data, forKey: StatsStoreKey.earnedBadges)
    }
  }

  // MARK: - Clear

  func clearAll() {
    queue.sync {
      defaults.removeObject(forKey: StatsStoreKey.sessions)
      defaults.removeObject(forKey: StatsStoreKey.streak)
      defaults.removeObject(forKey: StatsStoreKey.completions)
      defaults.removeObject(forKey: StatsStoreKey.earnedBadges)
    }
  }
}
