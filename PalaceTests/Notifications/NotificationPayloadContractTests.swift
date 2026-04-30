//
//  NotificationPayloadContractTests.swift
//  PalaceTests
//
//  Contract tests validating that iOS notification handling matches the
//  Palace circulation manager backend (ThePalaceProject/circulation).
//
//  Fixture: PalaceTests/Fixtures/API/notification_payloads.json
//  Source of truth: circulation/src/palace/manager/celery/tasks/notifications.py
//
//  If the CM backend changes notification payload field names, event types,
//  or structure, these tests catch it BEFORE users hit broken notifications.
//

import XCTest
@testable import Palace

// MARK: - Fixture Loader

private enum NotificationFixture {
    static func loadPayloads() -> [String: [String: Any]] {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/API/notification_payloads.json")
        let data = try! Data(contentsOf: path)
        return (try! JSONSerialization.jsonObject(with: data)) as! [String: [String: Any]]
    }
}

// MARK: - NotificationEventType Contract Tests

final class NotificationEventTypeContractTests: XCTestCase {

    /// The CM backend defines exactly 4 event types in NotificationType (StrEnum).
    /// Our iOS enum must have matching raw values.
    /// Source: circulation/src/palace/manager/celery/tasks/notifications.py
    private let cmEventTypes = ["HoldAvailable", "HoldRemoved", "LoanExpiry", "LoanRemoved"]

    func testAllCMEventTypes_ParseToiOSEnum() {
        for cmType in cmEventTypes {
            let parsed = NotificationService.NotificationEventType(rawValue: cmType)
            XCTAssertNotNil(parsed,
                "CM event_type '\(cmType)' must parse to NotificationEventType. " +
                "If the backend renamed this type, update the iOS enum to match.")
        }
    }

    func testHoldAvailable_IsHoldRelated() {
        let event = NotificationService.NotificationEventType(rawValue: "HoldAvailable")
        XCTAssertNotNil(event)
        XCTAssertTrue(event!.isHoldRelated,
            "HoldAvailable must be classified as hold-related for correct tab routing")
    }

    func testHoldRemoved_IsHoldRelated() {
        let event = NotificationService.NotificationEventType(rawValue: "HoldRemoved")
        XCTAssertNotNil(event)
        XCTAssertTrue(event!.isHoldRelated,
            "HoldRemoved must be classified as hold-related")
    }

    func testLoanExpiry_IsNotHoldRelated() {
        let event = NotificationService.NotificationEventType(rawValue: "LoanExpiry")
        XCTAssertNotNil(event)
        XCTAssertFalse(event!.isHoldRelated,
            "LoanExpiry must NOT be hold-related — it routes to My Books, not Holds")
    }

    func testLoanRemoved_IsNotHoldRelated() {
        let event = NotificationService.NotificationEventType(rawValue: "LoanRemoved")
        XCTAssertNotNil(event)
        XCTAssertFalse(event!.isHoldRelated,
            "LoanRemoved must NOT be hold-related")
    }

    func testiOSEnum_HasNoCasesUnknownToCM() {
        // Every iOS case must map to a CM backend type.
        // If we add an iOS-only case, this test flags it for backend alignment.
        let allCases: [NotificationService.NotificationEventType] = [
            .holdAvailable, .holdRemoved, .loanExpiry, .loanRemoved
        ]
        for iosCase in allCases {
            XCTAssertTrue(cmEventTypes.contains(iosCase.rawValue),
                "iOS enum case '\(iosCase.rawValue)' has no matching CM backend event type. " +
                "Either the backend needs to add it or the iOS case should be removed.")
        }
    }

    /// Unknown raw values return nil — production classifier falls back
    /// to APS keyword matching. Pin multiple distinct unknown values
    /// (including empty string) so a mutant that special-cases one
    /// unknown into a default enum case fails on a distinct row.
    func testUnknownEventType_returnsNilForAllUnrecognizedRawValues() {
        for rawValue in ["SomeNewType", "FutureEvent_v3", "garbage", ""] {
            XCTAssertNil(
                NotificationService.NotificationEventType(rawValue: rawValue),
                "Unknown raw value '\(rawValue)' must return nil — required for APS-keyword fallback")
        }
    }
}

// MARK: - Notification Payload Structure Contract Tests

final class NotificationPayloadContractTests: XCTestCase {

    private var payloads: [String: [String: Any]] = [:]

    override func setUp() {
        super.setUp()
        payloads = NotificationFixture.loadPayloads()
    }

    // MARK: - Required Fields

    /// Every CM notification payload MUST include event_type.
    /// This is the field iOS reads for routing — F-071 was caused by reading
    /// the wrong field ("type" instead of "event_type") for 4 years.
    func testAllPayloads_HaveEventTypeField() {
        XCTAssertGreaterThanOrEqual(payloads.count, 4, "Fixture must have all 4 payload types")
        for (key, payload) in payloads {
            let eventType = payload["event_type"] as? String
            XCTAssertNotNil(eventType, "\(key): must have 'event_type' field (not 'type')")
            XCTAssertFalse(eventType?.isEmpty ?? true, "\(key): event_type must not be empty")
        }
    }

    /// Every CM notification includes the book identifier type (e.g. "ISBN")
    /// in the "type" field. This is NOT the event type — verify iOS doesn't confuse them.
    func testAllPayloads_HaveIdentifierTypeField() {
        for (key, payload) in payloads {
            let identifierType = payload["type"] as? String
            XCTAssertNotNil(identifierType, "\(key): must have 'type' field (book identifier type)")
            // The 'type' field should NOT equal any event type value
            let eventType = payload["event_type"] as? String ?? ""
            XCTAssertNotEqual(identifierType, eventType,
                "\(key): 'type' (identifier) and 'event_type' must be different fields with different values")
        }
    }

