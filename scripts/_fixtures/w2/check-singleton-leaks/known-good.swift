// PalaceTests/Fixtures/SingletonLeaksKnownGood.swift
//
// KNOWN-GOOD fixture for check-singleton-leaks.py.
// All three risky patterns are present BUT marked. Expected: 0 findings.

import XCTest

final class SingletonLeaksKnownGood: XCTestCase {

    func testRealAccountsManagerMarked() {
        // allow-real-accounts-manager: integration test against the real
        // account-load pipeline; cannot use a mock here.
        let manager = AccountsManager()
        XCTAssertNotNil(manager)
    }

    func testSharedAccountMarkedAbove() {
        // allow-real-tppuser-account: keychain-availability integration
        let account = TPPUserAccount.sharedAccount(libraryUUID: "uuid-123")
        XCTAssertNotNil(account)
    }

    func testDefaultCenterBroadcastMarkedSameLine() {
        NotificationCenter.default.post(name: .TPPCurrentAccountDidChange, object: nil) // allow-default-center-broadcast: regression for stale-account-modal observer.
    }

    func testMockedAccountsManagerNoMarkerNeeded() {
        // Constructing a mock is not a singleton leak; pattern doesn't match.
        let manager = MockAccountsManager()
        XCTAssertNotNil(manager)
    }
}
