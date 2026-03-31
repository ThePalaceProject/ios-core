//
//  ShareServiceExtendedTests.swift
//  PalaceTests
//
//  Extended coverage for ShareService: edge cases and format validation.
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class ShareServiceExtendedTests: XCTestCase {

    private var sut: ShareService!

    override func setUp() {
        super.setUp()
        sut = ShareService()
    }

    override func tearDown() {
        sut = nil
        super.tearDown()
    }

    // MARK: - Deep Link Format Validation

    func testDeepLink_Format_ContainsBookPath() {
        let book = TPPBookMocker.mockBook(identifier: "abc-123", title: "Test")
        let link = sut.deepLink(for: book)

        XCTAssertNotNil(link)
        XCTAssertEqual(link?.scheme, "palace")
        XCTAssertEqual(link?.host, "book")
    }

    func testDeepLink_PercentEncodesSpecialCharacters() {
        let book = TPPBookMocker.mockBook(identifier: "id with spaces", title: "Test")
        let link = sut.deepLink(for: book)

        XCTAssertNotNil(link)
        XCTAssertFalse(link?.absoluteString.contains(" ") ?? true,
                        "Spaces should be percent-encoded")
    }

    func testDeepLink_PreservesSimpleIdentifier() {
        let book = TPPBookMocker.mockBook(identifier: "simple-id-123", title: "Test")
        let link = sut.deepLink(for: book)

        XCTAssertTrue(link?.absoluteString.contains("simple-id-123") ?? false)
    }

    // MARK: - Share Text Edge Cases

    func testShareText_BookWithNoAuthor_OmitsAuthorPart() {
        let book = TPPBookMocker.mockBook(identifier: "no-author", title: "Orphan Book", authors: nil)
        let text = sut.shareText(for: book)

        XCTAssertTrue(text.contains("Orphan Book"))
        XCTAssertFalse(text.contains(" by "))
    }

    func testShareText_BookWithEmptyAuthor_OmitsAuthorPart() {
        let book = TPPBookMocker.mockBook(identifier: "empty-author", title: "No Author", authors: "")
        let text = sut.shareText(for: book)

        XCTAssertTrue(text.contains("No Author"))
        XCTAssertFalse(text.contains(" by "))
    }

    func testShareText_BookWithLongTitle_IncludesFullTitle() {
        let longTitle = String(repeating: "Very Long Title ", count: 20)
        let book = TPPBookMocker.mockBook(identifier: "long-title", title: longTitle)
        let text = sut.shareText(for: book)

        // The service does not truncate; full title should be present
        XCTAssertTrue(text.contains(longTitle))
    }

    func testShareText_AlwaysContainsPalaceBranding() {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        let text = sut.shareText(for: book)

        XCTAssertTrue(text.contains("Palace"))
    }

    // MARK: - Share Items Composition

    func testShareItems_WithoutImage_HasTextAndURL() {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        let items = sut.shareItems(for: book, cardImage: nil)

        // Should have text and URL, no image
        let textCount = items.filter { $0 is String }.count
        let urlCount = items.filter { $0 is URL }.count
        let imageCount = items.filter { $0 is UIImage }.count

        XCTAssertEqual(textCount, 1)
        XCTAssertEqual(urlCount, 1)
        XCTAssertEqual(imageCount, 0)
    }

    func testShareItems_WithImage_HasAllThree() {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        let image = UIImage()
        let items = sut.shareItems(for: book, cardImage: image)

        let textCount = items.filter { $0 is String }.count
        let urlCount = items.filter { $0 is URL }.count
        let imageCount = items.filter { $0 is UIImage }.count

        XCTAssertEqual(textCount, 1)
        XCTAssertEqual(urlCount, 1)
        XCTAssertEqual(imageCount, 1)
    }
}
