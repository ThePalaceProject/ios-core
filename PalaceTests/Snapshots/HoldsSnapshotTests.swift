//
//  HoldsSnapshotTests.swift
//  PalaceTests
//
//  Snapshot tests for Holds/Reservations views.
//

import XCTest
import SwiftUI
import SnapshotTesting
@testable import Palace

@MainActor
final class HoldsSnapshotTests: XCTestCase {

    // MARK: - Empty State Tests

    func testHoldsEmptyState() {
        let emptyMessage = Strings.HoldsView.emptyMessage
        XCTAssertFalse(emptyMessage.isEmpty, "Holds empty message string must not be empty")

        let emptyView = VStack {
            Text(emptyMessage)
                .multilineTextAlignment(.center)
                .foregroundColor(Color(white: 0.667))
                .font(.body)
                .padding(.horizontal, 24)
        }
        .frame(width: 390, height: 400)
        .background(Color(UIColor.systemBackground))

        assertMultiDeviceSnapshot(of: emptyView)
    }

    func testHoldsEmptyState_darkMode() {
        let emptyMessage = Strings.HoldsView.emptyMessage
        XCTAssertFalse(emptyMessage.isEmpty, "Holds empty message must not be empty in dark mode either")

        let emptyView = VStack {
            Text(emptyMessage)
                .multilineTextAlignment(.center)
                .foregroundColor(Color(white: 0.667))
                .font(.body)
                .padding(.horizontal, 24)
        }
        .frame(width: 390, height: 400)
        .background(Color(UIColor.systemBackground))
        .colorScheme(.dark)

        assertFixedSizeSnapshot(of: emptyView, width: 390, height: 400, userInterfaceStyle: .dark)
    }

    // MARK: - Loading State Tests

    func testHoldsLoadingState() {
        let rowCount = 5
        XCTAssertGreaterThan(rowCount, 0, "Loading skeleton must have at least one row")
        let loadingView = BookListSkeletonView(rows: rowCount)
            .frame(width: 390, height: 600)
            .background(Color(UIColor.systemBackground))

        assertMultiDeviceSnapshot(of: loadingView)
    }

    // MARK: - Book List Tests

    func testHoldsBookList() {
        let books = [
            TPPBookMocker.snapshotHoldBook(),
            TPPBookMocker.snapshotEPUB(),
            TPPBookMocker.snapshotAudiobook()
        ]

        for book in books {
            XCTAssertNotNil(book.coverImage, "Book \(book.title) should have cover image")
        }

        let bookListView = BookListView(
            books: books,
            isLoading: .constant(false),
            onSelect: { _ in }
        )
        .frame(width: 390, height: 600)
        .padding(.horizontal, 8)
        .background(Color(UIColor.systemBackground))

        assertMultiDeviceSnapshot(of: bookListView)
    }

    func testHoldsBookList_darkMode() {
        let books = [
            TPPBookMocker.snapshotHoldBook(),
            TPPBookMocker.snapshotEPUB()
        ]
        XCTAssertEqual(books.count, 2, "Dark mode holds list must contain exactly 2 books")

        let bookListView = BookListView(
            books: books,
            isLoading: .constant(false),
            onSelect: { _ in }
        )
        .frame(width: 390, height: 400)
        .padding(.horizontal, 8)
        .background(Color(UIColor.systemBackground))
        .colorScheme(.dark)

        assertFixedSizeSnapshot(of: bookListView, width: 390, height: 400, userInterfaceStyle: .dark)
    }

    // MARK: - Search Bar Tests

    func testHoldsSearchBar_empty() {
        let searchText = ""
        XCTAssertTrue(searchText.isEmpty, "Empty search bar must have no text")

        let searchBar = HStack {
            TextField(NSLocalizedString("Search Holds", comment: ""), text: .constant(searchText))
                .searchBarStyle()
            Button(action: {}, label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.gray)
                    .accessibilityHidden(true)
            })
            .accessibilityLabel(NSLocalizedString("Clear search", comment: "Clear search button"))
        }
        .padding(.horizontal)
        .frame(width: 390, height: 60)
        .background(Color(UIColor.systemBackground))

        assertMultiDeviceSnapshot(of: searchBar)
    }

    func testHoldsSearchBar_withText() {
        let searchText = "Harry Potter"
        XCTAssertFalse(searchText.isEmpty, "Search bar with text must have non-empty content")

        let searchBar = HStack {
            TextField(NSLocalizedString("Search Holds", comment: ""), text: .constant(searchText))
                .searchBarStyle()
            Button(action: {}, label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.gray)
                    .accessibilityHidden(true)
            })
            .accessibilityLabel(NSLocalizedString("Clear search", comment: "Clear search button"))
        }
        .padding(.horizontal)
        .frame(width: 390, height: 60)
        .background(Color(UIColor.systemBackground))

        assertMultiDeviceSnapshot(of: searchBar)
    }
}
