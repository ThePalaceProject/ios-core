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
import UIKit
import PalaceAudiobookToolkit

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
  // Serial queue for thread-safe access to duration and other mutable state
  private let syncQueue = DispatchQueue(label: "com.audiobook.timeTracker")

  private let minuteFormatter: DateFormatter
  private let tick: TimeInterval = 1
  private var isPlaying = false
  private var playbackTimer: Cancellable?
  private var terminationObserver: NSObjectProtocol?

  private let audiobookLogger = AudiobookFileLogger.shared

  init(libraryId: String, bookId: String, timeTrackingUrl: URL, dataManager: DataManager) {
    self.libraryId = libraryId
    self.bookId = bookId
    self.timeTrackingUrl = timeTrackingUrl
    self.dataManager = dataManager
    self.minuteFormatter = DateFormatter()
    minuteFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm'Z'"
    minuteFormatter.timeZone = TimeZone(identifier: "UTC")
    currentMinute = minuteFormatter.string(from: Date())

    super.init()
    
    // Register for app termination to ensure data is saved
    // This is critical because deinit timing is unreliable with ARC
    terminationObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.willTerminateNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.stopAndSave()
    }

    audiobookLogger.logEvent(forBookId: bookId, event: "TimeTracker initialized for bookId: \(bookId)")
  }

  @objc
  convenience init(libraryId: String, bookId: String, timeTrackingUrl: URL) {
    self.init(
      libraryId: libraryId,
      bookId: bookId,
      timeTrackingUrl: timeTrackingUrl,
      dataManager: AudiobookDataManager()
    )
  }

  /// Thread-safe access to current time entry snapshot
  /// Use this property when accessing from outside the syncQueue
  var timeEntry: AudiobookTimeEntry {
    syncQueue.sync {
      createTimeEntry()
    }
  }
  
  /// Internal method to create time entry - must be called from within syncQueue
  private func createTimeEntry() -> AudiobookTimeEntry {
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
    if let observer = terminationObserver {
      NotificationCenter.default.removeObserver(observer)
    }
    stopAndSave()
  }
  
  /// Stops playback and saves any accumulated time.
  /// Call this method explicitly when done tracking to ensure all data is saved.
  /// Note: Relying on deinit for saving is unreliable as ARC doesn't guarantee immediate deallocation.
  func stopAndSave() {
    playbackTimer?.cancel()
    subscriptions.removeAll()
    // Use sync to ensure all pending receiveValue() calls complete, then save
    syncQueue.sync {
      self.saveCurrentDuration()
    }
    audiobookLogger.logEvent(forBookId: bookId, event: "TimeTracker stopped and saved for bookId: \(bookId)")
  }

  func receiveValue(_ value: Date) {
    syncQueue.async { [weak self] in
      guard let self = self else { return }

      self.duration += self.tick
      let minute = self.minuteFormatter.string(from: value)

      if minute != self.currentMinute {
        self.saveCurrentDuration(date: value)
        self.currentMinute = minute
      }
    }
  }

  /// Must be called from within syncQueue to avoid race conditions
  private func saveCurrentDuration(date: Date = Date()) {
    if duration > 0 {
      timeEntryId = ULID(timestamp: date)
      // Use createTimeEntry() directly since we're already on syncQueue
      dataManager.save(time: createTimeEntry())

      audiobookLogger.logEvent(forBookId: bookId, event: "Time entry saved for minute \(currentMinute), \(min(60, Int(duration))) seconds played.")

      duration = 0
    }
  }

  // MARK: - AudiobookPlaybackTrackerDelegate

  func playbackStarted() {
    // Cancel any existing timer to prevent multiple concurrent timers
    // This prevents overcounting when playbackStarted is called multiple times
    playbackTimer?.cancel()
    
    if !isPlaying {
      audiobookLogger.logEvent(forBookId: bookId, event: "Playback started for bookId: \(bookId)")
      isPlaying = true
    }

    // Use .common RunLoop mode to ensure timer fires even during UI scrolling/interactions
    playbackTimer = Timer.publish(every: tick, on: .main, in: .common)
      .autoconnect()
      .sink { [weak self] value in
        self?.receiveValue(value)
      }

    playbackTimer?.store(in: &subscriptions)
  }

  func playbackStopped() {
    // Save accumulated time BEFORE canceling timer
    // This ensures no data is lost when playback stops (sleep timer, pause, chapter change)
    // Use sync to wait for all pending receiveValue() calls to complete, then save
    syncQueue.sync {
      self.saveCurrentDuration()
    }
    
    if isPlaying {
      audiobookLogger.logEvent(forBookId: bookId, event: "Playback stopped for bookId: \(bookId)")
      isPlaying = false
    }

    playbackTimer?.cancel()
    subscriptions.removeAll()
  }
}
