//
//  NavigationCoordinatorPDFRouteTests.swift
//  PalaceTests
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import Combine
import PalaceBookModel
import PalaceReadingPosition
@testable import Palace

/// Pins what the `.pdf` route shows across an LCP PDF open: the loading view
/// while the extract runs, the PDFKit reader after the handoff, and nothing
/// (not a stuck loader) after a failed or abandoned open.
@MainActor
final class NavigationCoordinatorPDFRouteTests: XCTestCase {

    private var coordinator: NavigationCoordinator!
    private var book: TPPBook!
    private var route: BookRoute!
    private var cancellables: Set<AnyCancellable> = []

    override func setUp() {
        super.setUp()
        coordinator = NavigationCoordinator()
        book = TPPBookMocker.snapshotPDF()
        route = BookRoute(id: book.identifier)
    }

    override func tearDown() {
        cancellables.removeAll()
        coordinator = nil
        book = nil
        route = nil
        super.tearDown()
    }

    private func makeMetadata() -> TPPPDFDocumentMetadata {
        TPPPDFDocumentMetadata(with: book,
                               bookRegistry: TPPBookRegistryMock(),
                               positionWriter: InertPositionWriter())
    }

    private func makeDocument() -> TPPPDFDocument {
        TPPPDFDocument(url: URL(fileURLWithPath: "/nonexistent/extracted.pdf"))
    }

    /// Mirrors `ReaderService.openLCPPDF`: the book is stored and the route
    /// marked pending before the extract starts.
    private func beginExtract() {
        coordinator.store(book: book)
        coordinator.markLCPPDFExtractPending(forBookId: book.identifier)
    }

    func testPDFRoute_WhileExtractPending_ShowsLoadingViewForTheBook() {
        beginExtract()

        guard case .extracting(let shown) = coordinator.pdfRouteContent(for: route) else {
            return XCTFail("A pending LCP extract must show the loading view")
        }
        XCTAssertEqual(shown.identifier, book.identifier)
    }

    /// A re-open while an earlier document is still cached must show the
    /// loader, not the previous open's pages.
    func testPDFRoute_PendingWithEarlierDocumentStored_StillShowsLoadingView() {
        coordinator.storePDF(document: makeDocument(), metadata: makeMetadata(), forBookId: book.identifier)
        beginExtract()

        guard case .extracting = coordinator.pdfRouteContent(for: route) else {
            return XCTFail("The pending extract must take precedence over a cached document")
        }
    }

    func testCompleteLCPPDFExtract_ShowsTheHandedOffDocumentAndClearsPending() {
        beginExtract()
        let document = makeDocument()
        let metadata = makeMetadata()

        coordinator.completeLCPPDFExtract(document: document, metadata: metadata, forBookId: book.identifier)

        XCTAssertFalse(coordinator.isLCPPDFExtractPending(for: route))
        guard case .reader(let shownDocument, let shownMetadata) = coordinator.pdfRouteContent(for: route) else {
            return XCTFail("After the handoff the route must show the PDFKit reader")
        }
        XCTAssertTrue(shownDocument === document)
        XCTAssertTrue(shownMetadata === metadata)
    }

    /// `pdfContentById` is not `@Published`, so the handoff must still publish
    /// a change or SwiftUI keeps rendering the loading view.
    func testCompleteLCPPDFExtract_PublishesAChangeSoTheRouteReRenders() {
        beginExtract()
        var changes = 0
        coordinator.objectWillChange.sink { changes += 1 }.store(in: &cancellables)

        coordinator.completeLCPPDFExtract(document: makeDocument(), metadata: makeMetadata(), forBookId: book.identifier)

        XCTAssertGreaterThan(changes, 0)
    }

    func testClearLCPPDFExtractPending_WithoutDocument_RouteShowsNothing() {
        beginExtract()

        coordinator.clearLCPPDFExtractPending(forBookId: book.identifier)

        XCTAssertFalse(coordinator.isLCPPDFExtractPending(for: route))
        guard case .empty = coordinator.pdfRouteContent(for: route) else {
            return XCTFail("A failed or abandoned open must not leave the loading view up")
        }
    }

