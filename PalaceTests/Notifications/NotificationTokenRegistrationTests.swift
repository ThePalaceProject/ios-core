//
//  NotificationTokenRegistrationTests.swift
//  PalaceTests
//
//  Locks the FCM-token-registration success contract used by
//  `NotificationService.updateToken`. The pure helper under test
//  (`shouldMarkTokenRegistered`) decides whether the per-account
//  `hasUpdatedToken` latch may be set to `true`.
//
//  Why this matters (HelpSpot 17680, post-3.0.0):
//  Prior to the fix, `hasUpdatedToken` was set BEFORE `/patrons/me/`
//  was even called. When SAML credentials had gone stale, the profile
//  fetch returned nil, the device-registration endpoint was never
//  resolved, and the FCM token was never sent to the Circulation
//  Manager — so the CM had no idea where to push hold-availability
//  notifications. The flag stayed `true`, blocking every retry until
//  cold-launch / sign-out / library switch. The fix sets the flag
//  only when this helper returns `true`.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

@MainActor
final class NotificationTokenRegistrationTests: XCTestCase {

    // MARK: - Failure paths (flag must NOT be set → retry stays possible)

    func testShouldNotMark_whenProfileDocumentMissing() {
        // SAML 401 / no credentials / network failure → profile doc nil.
        // This is the bug being fixed: previously the flag was set anyway
        // and registration was permanently skipped.
        let result = NotificationService.shouldMarkTokenRegistered(
            profileDocumentPresent: false,
            hasDeviceRegistrationLink: false,
            fcmTokenPresent: false,
            existsResult: nil,
            saveSucceeded: nil
        )
        XCTAssertFalse(result, "Missing profile document must leave hasUpdatedToken=false so a future sign-in can retry registration")
    }

    func testShouldNotMark_whenDeviceRegistrationLinkAbsent() {
        // Profile doc returned but didn't advertise a device-registration link
        // (e.g. library doesn't support push). No registration to do, but also
        // nothing to latch — leave the flag false so a future profile doc with
        // the link can register.
        let result = NotificationService.shouldMarkTokenRegistered(
            profileDocumentPresent: true,
            hasDeviceRegistrationLink: false,
            fcmTokenPresent: true,
            existsResult: true,
            saveSucceeded: nil
        )
        XCTAssertFalse(result, "Profile doc without a deviceRegistration link cannot count as a successful registration")
    }

    func testShouldNotMark_whenFCMTokenUnavailable() {
        // Firebase didn't return a token (no network / not yet provisioned).
        // We have no proof the CM has a token to push to.
        let result = NotificationService.shouldMarkTokenRegistered(
            profileDocumentPresent: true,
            hasDeviceRegistrationLink: true,
            fcmTokenPresent: false,
            existsResult: true,
            saveSucceeded: nil
        )
        XCTAssertFalse(result, "Without an FCM token, registration cannot be considered successful")
    }

    func testShouldNotMark_whenExistsCheckInconclusive() {
        // checkTokenExists returns nil for any non-200/non-404 status — we
        // don't know if the server has the token. Leave flag false so retry
        // keeps trying until we get a definitive answer.
        let result = NotificationService.shouldMarkTokenRegistered(
            profileDocumentPresent: true,
            hasDeviceRegistrationLink: true,
            fcmTokenPresent: true,
            existsResult: nil,
            saveSucceeded: nil
        )
        XCTAssertFalse(result, "Inconclusive token-exists check must NOT latch the flag — retry needed")
    }

    func testShouldNotMark_whenSaveFails() {
        // Token didn't exist on the server, save was attempted, save failed
        // (network error or non-2xx). The CM still doesn't have the token.
        let result = NotificationService.shouldMarkTokenRegistered(
            profileDocumentPresent: true,
            hasDeviceRegistrationLink: true,
            fcmTokenPresent: true,
            existsResult: false,
            saveSucceeded: false
        )
        XCTAssertFalse(result, "Failed save must leave the flag false so the next observer trigger can retry")
    }

