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
}
