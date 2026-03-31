//
//  ShareViewModelTests.swift
//  PalaceTests
//
//  Tests for ShareViewModel share preparation and card generation.
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Combine
import XCTest
@testable import Palace

@MainActor
final class ShareViewModelTests: XCTestCase {

    private var sut: ShareViewModel!
    private var mockShareService: MockShareService!

    override func setUp() {
        super.setUp()
        mockShareService = MockShareService()
        sut = ShareViewModel(shareService: mockShareService)
    }

    override func tearDown() {
        sut = nil
        mockShareService = nil
        super.tearDown()
    }

    // MARK: - Prepare Share

    func testPrepareShare_CreatesShareItems() {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        sut.prepareShare(for: book)

        XCTAssertFalse(sut.shareItems.isEmpty)
        XCTAssertTrue(sut.isReady)
    }

    func testPrepareShare_IncludesText() {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        sut.prepareShare(for: book)

        let hasText = sut.shareItems.contains { $0 is String }
        XCTAssertTrue(hasText)
    }

    func testPrepareShare_IncludesURL() {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        sut.prepareShare(for: book)

        let hasURL = sut.shareItems.contains { $0 is URL }
        XCTAssertTrue(hasURL)
    }

    func testPrepareShare_TextContainsBookTitle() {
        let book = TPPBookMocker.mockBook(identifier: "t1", title: "The Great Gatsby")
        sut.prepareShare(for: book)

        let text = sut.shareItems.compactMap { $0 as? String }.first
        XCTAssertNotNil(text)
        XCTAssertTrue(text?.contains("The Great Gatsby") ?? false)
    }

    func testPrepareShare_TextContainsAuthor() {
        let book = TPPBookMocker.mockBook(identifier: "t2", title: "Gatsby", authors: "F. Scott Fitzgerald")
        sut.prepareShare(for: book)

        let text = sut.shareItems.compactMap { $0 as? String }.first
        XCTAssertNotNil(text)
        XCTAssertTrue(text?.contains("F. Scott Fitzgerald") ?? false)
    }

    func testPrepareShare_DeepLinkUsesPalaceScheme() {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        sut.prepareShare(for: book)

        let url = sut.shareItems.compactMap { $0 as? URL }.first
        XCTAssertNotNil(url)
        XCTAssertEqual(url?.scheme, "palace")
    }

    // MARK: - Share Card Image

    func testGenerateShareCard_SetsImage() {
        mockShareService.stubbedCardImage = UIImage()
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        sut.generateShareCard(for: book)

        XCTAssertNotNil(sut.shareCardImage)
    }

    func testGenerateShareCard_NilFromService_SetsNil() {
        mockShareService.stubbedCardImage = nil
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        sut.generateShareCard(for: book)

        XCTAssertNil(sut.shareCardImage)
    }

    func testPrepareShare_WithCardImage_IncludesImageInItems() {
        mockShareService.stubbedCardImage = UIImage()
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        sut.generateShareCard(for: book)
        sut.prepareShare(for: book)

        let hasImage = sut.shareItems.contains { $0 is UIImage }
        XCTAssertTrue(hasImage)
    }

    // MARK: - Reset

    func testReset_ClearsAllState() {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        mockShareService.stubbedCardImage = UIImage()
        sut.generateShareCard(for: book)
        sut.prepareShare(for: book)

        XCTAssertTrue(sut.isReady)
        XCTAssertFalse(sut.shareItems.isEmpty)

        sut.reset()

        XCTAssertFalse(sut.isReady)
        XCTAssertTrue(sut.shareItems.isEmpty)
        XCTAssertNil(sut.shareCardImage)
    }

    func testShareItems_ClearedBetweenBooks() {
        let book1 = TPPBookMocker.mockBook(identifier: "b1", title: "Book One")
        let book2 = TPPBookMocker.mockBook(identifier: "b2", title: "Book Two")

        sut.prepareShare(for: book1)
        let firstItems = sut.shareItems

        sut.reset()
        sut.prepareShare(for: book2)
        let secondItems = sut.shareItems

        // Items should not be identical (different book titles in text)
        let firstText = firstItems.compactMap { $0 as? String }.first
        let secondText = secondItems.compactMap { $0 as? String }.first
        XCTAssertNotEqual(firstText, secondText)
    }

    // MARK: - Initial State

    func testInitialState_NotReady() {
        XCTAssertFalse(sut.isReady)
        XCTAssertTrue(sut.shareItems.isEmpty)
        XCTAssertNil(sut.shareCardImage)
    }
}

// MARK: - Mock Share Service

final class MockShareService: ShareServiceProtocol {

    var stubbedCardImage: UIImage?

    func shareText(for book: TPPBook) -> String {
        let authorPart: String
        if let authors = book.authors, !authors.isEmpty {
            authorPart = " by \(authors)"
        } else {
            authorPart = ""
        }
        return "I'm reading \"\(book.title)\"\(authorPart) on Palace!"
    }

    func deepLink(for book: TPPBook) -> URL? {
        URL(string: "palace://book/\(book.identifier)")
    }

    func renderShareCard(_ card: ShareableBookCard) -> UIImage? {
        stubbedCardImage
    }

    func shareItems(for book: TPPBook, cardImage: UIImage?) -> [Any] {
        var items: [Any] = [shareText(for: book)]
        if let image = cardImage {
            items.append(image)
        }
        if let link = deepLink(for: book) {
            items.append(link)
        }
        return items
    }
}
