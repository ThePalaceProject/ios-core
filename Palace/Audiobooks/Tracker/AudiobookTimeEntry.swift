//
//  AudiobookTimeEntry.swift
//  The Palace Project
//
//  Created by Vladimir Fedorov on 03/07/2023.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import Foundation

/// Audiobook time entry
///
/// Implements `DataManager` `TimeEntry` protocol
struct AudiobookTimeEntry: TimeEntry, Codable, Hashable {
  let id: String
  let bookId: String
  let libraryId: String
  let timeTrackingUrl: URL
  let duringMinute: String
  let duration: Int
}
