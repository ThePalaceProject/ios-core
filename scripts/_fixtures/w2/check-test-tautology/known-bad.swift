// PalaceTests/Fixtures/TestTautologyKnownBad.swift
//
// KNOWN-BAD fixture for check-test-tautology.py.
// Expected: 2 TEST-TAUTOLOGY findings — `accounts()` and `currentLibraryUUID()`
// are non-optional in the codebase fixture; XCTAssertNotNil tautologies them.

import XCTest

final class TestTautologyKnownBad: XCTestCase {

    func testTautologyOnAccounts() {
        let manager = AccountsManager()
        XCTAssertNotNil(manager.accounts(), "should be non-empty after load")
    }

    func testTautologyOnLibraryUUID() {
        let manager = AccountsManager()
        XCTAssertNotNil(manager.currentLibraryUUID())
    }
}
