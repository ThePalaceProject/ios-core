//
//  ShareServiceTests.swift
//  PalaceTests
//
//  Tests for ShareService text generation and deep link creation.
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class ShareServiceTests: XCTestCase {

    private var sut: ShareService!

    override func setUp() {
        super.setUp()
        sut = ShareService()
    }

    override func tearDown() {
        sut = nil
        super.tearDown()
    }

    // MARK: - Share Text

    func testShareText_IncludesTitleAndAuthor() {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        let text = sut.shareText(for: book)
        XCTAssertTrue(text.contains(book.title))
        XCTAssertTrue(text.contains("Palace"))
    }

    func testShareText_ContainsReadingPhrase() {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        let text = sut.shareText(for: book)
        XCTAssertTrue(text.contains("I'm reading"))
    }

    // MARK: - Deep Link

    func testDeepLink_HasPalaceScheme() {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        let link = sut.deepLink(for: book)
        XCTAssertNotNil(link)
        XCTAssertEqual(link?.scheme, "palace")
    }

    func testDeepLink_ContainsBookID() {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        let link = sut.deepLink(for: book)
        XCTAssertNotNil(link)
        XCTAssertTrue(link!.absoluteString.contains(book.identifier))
    }

    func testDeepLink_StartsWithBookPath() {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        let link = sut.deepLink(for: book)
        XCTAssertTrue(link?.absoluteString.hasPrefix("palace://book/") ?? false)
    }

    // MARK: - Share Items

    func testShareItems_ContainsText() {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        let items = sut.shareItems(for: book, cardImage: nil)
        let hasText = items.contains { $0 is String }
        XCTAssertTrue(hasText)
    }

    func testShareItems_ContainsURL() {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        let items = sut.shareItems(for: book, cardImage: nil)
        let hasURL = items.contains { $0 is URL }
        XCTAssertTrue(hasURL)
    }

    func testShareItems_IncludesImageWhenProvided() {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        let image = UIImage()
        let items = sut.shareItems(for: book, cardImage: image)
        let hasImage = items.contains { $0 is UIImage }
        XCTAssertTrue(hasImage)
    }

    func testShareItems_ExcludesImageWhenNil() {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        let items = sut.shareItems(for: book, cardImage: nil)
        let hasImage = items.contains { $0 is UIImage }
        XCTAssertFalse(hasImage)
    }
}
