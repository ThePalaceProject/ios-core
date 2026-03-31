//
//  SleepTimerTests.swift
//  PalaceTests
//
//  Tests for sleep timer models: options, state, formatting, and duration values.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

@testable import Palace
import XCTest

// MARK: - SleepTimerOptionTests

final class SleepTimerOptionTests: XCTestCase {

    // MARK: - Duration

    func testDurations() {
        XCTAssertEqual(SleepTimerOption.minutes15.duration, 900)
        XCTAssertEqual(SleepTimerOption.minutes30.duration, 1800)
        XCTAssertEqual(SleepTimerOption.minutes45.duration, 2700)
        XCTAssertEqual(SleepTimerOption.minutes60.duration, 3600)
        XCTAssertNil(SleepTimerOption.endOfChapter.duration)
    }

    // MARK: - Display Names

    func testDisplayNames() {
        XCTAssertEqual(SleepTimerOption.minutes15.displayName, "15 minutes")
        XCTAssertEqual(SleepTimerOption.minutes30.displayName, "30 minutes")
        XCTAssertEqual(SleepTimerOption.minutes45.displayName, "45 minutes")
        XCTAssertEqual(SleepTimerOption.minutes60.displayName, "60 minutes")
        XCTAssertEqual(SleepTimerOption.endOfChapter.displayName, "End of chapter")
    }

    // MARK: - Short Labels

    func testShortLabels() {
        XCTAssertEqual(SleepTimerOption.minutes15.shortLabel, "15m")
        XCTAssertEqual(SleepTimerOption.minutes30.shortLabel, "30m")
        XCTAssertEqual(SleepTimerOption.minutes45.shortLabel, "45m")
        XCTAssertEqual(SleepTimerOption.minutes60.shortLabel, "60m")
        XCTAssertEqual(SleepTimerOption.endOfChapter.shortLabel, "Ch.")
    }

    // MARK: - CaseIterable

    func testAllCases() {
        XCTAssertEqual(SleepTimerOption.allCases.count, 5)
    }

    // MARK: - Identifiable

    func testIds_areUnique() {
        let ids = SleepTimerOption.allCases.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }
}

// MARK: - SleepTimerStateTests

final class SleepTimerStateTests: XCTestCase {

    // MARK: - isActive

    func testInactive_isNotActive() {
        XCTAssertFalse(SleepTimerState.inactive.isActive)
    }

    func testActive_isActive() {
        XCTAssertTrue(SleepTimerState.active(remaining: 300, option: .minutes15).isActive)
    }

    func testEndOfChapter_isActive() {
        XCTAssertTrue(SleepTimerState.endOfChapter.isActive)
    }

    // MARK: - Remaining Formatted

    func testInactive_remainingFormatted_isNil() {
        XCTAssertNil(SleepTimerState.inactive.remainingFormatted)
    }

    func testActive_remainingFormatted() {
        let state = SleepTimerState.active(remaining: 754, option: .minutes15)
        XCTAssertEqual(state.remainingFormatted, "12:34")
    }

    func testActive_remainingFormatted_zeroSeconds() {
        let state = SleepTimerState.active(remaining: 60, option: .minutes15)
        XCTAssertEqual(state.remainingFormatted, "1:00")
    }

    func testEndOfChapter_remainingFormatted() {
        XCTAssertEqual(SleepTimerState.endOfChapter.remainingFormatted, "Ch.")
    }

    // MARK: - Button Label

    func testInactive_buttonLabel() {
        XCTAssertEqual(SleepTimerState.inactive.buttonLabel, "Sleep")
    }

    func testActive_buttonLabel_showsTime() {
        let state = SleepTimerState.active(remaining: 125, option: .minutes15)
        XCTAssertEqual(state.buttonLabel, "2:05")
    }

    func testEndOfChapter_buttonLabel() {
        XCTAssertEqual(SleepTimerState.endOfChapter.buttonLabel, "End Ch.")
    }

    // MARK: - Equatable

    func testEquatable() {
        XCTAssertEqual(SleepTimerState.inactive, .inactive)
        XCTAssertEqual(SleepTimerState.endOfChapter, .endOfChapter)
        XCTAssertEqual(
            SleepTimerState.active(remaining: 100, option: .minutes15),
            SleepTimerState.active(remaining: 100, option: .minutes15)
        )
        XCTAssertNotEqual(
            SleepTimerState.active(remaining: 100, option: .minutes15),
            SleepTimerState.active(remaining: 200, option: .minutes15)
        )
        XCTAssertNotEqual(SleepTimerState.inactive, .endOfChapter)
    }
}

// MARK: - PlaybackSpeedTests

final class PlaybackSpeedTests: XCTestCase {

