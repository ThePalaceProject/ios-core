//
//  UserAccountChangesTests.swift
//  PalaceTests
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import Combine
@testable import Palace

/// PP-5473 — screens learn about sign-in, sign-out and token refreshes from
/// the account of the library they show, not from an app-wide broadcast.
final class UserAccountChangesTests: XCTestCase {

    private var cancellables = Set<AnyCancellable>()

    override func tearDown() {
        cancellables.removeAll()
        super.tearDown()
    }

    private func countChanges(of account: TPPUserAccount) -> ChangeCounter {
        let counter = ChangeCounter()
        account.changes.sink { counter.increment() }.store(in: &cancellables)
        return counter
    }

    /// The account page relies on this to leave its signed-in layout.
    func testSigningOut_PublishesOneChange() {
        let account = TPPUserAccountTestFactory.makeIsolated()
        let counter = countChanges(of: account)

        account.removeAll()

        XCTAssertEqual(counter.value, 1)
    }

    /// Sign-out clears the stored credentials before it publishes, so the
    /// account page and the 401 handling read signed-out state on the change.
    func testSigningOut_SubscribersAlreadyReadSignedOutState() {
        let account = TPPUserAccountTestFactory.makeIsolated()
        account.setAuthToken("token", barcode: "1234", pin: "5678", expirationDate: nil)
        XCTAssertTrue(account.credentialSnapshot().hasCredentials, "precondition: signed in")
        let seen = CredentialRecorder()
        account.changes
            .sink { seen.append(account.credentialSnapshot().hasCredentials) }
            .store(in: &cancellables)

        account.removeAll()

        XCTAssertEqual(seen.values, [false])
    }

    func testStoringAToken_PublishesOneChange() {
        let account = TPPUserAccountTestFactory.makeIsolated()
        let counter = countChanges(of: account)

        account.setAuthToken("token", barcode: nil, pin: nil, expirationDate: nil)

        XCTAssertEqual(counter.value, 1)
    }

    /// A token refresh for one library must not redraw another library's page.
    func testChangeToAnotherLibrarysAccount_IsNotPublishedHere() {
        let account = TPPUserAccountTestFactory.makeIsolated()
        let other = TPPUserAccountTestFactory.makeIsolated()
        let counter = countChanges(of: account)

        other.setAuthToken("token", barcode: nil, pin: nil, expirationDate: nil)
        other.removeAll()

        XCTAssertEqual(counter.value, 0)
    }

    /// Token refreshes store the new token off the main thread.
    func testChangeOnABackgroundQueue_IsPublished() {
        let account = TPPUserAccountTestFactory.makeIsolated()
        let published = expectation(description: "change published")
        account.changes.first().sink { published.fulfill() }.store(in: &cancellables)

        DispatchQueue.global(qos: .userInitiated).async {
            account.setAuthToken("token", barcode: nil, pin: nil, expirationDate: nil)
        }

        wait(for: [published], timeout: 5)
    }
}

private final class ChangeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

private final class CredentialRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Bool] = []
    var values: [Bool] { lock.withLock { recorded } }
    func append(_ value: Bool) { lock.withLock { recorded.append(value) } }
}
