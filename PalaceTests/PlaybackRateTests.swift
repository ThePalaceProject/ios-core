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

  /// presets is the user-facing 5-rate ladder. Lock the exact set here so
  /// a mutant that adds/removes a preset (e.g. accidentally exposing an
  /// intermediate `.p080`) fails on the equality. Pinning the set, not
  /// just the count, kills mutants that swap one named rate for another.
  func testPresets_isExactly_ThreeQuarters_Normal_OneAndAQuarter_OneAndAHalf_Double() {
    let expected: [PlaybackRate] = [
      .threeQuartersTime, .normalTime, .oneAndAQuarterTime, .oneAndAHalfTime, .doubleTime,
    ]
    XCTAssertEqual(PlaybackRate.presets, expected,
                   "presets must be exactly the 5 named-rate ladder, in ascending order")
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

  /// `steps` is the full slider rail: 26 values from 0.75 to 2.00 in 0.05
  /// increments, sorted ascending. Lock the bounds, count, sortedness, AND
  /// the uniform 0.05 gap in one body so a mutant that drops a step,
  /// shuffles the order, or changes the increment fails on a single test.
  func testSteps_isMonotonicLadderFromThreeQuartersToDoubleIn0Point05Increments() {
    let steps = PlaybackRate.steps
    XCTAssertEqual(steps.count, 26,
                   "0.75→2.00 in 0.05 increments must be 26 distinct values")
    XCTAssertEqual(steps.first, .threeQuartersTime, "Lower bound is 0.75×")
    XCTAssertEqual(steps.last,  .doubleTime,        "Upper bound is 2.00×")

    let raws = steps.map(\.rawValue)
    XCTAssertEqual(raws, raws.sorted(),
                   "steps must be sorted ascending by raw value")
    for i in 1..<raws.count {
      XCTAssertEqual(raws[i] - raws[i-1], 5,
                     "Adjacent steps at indices \(i-1)→\(i) must advance by exactly 0.05× (raw gap of 5)")
    }
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

  /// `nearest(to:)` clamps out-of-range values to the bounds — sub-minimum
  /// snaps to the slowest preset, super-maximum snaps to the fastest.
  /// Pin both clamping branches at multiple values per side so a mutant
  /// that flips one boundary fails immediately.
  func testNearest_clampsOutOfRangeValuesToBounds() {
    // Sub-minimum
    XCTAssertEqual(PlaybackRate.nearest(to: 0.10), .threeQuartersTime)
    XCTAssertEqual(PlaybackRate.nearest(to: 0.50), .threeQuartersTime)
    XCTAssertEqual(PlaybackRate.nearest(to: 0.74), .threeQuartersTime,
                   "Just under the minimum must still snap to the minimum, not interpolate")

    // Super-maximum
    XCTAssertEqual(PlaybackRate.nearest(to: 2.01), .doubleTime,
                   "Just over the maximum must still snap to the maximum")
    XCTAssertEqual(PlaybackRate.nearest(to: 5.0),  .doubleTime)
    XCTAssertEqual(PlaybackRate.nearest(to: 9.99), .doubleTime)

    // Negative input should not crash and must clamp to the minimum.
    XCTAssertEqual(PlaybackRate.nearest(to: -1.0), .threeQuartersTime,
                   "Negative input must be clamped, not crash on arithmetic")
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

  /// Every step in the slider rail produces a label that ends with the
  /// multiply sign and is non-empty. Loop guarantees coverage if a future
  /// step is added without updating tests; the tail-suffix check rules out
  /// a mutant that prepends `×` instead of appending it.
  func testFormatMultiplier_allStepsProduceLabelEndingWithMultiplySign() {
    for rate in PlaybackRate.steps {
      let label = HumanReadablePlaybackRate.formatMultiplier(PlaybackRate.convert(rate: rate))
      XCTAssertFalse(label.isEmpty, "Empty label for \(rate)")
      XCTAssertTrue(label.hasSuffix("×"),
                    "Label '\(label)' for \(rate) must END with × — the multiply sign is the trailing unit, not a prefix")
    }
  }
}
