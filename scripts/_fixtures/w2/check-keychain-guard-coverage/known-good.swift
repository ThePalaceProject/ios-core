// PalaceTests/Fixtures/KeychainGuardKnownGood.swift
//
// KNOWN-GOOD fixture for check-keychain-guard-coverage.py.
// Risky patterns are present BUT each method either:
//   - calls KeychainAvailability.skipIfUnavailable() in its body, OR
//   - uses a mock receiver (no risky pattern match), OR
//   - uses an explicit mock-named method touching a mock receiver.
// Expected: 0 findings.

import XCTest

final class KeychainGuardKnownGood: XCTestCase {

    func testGuardedInMethodBody_sharedAccount() {
        KeychainAvailability.skipIfUnavailable()
        let acct = TPPUserAccount.sharedAccount(libraryUUID: "uuid")
        XCTAssertNotNil(acct)
    }

    func testGuardedInMethodBody_userAccountInit() {
        KeychainAvailability.skipIfUnavailable()
        let acct = TPPUserAccount()
        XCTAssertNotNil(acct)
    }

    func testGuardedInMethodBody_realAccountsManager() {
        KeychainAvailability.skipIfUnavailable()
        let manager = AccountsManager()
        XCTAssertNotNil(manager)
    }

    func testMockedAccountsManagerNoGuardNeeded() {
        // Mock receivers don't match risk patterns.
        let manager = MockAccountsManager()
        XCTAssertNotNil(manager)
    }

    func testMockSpyExplicitlyNamed_touchesMockReceiver() {
        // Method-name carveout ("mock" token) + mock receiver.
        let acct = MockUserAccount()
        XCTAssertNotNil(acct)
    }
}
