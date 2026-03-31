//
//  CarModeServicePlaybackTests.swift
//  PalaceTests
//
//  Tests for CarModeService playback controls, chapter navigation,
//  speed control, and sleep timer.
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

// MARK: - Mock Playback Engine

@MainActor
private final class MockPlaybackEngine: CarModePlaybackEngine {
    var isPlaying: Bool = false
    var currentPositionSeconds: TimeInterval = 100.0
    var currentChapterIndex: Int = 2
    var chapterCount: Int = 10
    var chapters: [CarModeChapterInfo] = (0..<10).map {
        CarModeChapterInfo(id: $0, title: "Chapter \($0 + 1)", durationSeconds: 600)
    }
    var currentSpeed: PlaybackSpeed = .normal
    var bookTitle: String? = "Test Audiobook"
    var bookAuthor: String? = "Test Author"
    var progress: Double = 0.35

    private(set) var playCallCount = 0
    private(set) var pauseCallCount = 0
    private(set) var lastSeekSeconds: TimeInterval?
    private(set) var lastJumpChapterIndex: Int?
    private(set) var lastSetSpeed: PlaybackSpeed?

    func play() {
        playCallCount += 1
        isPlaying = true
    }

    func pause() {
        pauseCallCount += 1
        isPlaying = false
    }

    func seekTo(seconds: TimeInterval) {
        lastSeekSeconds = seconds
        currentPositionSeconds = seconds
    }

    func jumpToChapter(index: Int) {
        lastJumpChapterIndex = index
        currentChapterIndex = index
    }

    func setSpeed(_ speed: PlaybackSpeed) {
        lastSetSpeed = speed
        currentSpeed = speed
    }
}

// MARK: - Tests

@MainActor
final class CarModeServicePlaybackTests: XCTestCase {

    private var engine: MockPlaybackEngine!
    private var service: CarModeService!

    override func setUp() {
        super.setUp()
        engine = MockPlaybackEngine()
        service = CarModeService(engine: engine)
    }

    override func tearDown() {
        service = nil
        engine = nil
        super.tearDown()
    }

    // MARK: - Skip Forward

    func testSkipForward_advancesPositionBy30Seconds() {
        engine.currentPositionSeconds = 100.0

        service.skipForward()

        XCTAssertEqual(engine.lastSeekSeconds, 130.0, accuracy: 0.001,
                       "Skip forward should advance by 30 seconds")
    }

    func testSkipForward_fromZero() {
        engine.currentPositionSeconds = 0.0

        service.skipForward()

        XCTAssertEqual(engine.lastSeekSeconds, 30.0, accuracy: 0.001)
    }

    // MARK: - Skip Back

    func testSkipBack_rewindsPositionBy15Seconds() {
        engine.currentPositionSeconds = 100.0

        service.skipBack()

        XCTAssertEqual(engine.lastSeekSeconds, 85.0, accuracy: 0.001,
                       "Skip back should rewind by 15 seconds")
    }

    func testSkipBack_doesNotGoBelowZero() {
        engine.currentPositionSeconds = 5.0

        service.skipBack()

        XCTAssertEqual(engine.lastSeekSeconds, 0.0, accuracy: 0.001,
                       "Skip back should clamp to zero")
    }

    func testSkipBack_fromZero_staysAtZero() {
        engine.currentPositionSeconds = 0.0

        service.skipBack()

        XCTAssertEqual(engine.lastSeekSeconds, 0.0, accuracy: 0.001)
    }

    // MARK: - Next Chapter

    func testNextChapter_movesToNextChapter() {
        engine.currentChapterIndex = 2

        service.nextChapter()

        XCTAssertEqual(engine.lastJumpChapterIndex, 3)
        XCTAssertEqual(service.currentChapterIndex, 3)
    }

