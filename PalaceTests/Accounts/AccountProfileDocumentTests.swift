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

    func testGetProfileDocument_WithDetailsButNilProfileUrl_CompletesWithNil() {
        let publication = OPDS2Publication(
            links: [],
            metadata: OPDS2Publication.Metadata(
                updated: Date(),
                description: nil,
                id: "urn:uuid:test-profile-2",
                title: "Test Library"
            ),
            images: nil
        )
        let account = Account(publication: publication, imageCache: mockImageCache)

        // Create minimal auth doc without a user-profile link
        let json: [String: Any] = [
            "id": "urn:uuid:test-profile-2",
            "title": "Test Library",
            "authentication": []
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        let authDoc = try! OPDS2AuthenticationDocument.fromData(data)
        account.authenticationDocument = authDoc

        // Details exist but userProfileUrl should be nil (no user-profile link)
        XCTAssertNotNil(account.details)
        XCTAssertNil(account.details?.userProfileUrl)

        let expectation = XCTestExpectation(description: "Completion called")
        account.getProfileDocument { profileDocument in
            XCTAssertNil(profileDocument, "Should return nil when userProfileUrl is nil")
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 2.0)
    }
}
