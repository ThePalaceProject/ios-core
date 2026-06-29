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
    // PP-4518: 3.0× is the new ceiling.
    XCTAssertEqual(PlaybackRate.convert(rate: .tripleTime),         3.00, accuracy: 0.001)
  }

  func testConvert_IntermediateCases_ReturnCorrectMultipliers() {
    // PP-4518 extends the rail down to 0.5× and up to 3.0×.
    XCTAssertEqual(PlaybackRate.convert(rate: .p050), 0.50, accuracy: 0.001)
    XCTAssertEqual(PlaybackRate.convert(rate: .p065), 0.65, accuracy: 0.001)
    XCTAssertEqual(PlaybackRate.convert(rate: .p080), 0.80, accuracy: 0.001)
    XCTAssertEqual(PlaybackRate.convert(rate: .p095), 0.95, accuracy: 0.001)
    XCTAssertEqual(PlaybackRate.convert(rate: .p110), 1.10, accuracy: 0.001)
    XCTAssertEqual(PlaybackRate.convert(rate: .p120), 1.20, accuracy: 0.001)
    XCTAssertEqual(PlaybackRate.convert(rate: .p145), 1.45, accuracy: 0.001)
    XCTAssertEqual(PlaybackRate.convert(rate: .p175), 1.75, accuracy: 0.001)
    XCTAssertEqual(PlaybackRate.convert(rate: .p195), 1.95, accuracy: 0.001)
    XCTAssertEqual(PlaybackRate.convert(rate: .p205), 2.05, accuracy: 0.001)
    XCTAssertEqual(PlaybackRate.convert(rate: .p250), 2.50, accuracy: 0.001)
    XCTAssertEqual(PlaybackRate.convert(rate: .p275), 2.75, accuracy: 0.001)
    XCTAssertEqual(PlaybackRate.convert(rate: .p295), 2.95, accuracy: 0.001)
  }

  // MARK: - presets

  /// PP-4518 product direction: the user-facing preset chips are even 0.5×
  /// steps across the full rail — [0.5×, 1.0×, 1.5×, 2.0×, 2.5×, 3.0×]. Pinning
  /// the *order* and the *exact* enum cases together kills mutants that:
  ///   - shuffle the order
  ///   - drop/add a preset
  ///   - reintroduce the old 0.75×/1.2× chips
  ///   - substitute an intermediate `.p###` step for a named rate (or vice versa)
  func testPresets_isExactly_0p5_1p0_1p5_2p0_2p5_3p0_inAscendingOrder() {
    let expected: [PlaybackRate] = [
      .p050, .normalTime, .oneAndAHalfTime, .doubleTime, .p250, .tripleTime,
    ]
    XCTAssertEqual(PlaybackRate.presets, expected,
                   "PP-4518 acceptance: presets must be exactly [0.5×, 1.0×, 1.5×, 2.0×, 2.5×, 3.0×] in ascending order")
  }

  /// Independent assertion of the multipliers — separate from enum-case identity —
  /// so a mutant that re-numbers a case's raw value still trips this test. Also
  /// asserts the chips are an evenly-spaced 0.5× ladder (each gap == 0.5).
  func testPresets_MultipliersAreEven0p5StepsFrom0p5To3p0() {
    let expected: [Float] = [0.5, 1.0, 1.5, 2.0, 2.5, 3.0]
    let actual = PlaybackRate.presets.map { PlaybackRate.convert(rate: $0) }
    XCTAssertEqual(actual.count, expected.count, "PP-4518 presets must be exactly 6 multipliers")
    for (index, (actualMultiplier, expectedMultiplier)) in zip(actual, expected).enumerated() {
      XCTAssertEqual(actualMultiplier, expectedMultiplier, accuracy: 0.001,
                     "PP-4518 preset[\(index)] multiplier must be \(expectedMultiplier)×, got \(actualMultiplier)×")
    }
    for i in 1..<actual.count {
      XCTAssertEqual(actual[i] - actual[i - 1], 0.5, accuracy: 0.001,
                     "PP-4518 chips must be evenly 0.5× apart; gap \(i - 1)→\(i) was \(actual[i] - actual[i - 1])")
    }
  }

  /// PP-4518 acceptance: the slow-down chip is 0.5× and there are TWO chips
  /// above 2.0× (2.5× and 3.0×).
  func testPresets_SlowChipIs0p5_AndTwoChipsExceed2x() {
    XCTAssertEqual(PlaybackRate.presets.first, .p050,
                   "Slowest chip must be 0.5× under the even-0.5 ladder")
    let above2x = PlaybackRate.presets.filter { PlaybackRate.convert(rate: $0) > 2.0 }
    XCTAssertEqual(above2x, [.p250, .tripleTime],
                   "Exactly 2.5× and 3.0× must exceed 2.0× in the preset row")
  }

  /// 0.75× and 1.2× are dropped from the quick-select CHIPS per product
  /// direction, but they remain valid enum cases reachable on the 0.05-step
  /// slider (so accessibility slow-down at 0.75× still works and historic
  /// UserDefaults raw 75/120 still decode).
  func testPresets_DropOld0p75And1p2Chips_ButCasesStillReachable() {
    XCTAssertFalse(PlaybackRate.presets.contains(.threeQuartersTime),
                   "0.75× is no longer a quick-select chip")
    XCTAssertFalse(PlaybackRate.presets.contains(.p120),
                   "1.2× is no longer a quick-select chip")
    // Still reachable on the slider rail.
    XCTAssertEqual(PlaybackRate.nearest(to: 0.75), .threeQuartersTime,
                   "0.75× must remain reachable via the slider for accessibility slow-down")
    XCTAssertEqual(PlaybackRate.nearest(to: 1.20), .p120,
                   "1.2× must remain reachable via the slider")
    // Historic persistence still decodes.
    XCTAssertEqual(PlaybackRate(rawValue: 75), .threeQuartersTime)
    XCTAssertEqual(PlaybackRate(rawValue: 120), .p120)
  }

  func testPresets_DoesNotContainOtherIntermediateCases() {
    XCTAssertFalse(PlaybackRate.presets.contains(.p080))
    XCTAssertFalse(PlaybackRate.presets.contains(.p110))
    XCTAssertFalse(PlaybackRate.presets.contains(.p175))
    XCTAssertFalse(PlaybackRate.presets.contains(.oneAndAQuarterTime),
                   "1.25× is not a chip")
  }

  // MARK: - steps

  /// `steps` is the full slider rail: 51 values from 0.50 to 3.00 in 0.05
  /// increments, sorted ascending. Lock the bounds, count, sortedness, AND
  /// the uniform 0.05 gap in one body so a mutant that drops a step,
  /// shuffles the order, or changes the increment fails on a single test.
  func testSteps_isMonotonicLadderFromHalfToTripleIn0Point05Increments() {
    let steps = PlaybackRate.steps
    XCTAssertEqual(steps.count, 51,
                   "0.50→3.00 in 0.05 increments must be 51 distinct values")
    XCTAssertEqual(steps.first, .p050,       "Lower bound is 0.50×")
    XCTAssertEqual(steps.last,  .tripleTime, "Upper bound is 3.00×")

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
    XCTAssertEqual(PlaybackRate.nearest(to: 3.00), .tripleTime)
  }

  func testNearest_ExactIntermediateValues_ReturnExactCase() {
    XCTAssertEqual(PlaybackRate.nearest(to: 0.50), .p050)
    XCTAssertEqual(PlaybackRate.nearest(to: 0.80), .p080)
    XCTAssertEqual(PlaybackRate.nearest(to: 0.95), .p095)
    XCTAssertEqual(PlaybackRate.nearest(to: 1.10), .p110)
    XCTAssertEqual(PlaybackRate.nearest(to: 1.45), .p145)
    XCTAssertEqual(PlaybackRate.nearest(to: 1.95), .p195)
    XCTAssertEqual(PlaybackRate.nearest(to: 2.50), .p250)
    XCTAssertEqual(PlaybackRate.nearest(to: 2.75), .p275)
  }

  func testNearest_ValueBetweenSteps_SnapsToNearest() {
    // 0.77 is closer to 0.75 than to 0.80
    XCTAssertEqual(PlaybackRate.nearest(to: 0.77), .threeQuartersTime)

    // 0.78 is closer to 0.80 than to 0.75 (equidistant → either is acceptable, but must be a valid case)
    let result078 = PlaybackRate.nearest(to: 0.78)
    XCTAssertTrue([.threeQuartersTime, .p080].contains(result078))

    // 1.22 is closer to 1.20 (distance 0.02) than to 1.25 (distance 0.03)
    XCTAssertEqual(PlaybackRate.nearest(to: 1.22), .p120)

    // 2.97 is closer to 2.95 than to 3.00
    XCTAssertEqual(PlaybackRate.nearest(to: 2.97), .p295)

    // 2.99 is closer to 3.00 than to 2.95
    XCTAssertEqual(PlaybackRate.nearest(to: 2.99), .tripleTime)
  }

  /// `nearest(to:)` clamps out-of-range values to the bounds — sub-minimum
  /// snaps to the slowest step (0.5×), super-maximum snaps to the fastest (3.0×).
  /// Pin both clamping branches at multiple values per side so a mutant
  /// that flips one boundary fails immediately.
  func testNearest_clampsOutOfRangeValuesToBounds() {
    // Sub-minimum → 0.50×
    XCTAssertEqual(PlaybackRate.nearest(to: 0.10), .p050)
    XCTAssertEqual(PlaybackRate.nearest(to: 0.49), .p050,
                   "Just under the minimum must still snap to the minimum, not interpolate")

    // Super-maximum → 3.00×
    XCTAssertEqual(PlaybackRate.nearest(to: 3.01), .tripleTime,
                   "Just over the maximum must still snap to the maximum")
    XCTAssertEqual(PlaybackRate.nearest(to: 5.0),  .tripleTime)
    XCTAssertEqual(PlaybackRate.nearest(to: 9.99), .tripleTime)

    // Negative input should not crash and must clamp to the minimum.
    XCTAssertEqual(PlaybackRate.nearest(to: -1.0), .p050,
                   "Negative input must be clamped, not crash on arithmetic")
  }

  // MARK: - persistence round-trip (rawValue ↔ case)

  /// Selected speed persists across app restart as the rawValue Int under the
  /// `playback_rate` UserDefaults key (see Player.savePlaybackRate / fetchPlaybackRate).
  /// The round-trip must hold for the new boundary + above-2.0× cases so a
  /// stored 3.0× restores as 3.0×, not a clamped 2.0×.
  func testRawValueRoundTrip_BoundaryAndAbove2xCases() {
    let cases: [(PlaybackRate, Int)] = [
      (.p050, 50), (.threeQuartersTime, 75), (.normalTime, 100),
      (.doubleTime, 200), (.p250, 250), (.p275, 275), (.tripleTime, 300),
    ]
    for (rate, raw) in cases {
      XCTAssertEqual(rate.rawValue, raw, "\(rate) must serialize to raw \(raw)")
      XCTAssertEqual(PlaybackRate(rawValue: raw), rate,
                     "raw \(raw) must restore to \(rate) across app restart")
    }
  }

  // MARK: - HumanReadablePlaybackRate.formatMultiplier

  func testFormatMultiplier_WholeNumber_ShowsOneDecimalPlace() {
    XCTAssertEqual(HumanReadablePlaybackRate.formatMultiplier(1.0), "1.0×")
    XCTAssertEqual(HumanReadablePlaybackRate.formatMultiplier(2.0), "2.0×")
    XCTAssertEqual(HumanReadablePlaybackRate.formatMultiplier(3.0), "3.0×")
  }

  func testFormatMultiplier_OneDecimalPlace_ShowsOneDecimalPlace() {
    XCTAssertEqual(HumanReadablePlaybackRate.formatMultiplier(1.5), "1.5×")
    XCTAssertEqual(HumanReadablePlaybackRate.formatMultiplier(0.75), "0.75×")
  }

  func testFormatMultiplier_TwoDecimalPlaces_ShowsTwoDecimalPlaces() {
    XCTAssertEqual(HumanReadablePlaybackRate.formatMultiplier(1.25), "1.25×")
    XCTAssertEqual(HumanReadablePlaybackRate.formatMultiplier(1.95), "1.95×")
    XCTAssertEqual(HumanReadablePlaybackRate.formatMultiplier(0.85), "0.85×")
    // PP-4518: above-2.0× labels, e.g. "2.75×".
    XCTAssertEqual(HumanReadablePlaybackRate.formatMultiplier(2.75), "2.75×")
    XCTAssertEqual(HumanReadablePlaybackRate.formatMultiplier(2.05), "2.05×")
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

  /// PP-4518: the fastest rate's spoken VoiceOver description must identify it as
  /// the fastest (and 2.0× must no longer claim to be the fastest).
  func testAccessibleDescription_FastestIsNowTripleTime_Not2x() {
    let tripleDesc = HumanReadablePlaybackRate(rate: .tripleTime).accessibleDescription.lowercased()
    XCTAssertTrue(tripleDesc.contains("fastest"),
                  "3.0× must announce itself as the fastest speed for VoiceOver users")
    let doubleDesc = HumanReadablePlaybackRate(rate: .doubleTime).accessibleDescription.lowercased()
    XCTAssertFalse(doubleDesc.contains("fastest"),
                   "2.0× is no longer the fastest — its description must not claim 'fastest'")
  }
}
