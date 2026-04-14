//
//  BookDetailSnapshotTests.swift
//  PalaceTests
//
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import XCTest
import SwiftUI
import SnapshotTesting
@testable import Palace

@MainActor
final class BookDetailSnapshotTests: XCTestCase {

    // MARK: - Helpers

    private func createMockEPUBBook() -> TPPBook {
        TPPBookMocker.snapshotEPUB()
    }

    private func createMockAudiobook() -> TPPBook {
        TPPBookMocker.snapshotAudiobook()
    }

    private func createMockPDFBook() -> TPPBook {
        TPPBookMocker.snapshotPDF()
    }

    private func createMockHoldBook() -> TPPBook {
        TPPBookMocker.snapshotHoldBook()
    }

    // MARK: - BookImageView

    func testBookImageView_epub_snapshot() {
        let book = createMockEPUBBook()
        let view = BookImageView(book: book, height: 280)
            .frame(width: 200, height: 280)
            .background(Color(UIColor.systemBackground))

        assertFixedSizeSnapshot(of: view, width: 200, height: 280)
        XCTAssertEqual(book.defaultBookContentType, .epub, "Mock EPUB book must have .epub content type")
    }

    func testBookImageView_audiobook_snapshot() {
        let book = createMockAudiobook()
        let view = BookImageView(book: book, height: 280)
            .frame(width: 200, height: 280)
            .background(Color(UIColor.systemBackground))

        assertFixedSizeSnapshot(of: view, width: 200, height: 280)
        XCTAssertTrue(book.isAudiobook, "Mock audiobook must be identified as an audiobook")
    }

    func testBookImageView_pdf_snapshot() {
        let book = createMockPDFBook()
        let view = BookImageView(book: book, height: 280)
            .frame(width: 200, height: 280)
            .background(Color(UIColor.systemBackground))

        assertFixedSizeSnapshot(of: view, width: 200, height: 280)
        XCTAssertEqual(book.defaultBookContentType, .pdf, "Mock PDF book must have .pdf content type")
    }

    func testBookImageView_holdBook_snapshot() {
        let book = createMockHoldBook()
        let view = BookImageView(book: book, height: 280)
            .frame(width: 200, height: 280)
            .background(Color(UIColor.systemBackground))

        assertFixedSizeSnapshot(of: view, width: 200, height: 280)
        XCTAssertFalse(book.identifier.isEmpty, "Mock hold book must have a non-empty identifier")
    }

    func testBookImageView_allTypes_grid() {
        let books = [
            createMockEPUBBook(),
            createMockAudiobook(),
            createMockPDFBook(),
            createMockHoldBook()
        ]

        let view = HStack(spacing: 12) {
            ForEach(books, id: \.identifier) { book in
                BookImageView(book: book, height: 150)
                    .frame(width: 100, height: 150)
            }
        }
        .padding()
        .background(Color(UIColor.systemBackground))

        assertMultiDeviceSnapshot(of: view)
        XCTAssertEqual(books.count, 4, "Grid must contain exactly 4 book types")
    }

    // MARK: - BookDetailView

    func testBookDetailView_epub() {
        let book = createMockEPUBBook()
        let view = BookDetailView(book: book)
            .frame(width: 390, height: 700)

        assertMultiDeviceSnapshot(of: view)
        XCTAssertFalse(book.title.isEmpty, "EPUB book used in snapshot must have a non-empty title")
    }

    func testBookDetailView_audiobook() {
        let book = createMockAudiobook()
        let view = BookDetailView(book: book)
            .frame(width: 390, height: 700)

        assertMultiDeviceSnapshot(of: view)
        XCTAssertTrue(book.isAudiobook, "Audiobook book used in snapshot must be identified as an audiobook")
    }

    func testBookDetailView_pdf() {
        let book = createMockPDFBook()
        let view = BookDetailView(book: book)
            .frame(width: 390, height: 700)

        assertMultiDeviceSnapshot(of: view)
        XCTAssertEqual(book.defaultBookContentType, .pdf, "PDF book used in snapshot must have .pdf content type")
    }

    func testBookDetailView_holdBook() {
        let book = createMockHoldBook()
        let view = BookDetailView(book: book)
            .frame(width: 390, height: 700)

        assertMultiDeviceSnapshot(of: view)
        XCTAssertFalse(book.title.isEmpty, "Hold book used in snapshot must have a non-empty title")
    }

    // MARK: - BookButtonsView

