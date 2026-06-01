// PalaceTests/Fixtures/KeychainGuardKnownBad.swift
//
// KNOWN-BAD fixture for check-keychain-guard-coverage.py.
// Expected: 4 findings — one per risky pattern, no guard anywhere.

import XCTest

final class KeychainGuardKnownBad: XCTestCase {

    func testTouchesSharedAccountWithoutGuard() {
        let acct = TPPUserAccount.sharedAccount(libraryUUID: "uuid")
        XCTAssertNotNil(acct)
    }

    func testInstantiatesUserAccountWithoutGuard() {
        let acct = TPPUserAccount()
        XCTAssertNotNil(acct)
    }

    func testHitsKeychainSharedWithoutGuard() {
        TPPKeychain.shared.deleteValue(forKey: "x")
    }

    func testInstantiatesRealAccountsManagerWithoutGuard() {
        let manager = AccountsManager()
        XCTAssertNotNil(manager)
    }
}