    func testClearLCPPDFExtractPending_ForAnotherBook_LeavesThisBookLoading() {
        beginExtract()

        coordinator.clearLCPPDFExtractPending(forBookId: "a-different-book")

        guard case .extracting = coordinator.pdfRouteContent(for: route) else {
            return XCTFail("Tearing down another book's open must not end this one's loader")
        }
    }

    /// A plain PDF never marks pending, so its stored document shows directly.
    func testPDFRoute_PlainPDFStoredWithoutPending_ShowsReader() {
        coordinator.store(book: book)
        coordinator.storePDF(document: makeDocument(), metadata: makeMetadata(), forBookId: book.identifier)

        guard case .reader = coordinator.pdfRouteContent(for: route) else {
            return XCTFail("A stored plain PDF must show the reader")
        }
    }

    /// Pending without a resolvable book cannot draw the loader (it needs the
    /// title and cover), so the route falls through to whatever is stored.
    func testPDFRoute_PendingButBookNotStored_ShowsNothing() {
        coordinator.markLCPPDFExtractPending(forBookId: book.identifier)

        guard case .empty = coordinator.pdfRouteContent(for: route) else {
            return XCTFail("Without a book there is no loader to show")
        }
    }

    // MARK: - Leaving the route while the extract runs

    /// System back and swipe-back write a shorter path through the stack's
    /// binding; leaving the loader must abandon the open and drop the loader.
    func testPushLCPPDFExtractRoute_RouteLeavesStackWhileExtracting_RunsBackOutOnce() {
        coordinator.store(book: book)
        var backOuts = 0
        coordinator.pushLCPPDFExtractRoute(forBookId: book.identifier) { backOuts += 1 }

        coordinator.path.removeLast()
        coordinator.push(.bookDetail(BookRoute(id: "another-book")))
        coordinator.path.removeLast()

        XCTAssertEqual(backOuts, 1, "Leaving the loading route must abandon the open exactly once")
        XCTAssertFalse(coordinator.isLCPPDFExtractPending(for: route))
    }

    func testPushLCPPDFExtractRoute_PopToRootWhileExtracting_RunsBackOut() {
        coordinator.push(.bookDetail(route))
        var backOuts = 0
        coordinator.pushLCPPDFExtractRoute(forBookId: book.identifier) { backOuts += 1 }

        coordinator.popToRoot(animated: false)

        XCTAssertEqual(backOuts, 1)
    }

    /// The loader-to-reader switch keeps the same route on the stack, so the
    /// normal flow must not abandon the open, then or when the reader closes.
    func testPushLCPPDFExtractRoute_ExtractCompletesThenReaderCloses_DoesNotRunBackOut() {
        coordinator.store(book: book)
        var backOuts = 0
        coordinator.pushLCPPDFExtractRoute(forBookId: book.identifier) { backOuts += 1 }

        coordinator.completeLCPPDFExtract(document: makeDocument(), metadata: makeMetadata(), forBookId: book.identifier)
        guard case .reader = coordinator.pdfRouteContent(for: route) else {
            return XCTFail("The handoff must show the reader on the same route")
        }
        coordinator.path.removeLast()

        XCTAssertEqual(backOuts, 0)
    }

    /// Popping a screen above the loading route leaves the loader on the stack.
    func testPushLCPPDFExtractRoute_PopAboveTheRoute_DoesNotRunBackOut() {
        coordinator.store(book: book)
        var backOuts = 0
        coordinator.pushLCPPDFExtractRoute(forBookId: book.identifier) { backOuts += 1 }
        coordinator.push(.bookDetail(BookRoute(id: "another-book")))

        coordinator.path.removeLast()

        XCTAssertEqual(backOuts, 0)
        XCTAssertTrue(coordinator.isLCPPDFExtractPending(for: route))
    }
}

private struct InertPositionWriter: PositionWriter {
    func save(_ snapshot: PositionSnapshot) async throws -> ServerPositionID? { nil }
    func load(for bookID: String) async throws -> PositionSnapshot? { nil }
    func cancel(for bookID: String) async {}
}
