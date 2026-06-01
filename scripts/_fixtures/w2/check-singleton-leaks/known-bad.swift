// PalaceTests/Fixtures/SingletonLeaksKnownBad.swift
//
// KNOWN-BAD fixture for check-singleton-leaks.py.
// Expected: 3 findings — one for each unmarked risk pattern.

import XCTest

final class SingletonLeaksKnownBad: XCTestCase {

    func testRealAccountsManagerWithoutMarker() {
        // No marker → flagged.
        let manager = AccountsManager()
        XCTAssertNotNil(manager)
    }

    func testSharedAccountWithoutMarker() {
        let account = TPPUserAccount.sharedAccount(libraryUUID: "uuid-123")
        XCTAssertNotNil(account)
    }

    func testDefaultCenterBroadcastWithoutMarker() {
        NotificationCenter.default.post(name: .TPPCurrentAccountDidChange, object: nil)
    }
}