    /// `identifier` and `library` are both required, non-empty string
    /// fields on every CM notification payload. iOS uses `identifier` to
    /// deduplicate and `library` to route to the right account. Pin both
    /// fields' presence + non-emptiness in one test so a mutant that
    /// drops emptiness validation on one of them is caught.
    func testAllPayloads_haveIdentifierAndLibraryAsNonEmptyStrings() {
        XCTAssertGreaterThanOrEqual(payloads.count, 4,
                                    "Fixture must have all 4 payload types — guards against an empty fixture mutant")

        for (key, payload) in payloads {
            let identifier = payload["identifier"] as? String
            XCTAssertNotNil(identifier, "\(key): missing 'identifier' field")
            XCTAssertFalse(identifier?.isEmpty ?? true,
                           "\(key): 'identifier' must be non-empty — empty would break dedup logic")

            let library = payload["library"] as? String
            XCTAssertNotNil(library, "\(key): missing 'library' field")
            XCTAssertFalse(library?.isEmpty ?? true,
                           "\(key): 'library' must be non-empty — empty would break per-account routing")
        }
    }

    func testAllPayloads_HaveLoansEndpointField() {
        for (key, payload) in payloads {
            let endpoint = payload["loans_endpoint"] as? String
            XCTAssertNotNil(endpoint,
                "\(key): must have 'loans_endpoint' field (URL for syncing loans)")
            if let endpoint = endpoint {
                XCTAssertTrue(endpoint.hasPrefix("https://"),
                    "\(key): loans_endpoint must be an HTTPS URL")
            }
        }
    }

    func testAllPayloads_HaveAPSAlert() {
        for (key, payload) in payloads {
            let aps = payload["aps"] as? [String: Any]
            XCTAssertNotNil(aps, "\(key): must have 'aps' dictionary")

            let alert = aps?["alert"] as? [String: Any]
            XCTAssertNotNil(alert, "\(key): aps must have 'alert' dictionary")
            XCTAssertNotNil(alert?["title"] as? String, "\(key): alert must have 'title'")
            XCTAssertNotNil(alert?["body"] as? String, "\(key): alert must have 'body'")
        }
    }

    // MARK: - Loan Expiry Specific

    func testLoanExpiry_HasDaysToExpiryField() {
        let payload = payloads["loan_expiry"]
        XCTAssertNotNil(payload, "Fixture must include loan_expiry payload")

        let days = payload?["days_to_expiry"] as? String
        XCTAssertNotNil(days,
            "loan_expiry must have 'days_to_expiry' field (string, not int — CM sends it as string)")

        if let days = days, let daysInt = Int(days) {
            XCTAssertGreaterThan(daysInt, 0, "days_to_expiry must be a positive integer string")
        }
    }

    func testNonExpiryPayloads_DoNotHaveDaysToExpiry() {
        for key in ["hold_available", "hold_removed", "loan_removed"] {
            let payload = payloads[key]
            XCTAssertNil(payload?["days_to_expiry"],
                "\(key): only loan_expiry should have days_to_expiry")
        }
    }

    // MARK: - Event Type → Payload Mapping

    func testEventTypes_MatchPayloadKeys() {
        let expectedMapping: [String: String] = [
            "hold_available": "HoldAvailable",
            "hold_removed": "HoldRemoved",
            "loan_expiry": "LoanExpiry",
            "loan_removed": "LoanRemoved",
        ]

        for (payloadKey, expectedEventType) in expectedMapping {
            let payload = payloads[payloadKey]
            XCTAssertNotNil(payload, "Fixture must include '\(payloadKey)' payload")
            XCTAssertEqual(payload?["event_type"] as? String, expectedEventType,
                "\(payloadKey) payload must have event_type='\(expectedEventType)'")
        }
    }

    // MARK: - iOS Parsing Integration

    /// Verify that real CM payloads parse through NotificationEventType correctly.
    /// This is the integration point — if this test fails, notification routing is broken.
    func testAllFixturePayloads_ParseThroughiOSEventTypeEnum() {
        for (key, payload) in payloads {
            guard let eventTypeString = payload["event_type"] as? String else {
                XCTFail("\(key): missing event_type")
                continue
            }
            let parsed = NotificationService.NotificationEventType(rawValue: eventTypeString)
            XCTAssertNotNil(parsed,
                "\(key): event_type '\(eventTypeString)' must parse to iOS NotificationEventType. " +
                "The CM backend and iOS enum are out of sync.")
        }
    }

    /// Verify hold classification matches expected routing for each payload.
    func testHoldClassification_MatchesExpectedRouting() {
        let expectedHoldRelated: [String: Bool] = [
            "hold_available": true,
            "hold_removed": true,
            "loan_expiry": false,
            "loan_removed": false,
        ]

        for (key, expectedIsHold) in expectedHoldRelated {
            guard let payload = payloads[key],
                  let eventTypeString = payload["event_type"] as? String,
                  let eventType = NotificationService.NotificationEventType(rawValue: eventTypeString) else {
                XCTFail("\(key): could not parse event type")
                continue
            }
            XCTAssertEqual(eventType.isHoldRelated, expectedIsHold,
                "\(key) (event_type='\(eventTypeString)'): isHoldRelated should be \(expectedIsHold). " +
                "Wrong classification causes navigation to the wrong tab.")
        }
    }
}
