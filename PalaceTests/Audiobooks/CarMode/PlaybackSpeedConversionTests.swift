//
//  PlaybackSpeedConversionTests.swift
//  PalaceTests
//
//  Tests for PlaybackSpeed rate conversion and clamping.
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class PlaybackSpeedConversionTests: XCTestCase {

    // MARK: - from(toolkitRate:) Named Presets

    func testFromToolkitRate_halfSpeed() {
        let speed = PlaybackSpeed.from(toolkitRate: 0.5)
        XCTAssertEqual(speed, .halfSpeed)
    }

    func testFromToolkitRate_threeQuarterSpeed() {
        let speed = PlaybackSpeed.from(toolkitRate: 0.75)
        XCTAssertEqual(speed, .threeQuarterSpeed)
    }

    func testFromToolkitRate_normal() {
        let speed = PlaybackSpeed.from(toolkitRate: 1.0)
        XCTAssertEqual(speed, .normal)
    }

    func testFromToolkitRate_oneAndQuarter() {
        let speed = PlaybackSpeed.from(toolkitRate: 1.25)
        XCTAssertEqual(speed, .oneAndQuarter)
    }

    func testFromToolkitRate_oneAndHalf() {
        let speed = PlaybackSpeed.from(toolkitRate: 1.5)
        XCTAssertEqual(speed, .oneAndHalf)
    }

    func testFromToolkitRate_oneAndThreeQuarter() {
        let speed = PlaybackSpeed.from(toolkitRate: 1.75)
        XCTAssertEqual(speed, .oneAndThreeQuarter)
    }

    func testFromToolkitRate_double() {
        let speed = PlaybackSpeed.from(toolkitRate: 2.0)
        XCTAssertEqual(speed, .double)
    }

    func testFromToolkitRate_twoAndHalf() {
        let speed = PlaybackSpeed.from(toolkitRate: 2.5)
        XCTAssertEqual(speed, .twoAndHalf)
    }

    func testFromToolkitRate_triple() {
        let speed = PlaybackSpeed.from(toolkitRate: 3.0)
        XCTAssertEqual(speed, .triple)
    }

    // MARK: - toolkitRate Round-Trip

    func testToolkitRate_roundTripsForAllPresets() {
        for speed in PlaybackSpeed.allCases {
            let rate = speed.toolkitRate
            let recovered = PlaybackSpeed.from(toolkitRate: rate)
            XCTAssertEqual(recovered, speed,
                           "Round-trip failed for \(speed): rate=\(rate), recovered=\(recovered)")
        }
    }

    // MARK: - Clamping

    func testFromToolkitRate_belowMinimum_clampsToHalfSpeed() {
        let speed = PlaybackSpeed.from(toolkitRate: 0.1)
        XCTAssertEqual(speed, .halfSpeed,
                       "Rate below 0.5x should clamp to halfSpeed")
    }

    func testFromToolkitRate_zero_clampsToHalfSpeed() {
        let speed = PlaybackSpeed.from(toolkitRate: 0.0)
        XCTAssertEqual(speed, .halfSpeed)
    }

    func testFromToolkitRate_negative_clampsToHalfSpeed() {
        let speed = PlaybackSpeed.from(toolkitRate: -1.0)
        XCTAssertEqual(speed, .halfSpeed)
    }

    func testFromToolkitRate_aboveMaximum_clampsToTriple() {
        let speed = PlaybackSpeed.from(toolkitRate: 5.0)
        XCTAssertEqual(speed, .triple,
                       "Rate above 3.0x should clamp to triple")
    }

    func testFromToolkitRate_slightlyAboveMax_clampsToTriple() {
        let speed = PlaybackSpeed.from(toolkitRate: 3.1)
        XCTAssertEqual(speed, .triple)
    }

    // MARK: - Float Precision

    func testFromToolkitRate_nearestPreset_0_6() {
        // 0.6 is closer to 0.5 than 0.75
        let speed = PlaybackSpeed.from(toolkitRate: 0.6)
        XCTAssertEqual(speed, .halfSpeed)
    }

    func testFromToolkitRate_nearestPreset_0_7() {
        // 0.7 is closer to 0.75 than 0.5
        let speed = PlaybackSpeed.from(toolkitRate: 0.7)
        XCTAssertEqual(speed, .threeQuarterSpeed)
    }

    func testFromToolkitRate_midpointBetweenPresets() {
        // Midpoint between 1.0 and 1.25 = 1.125, should go to closer one
        let speed = PlaybackSpeed.from(toolkitRate: 1.125)
        // 1.125 is equidistant; the first match wins (normal at 1.0 is checked first)
        XCTAssertTrue(speed == .normal || speed == .oneAndQuarter,
                      "Should match one of the two closest presets")
    }

    func testFromToolkitRate_floatPrecision_onePointZeroOne() {
        // Tiny imprecision around 1.0 should still match normal
        let speed = PlaybackSpeed.from(toolkitRate: 1.01)
        XCTAssertEqual(speed, .normal)
    }

    func testFromToolkitRate_floatPrecision_0_99() {
        let speed = PlaybackSpeed.from(toolkitRate: 0.99)
        XCTAssertEqual(speed, .normal)
    }

    // MARK: - toolkitRate Values

    func testToolkitRate_values() {
        XCTAssertEqual(PlaybackSpeed.halfSpeed.toolkitRate, 0.5, accuracy: 0.001)
        XCTAssertEqual(PlaybackSpeed.threeQuarterSpeed.toolkitRate, 0.75, accuracy: 0.001)
        XCTAssertEqual(PlaybackSpeed.normal.toolkitRate, 1.0, accuracy: 0.001)
        XCTAssertEqual(PlaybackSpeed.oneAndQuarter.toolkitRate, 1.25, accuracy: 0.001)
        XCTAssertEqual(PlaybackSpeed.oneAndHalf.toolkitRate, 1.5, accuracy: 0.001)
        XCTAssertEqual(PlaybackSpeed.oneAndThreeQuarter.toolkitRate, 1.75, accuracy: 0.001)
        XCTAssertEqual(PlaybackSpeed.double.toolkitRate, 2.0, accuracy: 0.001)
        XCTAssertEqual(PlaybackSpeed.twoAndHalf.toolkitRate, 2.5, accuracy: 0.001)
        XCTAssertEqual(PlaybackSpeed.triple.toolkitRate, 3.0, accuracy: 0.001)
    }

    // MARK: - Codable

    func testPlaybackSpeed_codableRoundTrip() throws {
        for speed in PlaybackSpeed.allCases {
            let data = try JSONEncoder().encode(speed)
            let decoded = try JSONDecoder().decode(PlaybackSpeed.self, from: data)
            XCTAssertEqual(decoded, speed,
                           "Codable round-trip failed for \(speed)")
        }
    }

    // MARK: - Display Label

    func testDisplayLabel_matchesRawValue() {
        for speed in PlaybackSpeed.allCases {
            XCTAssertEqual(speed.displayLabel, speed.rawValue)
        }
    }

    // MARK: - All Cases Count

    func testAllCases_hasExpectedCount() {
        XCTAssertEqual(PlaybackSpeed.allCases.count, 9)
    }
}
