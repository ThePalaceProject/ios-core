//
//  CarModeViewModelTests.swift
//  PalaceTests
//
//  Tests for CarModeViewModel: playback control, speed changes,
//  sleep timer state, skip forward/back, and chapter navigation.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Combine
@testable import Palace
import XCTest

// MARK: - CarModeViewModelTests

@MainActor
final class CarModeViewModelTests: XCTestCase {

    private var mockService: MockCarModeService!
    private var viewModel: CarModeViewModel!
    private var cancellables: Set<AnyCancellable>!

    override func setUp() {
        super.setUp()
        cancellables = []
        mockService = MockCarModeService()
        viewModel = CarModeViewModel(service: mockService)
    }

    override func tearDown() {
        cancellables = nil
        viewModel = nil
        mockService = nil
        super.tearDown()
    }

    // MARK: - Initialization

    func testInit_entersCarMode() {
        XCTAssertTrue(mockService.enterCarModeCalled)
    }

    func testInit_syncsStateFromService() {
        // Give the initial sync a chance to propagate
        mockService.isPlaying = true
        mockService.elapsedTimeFormatted = "5:30"
        mockService.remainingTimeFormatted = "10:15"
        mockService.sendStateUpdate()

        let expectation = expectation(description: "State synced")
        viewModel.$isPlaying
            .dropFirst()
            .first(where: { $0 })
            .sink { _ in expectation.fulfill() }
            .store(in: &cancellables)

        wait(for: [expectation], timeout: 2.0)

        XCTAssertTrue(viewModel.isPlaying)
        XCTAssertEqual(viewModel.elapsedTime, "5:30")
        XCTAssertEqual(viewModel.remainingTime, "10:15")
    }

    // MARK: - Playback Control

    func testTogglePlayback_callsService() {
        viewModel.togglePlayback()
        XCTAssertTrue(mockService.togglePlaybackCalled)
    }

    func testSkipForward_callsService() {
        viewModel.skipForward()
        XCTAssertTrue(mockService.skipForwardCalled)
    }

    func testSkipBack_callsService() {
        viewModel.skipBack()
        XCTAssertTrue(mockService.skipBackCalled)
    }

    func testNextChapter_callsService() {
        viewModel.nextChapter()
        XCTAssertTrue(mockService.nextChapterCalled)
    }

    func testPreviousChapter_callsService() {
        viewModel.previousChapter()
        XCTAssertTrue(mockService.previousChapterCalled)
    }

    // MARK: - Speed Control

    func testSetSpeed_callsService() {
        viewModel.setSpeed(.fast)
        XCTAssertEqual(mockService.lastSpeedSet?.rate, 1.5)
    }

    func testSetSpeed_dismissesPicker() {
        viewModel.showingSpeedPicker = true
        viewModel.setSpeed(.normal)
        XCTAssertFalse(viewModel.showingSpeedPicker)
    }

    func testSpeedLabel_returnsCompactFormat() {
        mockService.playbackSpeedValue = .fast
        mockService.sendStateUpdate()

        let expectation = expectation(description: "Speed synced")
        viewModel.$playbackSpeed
            .dropFirst()
            .first(where: { $0 == 1.5 })
            .sink { _ in expectation.fulfill() }
            .store(in: &cancellables)

        wait(for: [expectation], timeout: 2.0)
        XCTAssertEqual(viewModel.speedLabel, "1.5x")
    }

    // MARK: - Sleep Timer

    func testSetSleepTimer_callsService() {
        viewModel.setSleepTimer(.minutes30)
        XCTAssertEqual(mockService.lastSleepTimerSet, .minutes30)
    }

    func testSetSleepTimer_dismissesPicker() {
        viewModel.showingSleepTimerPicker = true
        viewModel.setSleepTimer(.minutes15)
        XCTAssertFalse(viewModel.showingSleepTimerPicker)
    }

    func testCancelSleepTimer_callsService() {
        viewModel.cancelSleepTimer()
        XCTAssertTrue(mockService.cancelSleepTimerCalled)
    }

    func testCancelSleepTimer_dismissesPicker() {
        viewModel.showingSleepTimerPicker = true
        viewModel.cancelSleepTimer()
        XCTAssertFalse(viewModel.showingSleepTimerPicker)
    }

    // MARK: - Chapter Navigation

    func testJumpToChapter_callsServiceAndDismisses() {
        viewModel.showingChapterList = true
        viewModel.jumpToChapter(at: 3)
        XCTAssertEqual(mockService.lastChapterJumpIndex, 3)
        XCTAssertFalse(viewModel.showingChapterList)
    }

