//
//  AudiobookLoadFailureSAMLReauthTests.swift
//  PalaceTests
//
//  Locks the audiobook-OPEN SAML re-auth predicate
//  (`AudiobookSessionManager.shouldTriggerSAMLReauthForLoadFailure`).
//
//  Why this matters (HelpSpot 17727):
//  Crashlytics shows "Audiobook failed to open - showing try again error (401)"
//  fires 107 events / 40 users on Palace 3.0.0 — many from RAILS school SAML
//  libraries. Before this fix the audiobook-load failure path showed a generic
//  "Try Again" alert that hit the same 401 again (because the credentials were
//  still stale). The fix wires the load-failure path through `TPPReauthenticator`
//  when the user's `authState` is `.credentialsStale` and the account is SAML
//  with stored credentials — same shape as the existing PP-3703 playback-time
//  re-auth (`shouldTriggerSAMLReauthForPlaybackFailure`).
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

@MainActor
final class AudiobookLoadFailureSAMLReauthTests: XCTestCase {

    private var userAccountMock: TPPUserAccountMock!
    private var libraryMock: TPPLibraryAccountMock!

    override func setUp() {
        super.setUp()
        userAccountMock = TPPUserAccountMock()
        libraryMock = TPPLibraryAccountMock()
    }

    override func tearDown() {
        userAccountMock?.removeAll()
        userAccountMock = nil
        libraryMock = nil
        super.tearDown()
    }

    // MARK: - Triggers re-auth (true)

    /// Primary success case: SAML user with stored credentials whose authState
    /// has been latched to `.credentialsStale` upstream by the network layer
    /// (typical 401-on-fulfill scenario). The load failure type itself is not
    /// `.cancelled`, so re-auth should be offered before showing Try Again.
    func testShouldTrigger_whenStaleCredentialsAndSAMLAndBook() {
        userAccountMock._authDefinition = libraryMock.samlAuthentication
        userAccountMock._credentials = .barcodeAndPin(barcode: "user", pin: "1234")
        userAccountMock.setAuthState(.credentialsStale)
        let book = TPPBookMocker.mockBook(title: "Test Audiobook", authors: "Author")

        XCTAssertTrue(
            AudiobookSessionManager.shouldTriggerSAMLReauthForLoadFailure(
                loadError: .manifestFetchFailed,
                userAccount: userAccountMock,
                currentBook: book
            ),
            "Stale SAML credentials + a book to re-open should trigger re-auth on load failure (HelpSpot 17727)")
    }

    /// Different load-failure subtype but same prerequisite shape — predicate
    /// should not depend on which AudiobookLoadError fired (other than excluding
    /// .cancelled). Locks against future refactors that try to subset by error
    /// type and accidentally drop legitimate cases.
    func testShouldTrigger_forAnyNonCancelledLoadErrorWhenSAMLStale() {
        userAccountMock._authDefinition = libraryMock.samlAuthentication
        userAccountMock._credentials = .barcodeAndPin(barcode: "user", pin: "1234")
        userAccountMock.setAuthState(.credentialsStale)
        let book = TPPBookMocker.mockBook(title: "Test", authors: "Author")

        let nonCancelledErrors: [AudiobookLoadError] = [
            .tokenRefreshFailed(underlying: nil),
            .missingCredentialsForTokenRefresh,
            .manifestFetchFailed,
            .manifestParseFailed,
            .manifestSerializationFailed,
            .lcpNotAvailable,
            .lcpInstantiationFailed,
            .licenseDownloadFailed(underlying: nil),
            .missingFulfillURL,
            .missingContentDirectory,
            .factoryFailed(manifestType: nil)
        ]
        for err in nonCancelledErrors {
            XCTAssertTrue(
                AudiobookSessionManager.shouldTriggerSAMLReauthForLoadFailure(
                    loadError: err,
                    userAccount: userAccountMock,
                    currentBook: book
                ),
                "Non-cancelled load error \(err) with stale SAML credentials must trigger re-auth")
        }
    }

    // MARK: - Does not trigger re-auth (false)

    /// Cancellation is the user (or a superseded open) saying "stop". We must
    /// never drag them through a sign-in sheet for that.
    func testShouldNotTrigger_onCancelledLoadEvenWhenSAMLStale() {
        userAccountMock._authDefinition = libraryMock.samlAuthentication
        userAccountMock._credentials = .barcodeAndPin(barcode: "user", pin: "1234")
        userAccountMock.setAuthState(.credentialsStale)
        let book = TPPBookMocker.mockBook(title: "Test", authors: "Author")

        XCTAssertFalse(
            AudiobookSessionManager.shouldTriggerSAMLReauthForLoadFailure(
                loadError: .cancelled,
                userAccount: userAccountMock,
                currentBook: book
            ),
            ".cancelled must short-circuit before any other check — never re-auth on a cancelled load")
    }

    /// Healthy authState (`.loggedIn`) means the credentials haven't gone stale
    /// (or have been re-validated by a 2xx in the meantime — see the
    /// TPPNetworkResponder self-heal path). Don't re-auth in that case; the
    /// failure is more likely a real DRM/manifest issue and Try Again is the
    /// right surface.
    func testShouldNotTrigger_whenAuthStateIsLoggedIn() {
        userAccountMock._authDefinition = libraryMock.samlAuthentication
        userAccountMock._credentials = .barcodeAndPin(barcode: "user", pin: "1234")
        userAccountMock.setAuthState(.loggedIn)
        let book = TPPBookMocker.mockBook(title: "Test", authors: "Author")

        XCTAssertFalse(
            AudiobookSessionManager.shouldTriggerSAMLReauthForLoadFailure(
                loadError: .manifestFetchFailed,
                userAccount: userAccountMock,
                currentBook: book
            ),
            "loggedIn authState means no stale credentials — do not re-auth on load failure")
    }

