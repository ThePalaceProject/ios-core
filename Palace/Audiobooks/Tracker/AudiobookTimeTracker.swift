//
//  AudiobookTimeTracker.swift
//  The Palace Project
//
//  Created by Vladimir Fedorov on 03/07/2023.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import Foundation
import Combine
import ULID

@objc
class AudiobookTimeTracker: NSObject, AudiobookPlaybackTrackerDelegate {
  
  private var subscriptions: Set<AnyCancellable> = []
  private let dataManager: DataManager
  private let libraryId: String
  private let bookId: String
  private let timeTrackingUrl: URL
  private var currentMinute: String
  private var duration: TimeInterval = 0
  private var timeEntryId: ULID = ULID(timestamp: Date())
  
  private let minuteFormatter: DateFormatter
  private let tick: TimeInterval = 1
    
  init(libraryId: String, bookId: String, timeTrackingUrl: URL, dataManager: DataManager) {
    self.libraryId = libraryId
    self.bookId = bookId
    self.timeTrackingUrl = timeTrackingUrl
    self.dataManager = dataManager
    self.minuteFormatter = DateFormatter()
    minuteFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm'Z'"
    minuteFormatter.timeZone = TimeZone(identifier: "UTC")
    currentMinute = minuteFormatter.string(from: Date())
  }
  
  @objc
  convenience init(libraryId: String, bookId: String, timeTrackingUrl: URL) {
    self.init(
      libraryId: libraryId,
      bookId: bookId,
      timeTrackingUrl: timeTrackingUrl,
      dataManager: AudiobookDataManager.shared
    )
  }

  var timeEntry: AudiobookTimeEntry {
    AudiobookTimeEntry(
      id: timeEntryId.ulidString,
      bookId: bookId,
      libraryId: libraryId,
      timeTrackingUrl: timeTrackingUrl,
      duringMinute: currentMinute,
      duration: min(60, Int(duration))
    )
  }
  
  deinit {
    subscriptions.removeAll()
    saveCurrentDuration()
  }
    
  func receiveValue(_ value: Date) {
    duration += tick
    let minute = minuteFormatter.string(from: value)
    if minute != currentMinute {
      saveCurrentDuration(date: value)
      currentMinute = minute
    }
  }

  private func saveCurrentDuration(date: Date = Date()) {
    if duration > 0 {
      timeEntryId = ULID(timestamp: date) // timeEntryId value updates once every minute
      dataManager.save(time: timeEntry)
      duration = 0
    }
  }
  
  // MARK: - AudiobookPlaybackTrackerDelegate
  
  func playbackStarted() {
    Timer.publish(every: tick, on: .main, in: .default)
      .autoconnect()
      .sink(receiveValue: receiveValue)
      .store(in: &subscriptions)
  }
  
  func playbackStopped() {
    subscriptions.removeAll()
  }

}
