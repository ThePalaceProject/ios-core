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

/// - Sendable invariant: instances are captured by the `willTerminateNotification`
///   observer (`queue: .main`), the `syncQueue.async` body in `receiveValue`, and
///   the Combine `Timer.publish(on: .main)` sink. Safe to share across those
///   boundaries because:
///   1. Every stored dependency (`dataManager`, `libraryId`, `bookId`,
///      `timeTrackingUrl`, `syncQueue`, `tick`, `audiobookLogger`)
///      is a `let` — immutable after `init`.
///   2. The mutable counters (`duration`, `currentMinute`, `currentMinuteIndex`,
///      `timeEntryId`) are read
///      and written ONLY through the serial `syncQueue` (`.sync`/`.async`).
///   3. The playback-lifecycle state (`isPlaying`, `playbackTimer`, `subscriptions`)
///      is touched only from the `AudiobookPlaybackTrackerDelegate` callbacks and
///      the main-scheduled Timer sink — i.e. the main runloop — never concurrently.
///   Hence `@unchecked Sendable`: the `syncQueue`/main-runloop discipline is the
///   invariant the compiler cannot see, and `DataManager` is not Sendable-audited.
@objc
class AudiobookTimeTracker: NSObject, AudiobookPlaybackTrackerDelegate, @unchecked Sendable {

    private var subscriptions: Set<AnyCancellable> = []
    private let dataManager: DataManager
    private let libraryId: String
    private let bookId: String
    private let timeTrackingUrl: URL
    private var currentMinute: String
    private var currentMinuteIndex: Int64
    private var duration: TimeInterval = 0
    private var timeEntryId: ULID = ULID(timestamp: Date())
    // Serial queue for thread-safe access to duration and other mutable state
    private let syncQueue = DispatchQueue(label: "com.audiobook.timeTracker")

    private let tick: TimeInterval = 1
    private var isPlaying = false
    private var playbackTimer: Cancellable?
    private var terminationObserver: NSObjectProtocol?

    private let audiobookLogger: AudiobookFileLogger

    init(libraryId: String, bookId: String, timeTrackingUrl: URL, dataManager: DataManager, audiobookLogger: AudiobookFileLogger = .shared) {
        self.libraryId = libraryId
        self.bookId = bookId
        self.timeTrackingUrl = timeTrackingUrl
        self.dataManager = dataManager
        self.audiobookLogger = audiobookLogger
        let now = Date()
        currentMinute = Self.minuteString(for: now)
        currentMinuteIndex = Self.minuteIndex(of: now)

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

    /// Locale left at the default, as the per-instance formatter had it.
    private static let minuteFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    /// The UTC minute key a time entry is filed under, e.g. "2023-11-14T22:13Z".
    static func minuteString(for date: Date) -> String {
        minuteFormatter.string(from: date)
    }

    /// Whole UTC minutes since 1970. Changes exactly where `minuteString(for:)`
    /// changes, so the 1 Hz tick compares integers and formats a string only
    /// once per minute.
    static func minuteIndex(of date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 / 60).rounded(.down))
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

            let minuteIndex = Self.minuteIndex(of: value)
            if minuteIndex != self.currentMinuteIndex {
                self.saveCurrentDuration(date: value)
                self.currentMinute = Self.minuteString(for: value)
                self.currentMinuteIndex = minuteIndex
            }
            self.duration += self.tick
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