    /// LoggedOut means there are no credentials to refresh — go through full
    /// sign-in flow, not the silent re-auth-with-existing-credentials path.
    func testShouldNotTrigger_whenAuthStateIsLoggedOut() {
        userAccountMock._authDefinition = libraryMock.samlAuthentication
        userAccountMock._credentials = nil
        userAccountMock.setAuthState(.loggedOut)
        let book = TPPBookMocker.mockBook(title: "Test", authors: "Author")

        XCTAssertFalse(
            AudiobookSessionManager.shouldTriggerSAMLReauthForLoadFailure(
                loadError: .manifestFetchFailed,
                userAccount: userAccountMock,
                currentBook: book
            ),
            "loggedOut authState — require full sign-in, not silent re-auth")
    }

    /// OAuth accounts use the token-refresh path, not the SAML re-auth path.
    /// The PP-3703 playback predicate makes the same distinction.
    func testShouldNotTrigger_forOAuthAccount() {
        userAccountMock._authDefinition = libraryMock.oauthAuthentication
        userAccountMock._credentials = .barcodeAndPin(barcode: "user", pin: "1234")
        userAccountMock.setAuthState(.credentialsStale)
        let book = TPPBookMocker.mockBook(title: "Test", authors: "Author")

        XCTAssertFalse(
            AudiobookSessionManager.shouldTriggerSAMLReauthForLoadFailure(
                loadError: .manifestFetchFailed,
                userAccount: userAccountMock,
                currentBook: book
            ),
            "OAuth account — token refresh path handles this, not SAML re-auth")
    }

    /// Basic-auth (barcode/PIN) accounts don't use SAML re-auth; sign-in surface
    /// is the standard credential prompt, not the SAML web sheet.
    func testShouldNotTrigger_forBasicAuthAccount() {
        userAccountMock._authDefinition = libraryMock.barcodeAuthentication
        userAccountMock._credentials = .barcodeAndPin(barcode: "user", pin: "1234")
        userAccountMock.setAuthState(.credentialsStale)
        let book = TPPBookMocker.mockBook(title: "Test", authors: "Author")

        XCTAssertFalse(
            AudiobookSessionManager.shouldTriggerSAMLReauthForLoadFailure(
                loadError: .manifestFetchFailed,
                userAccount: userAccountMock,
                currentBook: book
            ),
            "Basic-auth account — wrong re-auth surface")
    }

    /// Stale credentials but no stored credential material. Re-auth-with-
    /// existing isn't applicable; fall back to standard error.
    func testShouldNotTrigger_whenNoStoredCredentials() {
        userAccountMock._authDefinition = libraryMock.samlAuthentication
        userAccountMock._credentials = nil
        userAccountMock.setAuthState(.credentialsStale)
        let book = TPPBookMocker.mockBook(title: "Test", authors: "Author")

        XCTAssertFalse(
            AudiobookSessionManager.shouldTriggerSAMLReauthForLoadFailure(
                loadError: .manifestFetchFailed,
                userAccount: userAccountMock,
                currentBook: book
            ),
            "No stored credentials means nothing to re-auth with — full sign-in needed")
    }

    /// Without a current book reference, re-auth has nothing to re-attempt
    /// after success. The session manager invariant is that we only trigger
    /// re-auth when we can also re-execute the failed open.
    func testShouldNotTrigger_whenCurrentBookIsNil() {
        userAccountMock._authDefinition = libraryMock.samlAuthentication
        userAccountMock._credentials = .barcodeAndPin(barcode: "user", pin: "1234")
        userAccountMock.setAuthState(.credentialsStale)

        XCTAssertFalse(
            AudiobookSessionManager.shouldTriggerSAMLReauthForLoadFailure(
                loadError: .manifestFetchFailed,
                userAccount: userAccountMock,
                currentBook: nil
            ),
            "currentBook=nil — nothing to re-open after re-auth")
    }

    // MARK: - Cross-cutting invariant: regression guard

    /// The fix-is-real test — ties directly to HelpSpot 17727. Asserts the
    /// exact patron scenario fingerprint: SAML school library, stored
    /// credentials, session expired (credentialsStale), audiobook open
    /// fails. Before the fix this returned false-by-default (no equivalent
    /// helper existed) and the patron got a useless Try Again dialog.
    func testRegressionForBug_SAMLOpenFailureGetsReauth_perHelpSpot17727() {
        userAccountMock._authDefinition = libraryMock.samlAuthentication
        userAccountMock._credentials = .barcodeAndPin(barcode: "school-id", pin: "0000")
        userAccountMock.setAuthState(.credentialsStale)
        let book = TPPBookMocker.mockBook(title: "School Audiobook", authors: "Author")

        XCTAssertTrue(
            AudiobookSessionManager.shouldTriggerSAMLReauthForLoadFailure(
                loadError: .manifestFetchFailed,
                userAccount: userAccountMock,
                currentBook: book
            ),
            "REGRESSION GUARD (HelpSpot 17727): SAML patron whose session expired must get re-auth on audiobook open failure, not the useless Try Again dialog")
    }
}
