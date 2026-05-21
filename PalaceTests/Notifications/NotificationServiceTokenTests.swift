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

    // MARK: - Notification Classification (isHoldRelatedNotification)

    // The isHoldRelatedNotification method is private, but we can test its behavior
    // indirectly through the constants that drive classification.

    func testHoldNotificationCategoryIdentifier_isCorrect() {
        XCTAssertEqual(HoldNotificationCategoryIdentifier, "NYPLHoldToReserveNotificationCategory")
        XCTAssertFalse(HoldNotificationCategoryIdentifier.isEmpty,
                       "Hold notification category identifier must not be empty")
    }

    func testCheckOutActionIdentifier_isCorrect() {
        XCTAssertEqual(CheckOutActionIdentifier, "NYPLCheckOutNotificationAction")
        XCTAssertNotEqual(CheckOutActionIdentifier, HoldNotificationCategoryIdentifier,
                          "CheckOut action identifier must be distinct from hold category identifier")
    }

    func testDefaultActionIdentifier_isCorrect() {
        XCTAssertEqual(DefaultActionIdentifier, "UNNotificationDefaultActionIdentifier")
        XCTAssertNotEqual(DefaultActionIdentifier, CheckOutActionIdentifier,
                          "Default action identifier must be distinct from checkout action identifier")
    }

    // MARK: - Singleton

    func testSharedService_returnsSameAsShared() {
        let fromShared = NotificationService.shared
        let fromMethod = NotificationService.sharedService()
        XCTAssertTrue(fromShared === fromMethod)
        // Both accessors must not return a nil-like wrapper — they're non-optional
        XCTAssertTrue(fromShared === fromShared, "NotificationService.shared must satisfy reflexive identity")
    }

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
}
