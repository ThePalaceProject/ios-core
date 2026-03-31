//
//  CarModeViewModel.swift
//  Palace
//
//  ViewModel for the car mode fullscreen view.
//  Provides simplified, glanceable state and large-target actions for driving.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Combine
import Foundation
import SwiftUI

// MARK: - CarModeViewModel

@MainActor
public final class CarModeViewModel: ObservableObject {

    // MARK: - Published State

    @Published public var isPlaying: Bool = false
    @Published public var currentBook: CarModeBookInfo?
    @Published public var currentChapter: String = ""
    @Published public var playbackSpeed: Double = 1.0
    @Published public var sleepTimer: SleepTimerState = .inactive
    @Published public var elapsedTime: String = "0:00"
    @Published public var remainingTime: String = "0:00"
    @Published public var chapters: [CarModeChapterInfo] = []
    @Published public var progress: Double = 0

    /// Whether the speed picker sheet is showing.
    @Published public var showingSpeedPicker: Bool = false

    /// Whether the sleep timer picker sheet is showing.
    @Published public var showingSleepTimerPicker: Bool = false

    /// Whether the chapter list sheet is showing.
    @Published public var showingChapterList: Bool = false

    // MARK: - Dependencies

    private let service: CarModeServiceProtocol
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Callbacks

    /// Called when the user exits car mode.
    public var onExitCarMode: (() -> Void)?

    // MARK: - Initialization

    public init(service: CarModeServiceProtocol) {
        self.service = service
        setupBindings()
        service.enterCarMode()
    }

    // MARK: - Actions

    public func togglePlayback() {
        service.togglePlayback()
    }

    /// Skips forward 30 seconds.
    public func skipForward() {
        service.skipForward()
    }

    /// Skips back 15 seconds.
    public func skipBack() {
        service.skipBack()
    }

    public func nextChapter() {
        service.nextChapter()
    }

    public func previousChapter() {
        service.previousChapter()
    }

    public func setSpeed(_ speed: PlaybackSpeed) {
        service.setSpeed(speed)
        showingSpeedPicker = false
    }

    public func setSleepTimer(_ option: SleepTimerOption) {
        service.setSleepTimer(option)
        showingSleepTimerPicker = false
    }

    public func cancelSleepTimer() {
        service.cancelSleepTimer()
        showingSleepTimerPicker = false
    }

    public func jumpToChapter(at index: Int) {
        service.jumpToChapter(at: index)
        showingChapterList = false
    }

    public func exitCarMode() {
        service.exitCarMode()
        onExitCarMode?()
    }

    // MARK: - Computed Properties

    /// The playback speed as a compact display string.
    public var speedLabel: String {
        PlaybackSpeed(rate: playbackSpeed, presetName: nil).compactLabel
    }

    // MARK: - Private

    private func setupBindings() {
        // Bind service state to our published properties.
        // We use the service's ObjectWillChange (via statePublisher + individual properties).

        // Combine all the service's published properties into our own.
        // We poll on state changes since the protocol uses concrete published properties.

        service.statePublisher
            .merge(with: Just(()))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.syncFromService()
            }
            .store(in: &cancellables)

        // Also observe on a timer for smooth time updates (service position may update frequently)
        Timer.publish(every: 0.5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.syncTimingFromService()
            }
            .store(in: &cancellables)
    }

    private func syncFromService() {
        isPlaying = service.isPlaying
        currentBook = service.currentBookInfo
        currentChapter = service.currentChapterTitle
        playbackSpeed = service.playbackSpeed.rate
        sleepTimer = service.sleepTimerState
        chapters = service.chapters
        syncTimingFromService()
    }

    private func syncTimingFromService() {
        elapsedTime = service.elapsedTimeFormatted
        remainingTime = service.remainingTimeFormatted

        // Calculate chapter progress
        let duration = service.chapterDurationSeconds
        if duration > 0 {
            progress = min(1.0, service.elapsedSeconds / duration)
        } else {
            progress = 0
        }
    }
}
