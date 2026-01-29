//
//  Clock.swift
//  PalaceTests
//
//  Time abstraction for testing time-dependent logic.
//  Allows tests to control the current time without modifying system time.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation

// MARK: - ClockProviding Protocol

/// Protocol for providing the current time.
/// Use this to inject time dependencies for testability.
protocol ClockProviding {
  /// The current date/time
  var now: Date { get }
}

// MARK: - SystemClock

/// Production implementation that returns the real system time.
struct SystemClock: ClockProviding {

  /// Returns the current system date/time
  var now: Date {
    Date()
  }
}

// MARK: - MockClock

/// Test implementation with controllable time.
/// Use this in unit tests to simulate time progression.
final class MockClock: ClockProviding {

  // MARK: - Properties

  /// The current mocked time. Mutable for test control.
  var now: Date

  /// Track all time advances for debugging
  private(set) var advanceHistory: [TimeInterval] = []

  // MARK: - Initialization

  /// Creates a MockClock with the specified initial time.
  /// - Parameter initialTime: The starting time. Defaults to the current system time.
  init(initialTime: Date = Date()) {
    self.now = initialTime
  }

  /// Creates a MockClock with a specific fixed date for deterministic testing.
  /// - Parameter fixedDate: A fixed date to use (e.g., for snapshot tests)
  convenience init(fixedDate: Date) {
    self.init(initialTime: fixedDate)
  }

  /// Creates a MockClock set to a specific Unix timestamp.
  /// - Parameter timestamp: Unix timestamp (seconds since 1970)
  convenience init(timestamp: TimeInterval) {
    self.init(initialTime: Date(timeIntervalSince1970: timestamp))
  }

  // MARK: - Time Control

  /// Advances the current time by the specified interval.
  /// - Parameter interval: The time interval to advance (in seconds)
  func advance(by interval: TimeInterval) {
    now = now.addingTimeInterval(interval)
    advanceHistory.append(interval)
  }

  /// Advances the current time by the specified number of seconds.
  /// - Parameter seconds: Number of seconds to advance
  func advanceSeconds(_ seconds: Double) {
    advance(by: seconds)
  }

  /// Advances the current time by the specified number of minutes.
  /// - Parameter minutes: Number of minutes to advance
  func advanceMinutes(_ minutes: Double) {
    advance(by: minutes * 60)
  }

  /// Advances the current time by the specified number of hours.
  /// - Parameter hours: Number of hours to advance
  func advanceHours(_ hours: Double) {
    advance(by: hours * 3600)
  }

  /// Advances the current time by the specified number of days.
  /// - Parameter days: Number of days to advance
  func advanceDays(_ days: Double) {
    advance(by: days * 86400)
  }

  /// Resets the clock to a new time and clears the advance history.
  /// - Parameter newTime: The new time to set. Defaults to current system time.
  func reset(to newTime: Date = Date()) {
    now = newTime
    advanceHistory.removeAll()
  }

  // MARK: - Convenience Properties

  /// Returns the total time that has been advanced since creation or last reset
  var totalAdvanced: TimeInterval {
    advanceHistory.reduce(0, +)
  }

  /// Returns true if advance() has been called at least once
  var hasAdvanced: Bool {
    !advanceHistory.isEmpty
  }
}

// MARK: - Fixed Test Dates

extension MockClock {

  /// Creates a MockClock set to January 1, 2024 00:00:00 UTC
  /// Useful for deterministic snapshot testing
  static var snapshotClock: MockClock {
    MockClock(timestamp: 1704067200) // Jan 1, 2024 00:00:00 UTC
  }

  /// Creates a MockClock set to a date that simulates a book expiring soon (3 days from now)
  static var expiringBookClock: MockClock {
    let clock = MockClock()
    // Set to a fixed date, then the book's "until" date would be set relative to this
    return clock
  }

  /// Creates a MockClock set to a date in the past (useful for testing expired content)
  /// - Parameter daysAgo: How many days in the past to set the clock
  static func pastClock(daysAgo: Int) -> MockClock {
    let pastDate = Date().addingTimeInterval(-Double(daysAgo) * 86400)
    return MockClock(initialTime: pastDate)
  }

  /// Creates a MockClock set to a date in the future
  /// - Parameter daysAhead: How many days in the future to set the clock
  static func futureClock(daysAhead: Int) -> MockClock {
    let futureDate = Date().addingTimeInterval(Double(daysAhead) * 86400)
    return MockClock(initialTime: futureDate)
  }
}
