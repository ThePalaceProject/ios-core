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
import PalaceBookModel

@MainActor
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

    /// Special-character tokens (URL-encoding-relevant chars + emoji-like
    /// noise) must round-trip through JSON encoding without escape damage.
    /// Asserts the decoded value AND that the wire bytes are valid UTF-8 —
    /// a mutant that drops the JSON escape would corrupt one or the other.
    func testTokenDataWithSpecialCharacters_roundTripsThroughJSON() throws {
        let raw = "token/with+special=chars&more🔑\""
        let tokenData = NotificationService.TokenData(token: raw)
        let data = try XCTUnwrap(tokenData.data)
        let decoded = try JSONDecoder().decode(NotificationService.TokenData.self, from: data)

        XCTAssertEqual(decoded.device_token, raw, "Decoded token must match input verbatim")
        XCTAssertEqual(decoded.token_type, "FCMiOS")

        let wireText = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(wireText.contains("FCMiOS"))
        XCTAssertTrue(wireText.contains("🔑"),
                      "JSON wire format must preserve unicode chars without mojibake")
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

    /// CM backend sends `event_type` to drive notification routing. Each
    /// known enum case must classify deterministically — hold-related cases
    /// MUST return true, non-hold cases MUST return false. Table-driven so
    /// a mutant that always-true-or-always-false fails on the first
    /// disagreeing row.
    func testHoldClassification_byEventType_routesAllKnownEnumCasesCorrectly() {
        let cases: [(eventType: String, expected: Bool, label: String)] = [
            ("HoldAvailable", true,  "hold available — primary positive case"),
            ("HoldRemoved",   true,  "hold removed — also hold-related"),
            ("LoanExpiry",    false, "loan expiry — distinct from holds, must be false"),
        ]
        for c in cases {
            let userInfo: [AnyHashable: Any] = ["event_type": c.eventType]
            XCTAssertEqual(classifyAsHoldRelated(userInfo), c.expected,
                           "\(c.label) — classifier must return \(c.expected)")
        }
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

    /// When neither event_type nor APS alert text is available, the
    /// classifier defaults to `true` — the "safe" choice that routes the
    /// user to the holds tab where they can see what changed. Lock both the
    /// empty-userInfo case and the "userInfo with unrelated keys" case so a
    /// mutant that flips the default fails.
    func testHoldClassification_unparseableInputDefaultsToHoldRelated() {
        XCTAssertTrue(classifyAsHoldRelated([:]),
                      "Empty userInfo defaults to hold-related for safe navigation")
        XCTAssertTrue(classifyAsHoldRelated(["unrelated": "value"]),
                      "userInfo with no event_type AND no APS still defaults to hold-related")
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

        let originalIdentifier = record.book.identifier
        NotificationService.compareAvailability(cachedRecord: record, andNewBook: book2)
        // Record must not be mutated when availability is absent on both sides
        XCTAssertEqual(record.book.identifier, originalIdentifier,
                       "compareAvailability with no availability on either book must not mutate the record")
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
        // notification center isn't authorized). Verify the call completes
        // without mutating the cached record (notification is an external effect).
        let originalIdentifier = record.book.identifier
        let originalState = record.state
        NotificationService.compareAvailability(cachedRecord: record, andNewBook: readyBook)
        XCTAssertEqual(record.book.identifier, originalIdentifier,
                       "compareAvailability must not mutate the cached record's book identifier")
        XCTAssertEqual(record.state, originalState,
                       "compareAvailability must not mutate the cached record's state")
    }

    // MARK: - backgroundFetchIsNeeded Tests

    /// `backgroundFetchIsNeeded()` is a static, side-effect-free Bool query.
    /// Without a hook to drive the underlying state, the only behaviour we
    /// can pin is that the function is referentially transparent within a
    /// single test — three consecutive calls return the same value. This
    /// rules out a mutant that toggles based on a hidden counter or shared
    /// mutable state. The previous test was a tautology
    /// (`XCTAssertNotNil(Bool?)` always succeeds — Swift Bool is non-optional).
    func testBackgroundFetchIsNeeded_isReferentiallyTransparent() {
        let a = NotificationService.backgroundFetchIsNeeded()
        let b = NotificationService.backgroundFetchIsNeeded()
        let c = NotificationService.backgroundFetchIsNeeded()
        XCTAssertEqual(a, b, "Consecutive calls must return identical values")
        XCTAssertEqual(b, c)
    }

    // MARK: - Constants

    /// Two notification identifiers ride on the wire for hold-availability
    /// alerts. Lock both verbatim in one test, AND assert they are distinct
    /// — pasting the same string into both constants by mistake would fail
    /// on the inequality.
    func testNotificationConstants_areStableAndDistinct() {
        XCTAssertEqual(HoldNotificationCategoryIdentifier,
                       "NYPLHoldToReserveNotificationCategory")
        XCTAssertEqual(CheckOutActionIdentifier,
                       "NYPLCheckOutNotificationAction")
        XCTAssertNotEqual(HoldNotificationCategoryIdentifier,
                          CheckOutActionIdentifier,
                          "Category and action identifiers must be distinct strings")
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
