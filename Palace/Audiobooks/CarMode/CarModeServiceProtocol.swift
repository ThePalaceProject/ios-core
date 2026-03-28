//
//  CarModeServiceProtocol.swift
//  Palace
//
//  Protocol defining the car mode service interface.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Combine
import Foundation

// MARK: - CarModeServiceProtocol

/// Defines the interface for managing car mode state and playback.
/// Bridges to the existing AudiobookSessionManager for actual playback control.
@MainActor
public protocol CarModeServiceProtocol: AnyObject {

    // MARK: - State Publishers

    /// Whether car mode is currently active.
    var isCarModeActive: Bool { get }

    /// Current book info for display.
    var currentBookInfo: CarModeBookInfo? { get }

    /// Current chapter name.
    var currentChapterTitle: String { get }

    /// All chapters for the current book.
    var chapters: [CarModeChapterInfo] { get }

    /// Whether playback is in progress.
    var isPlaying: Bool { get }

    /// Current playback speed.
    var playbackSpeed: PlaybackSpeed { get }

    /// Current sleep timer state.
    var sleepTimerState: SleepTimerState { get }

    /// Elapsed time in the current chapter (formatted).
    var elapsedTimeFormatted: String { get }

    /// Remaining time in the current chapter (formatted).
    var remainingTimeFormatted: String { get }

    /// Elapsed time in seconds (raw).
    var elapsedSeconds: TimeInterval { get }

    /// Total duration of the current chapter in seconds.
    var chapterDurationSeconds: TimeInterval { get }

    /// Publisher for state changes (for external observation).
    var statePublisher: AnyPublisher<Void, Never> { get }

    // MARK: - Playback Controls

    /// Enters car mode.
    func enterCarMode()

    /// Exits car mode.
    func exitCarMode()

    /// Toggles play/pause.
    func togglePlayback()

    /// Skips forward by the standard amount (30 seconds).
    func skipForward()

    /// Skips backward by the standard amount (15 seconds).
    func skipBack()

    /// Jumps to the next chapter.
    func nextChapter()

    /// Jumps to the previous chapter.
    func previousChapter()

    /// Jumps to a specific chapter by index.
    func jumpToChapter(at index: Int)

    /// Sets the playback speed.
    func setSpeed(_ speed: PlaybackSpeed)

    /// Starts a sleep timer with the given option.
    func setSleepTimer(_ option: SleepTimerOption)

    /// Cancels the active sleep timer.
    func cancelSleepTimer()
}
