//
//  CatalogSnapshotTests.swift
//  PalaceTests
//
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import XCTest
import SwiftUI
import SnapshotTesting
@testable import Palace

@MainActor
final class CatalogSnapshotTests: XCTestCase {

    // MARK: - Helpers

    private func createMockBooks(count: Int) -> [TPPBook] {
        let allBooks = [
            TPPBookMocker.snapshotEPUB(),
            TPPBookMocker.snapshotAudiobook(),
            TPPBookMocker.snapshotPDF(),
            TPPBookMocker.snapshotHoldBook()
        ]
        return Array(allBooks.prefix(count))
    }

    // MARK: - CatalogLaneRowView

    func testCatalogLaneRowView_withBooks() {
        let books = createMockBooks(count: 4)
        XCTAssertEqual(books.count, 4, "Should create 4 mock books for this snapshot")
        let view = CatalogLaneRowView(
            title: "Featured Books",
            books: books,
            moreURL: URL(string: "https://example.org/more"),
            onSelect: { _ in },
            onMoreTapped: { _, _ in }
        )
        .frame(width: 390, height: 220)
        .background(Color(UIColor.systemBackground))

        assertMultiDeviceSnapshot(of: view)
    }

    func testCatalogLaneRowView_empty() {
        let emptyBooks: [TPPBook] = []
        XCTAssertTrue(emptyBooks.isEmpty, "Empty lane must have zero books")
        let view = CatalogLaneRowView(
            title: "Empty Lane",
            books: emptyBooks,
            moreURL: nil,
            onSelect: { _ in },
            onMoreTapped: nil
        )
        .frame(width: 390, height: 220)
        .background(Color(UIColor.systemBackground))

        assertMultiDeviceSnapshot(of: view)
    }

    func testCatalogLaneRowView_loading() {
        let emptyBooks: [TPPBook] = []
        XCTAssertTrue(emptyBooks.isEmpty, "Loading state starts with no books")
        let view = CatalogLaneRowView(
            title: "Loading Lane",
            books: emptyBooks,
            moreURL: nil,
            onSelect: { _ in },
            onMoreTapped: nil,
            isLoading: true
        )
        .frame(width: 390, height: 220)
        .background(Color(UIColor.systemBackground))

        assertMultiDeviceSnapshot(of: view)
    }

    func testCatalogLaneRowView_noHeader() {
        let books = createMockBooks(count: 3)
        XCTAssertEqual(books.count, 3, "Should create 3 mock books for no-header snapshot")
        let view = CatalogLaneRowView(
            title: "Hidden Header",
            books: books,
            moreURL: nil,
            onSelect: { _ in },
            onMoreTapped: nil,
            showHeader: false
        )
        .frame(width: 390, height: 180)
        .background(Color(UIColor.systemBackground))

        assertMultiDeviceSnapshot(of: view)
    }

    // MARK: - BookImageView

    func testBookImageView_epub() {
        let book = TPPBookMocker.snapshotEPUB()
        XCTAssertFalse(book.title.isEmpty, "EPUB book must have a non-empty title")
        let view = BookImageView(book: book, height: 150)
            .frame(width: 100, height: 150)
            .background(Color(UIColor.systemBackground))

        assertFixedSizeSnapshot(of: view, width: 100, height: 150)
    }

    func testBookImageView_audiobook() {
        let book = TPPBookMocker.snapshotAudiobook()
        XCTAssertFalse(book.title.isEmpty, "Audiobook must have a non-empty title")
        let view = BookImageView(book: book, height: 150)
            .frame(width: 100, height: 150)
            .background(Color(UIColor.systemBackground))

        assertFixedSizeSnapshot(of: view, width: 100, height: 150)
    }

    // MARK: - FacetToolbarView

    func testFacetToolbarView_withSort() {
        let sortTitle = "Author"
        XCTAssertFalse(sortTitle.isEmpty, "Sort title must be non-empty for sort toolbar test")
        let view = FacetToolbarView(
            title: "Fiction",
            showFilter: true,
            onSort: { },
            onFilter: { },
            currentSortTitle: sortTitle
        )
        .frame(width: 390, height: 50)
        .background(Color(UIColor.systemBackground))

        assertMultiDeviceSnapshot(of: view)
    }

    func testFacetToolbarView_noSort() {
        let currentSortTitle: String? = nil
        XCTAssertNil(currentSortTitle, "No-sort toolbar must have nil currentSortTitle")
        let view = FacetToolbarView(
            title: "All Books",
            showFilter: false,
            onSort: nil,
            onFilter: { },
            currentSortTitle: currentSortTitle
        )
        .frame(width: 390, height: 50)
        .background(Color(UIColor.systemBackground))

        assertMultiDeviceSnapshot(of: view)
    }

    // MARK: - CatalogLaneSkeletonView

    func testCatalogLaneSkeletonView() {
        let view = CatalogLaneSkeletonView()
            .frame(width: 390, height: 200)
            .background(Color(UIColor.systemBackground))

        XCTAssertNotNil(view, "CatalogLaneSkeletonView must be constructible without parameters")
        assertMultiDeviceSnapshot(of: view)
    }

    // MARK: - Accessibility

    func testAccessibilityIdentifiers_exist() {
        XCTAssertFalse(AccessibilityID.Catalog.scrollView.isEmpty)
        XCTAssertFalse(AccessibilityID.Catalog.searchButton.isEmpty)
        XCTAssertFalse(AccessibilityID.Catalog.navigationBar.isEmpty)
    }
}
