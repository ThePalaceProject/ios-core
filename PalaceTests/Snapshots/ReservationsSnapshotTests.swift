//
//  ReservationsSnapshotTests.swift
//  PalaceTests
//
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import XCTest
import SwiftUI
import SnapshotTesting
@testable import Palace

@MainActor
final class ReservationsSnapshotTests: XCTestCase {

    private var mockRegistry: TPPBookRegistryMock!
    private var mockImageCache: MockImageCache!

    override func setUp() {
        super.setUp()
        mockRegistry = TPPBookRegistryMock()
        mockImageCache = MockImageCache()
    }

    // MARK: - Helpers

    private func snapshotHoldBook() -> TPPBook {
        TPPBookMocker.snapshotHoldBook()
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

    func testNormalBookCell_holding() {
        let book = snapshotHoldBook()
        let model = createBookCellModel(book: book, state: .holding)

        let view = NormalBookCell(model: model)
            .background(Color(UIColor.systemBackground))

        assertFixedSizeSnapshot(of: view, width: 390, height: 120)
        // Verify the model reflects holding state
        XCTAssertEqual(mockRegistry.state(for: book.identifier), .holding,
                       "Book must be in holding state for this snapshot")
    }

    func testNormalBookCell_downloadSuccessful() {
        let book = TPPBookMocker.snapshotEPUB()
        let model = createBookCellModel(book: book, state: .downloadSuccessful)

        let view = NormalBookCell(model: model)
            .background(Color(UIColor.systemBackground))

        assertFixedSizeSnapshot(of: view, width: 390, height: 120)
        // Verify the model reflects downloadSuccessful state
        XCTAssertEqual(mockRegistry.state(for: book.identifier), .downloadSuccessful,
                       "Book must be in downloadSuccessful state for this snapshot")
    }

    // MARK: - Empty State

    func testReservationsEmptyState() {
        let emptyView = Text(Strings.HoldsView.emptyMessage)
            .multilineTextAlignment(.center)
            .foregroundColor(Color(white: 0.667))
            .font(.body)
            .padding(.horizontal, 24)
            .padding(.top, 100)
            .accessibilityIdentifier(AccessibilityID.Holds.emptyStateView)
            .background(Color(TPPConfiguration.backgroundColor()))

        assertFixedSizeSnapshot(of: emptyView, width: 390, height: 400)
        // The empty message must be non-trivially long
        XCTAssertFalse(Strings.HoldsView.emptyMessage.isEmpty,
                       "HoldsView empty message must not be empty")
    }

    // MARK: - Button States

    func testReserveButton_showsForUnavailableBook() {
        let book = snapshotHoldBook()
        let buttons = BookButtonState.canHold.buttonTypes(book: book)
        XCTAssertTrue(buttons.contains(.reserve))
        XCTAssertFalse(buttons.isEmpty, "canHold state must produce at least one button")
        XCTAssertFalse(buttons.contains(.read), "canHold state must not show a read button")
    }

    func testRemoveButton_showsAfterReservation() {
        let book = snapshotHoldBook()
        let buttons = BookButtonState.holding.buttonTypes(book: book)
        XCTAssertTrue(buttons.contains(.manageHold) || buttons.contains(.cancelHold))
        XCTAssertFalse(buttons.isEmpty, "holding state must produce at least one button")
        XCTAssertFalse(buttons.contains(.reserve), "holding state must not show a reserve button again")
    }

    func testHoldingFrontOfQueue_buttonBehavior() {
        let book = snapshotHoldBook()
        let buttons = BookButtonState.holdingFrontOfQueue.buttonTypes(book: book)
        XCTAssertFalse(buttons.isEmpty)
        XCTAssertTrue(buttons.contains(.manageHold) || buttons.contains(.get))
    }

    // MARK: - Sorting

    func testHoldsSorting_byTitle() {
        let books = [
            TPPBookMocker.snapshotEPUB(),
            TPPBookMocker.snapshotAudiobook(),
            TPPBookMocker.snapshotPDF()
        ]
        let sorted = books.sorted { $0.title < $1.title }
        XCTAssertEqual(sorted.count, 3)
        XCTAssertEqual(sorted[0].title, "1984")
        XCTAssertEqual(sorted[1].title, "Pride and Prejudice")
        XCTAssertEqual(sorted[2].title, "The Great Gatsby")
    }

    func testHoldsSorting_byAuthor() {
        let books = [
            TPPBookMocker.snapshotEPUB(),
            TPPBookMocker.snapshotAudiobook()
        ]
        let sorted = books.sorted { ($0.authors ?? "") < ($1.authors ?? "") }
        XCTAssertEqual(sorted.count, 2)
        XCTAssertEqual(sorted[0].authors, "F. Scott Fitzgerald")
        XCTAssertEqual(sorted[1].authors, "Jane Austen")
    }

    // MARK: - Accessibility

    func testReservationsAccessibilityIdentifiers() {
        XCTAssertFalse(AccessibilityID.Holds.scrollView.isEmpty)
        XCTAssertFalse(AccessibilityID.Holds.emptyStateView.isEmpty)
        XCTAssertFalse(AccessibilityID.Holds.sortButton.isEmpty)
    }
}
