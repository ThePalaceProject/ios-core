// PalaceTests/Fixtures/TestTautologyKnownGood.swift
//
// KNOWN-GOOD fixture for check-test-tautology.py.
// Three patterns that must NOT flag:
//   1. XCTAssertNotNil on Optional return type (real test).
//   2. XCTAssertNotNil on non-optional return type WITH a marker.
//   3. XCTAssertNotNil on a bare local identifier (cannot infer type → skip).
//   4. XCTAssertNotNil on an unknown method (no production decl → skip).
//   5. Behavioral assertion replacing the tautology.

import XCTest

final class TestTautologyKnownGood: XCTestCase {

    func testOptionalReturnIsLegitimate() {
        let manager = AccountsManager()
        XCTAssertNotNil(manager.lookupCatalog())
    }

    func testOptionalExplicitFormIsLegitimate() {
        let manager = AccountsManager()
        XCTAssertNotNil(manager.explicitOptional())
    }

    func testNonOptionalTautology_butMarked() {
        let manager = AccountsManager()
        // allow-non-optional-not-nil: tautological assertion preserved as a
        // smoke check during refactor; the next sweep replaces with equality.
        XCTAssertNotNil(manager.accounts())
    }

    func testBareLocalSkipped() {
        let value = someHelperReturningOptional()
        XCTAssertNotNil(value)  // bare ident — script cannot infer; skipped.
    }

    func testUnknownMethodSkipped() {
        let helper = LocalHelper()
        XCTAssertNotNil(helper.notInProductionCodebase())
    }

    func testBehaviorRatherThanTautology() {
        let manager = AccountsManager()
        XCTAssertEqual(manager.accounts().count, 0)
    }

    private func someHelperReturningOptional() -> String? { nil }
}

final class LocalHelper {
    func notInProductionCodebase() -> Int { 1 }
}
