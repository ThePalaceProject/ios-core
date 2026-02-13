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
