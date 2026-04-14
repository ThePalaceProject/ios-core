//
//  MyBooksSnapshotTests.swift
//  PalaceTests
//
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import XCTest
import SwiftUI
import SnapshotTesting
@testable import Palace

@MainActor
final class MyBooksSnapshotTests: XCTestCase {

    private var mockRegistry: TPPBookRegistryMock!
    private var mockImageCache: MockImageCache!

    override func setUp() {
        super.setUp()
        mockRegistry = TPPBookRegistryMock()
        mockImageCache = MockImageCache()
    }

    // MARK: - Helpers

    private func snapshotEPUB() -> TPPBook {
        TPPBookMocker.snapshotEPUB()
    }

    private func snapshotAudiobook() -> TPPBook {
        TPPBookMocker.snapshotAudiobook()
    }

    private func createBookCellModel(book: TPPBook, state: TPPBookState) -> BookCellModel {
        mockRegistry.addBook(book, state: state)

        let tenPrintCover = MockImageCache.generateTenPrintCover(
            title: book.title,
            author: book.authors ?? "Unknown Author"
        )
        mockRegistry.setMockImage(tenPrintCover, for: book.identifier)
        mockImageCache.set(tenPrintCover, for: book.identifier, expiresIn: nil)

        return BookCellModel(
            book: book,
            imageCache: mockImageCache,
            bookRegistry: mockRegistry
        )
    }

    // MARK: - NormalBookCell

    func testNormalBookCell_downloadedEPUB() {
        let book = snapshotEPUB()
        let model = createBookCellModel(book: book, state: .downloadSuccessful)

        let view = NormalBookCell(model: model)
            .background(Color(UIColor.systemBackground))

        assertFixedSizeSnapshot(of: view, width: 390, height: 120)
        XCTAssertEqual(mockRegistry.state(for: book.identifier), .downloadSuccessful,
                       "Book must be in downloadSuccessful state for EPUB cell snapshot")
    }

    func testNormalBookCell_downloadedAudiobook() {
        let book = snapshotAudiobook()
        let model = createBookCellModel(book: book, state: .downloadSuccessful)

        let view = NormalBookCell(model: model)
            .background(Color(UIColor.systemBackground))

        assertFixedSizeSnapshot(of: view, width: 390, height: 120)
        XCTAssertEqual(mockRegistry.state(for: book.identifier), .downloadSuccessful,
                       "Book must be in downloadSuccessful state for audiobook cell snapshot")
    }

    func testNormalBookCell_downloadNeeded() {
        let book = snapshotEPUB()
        let model = createBookCellModel(book: book, state: .downloadNeeded)

        let view = NormalBookCell(model: model)
            .background(Color(UIColor.systemBackground))

        assertFixedSizeSnapshot(of: view, width: 390, height: 120)
        XCTAssertEqual(mockRegistry.state(for: book.identifier), .downloadNeeded,
                       "Book must be in downloadNeeded state for this cell snapshot")
    }

    // MARK: - DownloadingBookCell

    func testDownloadingBookCell() {
        let book = snapshotEPUB()
        let model = createBookCellModel(book: book, state: .downloading)

        let view = DownloadingBookCell(model: model)
            .background(Color(UIColor.systemBackground))

        assertFixedSizeSnapshot(of: view, width: 390, height: 120)
        XCTAssertEqual(mockRegistry.state(for: book.identifier), .downloading,
                       "Book must be in downloading state for the DownloadingBookCell snapshot")
    }

    // MARK: - Empty State

    func testMyBooksEmptyState() {
        let emptyView = Text(Strings.MyBooksView.emptyViewMessage)
            .multilineTextAlignment(.center)
            .foregroundColor(.gray)
            .palaceFont(.body)
            .accessibilityIdentifier(AccessibilityID.MyBooks.emptyStateView)
            .background(Color(UIColor.systemBackground))

        assertFixedSizeSnapshot(of: emptyView, width: 390, height: 300)
        XCTAssertFalse(Strings.MyBooksView.emptyViewMessage.isEmpty,
                       "Empty view message must not be empty")
    }

    // MARK: - Button Types

    func testButtonTypes_downloadedEPUB() {
        let book = snapshotEPUB()
        let buttons = BookButtonState.downloadSuccessful.buttonTypes(book: book)
        XCTAssertTrue(buttons.contains(.read))
        XCTAssertFalse(buttons.isEmpty, "downloadSuccessful EPUB must have at least one button")
        XCTAssertFalse(buttons.contains(.download), "Downloaded EPUB must not show a download button again")
    }

    func testButtonTypes_downloadedAudiobook() {
        let book = snapshotAudiobook()
        let buttons = BookButtonState.downloadSuccessful.buttonTypes(book: book)
        XCTAssertTrue(buttons.contains(.listen))
        XCTAssertFalse(buttons.isEmpty, "downloadSuccessful audiobook must have at least one button")
        XCTAssertFalse(buttons.contains(.download), "Downloaded audiobook must not show a download button again")
    }

    // MARK: - Sorting

    func testSortByTitle() {
        let books = [snapshotEPUB(), snapshotAudiobook(), TPPBookMocker.snapshotPDF()]
        let sorted = books.sorted { $0.title < $1.title }
        XCTAssertEqual(sorted.count, 3)
        XCTAssertEqual(sorted[0].title, "1984")
    }

    func testSortByAuthor() {
        let books = [snapshotEPUB(), snapshotAudiobook()]
        let sorted = books.sorted { ($0.authors ?? "") < ($1.authors ?? "") }
        XCTAssertEqual(sorted.count, 2)
        XCTAssertEqual(sorted[0].authors, "F. Scott Fitzgerald")
    }

    // MARK: - Accessibility

    func testMyBooksAccessibilityIdentifiers() {
        XCTAssertFalse(AccessibilityID.MyBooks.gridView.isEmpty)
        XCTAssertFalse(AccessibilityID.MyBooks.emptyStateView.isEmpty)
        XCTAssertFalse(AccessibilityID.MyBooks.sortButton.isEmpty)
    }
}
