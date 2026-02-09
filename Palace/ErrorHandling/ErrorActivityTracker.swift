//
//  ErrorActivityTracker.swift
//  Palace
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation

/// Tracks a rolling trail of application activities for error diagnostics.
///
/// When an error occurs, the recent activity trail provides context about
/// what the app was doing leading up to the failure — similar to Android's
/// "View Error Details" step list.
///
/// Usage:
/// ```swift
/// ErrorActivityTracker.shared.log("Initiating borrow for '\(book.title)'")
/// ErrorActivityTracker.shared.log("Requesting loan from \(url)")
/// ErrorActivityTracker.shared.log("Received HTTP \(statusCode)")
/// ```
actor ErrorActivityTracker {
  static let shared = ErrorActivityTracker()

  /// A single timestamped activity entry.
  struct Activity: Sendable {
    let timestamp: Date
    let message: String
    let category: Category
    let file: String
    let line: Int

    /// Activity categories for filtering and display.
    enum Category: String, Sendable {
      case network = "Network"
      case borrow = "Borrow"
      case download = "Download"
      case auth = "Auth"
      case drm = "DRM"
      case ui = "UI"
      case general = "General"
    }
  }

  private var activities: [Activity] = []
  private let maxEntries = 200

  private init() {}

  // MARK: - Logging

  /// Logs an activity with automatic file/line capture.
  func log(
    _ message: String,
    category: Activity.Category = .general,
    file: String = #fileID,
    line: Int = #line
  ) {
    let activity = Activity(
      timestamp: Date(),
      message: message,
      category: category,
      file: file,
      line: line
    )

    activities.append(activity)

    // Trim to ring buffer size
    if activities.count > maxEntries {
      activities.removeFirst(activities.count - maxEntries)
    }
  }

  // MARK: - Snapshot

  /// Returns a snapshot of all recent activities (newest last).
  func snapshot() -> [Activity] {
    return activities
  }

  /// Returns activities from the last N seconds.
  func recentActivities(seconds: TimeInterval = 300) -> [Activity] {
    let cutoff = Date().addingTimeInterval(-seconds)
    return activities.filter { $0.timestamp >= cutoff }
  }

  /// Clears all tracked activities.
  func clear() {
    activities.removeAll()
  }
}

// MARK: - Formatting

extension ErrorActivityTracker.Activity {
  private static let formatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f
  }()

  /// Formats the activity as a single display line.
  var displayString: String {
    let time = Self.formatter.string(from: timestamp)
    return "[\(time)] [\(category.rawValue)] \(message)"
  }

  /// The short source location (e.g. "MyBooksDownloadCenter.swift:42").
  var shortSource: String {
    let fileName = (file as NSString).lastPathComponent
    return "\(fileName):\(line)"
  }
}