    func testShouldNotMark_whenSaveNeededButNotAttempted() {
        // existsResult=false means a save IS needed. If `saveSucceeded` is
        // nil (i.e. save wasn't attempted, or completion never fired), the
        // flag must NOT be set.
        let result = NotificationService.shouldMarkTokenRegistered(
            profileDocumentPresent: true,
            hasDeviceRegistrationLink: true,
            fcmTokenPresent: true,
            existsResult: false,
            saveSucceeded: nil
        )
        XCTAssertFalse(result, "Save was needed but not attempted — flag must remain false")
    }

    // MARK: - Success paths (flag MAY be set → registration confirmed)

    func testShouldMark_whenTokenAlreadyRegistered() {
        // checkTokenExists returns true → CM already has this token, no save
        // needed, registration is effectively done.
        let result = NotificationService.shouldMarkTokenRegistered(
            profileDocumentPresent: true,
            hasDeviceRegistrationLink: true,
            fcmTokenPresent: true,
            existsResult: true,
            saveSucceeded: nil
        )
        XCTAssertTrue(result, "Existing token on the server is the no-op success case — flag must latch true")
    }

    func testShouldMark_whenSaveSucceeds() {
        // checkTokenExists returned false, save attempted, save returned 2xx.
        // CM now has the token.
        let result = NotificationService.shouldMarkTokenRegistered(
            profileDocumentPresent: true,
            hasDeviceRegistrationLink: true,
            fcmTokenPresent: true,
            existsResult: false,
            saveSucceeded: true
        )
        XCTAssertTrue(result, "Successful save is the primary success case — flag must latch true")
    }

    // MARK: - Cross-cutting invariants

    /// A successful save cannot rescue a missing prerequisite. Even with
    /// `saveSucceeded: true`, if any earlier link in the chain is missing,
    /// the helper must still return false. Locks against a future refactor
    /// that accidentally short-circuits the prerequisite checks.
    func testShouldNotMark_whenSaveSucceededButPrerequisiteMissing() {
        let combos: [(pd: Bool, link: Bool, token: Bool, exists: Bool?)] = [
            (false, true,  true,  false),
            (true,  false, true,  false),
            (true,  true,  false, false),
            (true,  true,  true,  nil),     // exists==nil short-circuits before save check
        ]
        for c in combos {
            let result = NotificationService.shouldMarkTokenRegistered(
                profileDocumentPresent: c.pd,
                hasDeviceRegistrationLink: c.link,
                fcmTokenPresent: c.token,
                existsResult: c.exists,
                saveSucceeded: true
            )
            XCTAssertFalse(result, "Prerequisite combo (\(c.pd),\(c.link),\(c.token),\(String(describing: c.exists))) with saveSucceeded=true must still return false")
        }
    }

    /// The "fix is real" test — directly exercises the bug fingerprint from
    /// HelpSpot 17680. Before the fix, the production code set
    /// `hasUpdatedToken=true` BEFORE the profile fetch, so a SAML 401 left
    /// the patron permanently unregistered. This test asserts the contract
    /// the fix enforces: when the profile fetch fails, the helper says do
    /// NOT mark, regardless of any later state.
    func testRegressionForBug_SAML401LeavesFlagUnlatched_perHelpSpot17680() {
        // Simulate the SAML-401 outcome: profile fetch returned nil → no
        // device endpoint, no FCM token request, no exists check, no save.
        let result = NotificationService.shouldMarkTokenRegistered(
            profileDocumentPresent: false,
            hasDeviceRegistrationLink: false,
            fcmTokenPresent: false,
            existsResult: nil,
            saveSucceeded: nil
        )
        XCTAssertFalse(result,
            "REGRESSION GUARD (HelpSpot 17680): SAML 401 must leave hasUpdatedToken=false so the post-re-auth observer can re-trigger registration")
    }
}
