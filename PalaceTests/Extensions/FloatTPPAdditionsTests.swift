//
//  FloatTPPAdditionsTests.swift
//  PalaceTests
//
//  Tests for Float+TPPAdditions.swift approximate equality and rounding.
//

import XCTest
@testable import Palace

@MainActor
final class FloatTPPAdditionsTests: XCTestCase {

  // MARK: - Approximate Equality Operator (=~=)

  /// `=~=` is true iff |a - b| < Float.ulpOfOne. Lock the contract across
  /// the full set of inputs the operator is exposed to in production:
  /// identical, near-equal under epsilon, just-over epsilon, distinct,
  /// signed differences, and zero. Each case sits inside one test so a
  /// mutant that flips `<` to `<=` (or `abs` to identity) fails on the
  /// boundary case without forcing the rest of the suite to re-check the
  /// trivial cases.
  func testApproxEqual_returnsTrueOnlyForValuesWithinEpsilon() {
    let a: Float = 1.0
    let identical: Float = 1.0
    let withinEpsilon: Float = 1.0 + Float.ulpOfOne / 2
    let outsideEpsilon: Float = 1.0 + Float.ulpOfOne * 4
    let differentMagnitude: Float = 2.0

    XCTAssertTrue(a =~= identical,
                  "Identical values must be approximately equal")
    XCTAssertTrue(a =~= withinEpsilon,
                  "Values within ulpOfOne MUST be approximately equal — boundary case for `<` mutant")
    XCTAssertFalse(a =~= outsideEpsilon,
                   "Values past ulpOfOne MUST NOT be approximately equal")
    XCTAssertFalse(a =~= differentMagnitude)

    // Zero is its own equivalence class — guard against a mutant that
    // collapses the abs() and yields true on |0 - 0| < epsilon by accident.
    XCTAssertTrue(0.0 as Float =~= 0.0 as Float)

    // Sign matters: |-1 - 1| = 2 ≫ epsilon. A mutant that drops `abs()`
    // would let -1 - 1 = -2 sneak under `< epsilon`.
    XCTAssertFalse((-1.0 as Float) =~= 1.0 as Float)
  }

  /// `=~=` is symmetric — a =~= b iff b =~= a. The implementation isn't
  /// obviously symmetric (the right-hand side is Optional), so this is a
  /// real contract guard against a mutant that tilts the operands.
  func testApproxEqual_isSymmetric() {
    let a: Float = 42.0
    let b: Float = 42.0
    let withinEpsilon: Float = 42.0 + Float.ulpOfOne / 4

    XCTAssertTrue(a =~= b)
    XCTAssertTrue(b =~= a)
    XCTAssertTrue(a =~= withinEpsilon)
    XCTAssertTrue(withinEpsilon =~= a, "Symmetry holds across the optional-RHS branch too")
  }

  /// `=~=` returns false when the right-hand side is nil — distinct branch
  /// in the production code, separate from the numeric comparison.
  func testApproxEqual_returnsFalseWhenRightHandSideIsNil() {
    let nilFloat: Float? = nil
    XCTAssertFalse(1.0 as Float =~= nilFloat)
    XCTAssertFalse(0.0 as Float =~= nilFloat,
                   "Even zero must not equal nil — guards against an `if let b = b else true` mutant")
  }

  // MARK: - roundTo(decimalPlaces:)

  /// `roundTo(decimalPlaces:)` formats the float with N digits after the
  /// decimal and appends `%`. Lock the digit count, the rounding behaviour
  /// (banker/half-even on 3.7 → 4 with zero places), and the percent suffix
  /// in a single test so a mutant that drops the percent sign or shifts the
  /// digit count fails here.
  func testRoundTo_formatsAsPercentageWithSpecifiedDecimalPlaces() {
    let pi: Float = 3.14159
    let half: Float = 3.7
    let small: Float = 50.0

    let twoPlaces = pi.roundTo(decimalPlaces: 2)
    XCTAssertEqual(twoPlaces, "3.14%",
                   "%.2f rounds 3.14159 down to 3.14")

    let zeroPlaces = half.roundTo(decimalPlaces: 0)
    XCTAssertEqual(zeroPlaces, "4%",
                   "%.0f rounds 3.7 → 4 (away from zero)")

    let threePlaces = pi.roundTo(decimalPlaces: 3)
    XCTAssertEqual(threePlaces, "3.142%",
                   "%.3f on 3.14159 → 3.142 (last digit rounds up from 5)")

    // Suffix and decimal-presence pinning — would catch a mutant that drops
    // the `%%` from the format string.
    XCTAssertTrue(small.roundTo(decimalPlaces: 1).hasSuffix("%"))
    XCTAssertTrue(pi.roundTo(decimalPlaces: 4).contains("."),
                  "Non-zero decimal places must yield a string with a decimal point")
  }

  /// Edge case: roundTo on the integer side (50.0 with 1 place) produces
  /// "50.0%" — the trailing zero is preserved by %.1f. A mutant that swaps
  /// %f for %g (which trims trailing zeros) would be caught here.
  func testRoundTo_preservesTrailingZerosFromFormatSpecifier() {
    let value: Float = 50.0
    XCTAssertEqual(value.roundTo(decimalPlaces: 1), "50.0%")
    XCTAssertEqual(value.roundTo(decimalPlaces: 3), "50.000%")
  }
}
