//
//  DataManager.swift
//  NYPLAudiobookToolkit
//
//  Created by Vladimir Fedorov on 03/07/2023.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import Foundation

public protocol TimeEntry {
  var id: String { get }
  var bookId: String { get }
  var libraryId: String { get }
  var timeTrackingUrl: URL { get }
  var duringMinute: String { get }
  var duration: Int { get }
}

public protocol DataManager {
  func save(time: TimeEntry)
}