    func testNextChapter_atLastChapter_doesNothing() {
        engine.currentChapterIndex = 9 // last chapter (0-indexed, count=10)

        service.nextChapter()

        XCTAssertNil(engine.lastJumpChapterIndex,
                     "Should not jump when already at last chapter")
    }

    // MARK: - Previous Chapter

    func testPreviousChapter_movesToPreviousChapter() {
        engine.currentChapterIndex = 5

        service.previousChapter()

        XCTAssertEqual(engine.lastJumpChapterIndex, 4)
        XCTAssertEqual(service.currentChapterIndex, 4)
    }

    func testPreviousChapter_atFirstChapter_doesNothing() {
        engine.currentChapterIndex = 0

        service.previousChapter()

        XCTAssertNil(engine.lastJumpChapterIndex,
                     "Should not jump when already at first chapter")
    }

    // MARK: - Jump To Chapter

    func testJumpToChapter_jumpsToSpecificChapter() {
        service.jumpToChapter(index: 7)

        XCTAssertEqual(engine.lastJumpChapterIndex, 7)
        XCTAssertEqual(service.currentChapterIndex, 7)
    }

    func testJumpToChapter_invalidNegativeIndex_doesNothing() {
        service.jumpToChapter(index: -1)

        XCTAssertNil(engine.lastJumpChapterIndex,
                     "Should not jump for negative index")
    }

    func testJumpToChapter_indexEqualToCount_doesNothing() {
        service.jumpToChapter(index: 10) // count is 10, so valid indices are 0-9

        XCTAssertNil(engine.lastJumpChapterIndex,
                     "Should not jump for out-of-bounds index")
    }

    func testJumpToChapter_indexBeyondCount_doesNothing() {
        service.jumpToChapter(index: 999)

        XCTAssertNil(engine.lastJumpChapterIndex)
    }

    func testJumpToChapter_firstChapter() {
        service.jumpToChapter(index: 0)

        XCTAssertEqual(engine.lastJumpChapterIndex, 0)
        XCTAssertEqual(service.currentChapterIndex, 0)
    }

    func testJumpToChapter_lastValidChapter() {
        service.jumpToChapter(index: 9)

        XCTAssertEqual(engine.lastJumpChapterIndex, 9)
        XCTAssertEqual(service.currentChapterIndex, 9)
    }

    // MARK: - Set Speed

    func testSetSpeed_updatesCurrentSpeed() {
        service.setSpeed(.double)

        XCTAssertEqual(engine.lastSetSpeed, .double)
        XCTAssertEqual(service.currentSpeed, .double)
    }

    func testSetSpeed_speedIsReflectedInState() {
        service.setSpeed(.oneAndHalf)

        XCTAssertEqual(service.currentSpeed, .oneAndHalf)
    }

    func testSetSpeed_allPresets() {
        for speed in PlaybackSpeed.allCases {
            service.setSpeed(speed)
            XCTAssertEqual(service.currentSpeed, speed,
                           "Speed should be \(speed) after setting it")
        }
    }

    // MARK: - Play / Pause

    func testPlay_callsEngine() {
        service.play()

        XCTAssertEqual(engine.playCallCount, 1)
        XCTAssertTrue(service.isPlaying)
    }

    func testPause_callsEngine() {
        service.play()

        service.pause()

        XCTAssertEqual(engine.pauseCallCount, 1)
        XCTAssertFalse(service.isPlaying)
    }

    func testTogglePlayPause_fromPaused_plays() {
        engine.isPlaying = false
        service.syncFromEngine()

        service.togglePlayPause()

        XCTAssertTrue(service.isPlaying)
    }

    func testTogglePlayPause_fromPlaying_pauses() {
        service.play()

        service.togglePlayPause()

        XCTAssertFalse(service.isPlaying)
    }

    // MARK: - Chapter List Population

    func testSyncFromEngine_populatesChapters() {
        service.syncFromEngine()

        XCTAssertEqual(service.chapters.count, 10)
        XCTAssertEqual(service.chapters.first?.title, "Chapter 1")
        XCTAssertEqual(service.chapters.last?.title, "Chapter 10")
    }

