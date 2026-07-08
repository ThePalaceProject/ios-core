//
//  BookCellModelStreamingHTMLTests.swift
//  PalaceTests
//
//  PP-4161 coverage for the BookCellModel routing path that lights up when
//  the user taps `.readStreaming` (or `.read` on a streamingHTML book) from
//  the My Books cell. BookCellModel.didSelectRead inspects
//  `book.defaultBookContentType` and routes:
//    .epub      → readerService.openEPUB
//    .pdf       → readerService.openPDF (or PDFKit path)
//    .audiobook → BookService.open (audiobook session)
//    .streamingHTML → NavigationCoordinator.push(.streamingHTML(...))
//
//  This file pins ONLY the streamingHTML path — the other branches are
//  covered by their respective integration tests.
//

import XCTest
import PalaceCatalog
@testable import Palace

@MainActor
final class BookCellModelStreamingHTMLTests: XCTestCase {

    private var mockRegistry: TPPBookRegistryMock!
    private var mockImageCache: MockImageCache!
    private var mockReachability: MockReachability!

    /// Production NavigationCoordinator used here because it owns concrete
    /// SwiftUI NavigationPath state and `push(.streamingHTML(_:))` is a
    /// stored-payload operation we can inspect via `path.count` + the
    /// resolveBook lookup. Mocking the coordinator would force a protocol
    /// extraction outside Module C scope.
    private var coordinator: NavigationCoordinator!

    override func setUp() {
        super.setUp()
        mockRegistry = TPPBookRegistryMock()
        mockImageCache = MockImageCache()
        mockReachability = MockReachability(initiallyConnected: true)
        coordinator = NavigationCoordinator()
        AppContainer.production().navigationCoordinatorHub.coordinator = coordinator
    }

    override func tearDown() {
        AppContainer.production().navigationCoordinatorHub.coordinator = nil
        coordinator = nil
        mockReachability = nil
        mockImageCache = nil
        mockRegistry = nil
        super.tearDown()
    }

    // MARK: - Helpers

    /// Builds a streamingHTML-only book: borrow → indirect → text/html
    /// streaming-media leaf. Matches the OPDS chain that surfaces this
    /// content type in production.
    private func makeStreamingHTMLBook(id: String = "streaming-cell-book") -> TPPBook {
        let leaf = TPPOPDSIndirectAcquisition(
            type: ContentTypeStreamingHTML,
            indirectAcquisitions: []
        )
        let acquisition = TPPOPDSAcquisition(
            relation: .borrow,
            type: ContentTypeOPDSPublication,
            hrefURL: URL(string: "https://example.com/streaming/\(id)")!,
            indirectAcquisitions: [leaf],
            availability: TPPOPDSAcquisitionAvailabilityUnlimited()
        )
        return TPPBook(
            acquisitions: [acquisition],
            authors: [TPPBookAuthor(authorName: "Author", relatedBooksURL: nil)],
            categoryStrings: ["Streaming"],
            distributor: "Streaming Distributor",
            identifier: id,
            imageURL: nil,
            imageThumbnailURL: nil,
            published: Date(),
            publisher: "Publisher",
            subtitle: nil,
            summary: "Streaming title",
            title: "Streaming Cell Title",
            updated: Date(),
            annotationsURL: nil,
            analyticsURL: nil,
            alternateURL: nil,
            relatedWorksURL: nil,
            previewLink: nil,
            seriesURL: nil,
            revokeURL: URL(string: "https://example.com/revoke"),
            reportURL: nil,
            timeTrackingURL: nil,
            contributors: [:],
            bookDuration: nil,
            imageCache: mockImageCache
        )
    }

    private func makeModel(book: TPPBook, downloadCenter: MyBooksDownloadCenter? = nil) -> BookCellModel {
        BookCellModel(
            book: book,
            imageCache: mockImageCache,
            bookRegistry: mockRegistry,
            downloadCenter: downloadCenter ?? AppContainer.production().downloadCenter,
            accountsManager: AppContainer.production().accountsManager,
            samplePreviewManager: AppContainer.production().samplePreviewManager,
            readerService: AppContainer.production().readerService,
            reachability: mockReachability
        )
    }

    // MARK: - Production-seam route push

    /// Canonical test: didSelectRead on a streamingHTML book pushes
    /// `.streamingHTML(BookRoute(id:))` on the navigation coordinator. The
    /// route-stack push is the only observable side effect of the
    /// presentation seam — Module B owns the actual VC rendering, which is
    /// covered in `StreamingReaderViewModelTests`.
    func testBookCellModel_didSelectRead_streamingHTMLBook_presentsStreamingReaderView_viaCoordinator() {
        let book = makeStreamingHTMLBook(id: "did-select-read-routes-to-streaming-reader")
        mockRegistry.addBook(book, location: nil, state: .downloadNeeded, fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)
        let model = makeModel(book: book)
        drainMainQueue()

        XCTAssertEqual(coordinator.path.count, 0,
                       "precondition: navigation stack must be empty before the tap")

        model.didSelectRead()
        drainMainQueue()

        XCTAssertEqual(coordinator.path.count, 1,
                       "didSelectRead on a streamingHTML book MUST push exactly one route — got \(coordinator.path.count) routes")
        // The pushed payload's book id must be retrievable via the
        // coordinator's bookById storage (BookCellModel.didSelectRead calls
        // coordinator.store(book:) before push).
        XCTAssertNotNil(coordinator.resolveBook(for: BookRoute(id: book.identifier)),
                        "Pushed streamingHTML route must have the book payload stored so NavigationHostView can resolve it")
        XCTAssertFalse(model.isLoading,
                       "Cell-level isLoading must be cleared after push — the streaming reader owns its own loading state")
    }

    /// Negative control: didSelectRead on an EPUB book must NOT push the
    /// streamingHTML route. If a mutant accidentally routes all content
    /// types through `coordinator.push(.streamingHTML(...))`, this test
    /// fails.
    func testBookCellModel_didSelectRead_epubBook_doesNotPushStreamingRoute() {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        mockRegistry.addBook(book, location: nil, state: .downloadSuccessful, fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)
        let model = makeModel(book: book)
        drainMainQueue()

        model.didSelectRead()
        drainMainQueue()

        // EPUB opens via readerService.openEPUB which has its own route
        // dispatch — the streamingHTML route specifically must not be on
        // the stack. We assert by attempting to resolve a streaming book
        // payload that we never stored.
        XCTAssertNil(coordinator.resolveBook(for: BookRoute(id: book.identifier)),
                     "EPUB books must not have their payload stored on the coordinator by the streamingHTML branch")
    }

}
