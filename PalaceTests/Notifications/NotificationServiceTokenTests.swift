//
//  NotificationServiceTokenTests.swift
//  PalaceTests
//
//  Unit tests for NotificationService.TokenData encoding and
//  notification classification logic.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

/// SRS: SET-001 — Push notification token data encodes correctly for backend API
@MainActor
final class NotificationServiceTokenTests: XCTestCase {

    // MARK: - TokenData

    func testTokenData_encodesCorrectJSON() throws {
        let tokenData = NotificationService.TokenData(token: "abc123")

        let data = try XCTUnwrap(tokenData.data)
        let decoded = try JSONDecoder().decode(NotificationService.TokenData.self, from: data)

        XCTAssertEqual(decoded.device_token, "abc123")
        XCTAssertEqual(decoded.token_type, "FCMiOS")
    }

    func testTokenData_tokenType_isAlwaysFCMiOS() {
        let tokenData = NotificationService.TokenData(token: "anything")
        XCTAssertEqual(tokenData.token_type, "FCMiOS",
                       "token_type must always be FCMiOS regardless of the token value")
        // The device_token field must also reflect the provided token
        XCTAssertEqual(tokenData.device_token, "anything",
                       "device_token must store the exact token passed to the initializer")
    }

    func testTokenData_data_isNotNil() {
        let tokenData = NotificationService.TokenData(token: "test-token-value")
        XCTAssertNotNil(tokenData.data, "TokenData.data must not be nil")
        // The encoded data must be non-empty JSON bytes
        if let data = tokenData.data {
            XCTAssertGreaterThan(data.count, 0, "Encoded token data must have non-zero byte count")
            // Must be valid JSON
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: data),
                             "TokenData.data must produce valid JSON")
        }
    }

    func testTokenData_emptyToken_stillEncodes() throws {
        let tokenData = NotificationService.TokenData(token: "")

        let data = try XCTUnwrap(tokenData.data)
        let decoded = try JSONDecoder().decode(NotificationService.TokenData.self, from: data)

        XCTAssertEqual(decoded.device_token, "")
        XCTAssertEqual(decoded.token_type, "FCMiOS",
                       "token_type must be FCMiOS even when token is an empty string")
    }

    func testTokenData_longToken_encodesCorrectly() throws {
        let longToken = String(repeating: "x", count: 500)
        let tokenData = NotificationService.TokenData(token: longToken)

        let data = try XCTUnwrap(tokenData.data)
        let decoded = try JSONDecoder().decode(NotificationService.TokenData.self, from: data)

        XCTAssertEqual(decoded.device_token, longToken)
    }

    // Constant-equals-literal-string tests for HoldNotificationCategoryIdentifier,
    // CheckOutActionIdentifier, and DefaultActionIdentifier were removed per
    // CLAUDE.md "Banned test patterns" — they test the compiler, not behavior.
    // Same with testSharedService_returnsSameAsShared (reflexive identity tautology).
    // Reviewers rev_8cd9d48c and rev_1d39b5c0 both flagged these in the swarm review.
    // The substantive coverage lives in `shouldRetryTokenRegistration` below.

    // MARK: - shouldRetryTokenRegistration (pure decision helper, swarm_f3b9b087 item #6)
    //
    // The auth-state-change retry path is driven by a pure decision
    // helper so mutation testing can pin every branch without standing
    // up a Combine subscription. The helper answers:
    // "given an auth-state transition AND the current hasUpdatedToken
    // flag, should the service re-attempt FCM token registration?"
    //
    // True iff the transition lands on `.loggedIn` from a non-`.loggedIn`
    // state AND `hasUpdatedToken == false`. False otherwise.

    func testShouldRetryTokenRegistration_staleToLoggedIn_withFlagFalse_retries() {
        XCTAssertTrue(
            NotificationService.shouldRetryTokenRegistration(
                previous: .credentialsStale,
                current: .loggedIn,
                hasUpdatedToken: false
            ),
            "Stale→LoggedIn with hasUpdatedToken=false must retry (the SAML-stale recovery path)")
    }

    func testShouldRetryTokenRegistration_loggedOutToLoggedIn_withFlagFalse_retries() {
        XCTAssertTrue(
            NotificationService.shouldRetryTokenRegistration(
                previous: .loggedOut,
                current: .loggedIn,
                hasUpdatedToken: false
            ),
            "LoggedOut→LoggedIn (fresh sign-in) with hasUpdatedToken=false must retry")
    }

    func testShouldRetryTokenRegistration_loggedInToLoggedIn_doesNotRetry() {
        XCTAssertFalse(
            NotificationService.shouldRetryTokenRegistration(
                previous: .loggedIn,
                current: .loggedIn,
                hasUpdatedToken: false
            ),
            "Idempotency: LoggedIn→LoggedIn must NOT trigger a retry — there was no recovery transition")
    }

    func testShouldRetryTokenRegistration_loggedInToStale_doesNotRetry() {
        XCTAssertFalse(
            NotificationService.shouldRetryTokenRegistration(
                previous: .loggedIn,
                current: .credentialsStale,
                hasUpdatedToken: false
            ),
            "Wrong direction: LoggedIn→Stale must NOT retry — credentials just went bad")
    }

    func testShouldRetryTokenRegistration_loggedInToLoggedOut_doesNotRetry() {
        XCTAssertFalse(
            NotificationService.shouldRetryTokenRegistration(
                previous: .loggedIn,
                current: .loggedOut,
                hasUpdatedToken: false
            ),
            "Wrong direction: LoggedIn→LoggedOut must NOT retry — user signed out")
    }

    func testShouldRetryTokenRegistration_staleToLoggedIn_withFlagTrue_doesNotRetry() {
        XCTAssertFalse(
            NotificationService.shouldRetryTokenRegistration(
                previous: .credentialsStale,
                current: .loggedIn,
                hasUpdatedToken: true
            ),
            "hasUpdatedToken=true must short-circuit — token is already registered, no need to retry")
    }

    func testShouldRetryTokenRegistration_staleToStale_doesNotRetry() {
        XCTAssertFalse(
            NotificationService.shouldRetryTokenRegistration(
                previous: .credentialsStale,
                current: .credentialsStale,
                hasUpdatedToken: false
            ),
            "Stale→Stale is not a recovery transition — must NOT retry")
    }

    func testShouldRetryTokenRegistration_loggedOutToLoggedOut_doesNotRetry() {
        XCTAssertFalse(
            NotificationService.shouldRetryTokenRegistration(
                previous: .loggedOut,
                current: .loggedOut,
                hasUpdatedToken: false
            ),
            "LoggedOut→LoggedOut: no transition, no retry")
    }
    // MARK: - PP-4958: which nil-profile outcomes are worth reporting

    /// The whole states x report table. A signed-out patron has nothing to
    /// register, so a nil profile is the CORRECT outcome, not a failure — the
    /// observed traffic includes exactly that case (a Settings library switch
    /// to a library the patron is not signed in to). Every other state means
    /// the patron SHOULD have been registered and was not, which is the signal
    /// worth keeping.
    func testShouldReportProfileFetchFailure_loggedOut_isNotReported() {
        XCTAssertFalse(NotificationService.shouldReportProfileFetchFailure(authState: .loggedOut),
                       "a signed-out patron has nothing to register — reporting it is the noise that buried the real failures")
    }

    func testShouldReportProfileFetchFailure_loggedIn_isReported() {
        XCTAssertTrue(NotificationService.shouldReportProfileFetchFailure(authState: .loggedIn),
                      "a signed-in patron with no profile document genuinely failed to register — that is the signal")
    }

    func testShouldReportProfileFetchFailure_credentialsStale_isReported() {
        XCTAssertTrue(NotificationService.shouldReportProfileFetchFailure(authState: .credentialsStale),
                      "stale credentials still mean a patron who should be registered is not")
    }

    // MARK: - PP-4958: the readiness gate must stay bounded

    /// An unbounded `awaitReady()` behind a background path is the documented
    /// HelpSpot #18414 load-forever wedge, and this gate runs from a Firebase
    /// callback at launch where nothing is watching. Pinning it finite is the
    /// point; the exact value is a tuning choice.
    func testAccountReadinessTimeout_isFiniteAndPositive() {
        let timeout = NotificationService.accountReadinessTimeout
        XCTAssertGreaterThan(timeout, 0, "a non-positive timeout would fail every launch registration outright")
        XCTAssertLessThanOrEqual(timeout, 60, "the gate must stay bounded — an unbounded wait here is the #18414 wedge class")
        // Against the SYMBOL, not the number. The invariant is a relationship:
        // at exactly authDocInflightTimeout the wait expires in the same instant
        // the wedge-reclaim re-fires, so it can never benefit from the reclaim
        // its rationale depends on. Hardcoding 30 would silently stop testing
        // that the day the loader's constant moves.
        XCTAssertGreaterThan(timeout, AuthDocumentLoader.authDocInflightTimeout,
                             "must EXCEED authDocInflightTimeout, or the wait expires exactly as the wedge-reclaim re-fires")
    }
    // MARK: - PP-4958: readiness-failure classification (this arm was wrong twice)

    /// The COMPLETE `AccountLoadError` table. Two of these are expected outcomes
    /// and must stay quiet; three mean the authentication document will not
    /// arrive and must be reported. Reporting `.evicted` filed a false failure on
    /// every library switch — against the very metric the fix is measured by.
    func testReadinessFailure_timeout_isResidualNotQuiet() {
        XCTAssertEqual(NotificationService.disposition(forReadinessFailure: .readinessTimedOut(timeout: 45)), .residual,
                       "silencing the timeout would drive the metric this fix is judged by to near-zero whether registration succeeds or the account is never driven — the fix must stay falsifiable")
    }

    func testReadinessFailure_evicted_isQuiet() {
        XCTAssertEqual(NotificationService.disposition(forReadinessFailure: .evicted(reason: .libraryDeselected(uuid: "u"))), .quiet,
                       "a library switch is a normal user action and IS re-driven — reporting it files false failures")
    }

    func testReadinessFailure_fetchFailed_isReported() {
        XCTAssertEqual(NotificationService.disposition(forReadinessFailure: .authDocumentFetchFailed(underlyingDescription: "500")), .report)
    }

    func testReadinessFailure_malformed_isReported() {
        XCTAssertEqual(NotificationService.disposition(forReadinessFailure: .malformedAuthDocument(reason: "no links")), .report)
    }

    func testReadinessFailure_accountNotFound_isReported() {
        XCTAssertEqual(NotificationService.disposition(forReadinessFailure: .accountNotFound(uuid: "u")), .report)
    }

    // MARK: - PP-4958: per-account claim

    func testRegistrationClaims_firstClaimSucceeds_secondForSameAccountIsRejected() {
        let claims = NotificationService.RegistrationClaims()
        XCTAssertTrue(claims.claim("A"))
        XCTAssertFalse(claims.claim("A"), "a second attempt for the SAME account must not run concurrently")
    }

    func testRegistrationClaims_differentAccountIsNotBlocked() {
        let claims = NotificationService.RegistrationClaims()
        XCTAssertTrue(claims.claim("A"))
        XCTAssertTrue(claims.claim("B"),
                      "a library switch must not have the incoming account's registration swallowed by the outgoing one — that left the new library unregistered until relaunch")
    }

    func testRegistrationClaims_releaseAllowsARetry() {
        let claims = NotificationService.RegistrationClaims()
        XCTAssertTrue(claims.claim("A"))
        claims.release("A")
        XCTAssertTrue(claims.claim("A"), "a released slot must be reclaimable, or one failed attempt disables registration for the process")
    }
}