    // MARK: - Display Labels

    func testCompactLabel_wholeNumber() {
        let speed = PlaybackSpeed(rate: 1.0, presetName: nil)
        XCTAssertEqual(speed.compactLabel, "1x")
    }

    func testCompactLabel_fractional() {
        let speed = PlaybackSpeed(rate: 1.5, presetName: nil)
        XCTAssertEqual(speed.compactLabel, "1.5x")
    }

    func testDisplayLabel_withPreset() {
        XCTAssertEqual(PlaybackSpeed.normal.displayLabel, "1x (Normal)")
        XCTAssertEqual(PlaybackSpeed.fast.displayLabel, "1.5x (Fast)")
    }

    func testDisplayLabel_withoutPreset() {
        let speed = PlaybackSpeed(rate: 1.3, presetName: nil)
        XCTAssertEqual(speed.displayLabel, "1.3x")
    }

    // MARK: - Named Presets

    func testPresets() {
        XCTAssertEqual(PlaybackSpeed.slow.rate, 0.75)
        XCTAssertEqual(PlaybackSpeed.normal.rate, 1.0)
        XCTAssertEqual(PlaybackSpeed.fast.rate, 1.5)
        XCTAssertEqual(PlaybackSpeed.veryFast.rate, 2.0)
    }

    // MARK: - All Options

    func testAllOptions_count() {
        // 0.5 to 3.0 in 0.1 increments = 26 options
        XCTAssertEqual(PlaybackSpeed.allOptions.count, 26)
    }

    func testAllOptions_firstAndLast() {
        XCTAssertEqual(PlaybackSpeed.allOptions.first?.rate, 0.5)
        XCTAssertEqual(PlaybackSpeed.allOptions.last?.rate, 3.0)
    }

    func testAllOptions_containsPresets() {
        let rates = PlaybackSpeed.allOptions.map(\.rate)
        XCTAssertTrue(rates.contains(0.75))
        XCTAssertTrue(rates.contains(1.0))
        XCTAssertTrue(rates.contains(1.5))
        XCTAssertTrue(rates.contains(2.0))
    }

    func testAllOptions_presetsHaveNames() {
        let normal = PlaybackSpeed.allOptions.first(where: { $0.rate == 1.0 })
        XCTAssertEqual(normal?.presetName, "Normal")

        let slow = PlaybackSpeed.allOptions.first(where: { $0.rate == 0.75 })
        XCTAssertEqual(slow?.presetName, "Slow")
    }

    // MARK: - Quick Picks

    func testQuickPicks_count() {
        XCTAssertEqual(PlaybackSpeed.quickPicks.count, 9)
    }

    func testQuickPicks_includesNamedPresets() {
        let rates = PlaybackSpeed.quickPicks.map(\.rate)
        XCTAssertTrue(rates.contains(0.75))
        XCTAssertTrue(rates.contains(1.0))
        XCTAssertTrue(rates.contains(1.5))
        XCTAssertTrue(rates.contains(2.0))
    }

    // MARK: - Equatable / Hashable

    func testEquatable() {
        let a = PlaybackSpeed(rate: 1.5, presetName: "Fast")
        let b = PlaybackSpeed(rate: 1.5, presetName: "Fast")
        let c = PlaybackSpeed(rate: 2.0, presetName: nil)

        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func testHashable() {
        let speeds: Set<PlaybackSpeed> = [.normal, .fast, .normal]
        XCTAssertEqual(speeds.count, 2)
    }

    // MARK: - Identifiable

    func testId_isRate() {
        let speed = PlaybackSpeed(rate: 1.25, presetName: nil)
        XCTAssertEqual(speed.id, 1.25)
    }
}

// MARK: - CarModeChapterInfoTests

final class CarModeChapterInfoTests: XCTestCase {

    func testFormattedDuration_minutesAndSeconds() {
        let chapter = CarModeChapterInfo(index: 0, title: "Ch 1", duration: 754, isCurrent: false)
        XCTAssertEqual(chapter.formattedDuration, "12:34")
    }

    func testFormattedDuration_zero() {
        let chapter = CarModeChapterInfo(index: 0, title: "Ch 1", duration: 0, isCurrent: false)
        XCTAssertEqual(chapter.formattedDuration, "0:00")
    }

    func testFormattedDuration_exact() {
        let chapter = CarModeChapterInfo(index: 0, title: "Ch 1", duration: 60, isCurrent: false)
        XCTAssertEqual(chapter.formattedDuration, "1:00")
    }

    func testIdentifiable() {
        let chapter = CarModeChapterInfo(index: 5, title: "Ch 6", duration: 120, isCurrent: true)
        XCTAssertEqual(chapter.id, 5)
    }
}
