//
//  CarModeServiceTests.swift
//  PalaceTests
//
//  Tests for CarModeService: state management, timer logic,
//  and playback bridging to AudiobookSessionManager.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Combine
@testable import Palace
import XCTest

// MARK: - CarModeServiceTests

@MainActor
final class CarModeServiceTests: XCTestCase {

    private var cancellables: Set<AnyCancellable>!

    override func setUp() {
        super.setUp()
        cancellables = []
    }

    override func tearDown() {
        cancellables = nil
        super.tearDown()
    }

    // MARK: - Enter/Exit Car Mode

    func testEnterCarMode_setsActiveTrue() {
        let service = CarModeService()

        service.enterCarMode()

        XCTAssertTrue(service.isCarModeActive)
    }

    func testExitCarMode_setsActiveFalse() {
        let service = CarModeService()

        service.enterCarMode()
        service.exitCarMode()

        XCTAssertFalse(service.isCarModeActive)
    }

    func testEnterCarMode_idempotent() {
        let service = CarModeService()
        var stateChangeCount = 0

        service.statePublisher
            .sink { stateChangeCount += 1 }
            .store(in: &cancellables)

        service.enterCarMode()
        service.enterCarMode()

        // Should only fire once (second call is a no-op)
        XCTAssertEqual(stateChangeCount, 1)
    }

    func testExitCarMode_cancelsSleepTimer() {
        let service = CarModeService()
        service.enterCarMode()
        service.setSleepTimer(.minutes15)

        XCTAssertTrue(service.sleepTimerState.isActive)

        service.exitCarMode()

        XCTAssertFalse(service.sleepTimerState.isActive)
    }

    // MARK: - State Publisher

    func testEnterCarMode_sendsStateUpdate() {
        let service = CarModeService()
        let expectation = expectation(description: "State update sent")

        service.statePublisher
            .first()
            .sink { expectation.fulfill() }
            .store(in: &cancellables)

        service.enterCarMode()

        wait(for: [expectation], timeout: 1.0)
    }

    func testExitCarMode_sendsStateUpdate() {
        let service = CarModeService()
        service.enterCarMode()

        let expectation = expectation(description: "State update sent")

        service.statePublisher
            .first()
            .sink { expectation.fulfill() }
            .store(in: &cancellables)

        service.exitCarMode()

        wait(for: [expectation], timeout: 1.0)
    }

    // MARK: - Time Formatting

    func testFormatTime_seconds() {
        XCTAssertEqual(CarModeService.formatTime(0), "0:00")
        XCTAssertEqual(CarModeService.formatTime(5), "0:05")
        XCTAssertEqual(CarModeService.formatTime(59), "0:59")
    }

    func testFormatTime_minutes() {
        XCTAssertEqual(CarModeService.formatTime(60), "1:00")
        XCTAssertEqual(CarModeService.formatTime(90), "1:30")
        XCTAssertEqual(CarModeService.formatTime(3599), "59:59")
    }

    func testFormatTime_hours() {
        XCTAssertEqual(CarModeService.formatTime(3600), "1:00:00")
        XCTAssertEqual(CarModeService.formatTime(3661), "1:01:01")
        XCTAssertEqual(CarModeService.formatTime(7200), "2:00:00")
    }

    func testFormatTime_negativeClampedToZero() {
        XCTAssertEqual(CarModeService.formatTime(-10), "0:00")
    }

    // MARK: - Sleep Timer

    func testSetSleepTimer_minutes15() {
        let service = CarModeService()
        service.setSleepTimer(.minutes15)

        if case .active(let remaining, let option) = service.sleepTimerState {
            XCTAssertEqual(remaining, 900, accuracy: 1.0)
            XCTAssertEqual(option, .minutes15)
        } else {
            XCTFail("Expected active state")
        }
    }

    func testSetSleepTimer_minutes30() {
        let service = CarModeService()
        service.setSleepTimer(.minutes30)

        if case .active(let remaining, let option) = service.sleepTimerState {
            XCTAssertEqual(remaining, 1800, accuracy: 1.0)
            XCTAssertEqual(option, .minutes30)
        } else {
            XCTFail("Expected active state")
        }
    }

    func testSetSleepTimer_endOfChapter() {
        let service = CarModeService()
        service.setSleepTimer(.endOfChapter)

        XCTAssertEqual(service.sleepTimerState, .endOfChapter)
    }

    func testCancelSleepTimer_resetsToInactive() {
        let service = CarModeService()
        service.setSleepTimer(.minutes15)
        service.cancelSleepTimer()

        XCTAssertEqual(service.sleepTimerState, .inactive)
    }

    func testSetSleepTimer_replacesExisting() {
        let service = CarModeService()
        service.setSleepTimer(.minutes15)
        service.setSleepTimer(.minutes45)

        if case .active(let remaining, let option) = service.sleepTimerState {
            XCTAssertEqual(remaining, 2700, accuracy: 1.0)
            XCTAssertEqual(option, .minutes45)
        } else {
            XCTFail("Expected active state with 45 minutes")
        }
    }

    // MARK: - Default State

    func testInitialState() {
        let service = CarModeService()

        XCTAssertFalse(service.isCarModeActive)
        XCTAssertNil(service.currentBookInfo)
        XCTAssertEqual(service.currentChapterTitle, "")
        XCTAssertTrue(service.chapters.isEmpty)
        XCTAssertFalse(service.isPlaying)
        XCTAssertEqual(service.playbackSpeed, .normal)
        XCTAssertEqual(service.sleepTimerState, .inactive)
        XCTAssertEqual(service.elapsedTimeFormatted, "0:00")
        XCTAssertEqual(service.remainingTimeFormatted, "0:00")
    }
}