    // MARK: - Exit

    func testExitCarMode_callsServiceAndCallback() {
        var exitCalled = false
        viewModel.onExitCarMode = { exitCalled = true }

        viewModel.exitCarMode()

        XCTAssertTrue(mockService.exitCarModeCalled)
        XCTAssertTrue(exitCalled)
    }

    // MARK: - Progress Calculation

    func testProgress_calculatesFromServiceTiming() {
        mockService.elapsedSecondsValue = 300
        mockService.chapterDurationSecondsValue = 600
        mockService.sendStateUpdate()

        let expectation = expectation(description: "Progress synced")
        viewModel.$progress
            .dropFirst()
            .first(where: { $0 > 0 })
            .sink { _ in expectation.fulfill() }
            .store(in: &cancellables)

        wait(for: [expectation], timeout: 2.0)
        XCTAssertEqual(viewModel.progress, 0.5, accuracy: 0.01)
    }

    func testProgress_clampsToOne() {
        mockService.elapsedSecondsValue = 700
        mockService.chapterDurationSecondsValue = 600
        mockService.sendStateUpdate()

        let expectation = expectation(description: "Progress synced")
        viewModel.$progress
            .dropFirst()
            .first(where: { $0 > 0 })
            .sink { _ in expectation.fulfill() }
            .store(in: &cancellables)

        wait(for: [expectation], timeout: 2.0)
        XCTAssertEqual(viewModel.progress, 1.0, accuracy: 0.01)
    }

    func testProgress_zeroWhenNoDuration() {
        mockService.elapsedSecondsValue = 100
        mockService.chapterDurationSecondsValue = 0
        mockService.sendStateUpdate()

        // Give time for any sync
        let expectation = expectation(description: "Wait")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { expectation.fulfill() }
        wait(for: [expectation], timeout: 2.0)

        XCTAssertEqual(viewModel.progress, 0)
    }
}

// MARK: - MockCarModeService

@MainActor
final class MockCarModeService: CarModeServiceProtocol {

    // State
    var isCarModeActive: Bool = false
    var currentBookInfo: CarModeBookInfo?
    var currentChapterTitle: String = "Test Chapter"
    var chapters: [CarModeChapterInfo] = []
    var isPlaying: Bool = false
    var playbackSpeed: PlaybackSpeed { playbackSpeedValue }
    var playbackSpeedValue: PlaybackSpeed = .normal
    var sleepTimerState: SleepTimerState = .inactive
    var elapsedTimeFormatted: String = "0:00"
    var remainingTimeFormatted: String = "0:00"
    var elapsedSeconds: TimeInterval { elapsedSecondsValue }
    var elapsedSecondsValue: TimeInterval = 0
    var chapterDurationSeconds: TimeInterval { chapterDurationSecondsValue }
    var chapterDurationSecondsValue: TimeInterval = 0

    private let _stateSubject = PassthroughSubject<Void, Never>()
    var statePublisher: AnyPublisher<Void, Never> {
        _stateSubject.eraseToAnyPublisher()
    }

    func sendStateUpdate() {
        _stateSubject.send()
    }

    // Call tracking
    var enterCarModeCalled = false
    var exitCarModeCalled = false
    var togglePlaybackCalled = false
    var skipForwardCalled = false
    var skipBackCalled = false
    var nextChapterCalled = false
    var previousChapterCalled = false
    var lastChapterJumpIndex: Int?
    var lastSpeedSet: PlaybackSpeed?
    var lastSleepTimerSet: SleepTimerOption?
    var cancelSleepTimerCalled = false

    func enterCarMode() {
        enterCarModeCalled = true
        isCarModeActive = true
    }

    func exitCarMode() {
        exitCarModeCalled = true
        isCarModeActive = false
    }

    func togglePlayback() {
        togglePlaybackCalled = true
    }

    func skipForward() {
        skipForwardCalled = true
    }

    func skipBack() {
        skipBackCalled = true
    }

    func nextChapter() {
        nextChapterCalled = true
    }

    func previousChapter() {
        previousChapterCalled = true
    }

    func jumpToChapter(at index: Int) {
        lastChapterJumpIndex = index
    }

    func setSpeed(_ speed: PlaybackSpeed) {
        lastSpeedSet = speed
        playbackSpeedValue = speed
    }

    func setSleepTimer(_ option: SleepTimerOption) {
        lastSleepTimerSet = option
    }

    func cancelSleepTimer() {
        cancelSleepTimerCalled = true
        sleepTimerState = .inactive
    }
}
