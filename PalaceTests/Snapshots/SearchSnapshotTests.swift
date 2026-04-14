//
//  SearchSnapshotTests.swift
//  PalaceTests
//
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import XCTest
import SwiftUI
import SnapshotTesting
@testable import Palace

@MainActor
final class SearchSnapshotTests: XCTestCase {

    // MARK: - CatalogSearchView

    func testCatalogSearchView_withBooks() {
        let books = [
            TPPBookMocker.snapshotEPUB(),
            TPPBookMocker.snapshotAudiobook(),
            TPPBookMocker.snapshotPDF(),
            TPPBookMocker.snapshotHoldBook()
        ]
        XCTAssertEqual(books.count, 4, "Search view must be given 4 books for this snapshot")

        let view = CatalogSearchView(
            books: books,
            onBookSelected: { _ in }
        )
        .frame(width: 390, height: 700)
        .background(Color(UIColor.systemBackground))

        assertMultiDeviceSnapshot(of: view)
    }

    func testCatalogSearchView_empty() {
        let books: [TPPBook] = []
        XCTAssertTrue(books.isEmpty, "Empty search view must have no books")

        let view = CatalogSearchView(
            books: books,
            onBookSelected: { _ in }
        )
        .frame(width: 390, height: 400)
        .background(Color(UIColor.systemBackground))

        assertMultiDeviceSnapshot(of: view)
    }

    // MARK: - BookListView

    func testBookListView_grid() {
        let books = [
            TPPBookMocker.snapshotEPUB(),
            TPPBookMocker.snapshotAudiobook()
        ]
        XCTAssertEqual(books.count, 2, "Grid list view must contain exactly 2 books")

        let view = BookListView(
            books: books,
            isLoading: .constant(false),
            onSelect: { _ in },
            previewEnabled: false
        )
        .frame(width: 390, height: 500)
        .background(Color(UIColor.systemBackground))

        assertMultiDeviceSnapshot(of: view)
    }

    func testBookListView_loading() {
        let books: [TPPBook] = []
        XCTAssertTrue(books.isEmpty, "Loading state must start with no books")

        let view = BookListView(
            books: books,
            isLoading: .constant(true),
            onSelect: { _ in }
        )
        .frame(width: 390, height: 300)
        .background(Color(UIColor.systemBackground))

        assertMultiDeviceSnapshot(of: view)
    }

    // MARK: - Accessibility

    func testSearchAccessibilityIdentifiers() {
        XCTAssertFalse(AccessibilityID.Catalog.searchButton.isEmpty)
        XCTAssertFalse(AccessibilityID.Search.searchField.isEmpty)
        XCTAssertFalse(AccessibilityID.Search.clearButton.isEmpty)
        XCTAssertFalse(AccessibilityID.Search.noResultsView.isEmpty)
    }
}