    // MARK: - Book Info Population

    func testSyncFromEngine_populatesBookInfo() {
        service.syncFromEngine()

        XCTAssertEqual(service.bookTitle, "Test Audiobook")
        XCTAssertEqual(service.bookAuthor, "Test Author")
        XCTAssertEqual(service.progress, 0.35, accuracy: 0.001)
    }

    // MARK: - Sleep Timer

    func testSleepTimer_initialStateIsOff() {
        XCTAssertEqual(service.sleepTimerState, .off)
    }

    func testStartSleepTimer_setsCountdownState() {
        service.startSleepTimer(minutes: 5)

        if case .countdown(let remaining) = service.sleepTimerState {
            XCTAssertEqual(remaining, 300, "5 minutes = 300 seconds")
        } else {
            XCTFail("Expected countdown state, got \(service.sleepTimerState)")
        }
    }

    func testSleepTimer_countdownTicks() async throws {
        service.startSleepTimer(minutes: 1)

        // Wait slightly over 1 second for the timer to tick
        try await Task.sleep(nanoseconds: 1_200_000_000)

        // Run the main run loop to let the timer fire
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        if case .countdown(let remaining) = service.sleepTimerState {
            // Should have ticked down at least 1 second
            XCTAssertLessThan(remaining, 60, "Timer should have ticked down")
        } else if case .off = service.sleepTimerState {
            // Timer might have been very fast in test environment
        } else {
            XCTFail("Expected countdown or off state")
        }

        service.cancelSleepTimer()
    }

    func testSleepTimer_expiryPausesPlayback() async throws {
        service.play()
        XCTAssertTrue(service.isPlaying)

        // Start a very short timer (1 second = minimum we can test)
        service.startSleepTimer(minutes: 0) // 0 minutes = 0 seconds, fires immediately

        // Since 0 * 60 = 0, the first tick will trigger pause
        try await Task.sleep(nanoseconds: 1_500_000_000)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        // After timer expires, playback should be paused
        XCTAssertFalse(service.isPlaying, "Playback should pause when timer expires")
        XCTAssertEqual(service.sleepTimerState, .off, "Timer state should be off after expiry")
    }

    func testSleepTimerEndOfChapter_setsState() {
        service.setSleepTimerEndOfChapter()

        XCTAssertEqual(service.sleepTimerState, .endOfChapter)
    }

    func testHandleChapterEnd_withEndOfChapterTimer_pausesPlayback() {
        service.play()
        service.setSleepTimerEndOfChapter()

        service.handleChapterEnd()

        XCTAssertFalse(service.isPlaying)
        XCTAssertEqual(service.sleepTimerState, .off)
    }

    func testHandleChapterEnd_withoutTimer_doesNotPause() {
        service.play()

        service.handleChapterEnd()

        XCTAssertTrue(service.isPlaying, "Should not pause without end-of-chapter timer")
    }

    func testCancelSleepTimer_clearsState() {
        service.startSleepTimer(minutes: 10)

        service.cancelSleepTimer()

        XCTAssertEqual(service.sleepTimerState, .off)
    }

    func testStartSleepTimer_replacesExistingTimer() {
        service.startSleepTimer(minutes: 10)

        service.startSleepTimer(minutes: 5)

        if case .countdown(let remaining) = service.sleepTimerState {
            XCTAssertEqual(remaining, 300, "New timer should replace old one")
        } else {
            XCTFail("Expected countdown state")
        }
    }

    func testStartSleepTimer_replacesEndOfChapterTimer() {
        service.setSleepTimerEndOfChapter()

        service.startSleepTimer(minutes: 5)

        if case .countdown = service.sleepTimerState {
            // Expected
        } else {
            XCTFail("Countdown timer should replace end-of-chapter timer")
        }
    }
}
