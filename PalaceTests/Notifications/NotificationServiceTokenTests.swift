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
        XCTAssertEqual(tokenData.token_type, "FCMiOS")
    }

    func testTokenData_data_isNotNil() {
        let tokenData = NotificationService.TokenData(token: "test-token-value")
        XCTAssertNotNil(tokenData.data)
    }

    func testTokenData_emptyToken_stillEncodes() throws {
        let tokenData = NotificationService.TokenData(token: "")

        let data = try XCTUnwrap(tokenData.data)
        let decoded = try JSONDecoder().decode(NotificationService.TokenData.self, from: data)

        XCTAssertEqual(decoded.device_token, "")
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
    }

    func testCheckOutActionIdentifier_isCorrect() {
        XCTAssertEqual(CheckOutActionIdentifier, "NYPLCheckOutNotificationAction")
    }

    func testDefaultActionIdentifier_isCorrect() {
        XCTAssertEqual(DefaultActionIdentifier, "UNNotificationDefaultActionIdentifier")
    }

    // MARK: - Singleton

    func testSharedService_returnsSameAsShared() {
        let fromShared = NotificationService.shared
        let fromMethod = NotificationService.sharedService()
        XCTAssertTrue(fromShared === fromMethod)
    }
}
