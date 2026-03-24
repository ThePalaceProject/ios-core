//
// PlaybackRateTests.swift
// PalaceTests
//
// Copyright © 2025 The Palace Project. All rights reserved.
//

import XCTest
@testable import PalaceAudiobookToolkit

class PlaybackRateTests: XCTestCase {

  // MARK: - convert(rate:)

  func testConvert_PresetCases_ReturnCorrectMultipliers() {
    XCTAssertEqual(PlaybackRate.convert(rate: .threeQuartersTime), 0.75, accuracy: 0.001)
    XCTAssertEqual(PlaybackRate.convert(rate: .normalTime),        1.00, accuracy: 0.001)
    XCTAssertEqual(PlaybackRate.convert(rate: .oneAndAQuarterTime), 1.25, accuracy: 0.001)
    XCTAssertEqual(PlaybackRate.convert(rate: .oneAndAHalfTime),   1.50, accuracy: 0.001)
    XCTAssertEqual(PlaybackRate.convert(rate: .doubleTime),         2.00, accuracy: 0.001)
  }

  func testConvert_IntermediateCases_ReturnCorrectMultipliers() {
    XCTAssertEqual(PlaybackRate.convert(rate: .p080), 0.80, accuracy: 0.001)
    XCTAssertEqual(PlaybackRate.convert(rate: .p095), 0.95, accuracy: 0.001)
    XCTAssertEqual(PlaybackRate.convert(rate: .p110), 1.10, accuracy: 0.001)
    XCTAssertEqual(PlaybackRate.convert(rate: .p145), 1.45, accuracy: 0.001)
    XCTAssertEqual(PlaybackRate.convert(rate: .p175), 1.75, accuracy: 0.001)
    XCTAssertEqual(PlaybackRate.convert(rate: .p195), 1.95, accuracy: 0.001)
  }

  // MARK: - presets

  func testPresets_ContainsExactlyFiveCases() {
    XCTAssertEqual(PlaybackRate.presets.count, 5)
  }

  func testPresets_ContainsAllNamedRates() {
    XCTAssertTrue(PlaybackRate.presets.contains(.threeQuartersTime))
    XCTAssertTrue(PlaybackRate.presets.contains(.normalTime))
    XCTAssertTrue(PlaybackRate.presets.contains(.oneAndAQuarterTime))
    XCTAssertTrue(PlaybackRate.presets.contains(.oneAndAHalfTime))
    XCTAssertTrue(PlaybackRate.presets.contains(.doubleTime))
  }

  func testPresets_DoesNotContainIntermediateCases() {
    XCTAssertFalse(PlaybackRate.presets.contains(.p080))
    XCTAssertFalse(PlaybackRate.presets.contains(.p110))
    XCTAssertFalse(PlaybackRate.presets.contains(.p175))
  }

  // MARK: - steps

  func testSteps_IsSortedAscending() {
    let rawValues = PlaybackRate.steps.map(\.rawValue)
    XCTAssertEqual(rawValues, rawValues.sorted(), "steps must be in ascending order")
  }

  func testSteps_BoundsAre75And200() {
    XCTAssertEqual(PlaybackRate.steps.first, .threeQuartersTime)
    XCTAssertEqual(PlaybackRate.steps.last, .doubleTime)
  }

  func testSteps_Has0Point05IncrementsBetweenBounds() {
    let rawValues = PlaybackRate.steps.map(\.rawValue)
    for i in 1..<rawValues.count {
      let gap = rawValues[i] - rawValues[i - 1]
      XCTAssertEqual(gap, 5, "Each step should advance by 0.05× (raw value gap of 5)")
    }
  }

  func testSteps_ContainsAll26Values() {
    // 0.75 to 2.00 in 0.05 increments = 26 distinct values
    XCTAssertEqual(PlaybackRate.steps.count, 26)
  }

  // MARK: - nearest(to:)

  func testNearest_ExactPresetValues_ReturnExactCase() {
    XCTAssertEqual(PlaybackRate.nearest(to: 0.75), .threeQuartersTime)
    XCTAssertEqual(PlaybackRate.nearest(to: 1.00), .normalTime)
    XCTAssertEqual(PlaybackRate.nearest(to: 1.25), .oneAndAQuarterTime)
    XCTAssertEqual(PlaybackRate.nearest(to: 1.50), .oneAndAHalfTime)
    XCTAssertEqual(PlaybackRate.nearest(to: 2.00), .doubleTime)
  }

  func testNearest_ExactIntermediateValues_ReturnExactCase() {
    XCTAssertEqual(PlaybackRate.nearest(to: 0.80), .p080)
    XCTAssertEqual(PlaybackRate.nearest(to: 0.95), .p095)
    XCTAssertEqual(PlaybackRate.nearest(to: 1.10), .p110)
    XCTAssertEqual(PlaybackRate.nearest(to: 1.45), .p145)
    XCTAssertEqual(PlaybackRate.nearest(to: 1.95), .p195)
  }

  func testNearest_ValueBetweenSteps_SnapsToNearest() {
    // 0.77 is closer to 0.75 than to 0.80
    XCTAssertEqual(PlaybackRate.nearest(to: 0.77), .threeQuartersTime)

    // 0.78 is closer to 0.80 than to 0.75 (equidistant → either is acceptable, but must be a valid case)
    let result078 = PlaybackRate.nearest(to: 0.78)
    XCTAssertTrue([.threeQuartersTime, .p080].contains(result078))

    // 1.22 is closer to 1.20 (distance 0.02) than to 1.25 (distance 0.03)
    XCTAssertEqual(PlaybackRate.nearest(to: 1.22), .p120)

    // 1.98 is closer to 2.00 than to 1.95
    XCTAssertEqual(PlaybackRate.nearest(to: 1.98), .doubleTime)
  }

  func testNearest_BelowMinimum_ReturnsThreeQuartersTime() {
    XCTAssertEqual(PlaybackRate.nearest(to: 0.10), .threeQuartersTime)
  }

  func testNearest_AboveMaximum_ReturnsDoubleTime() {
    XCTAssertEqual(PlaybackRate.nearest(to: 9.99), .doubleTime)
  }

  // MARK: - HumanReadablePlaybackRate.formatMultiplier

  func testFormatMultiplier_WholeNumber_ShowsOneDecimalPlace() {
    XCTAssertEqual(HumanReadablePlaybackRate.formatMultiplier(1.0), "1.0×")
    XCTAssertEqual(HumanReadablePlaybackRate.formatMultiplier(2.0), "2.0×")
  }

  func testFormatMultiplier_OneDecimalPlace_ShowsOneDecimalPlace() {
    XCTAssertEqual(HumanReadablePlaybackRate.formatMultiplier(1.5), "1.5×")
    XCTAssertEqual(HumanReadablePlaybackRate.formatMultiplier(0.75), "0.75×")
  }

  func testFormatMultiplier_TwoDecimalPlaces_ShowsTwoDecimalPlaces() {
    XCTAssertEqual(HumanReadablePlaybackRate.formatMultiplier(1.25), "1.25×")
    XCTAssertEqual(HumanReadablePlaybackRate.formatMultiplier(1.95), "1.95×")
    XCTAssertEqual(HumanReadablePlaybackRate.formatMultiplier(0.85), "0.85×")
  }

  func testFormatMultiplier_AllIntermediateSteps_ContainMultiplySign() {
    for rate in PlaybackRate.steps {
      let label = HumanReadablePlaybackRate.formatMultiplier(PlaybackRate.convert(rate: rate))
      XCTAssertTrue(label.contains("×"), "Label '\(label)' for \(rate) should contain ×")
    }
  }
}