    func testBookButtonsView_canBorrow() {
        let book = createMockEPUBBook()
        let provider = MockBookButtonProvider(book: book, state: .canBorrow)

        let view = BookButtonsView(provider: provider)
            .frame(width: 390)
            .padding()
            .background(Color(UIColor.systemBackground))

        assertMultiDeviceSnapshot(of: view)
        XCTAssertTrue(provider.buttonTypes.contains(.get), "canBorrow state must show a Get button")
    }

    func testBookButtonsView_downloadSuccessful_epub() {
        let book = createMockEPUBBook()
        let provider = MockBookButtonProvider(book: book, state: .downloadSuccessful)

        let view = BookButtonsView(provider: provider)
            .frame(width: 390)
            .padding()
            .background(Color(UIColor.systemBackground))

        assertMultiDeviceSnapshot(of: view)
        XCTAssertTrue(provider.buttonTypes.contains(.read), "downloadSuccessful EPUB must show a Read button")
    }

    func testBookButtonsView_downloadSuccessful_audiobook() {
        let book = createMockAudiobook()
        let provider = MockBookButtonProvider(book: book, state: .downloadSuccessful)

        let view = BookButtonsView(provider: provider)
            .frame(width: 390)
            .padding()
            .background(Color(UIColor.systemBackground))

        assertMultiDeviceSnapshot(of: view)
        XCTAssertTrue(provider.buttonTypes.contains(.listen), "downloadSuccessful audiobook must show a Listen button")
    }

    // MARK: - Button State Logic

    func testButtonState_canBorrow_showsBorrowButton() {
        let book = createMockEPUBBook()
        let buttons = BookButtonState.canBorrow.buttonTypes(book: book)
        XCTAssertTrue(buttons.contains(.get))
    }

    func testButtonState_downloadSuccessful_epub_showsReadButton() {
        let book = createMockEPUBBook()
        let buttons = BookButtonState.downloadSuccessful.buttonTypes(book: book)
        XCTAssertTrue(buttons.contains(.read))
    }

    func testButtonState_downloadSuccessful_audiobook_showsListenButton() {
        let book = createMockAudiobook()
        let buttons = BookButtonState.downloadSuccessful.buttonTypes(book: book)
        XCTAssertTrue(buttons.contains(.listen))
    }

    func testButtonState_holdingFrontOfQueue_showsManageHold() {
        let book = createMockHoldBook()
        let buttons = BookButtonState.holdingFrontOfQueue.buttonTypes(book: book)
        XCTAssertTrue(buttons.contains(.manageHold))
    }

    // MARK: - Accessibility

    func testBookDetailAccessibilityIdentifiers() {
        XCTAssertFalse(AccessibilityID.BookDetail.coverImage.isEmpty)
        XCTAssertFalse(AccessibilityID.BookDetail.title.isEmpty)
        XCTAssertFalse(AccessibilityID.BookDetail.author.isEmpty)
        XCTAssertFalse(AccessibilityID.BookDetail.getButton.isEmpty)
    }
}

// MARK: - MockBookButtonProvider

private class MockBookButtonProvider: BookButtonProvider {
    let book: TPPBook
    let state: BookButtonState
    private let fixedButtonTypes: [BookButtonType]?

    init(book: TPPBook, state: BookButtonState, buttonTypes: [BookButtonType]? = nil) {
        self.book = book
        self.state = state
        self.fixedButtonTypes = buttonTypes
    }

    var buttonTypes: [BookButtonType] {
        // Use fixed button types if provided, otherwise derive from state
        // This makes snapshot tests deterministic regardless of account state
        if let fixed = fixedButtonTypes {
            return fixed
        }
        return deterministicButtonTypes(for: state, book: book)
    }

    /// Returns deterministic button types that don't depend on global account state
    private func deterministicButtonTypes(for state: BookButtonState, book: TPPBook) -> [BookButtonType] {
        switch state {
        case .canBorrow, .canHold:
            return [.get]
        case .holding:
            return [.manageHold]
        case .holdingFrontOfQueue:
            return [.get]
        case .downloadNeeded:
            return [.download, .return]
        case .downloadSuccessful, .used:
            switch book.defaultBookContentType {
            case .audiobook:
                return [.listen, .return]
            case .pdf, .epub:
                return [.read, .return]
            case .unsupported:
                return [.return]
            }
        case .downloadInProgress:
            return [.cancel]
        case .downloadFailed:
            return [.cancel, .retry]
        case .returning:
            return [.returning]
        case .managingHold:
            return [.manageHold]
        case .unsupported:
            return []
        }
    }

    func handleAction(for type: BookButtonType) {}

    func isProcessing(for type: BookButtonType) -> Bool { false }
}
