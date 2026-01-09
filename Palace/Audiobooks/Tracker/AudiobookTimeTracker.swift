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
  private let syncQueue = DispatchQueue(label: "com.audiobook.timeTracker", attributes: .concurrent)

  private let minuteFormatter: DateFormatter
  private let tick: TimeInterval = 1
  private var isPlaying = false
  private var playbackTimer: Cancellable?

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
    stopAndSave()
  }
  
  /// Stops playback and saves any accumulated time.
  /// Call this method explicitly when done tracking to ensure all data is saved.
  /// Note: Relying on deinit for saving is unreliable as ARC doesn't guarantee immediate deallocation.
  func stopAndSave() {
    playbackTimer?.cancel()
    subscriptions.removeAll()
    saveCurrentDuration()
    audiobookLogger.logEvent(forBookId: bookId, event: "TimeTracker stopped and saved for bookId: \(bookId)")
  }

  func receiveValue(_ value: Date) {
    syncQueue.async(flags: .barrier) { [weak self] in
      guard let self = self else { return }

      self.duration += self.tick
      let minute = self.minuteFormatter.string(from: value)

      if minute != self.currentMinute {
        self.saveCurrentDuration(date: value)
        self.currentMinute = minute
      }
    }
  }

  private func saveCurrentDuration(date: Date = Date()) {
    if duration > 0 {
      timeEntryId = ULID(timestamp: date)
      dataManager.save(time: timeEntry)

      audiobookLogger.logEvent(forBookId: bookId, event: "Time entry saved for minute \(currentMinute), \(min(60, Int(duration))) seconds played.")

      duration = 0
    }
  }

  // MARK: - AudiobookPlaybackTrackerDelegate

  func playbackStarted() {
    if !isPlaying {
      audiobookLogger.logEvent(forBookId: bookId, event: "Playback started for bookId: \(bookId)")
      isPlaying = true
    }

    playbackTimer = Timer.publish(every: tick, on: .main, in: .default)
      .autoconnect()
      .sink { [weak self] value in
        self?.receiveValue(value)
      }

    playbackTimer?.store(in: &subscriptions)
  }

  func playbackStopped() {
    if isPlaying {
      audiobookLogger.logEvent(forBookId: bookId, event: "Playback stopped for bookId: \(bookId)")
      isPlaying = false
    }

    playbackTimer?.cancel()
    subscriptions.removeAll()
  }
}
