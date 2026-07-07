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

@MainActor
final class ForceResetTests: XCTestCase {

    private let key = TPPSignInBusinessLogic.nextOIDCSessionEphemeralKey
    private var defaults: UserDefaults!
    private var savedDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        // swarm_cd181acd D-cleanup: swap the extension's static
        // `forceResetUserDefaults` for a per-test isolated suite so the
        // one-shot ephemeral flag cannot leak between tests.
        // `static var` swap-and-restore is the chosen seam because Swift
        // extensions cannot hold stored properties (so no init-DI path).
        savedDefaults = TPPSignInBusinessLogic.forceResetUserDefaults
        defaults = testUserDefaults()
        TPPSignInBusinessLogic.forceResetUserDefaults = defaults
    }

    override func tearDown() {
        // Restore the production .standard default so this test's swap
        // can't bleed into the next test class running in this process.
        TPPSignInBusinessLogic.forceResetUserDefaults = savedDefaults
        defaults = nil
        savedDefaults = nil
        super.tearDown()
    }

    // MARK: - One-shot consume contract

    /// Default state: the flag is not set, so consume returns false.
    func testConsume_whenFlagNeverSet_returnsFalse() {
        // Pair-assert that the UserDefaults key is also still cleared after
        // the consume call (no side-effect when nothing was there) AND a
        // second consume still returns false — pinning idempotency.
        XCTAssertNil(defaults.object(forKey: key),
                     "Precondition: flag is not set in the injected UserDefaults suite")
        XCTAssertFalse(
            TPPSignInBusinessLogic.consumeNextOIDCSessionEphemeralFlag(),
            "Fresh consume with no prior set must return false — silent SSO stays on by default"
        )
        XCTAssertFalse(
            TPPSignInBusinessLogic.consumeNextOIDCSessionEphemeralFlag(),
            "Repeated consume on never-set flag must remain false — no spurious latching"
        )
    }

    /// Set then immediately consume returns true exactly once.
    func testConsume_whenFlagSet_returnsTrueOnce() {
        // Pair-assert the UserDefaults observable went from true→cleared so
        // a mutation that returns true without actually consuming the
        // underlying flag is caught.
        defaults.set(true, forKey: key)
        XCTAssertTrue(defaults.bool(forKey: key),
                      "Precondition: flag is set in the injected UserDefaults suite")

        let first = TPPSignInBusinessLogic.consumeNextOIDCSessionEphemeralFlag()

        XCTAssertTrue(first, "First consume after set must return true so the next OIDC session uses ephemeral cookies")
        XCTAssertFalse(defaults.bool(forKey: key),
                       "Consume must clear the underlying UserDefaults flag — not just return true")
    }

    /// After one consume, the flag is cleared — subsequent consumes return false.
    /// This is the entire point of "one-shot": defeat Safari cookie reuse for
    /// the next sign-in only, then silently restore default behavior so future
    /// borrow-time silent-SSO still works.
    func testConsume_secondCallAfterSet_returnsFalse() {
        defaults.set(true, forKey: key)

        let first = TPPSignInBusinessLogic.consumeNextOIDCSessionEphemeralFlag()
        let second = TPPSignInBusinessLogic.consumeNextOIDCSessionEphemeralFlag()
        let third = TPPSignInBusinessLogic.consumeNextOIDCSessionEphemeralFlag()

        XCTAssertTrue(first, "Sanity: first consume returns true")
        XCTAssertFalse(second, "Second consume must return false — flag is one-shot; silent SSO restored after one ephemeral session")
        XCTAssertFalse(third, "Third consume must also return false — flag does not auto-reset between calls")
    }

    /// The consume side-effect (clearing the UserDefaults key) is verified
    /// directly so a future refactor that returns true without clearing
    /// would fail this test.
    func testConsume_clearsTheUserDefaultsKey() {
        defaults.set(true, forKey: key)
        XCTAssertTrue(defaults.bool(forKey: key), "Pre-condition: flag is set in the injected UserDefaults suite")

        _ = TPPSignInBusinessLogic.consumeNextOIDCSessionEphemeralFlag()

        XCTAssertFalse(
            defaults.bool(forKey: key),
            "Consume must remove the key from UserDefaults so the next read returns false"
        )
    }

    /// Repeated set+consume cycles each return true once. Locks against a
    /// future refactor that latches the flag permanently after first set.
    func testConsume_supportsMultipleSetThenConsumeCycles() {
        for cycle in 1...3 {
            defaults.set(true, forKey: key)
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
        defaults.set(true, forKey: key)

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
