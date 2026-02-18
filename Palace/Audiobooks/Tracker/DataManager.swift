//
//  DataManager.swift
//  The Palace Project
//
//  Created by Vladimir Fedorov on 03/07/2023.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import Foundation

/// Tracked time entry for DataManager internal storage
public protocol TimeEntry {
  /// Unique entry identifier
  var id: String { get }
  /// Book identifier
  var bookId: String { get }
  /// Library identifier
  var libraryId: String { get }
  /// URL for tracked time synchronization, time entries are uploaded to this URL
  var timeTrackingUrl: URL { get }
  /// Tracked minute
  var duringMinute: String { get }
  /// Number of seconds, 1...60, withing tracked minute
  var duration: Int { get }
}

/// Data Manager.
public protocol DataManager {
  /// Save tracked time
  /// - Parameter time: Time entry.
  func save(time: TimeEntry)
}

