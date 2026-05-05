//
//  ForceResetTests.swift
//  PalaceTests
//
//  Locks the patron-self-service "Reset Account" contract:
//   1. The one-shot ephemeral-session flag (set by `performForceReset`,
//      consumed by the OIDC sign-in entry points) self-clears on read so
//      it forces ephemeral cookies for exactly one OIDC session and no more.
//   2. Reading the flag when it was never set returns false (no-op).
//   3. Writing-then-reading-twice returns true once and false after.
//
//  Why this matters (HelpSpot 17716, PP-4282):
//  Carissa from support flagged that "delete app + reinstall" doesn't fix
//  patrons stuck in a weird state. For OIDC libraries this is partially
//  caused by Safari-shared cookies that survive app deletion (the
//  `ASWebAuthenticationSession` was created with
//  `prefersEphemeralWebBrowserSession = false` to support silent borrow
//  re-auth). The "Reset Account" button defeats that for one cycle by
//  flipping the flag — but only for one cycle, so silent SSO still works
//  for normal future borrows.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class ForceResetTests: XCTestCase {

    private let key = TPPSignInBusinessLogic.nextOIDCSessionEphemeralKey

    override func setUp() {
        super.setUp()
        // Each test starts from a clean flag state.
        UserDefaults.standard.removeObject(forKey: key)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: key)
        super.tearDown()
    }

    // MARK: - One-shot consume contract

    /// Default state: the flag is not set, so consume returns false.
    func testConsume_whenFlagNeverSet_returnsFalse() {
        XCTAssertFalse(
            TPPSignInBusinessLogic.consumeNextOIDCSessionEphemeralFlag(),
            "Fresh consume with no prior set must return false — silent SSO stays on by default"
        )
    }

    /// Set then immediately consume returns true exactly once.
    func testConsume_whenFlagSet_returnsTrueOnce() {
        UserDefaults.standard.set(true, forKey: key)

        let first = TPPSignInBusinessLogic.consumeNextOIDCSessionEphemeralFlag()

        XCTAssertTrue(first, "First consume after set must return true so the next OIDC session uses ephemeral cookies")
    }

    /// After one consume, the flag is cleared — subsequent consumes return false.
    /// This is the entire point of "one-shot": defeat Safari cookie reuse for
    /// the next sign-in only, then silently restore default behavior so future
    /// borrow-time silent-SSO still works.
    func testConsume_secondCallAfterSet_returnsFalse() {
        UserDefaults.standard.set(true, forKey: key)

        _ = TPPSignInBusinessLogic.consumeNextOIDCSessionEphemeralFlag()
        let second = TPPSignInBusinessLogic.consumeNextOIDCSessionEphemeralFlag()

        XCTAssertFalse(second, "Second consume must return false — flag is one-shot; silent SSO restored after one ephemeral session")
    }

    /// The consume side-effect (clearing the UserDefaults key) is verified
    /// directly so a future refactor that returns true without clearing
    /// would fail this test.
    func testConsume_clearsTheUserDefaultsKey() {
        UserDefaults.standard.set(true, forKey: key)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: key), "Pre-condition: flag is set in UserDefaults")

        _ = TPPSignInBusinessLogic.consumeNextOIDCSessionEphemeralFlag()

        XCTAssertFalse(
            UserDefaults.standard.bool(forKey: key),
            "Consume must remove the key from UserDefaults so the next read returns false"
        )
    }

    /// Repeated set+consume cycles each return true once. Locks against a
    /// future refactor that latches the flag permanently after first set.
    func testConsume_supportsMultipleSetThenConsumeCycles() {
        for cycle in 1...3 {
            UserDefaults.standard.set(true, forKey: key)
            XCTAssertTrue(
                TPPSignInBusinessLogic.consumeNextOIDCSessionEphemeralFlag(),
                "Cycle \(cycle): set-then-consume must return true"
            )
            XCTAssertFalse(
                TPPSignInBusinessLogic.consumeNextOIDCSessionEphemeralFlag(),
                "Cycle \(cycle): second consume must return false"
            )
        }
    }

    // MARK: - Cross-cutting: regression guard

    /// The fix-is-real test — directly exercises the patron scenario in
    /// HelpSpot 17716. After a patron taps "Reset Account" (which sets the
    /// flag), the very next OIDC sign-in attempt must use ephemeral cookies
    /// to defeat the Safari-shared-cookie reuse that would otherwise
    /// silently sign the patron back into the SAME stale identity.
    func testRegressionForBug_resetAccountForcesNextOIDCSessionEphemeral_perHelpSpot17716() {
        // Simulate Reset Account writing the flag — actual performForceReset
        // also clears credentials, downloads, etc., but the OIDC-specific
        // "Safari cookie reuse defeat" is the part that survives across
        // app deletion. Test the exact contract: flag is set, next OIDC
        // sign-in consumes it as true.
        UserDefaults.standard.set(true, forKey: key)

        XCTAssertTrue(
            TPPSignInBusinessLogic.consumeNextOIDCSessionEphemeralFlag(),
            "REGRESSION GUARD (HelpSpot 17716 / PP-4282): the next OIDC ASWebAuthenticationSession after Reset Account MUST use ephemeral cookies, otherwise Safari's shared cookie jar silently re-signs the patron back into the broken state"
        )
        XCTAssertFalse(
            TPPSignInBusinessLogic.consumeNextOIDCSessionEphemeralFlag(),
            "REGRESSION GUARD: the ephemeral-session forcing is one-shot only — silent SSO must restore for normal borrows after the patron has signed back in"
        )
    }
}
