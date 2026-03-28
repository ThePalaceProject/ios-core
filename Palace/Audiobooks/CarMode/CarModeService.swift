//
//  CarModeService.swift
//  Palace
//
//  Manages car mode state and bridges to AudiobookSessionManager for playback.
//  Handles sleep timer countdown, speed changes, and Bluetooth auto-activation.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import AVFoundation
import Combine
import Foundation
import PalaceAudiobookToolkit
import UIKit

// MARK: - CarModeService

@MainActor
public final class CarModeService: ObservableObject, CarModeServiceProtocol {

    // MARK: - Configuration

    private enum Config {
        static let skipForwardInterval: TimeInterval = 30
        static let skipBackInterval: TimeInterval = 15
        static let timerTickInterval: TimeInterval = 1.0
    }

    // MARK: - Published Properties

    @Published public private(set) var isCarModeActive: Bool = false
    @Published public private(set) var currentBookInfo: CarModeBookInfo?
    @Published public private(set) var currentChapterTitle: String = ""
    @Published public private(set) var chapters: [CarModeChapterInfo] = []
    @Published public private(set) var isPlaying: Bool = false
    @Published public private(set) var playbackSpeed: PlaybackSpeed = .normal
    @Published public private(set) var sleepTimerState: SleepTimerState = .inactive
    @Published public private(set) var elapsedTimeFormatted: String = "0:00"
    @Published public private(set) var remainingTimeFormatted: String = "0:00"
    @Published public private(set) var elapsedSeconds: TimeInterval = 0
    @Published public private(set) var chapterDurationSeconds: TimeInterval = 0

    // MARK: - State Publisher

    private let _stateSubject = PassthroughSubject<Void, Never>()
    public var statePublisher: AnyPublisher<Void, Never> {
        _stateSubject.eraseToAnyPublisher()
    }

    // MARK: - Dependencies

    private let sessionManager: AudiobookSessionManager

    // MARK: - Internal State

    private var cancellables = Set<AnyCancellable>()
    private var sleepTimerCancellable: AnyCancellable?
    private var sleepTimerRemaining: TimeInterval = 0
    private var sleepTimerOption: SleepTimerOption?

    // MARK: - Initialization

