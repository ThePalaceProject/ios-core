//
//  AccountProfileDocumentTests.swift
//  PalaceTests
//
//  Tests for Account+profileDocument.swift: getProfileDocument.
//  Covers High-priority coverage gap: getProfileDocument.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import PalaceCatalog
@testable import Palace

@MainActor
final class AccountProfileDocumentTests: XCTestCase {

    private var mockImageCache: MockImageCache!

    override func setUp() {
        super.setUp()
        mockImageCache = MockImageCache()
    }

    override func tearDown() {
        mockImageCache = nil
        super.tearDown()
    }

    // MARK: - getProfileDocument Tests

    func testGetProfileDocument_WithNilDetails_CompletesWithNil() {
        let publication = OPDS2Publication(
            links: [],
            metadata: OPDS2Publication.Metadata(
                updated: Date(),
                description: nil,
                id: "urn:uuid:test-profile",
                title: "Test Library"
            ),
            images: nil
        )
        let account = Account(publication: publication, imageCache: mockImageCache)
        XCTAssertNil(account.details)

        let expectation = XCTestExpectation(description: "Completion called")
        account.getProfileDocument { profileDocument in
            XCTAssertNil(profileDocument, "Should return nil when details is nil")
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 2.0)
    }

    /// F-007 regression guard: anonymous Palace Bookshelf was hitting
    /// `/patrons/me/` on every cold launch and getting a 401 because
    /// `getProfileDocument` fired the request whenever the auth document
    /// declared a `userProfileUrl`, regardless of whether the current user
    /// had credentials. Discovered by chaos-qa dogfood-3 + dogfood-5;
    /// gated in a single chokepoint at the Account extension. This test
    /// kills the gate-removal mutation on Palace/Accounts/Library/Account+profileDocument.swift.
    func testGetProfileDocument_WhenUserAccountHasNoCredentials_CompletesWithNil_DoesNotFetch() {
        let uuid = "urn:uuid:f007-no-creds-\(UUID().uuidString)"
        let publication = OPDS2Publication(
            links: [],
            metadata: OPDS2Publication.Metadata(
                updated: Date(),
                description: nil,
                id: uuid,
                title: "F-007 Test Library"
            ),
            images: nil
        )
        let account = Account(publication: publication, imageCache: mockImageCache)

        let json: [String: Any] = [
            "id": uuid,
            "title": "F-007 Test Library",
            "links": [
                ["rel": "http://librarysimplified.org/terms/rel/user-profile",
                 "href": "https://example.invalid/patrons/me/",
                 "type": "vnd.librarysimplified/user-profile+json"]
            ],
            "authentication": []
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        let authDoc = try! OPDS2AuthenticationDocument.fromData(data)
        account.authenticationDocument = authDoc

        XCTAssertNotNil(account.details?.userProfileUrl,
                        "Test setup precondition: auth doc must declare a user-profile URL.")

        let expectation = XCTestExpectation(description: "Completion called without network")
        let start = Date()
        account.getProfileDocument { profileDocument in
            XCTAssertNil(profileDocument,
                         "Gate must short-circuit when no credentials are stored.")
            XCTAssertLessThan(Date().timeIntervalSince(start), 1.0,
                              "Gate must NOT issue a network request — should return synchronously-fast.")
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 3.0)
    }

    // MARK: - The gate decision (states x events, asserted directly)
    //
    // These assert the PREDICATE, not `getProfileDocument`, and that is
    // deliberate. `getProfileDocument` reaches `AppContainer.production()`
    // internally, so no test can observe whether the request was actually
    // issued. The F-007 test above claims to "kill the gate-removal mutation";
    // measured on 2026-09-03 it does not — with the entire credentials gate
    // deleted, every test in this file still passed, because
    // `https://example.invalid/` fails DNS fast enough to satisfy both a nil
    // result and a sub-second bound whether or not the request was sent.
    // The decision is therefore lifted into `canAuthenticateProfileRequest`
    // where it can genuinely be falsified, and these four cases are its
    // complete truth table.

    /// Live credentials: the only cell that may reach the network.
    func testCanAuthenticate_WithValidUnexpiredCredentials_IsTrue() {
        XCTAssertTrue(
            Account.canAuthenticateProfileRequest(hasCredentials: true,
                                                  tokenHasExpired: false),
            "Usable credentials must reach /patrons/me/ — otherwise profile fetch, "
            + "and with it FCM device registration, is dead for every signed-in patron.")
    }

    /// The reported defect: present but expired.
    func testCanAuthenticate_WithExpiredToken_IsFalse() {
        XCTAssertFalse(
            Account.canAuthenticateProfileRequest(hasCredentials: true,
                                                  tokenHasExpired: true),
            "An expired token must NOT be sent. It passes hasCredentials() (presence, "
            + "not validity), takes a 401 that cannot self-heal under "
            + "enableTokenRefresh: false, and surfaces to callers as 'signed out'.")
    }

    /// The original F-007 case, now actually asserted.
    func testCanAuthenticate_WithNoCredentials_IsFalse() {
        XCTAssertFalse(
            Account.canAuthenticateProfileRequest(hasCredentials: false,
                                                  tokenHasExpired: false),
            "Anonymous libraries advertise a userProfileUrl but store no credentials; "
            + "firing anyway is the /patrons/me/ 401 storm of PP-4164 / F-007.")
    }

    /// Degenerate but reachable: no credentials AND a stale expiry flag.
    /// Pinned so the predicate cannot be rewritten as `!tokenHasExpired` alone,
    /// which would pass all three cells above.
    func testCanAuthenticate_WithNoCredentialsAndExpiredFlag_IsFalse() {
        XCTAssertFalse(
            Account.canAuthenticateProfileRequest(hasCredentials: false,
                                                  tokenHasExpired: true),
            "Absence of credentials is decisive on its own.")
    }
}
