//
//  NotificationServiceTests.swift
//  PalaceTests
//
//  Tests for NotificationService: token data encoding, hold notification classification
//  logic, sync throttling keys, and availability comparison paths.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class NotificationServiceTests: XCTestCase {

    // MARK: - TokenData Tests

    func testTokenDataEncoding() throws {
        let tokenData = NotificationService.TokenData(token: "abc123")
        XCTAssertEqual(tokenData.device_token, "abc123")
        XCTAssertEqual(tokenData.token_type, "FCMiOS")

        let data = try XCTUnwrap(tokenData.data)
        let decoded = try JSONDecoder().decode(NotificationService.TokenData.self, from: data)
        XCTAssertEqual(decoded.device_token, "abc123")
        XCTAssertEqual(decoded.token_type, "FCMiOS")
    }

    func testTokenDataEncodesToValidJSON() throws {
        let tokenData = NotificationService.TokenData(token: "test-fcm-token-xyz")
        let data = try XCTUnwrap(tokenData.data)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])

        XCTAssertEqual(json["device_token"], "test-fcm-token-xyz")
        XCTAssertEqual(json["token_type"], "FCMiOS")
        XCTAssertEqual(json.count, 2, "TokenData should only have two fields")
    }

    func testTokenDataWithEmptyToken() throws {
        let tokenData = NotificationService.TokenData(token: "")
        XCTAssertEqual(tokenData.device_token, "")
        XCTAssertNotNil(tokenData.data, "Even an empty token should produce valid JSON data")
    }

    func testTokenDataWithSpecialCharacters() throws {
        let tokenData = NotificationService.TokenData(token: "token/with+special=chars&more")
        let data = try XCTUnwrap(tokenData.data)
        let decoded = try JSONDecoder().decode(NotificationService.TokenData.self, from: data)
        XCTAssertEqual(decoded.device_token, "token/with+special=chars&more")
    }

    func testTokenDataCodableRoundTrip() throws {
        let original = NotificationService.TokenData(token: "round-trip-token")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(NotificationService.TokenData.self, from: data)

        XCTAssertEqual(original.device_token, decoded.device_token)
        XCTAssertEqual(original.token_type, decoded.token_type)
    }

    // MARK: - Hold Notification Classification Logic Tests
    //
    // Since isHoldRelatedNotification is private, we test the logic inline.
    // This mirrors the implementation to ensure the classification rules are correct.

    func testHoldClassificationWithExplicitHoldEventType() {
        // CM backend sends event_type (not type) for notification routing
        let userInfo: [AnyHashable: Any] = ["event_type": "HoldAvailable"]
        XCTAssertTrue(classifyAsHoldRelated(userInfo),
                       "HoldAvailable event_type should be classified as hold-related")
    }

    func testHoldClassificationWithHoldRemovedEventType() {
        let userInfo: [AnyHashable: Any] = ["event_type": "HoldRemoved"]
        XCTAssertTrue(classifyAsHoldRelated(userInfo),
                       "HoldRemoved event_type should be classified as hold-related")
    }

    func testHoldClassificationWithLoanExpiryEventType() {
        let userInfo: [AnyHashable: Any] = ["event_type": "LoanExpiry"]
        XCTAssertFalse(classifyAsHoldRelated(userInfo),
                        "LoanExpiry event_type should NOT be hold-related")
    }

    func testHoldClassificationWithAPSAlertContainingAvailableKeyword() {
        let userInfo: [AnyHashable: Any] = [
            "aps": [
                "alert": [
                    "title": "Hold Available",
                    "body": "Your book is ready to borrow."
                ]
            ]
        ]
        XCTAssertTrue(classifyAsHoldRelated(userInfo))
    }

    func testHoldClassificationWithAPSAlertContainingReadyKeyword() {
        let userInfo: [AnyHashable: Any] = [
            "aps": [
                "alert": [
                    "title": "Book Ready",
                    "body": "Check it out now."
                ]
            ]
        ]
        XCTAssertTrue(classifyAsHoldRelated(userInfo))
    }

    func testHoldClassificationWithNonHoldAPSAlert() {
        let userInfo: [AnyHashable: Any] = [
            "aps": [
                "alert": [
                    "title": "New Feature",
                    "body": "Check out our updated app."
                ]
            ]
        ]
        XCTAssertFalse(classifyAsHoldRelated(userInfo))
    }

    func testHoldClassificationWithEmptyUserInfoDefaultsToTrue() {
        let userInfo: [AnyHashable: Any] = [:]
        XCTAssertTrue(classifyAsHoldRelated(userInfo),
                       "Empty userInfo should default to hold-related for safe navigation")
    }

    func testHoldClassificationFallback_WhenEventTypeNotInEnum() {
        // If CM sends a new event type not yet in our enum, falls back to APS keyword matching
        let userInfo: [AnyHashable: Any] = [
            "event_type": "SomeNewHoldType",
            "aps": ["alert": ["title": "Hold Update", "body": "Your hold status changed"]]
        ]
        XCTAssertTrue(classifyAsHoldRelated(userInfo),
                       "Unknown event_type with 'hold' in APS text should still be classified as hold-related")
    }

    func testHoldClassificationWithReservationInBody() {
        let userInfo: [AnyHashable: Any] = [
            "aps": [
                "alert": [
                    "title": "Library Update",
                    "body": "Your reservation is ready!"
                ]
            ]
        ]
        XCTAssertTrue(classifyAsHoldRelated(userInfo))
    }

    // MARK: - compareAvailability Tests (Static Method)

    func testCompareAvailabilityDoesNotCrashWithNoAvailability() {
        // Create two books without availability info
        let book1 = TPPBookMocker.mockBook(distributorType: .EpubZip)
        let book2 = TPPBookMocker.mockBook(distributorType: .EpubZip)

        let record = TPPBookRegistryRecord(
            book: book1,
            location: nil,
            state: .holding,
            fulfillmentId: nil,
            readiumBookmarks: [],
            genericBookmarks: []
        )

        // Should not crash
        NotificationService.compareAvailability(cachedRecord: record, andNewBook: book2)
    }

    func testCompareAvailabilityReservedToReady() {
        // Create a book with reserved availability
        let reservedBook = TPPBookMocker.snapshotReservedBook(
            identifier: "hold-test",
            title: "Reserved Book",
            holdPosition: 1
        )

        let record = TPPBookRegistryRecord(
            book: reservedBook,
            location: nil,
            state: .holding,
            fulfillmentId: nil,
            readiumBookmarks: [],
            genericBookmarks: []
        )

        // Create the same book but now with ready availability
        let readyBook = TPPBookMocker.snapshotReadyBook(
            identifier: "hold-test",
            title: "Reserved Book"
        )

        // This should trigger a local notification (but won't in test since
        // notification center isn't authorized). We verify it doesn't crash.
        NotificationService.compareAvailability(cachedRecord: record, andNewBook: readyBook)
    }

    // MARK: - backgroundFetchIsNeeded Tests

    func testBackgroundFetchIsNeededReturnsBoolean() {
        let result = NotificationService.backgroundFetchIsNeeded()
        // Just verify it returns without crashing
        XCTAssertNotNil(result as Bool?)
    }

    // MARK: - Constants

    func testNotificationCategoryIdentifier() {
        XCTAssertEqual(HoldNotificationCategoryIdentifier, "NYPLHoldToReserveNotificationCategory")
    }

    func testCheckOutActionIdentifier() {
        XCTAssertEqual(CheckOutActionIdentifier, "NYPLCheckOutNotificationAction")
    }

    // MARK: - Helpers

    /// Mirrors the private isHoldRelatedNotification logic for testing.
    ///
    /// This must stay in sync with the production code in NotificationService.
    /// Primary path: parse event_type via NotificationEventType enum.
    /// Fallback: keyword match on APS alert text.
    private func classifyAsHoldRelated(_ userInfo: [AnyHashable: Any]) -> Bool {
        // Primary: CM backend's event_type field (matches production code)
        if let rawType = userInfo["event_type"] as? String,
           let event = NotificationService.NotificationEventType(rawValue: rawType) {
            return event.isHoldRelated
        }

        // Fallback: keyword match on APS alert text
        if let aps = userInfo["aps"] as? [String: Any],
           let alert = aps["alert"] as? [String: Any] {
            let title = (alert["title"] as? String)?.lowercased() ?? ""
            let body = (alert["body"] as? String)?.lowercased() ?? ""
            let keywords = ["available", "ready", "hold", "reservation"]
            return keywords.contains { title.contains($0) || body.contains($0) }
        }

        // Legacy fallback: check event_type as raw string
        if let type = userInfo["event_type"] as? String {
            return type.lowercased().contains("hold")
        }

        return true
    }
}