    public init(sessionManager: AudiobookSessionManager = .shared) {
        self.sessionManager = sessionManager
        setupSubscriptions()
        Log.info(#file, "CarModeService initialized")
    }

    // MARK: - CarModeServiceProtocol

    public func enterCarMode() {
        guard !isCarModeActive else { return }
        isCarModeActive = true
        syncStateFromSession()
        _stateSubject.send()
        Log.info(#file, "Car mode entered")
    }

    public func exitCarMode() {
        guard isCarModeActive else { return }
        isCarModeActive = false
        cancelSleepTimer()
        _stateSubject.send()
        Log.info(#file, "Car mode exited")
    }

    public func togglePlayback() {
        sessionManager.togglePlayPause()
        Log.debug(#file, "Toggled playback")
    }

    public func skipForward() {
        guard let manager = sessionManager.manager else {
            Log.warn(#file, "Cannot skip forward - no active manager")
            return
        }

        let player = manager.audiobook.player
        guard let currentPosition = player.currentTrackPosition else { return }

        let newOffset = currentPosition.timestamp + Config.skipForwardInterval
        let track = currentPosition.track

        // If skip would go past the end of this track, move to next chapter
        if newOffset >= track.duration {
            nextChapter()
        } else {
            let newPosition = TrackPosition(track: track, timestamp: newOffset, tracks: manager.audiobook.tableOfContents.tracks)
            player.play(at: newPosition, completion: nil)
        }

        Log.debug(#file, "Skipped forward \(Config.skipForwardInterval)s")
    }

    public func skipBack() {
        guard let manager = sessionManager.manager else {
            Log.warn(#file, "Cannot skip back - no active manager")
            return
        }

        let player = manager.audiobook.player
        guard let currentPosition = player.currentTrackPosition else { return }

        let newOffset = max(0, currentPosition.timestamp - Config.skipBackInterval)
        let track = currentPosition.track

        let newPosition = TrackPosition(track: track, timestamp: newOffset, tracks: manager.audiobook.tableOfContents.tracks)
        player.play(at: newPosition, completion: nil)

        Log.debug(#file, "Skipped back \(Config.skipBackInterval)s")
    }

    public func nextChapter() {
        let chapters = sessionManager.currentChapters
        guard let current = sessionManager.currentChapter,
              let currentIndex = chapters.firstIndex(where: { $0.position.track.key == current.position.track.key }),
              currentIndex + 1 < chapters.count else {
            Log.debug(#file, "No next chapter available")
            return
        }

        sessionManager.skipToChapter(at: currentIndex + 1)
        Log.debug(#file, "Moved to next chapter")
    }

    public func previousChapter() {
        let chapters = sessionManager.currentChapters
        guard let current = sessionManager.currentChapter,
              let currentIndex = chapters.firstIndex(where: { $0.position.track.key == current.position.track.key }),
              currentIndex > 0 else {
            Log.debug(#file, "No previous chapter available")
            return
        }

        sessionManager.skipToChapter(at: currentIndex - 1)
        Log.debug(#file, "Moved to previous chapter")
    }

    public func jumpToChapter(at index: Int) {
        sessionManager.skipToChapter(at: index)
        Log.debug(#file, "Jumped to chapter at index \(index)")
    }

    public func setSpeed(_ speed: PlaybackSpeed) {
        guard let player = sessionManager.manager?.audiobook.player else {
            Log.warn(#file, "Cannot set speed - no active player")
            return
        }

        player.playbackRate = speed.toolkitRate
        playbackSpeed = speed
        sessionManager.nowPlayingCoordinator?.updatePlaybackRate(speed.toolkitRate)
        _stateSubject.send()

        Log.debug(#file, "Playback speed set to \(speed.compactLabel)")
    }

    public func setSleepTimer(_ option: SleepTimerOption) {
        // Cancel any existing timer
        sleepTimerCancellable?.cancel()
        sleepTimerCancellable = nil

        sleepTimerOption = option

        if option == .endOfChapter {
            sleepTimerState = .endOfChapter
            _stateSubject.send()
            Log.info(#file, "Sleep timer set: end of chapter")
            return
        }

        guard let duration = option.duration else { return }

        sleepTimerRemaining = duration
        sleepTimerState = .active(remaining: duration, option: option)
        _stateSubject.send()

        // Start countdown timer
        sleepTimerCancellable = Timer.publish(every: Config.timerTickInterval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.tickSleepTimer()
            }

        Log.info(#file, "Sleep timer set: \(option.displayName)")
    }

    public func cancelSleepTimer() {
        sleepTimerCancellable?.cancel()
        sleepTimerCancellable = nil
        sleepTimerRemaining = 0
        sleepTimerOption = nil
        sleepTimerState = .inactive
        _stateSubject.send()
        Log.info(#file, "Sleep timer cancelled")
    }

    // MARK: - Private Methods

    private func setupSubscriptions() {
        // Observe playback state
        sessionManager.playbackStatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.syncStateFromSession()
            }
            .store(in: &cancellables)

        // Observe chapter changes
        sessionManager.chapterUpdatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.syncChaptersFromSession()
                self?.checkEndOfChapterTimer()
            }
            .store(in: &cancellables)

        // Observe position updates for timing display
        sessionManager.$currentPosition
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateTimingDisplay()
            }
            .store(in: &cancellables)

        // Observe isPlaying
        sessionManager.$isPlaying
            .receive(on: DispatchQueue.main)
            .assign(to: &$isPlaying)

        // Observe cover image changes
        sessionManager.$coverImage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateBookInfo()
            }
            .store(in: &cancellables)
    }

    private func syncStateFromSession() {
        updateBookInfo()
        syncChaptersFromSession()
        updateTimingDisplay()
        updateSpeedFromPlayer()
        _stateSubject.send()
    }

    private func updateBookInfo() {
        guard let book = sessionManager.currentBook else {
            currentBookInfo = nil
            return
        }

        let manager = sessionManager.manager
        let totalDuration: TimeInterval? = manager.map { mgr in
            mgr.audiobook.tableOfContents.tracks.reduce(0) { $0 + $1.duration }
        }

        // Calculate overall progress
        var progress: Double = 0
        if let totalDuration = totalDuration, totalDuration > 0,
           let position = sessionManager.currentPosition {
            let tracks = manager?.audiobook.tableOfContents.tracks ?? []
            var elapsed: TimeInterval = 0
            for track in tracks {
                if track.key == position.track.key {
                    elapsed += position.timestamp
                    break
                }
                elapsed += track.duration
            }
            progress = min(1.0, elapsed / totalDuration)
        }

        currentBookInfo = CarModeBookInfo(
            identifier: book.identifier,
            title: book.title,
            author: book.authors,
            coverImage: sessionManager.coverImage,
            totalDuration: totalDuration,
            progress: progress
        )
    }

    private func syncChaptersFromSession() {
        let sessionChapters = sessionManager.currentChapters
        let current = sessionManager.currentChapter

        currentChapterTitle = current?.title ?? "Unknown Chapter"

        chapters = sessionChapters.enumerated().map { index, chapter in
            CarModeChapterInfo(
                index: index,
                title: chapter.title ?? "Chapter \(index + 1)",
                duration: chapter.duration,
                isCurrent: chapter.position.track.key == current?.position.track.key
            )
        }
    }

    private func updateTimingDisplay() {
        guard let manager = sessionManager.manager else {
            elapsedTimeFormatted = "0:00"
            remainingTimeFormatted = "0:00"
            elapsedSeconds = 0
            chapterDurationSeconds = 0
            return
        }

        let offset = manager.currentOffset
        let duration = manager.currentDuration

        elapsedSeconds = offset
        chapterDurationSeconds = duration

        elapsedTimeFormatted = Self.formatTime(offset)
        remainingTimeFormatted = Self.formatTime(max(0, duration - offset))
    }

    private func updateSpeedFromPlayer() {
        guard let player = sessionManager.manager?.audiobook.player else { return }
        playbackSpeed = PlaybackSpeed.from(toolkitRate: player.playbackRate)
    }

    private func tickSleepTimer() {
        guard sleepTimerRemaining > 0 else {
            triggerSleepTimerExpiry()
            return
        }

        sleepTimerRemaining -= Config.timerTickInterval

        if sleepTimerRemaining <= 0 {
            triggerSleepTimerExpiry()
        } else if let option = sleepTimerOption {
            sleepTimerState = .active(remaining: sleepTimerRemaining, option: option)
        }
    }

    private func checkEndOfChapterTimer() {
        guard sleepTimerOption == .endOfChapter else { return }
        // When the chapter changes and we have an end-of-chapter timer, pause
        triggerSleepTimerExpiry()
    }

    private func triggerSleepTimerExpiry() {
        Log.info(#file, "Sleep timer expired - pausing playback")
        sessionManager.pause()
        cancelSleepTimer()
    }

    // MARK: - Formatting Helpers

    static func formatTime(_ seconds: TimeInterval) -> String {
        let totalSeconds = max(0, Int(seconds))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}
