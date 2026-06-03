//
//  BorrowOperationStreamingHTMLTests.swift
//  PalaceTests
//
//  PP-4161 (v2.1 advisory F) regression net for the BorrowOperation:453
//  guard:
//
//      if attemptDownload && mapping.state == .downloadNeeded
//         && !borrowedBook.isStreamingHTML {
//          delegate?.startDownload(for: borrowedBook, withRequest: nil)
//      }
//
//  Without the `!borrowedBook.isStreamingHTML` clause, the auto-download
//  chain fires for streamingHTML books, MyBooksDownloadCenter tries to
//  download a non-existent asset (only `text/html;profile=streaming-media`
//  is in the indirect-acquisition chain), the request fails, and the
//  registry lands in `.downloadFailed` — locking the user out of the
//  readStreaming affordance.
//
//  This file mirrors the structure of `BorrowOperationTests.swift` (same
//  closure-injection seams + spy delegate) but is scoped to the streaming-
//  HTML / EPUB guard predicate alone.
//

import XCTest
import PalaceCatalog
@testable import Palace

@MainActor
final class BorrowOperationStreamingHTMLTests: XCTestCase {

    private var bookRegistry: TPPBookRegistryMock!
    private var userAccount: TPPUserAccountMock!
    private var spyDelegate: StreamingSpyDelegate!
    private var operation: BorrowOperation!

    /// Recorders for the closure-injected seams (copied from
    /// `BorrowOperationTests` so this file stands alone).
    private var fetchBookResult: Result<TPPBook, Error>!
    private var fetchBookCalls: [(url: URL, resetCache: Bool, useToken: Bool)] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        BorrowOperation.clearAllBorrowReauthState()

        bookRegistry = TPPBookRegistryMock()
        userAccount = TPPUserAccountMock()
        spyDelegate = StreamingSpyDelegate()
        fetchBookCalls = []
    }

    override func tearDownWithError() throws {
        BorrowOperation.clearAllBorrowReauthState()
        bookRegistry = nil
        userAccount = nil
        spyDelegate = nil
        operation = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    /// Configures the operation so the borrow round-trip returns the given book.
    private func configureOperation(returning book: TPPBook) {
        fetchBookResult = .success(book)
        operation = BorrowOperation(
            bookRegistry: bookRegistry,
            downloadAnnouncementService: DownloadAnnouncementService(),
            errorActivityTracker: .shared,
            debugSettings: DebugSettings(),
            userRetryTracker: .shared,
            userAccountProvider: { [unowned self] in self.userAccount },
            adobeDRMService: AdobeDRMService.shared,
            fetchBook: { [unowned self] url, resetCache, useToken in
                self.fetchBookCalls.append((url, resetCache, useToken))
                switch self.fetchBookResult! {
                case .success(let result): return result
                case .failure(let error): throw error
                }
            },
            presentBorrowErrorAlert: { _, _, _, _, _, _ in },
            presentSignInModal: { _ in },
            attemptOIDCReauth: { false }
        )
        operation.delegate = spyDelegate
    }

    private func makeStreamingHTMLBook(id: String = "streaming-borrow-book") -> TPPBook {
        let leaf = TPPOPDSIndirectAcquisition(
            type: ContentTypeStreamingHTML,
            indirectAcquisitions: []
        )
        let acquisition = TPPOPDSAcquisition(
            relation: .borrow,
            type: ContentTypeOPDSPublication,
            hrefURL: URL(string: "https://example.com/borrow/\(id)")!,
            indirectAcquisitions: [leaf],
            availability: TPPOPDSAcquisitionAvailabilityUnlimited()
        )
        return TPPBook(
            acquisitions: [acquisition],
            authors: [],
            categoryStrings: [],
            distributor: nil,
            identifier: id,
            imageURL: nil,
            imageThumbnailURL: nil,
            published: Date(),
            publisher: nil,
            subtitle: nil,
            summary: nil,
            title: "Streaming Borrow Title",
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
            imageCache: MockImageCache()
        )
    }

    // MARK: - Streaming-HTML guard

    /// Advisory-F regression: a successful borrow for a streamingHTML book
    /// MUST NOT call `delegate.startDownload`. Without the guard, MBDC tries
    /// to download the text/html asset, fails, and the registry lands in
    /// `.downloadFailed` — locking the user out of the readStreaming
    /// affordance.
    func testBorrowOperation_borrowSucceeded_streamingHTMLBook_doesNotCallStartDownload() async throws {
        let book = makeStreamingHTMLBook(id: "streaming-no-auto-download")
        XCTAssertTrue(book.isStreamingHTML,
                      "precondition: book must report isStreamingHTML == true")
        configureOperation(returning: book)

        let result = try await operation.borrowAsync(book, attemptDownload: true)

        XCTAssertEqual(result.identifier, book.identifier,
                       "borrowAsync must succeed for streamingHTML books")
        XCTAssertEqual(bookRegistry.state(for: book.identifier), .downloadNeeded,
                       "Successful borrow for a streamingHTML book must land in .downloadNeeded (the v2 Option (c) NORMAL post-borrow state)")

        // Allow the @MainActor.run hop a chance to fire (delegate?.startDownload
        // is wrapped in MainActor.run after the borrow). If the guard breaks
        // and startDownload IS called, this delay gives it time to record.
        for _ in 0..<5 {
            try? await Task.sleep(nanoseconds: 30_000_000)
            await Task.yield()
        }

        XCTAssertEqual(spyDelegate.startDownloadCalls.count, 0,
                       "streamingHTML books MUST NOT trigger delegate.startDownload — " +
                       "the BorrowOperation:453 guard `&& !borrowedBook.isStreamingHTML` prevents " +
                       "MBDC from trying to download a non-existent asset and landing in .downloadFailed.")
    }

    /// Companion positive control: a successful borrow for an EPUB book
    /// (which has a downloadable asset) MUST still call
    /// `delegate.startDownload`. Without this test, a mutant that removes
    /// the entire conditional (so startDownload never fires) would pass
    /// the streaming-HTML test silently.
    func testBorrowOperation_borrowSucceeded_epubBook_callsStartDownloadOnce() async throws {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        XCTAssertFalse(book.isStreamingHTML,
                       "precondition: EPUB book must NOT report isStreamingHTML")
        configureOperation(returning: book)

        let result = try await operation.borrowAsync(book, attemptDownload: true)

        XCTAssertEqual(result.identifier, book.identifier)

        for _ in 0..<5 {
            try? await Task.sleep(nanoseconds: 30_000_000)
            await Task.yield()
        }

        XCTAssertEqual(spyDelegate.startDownloadCalls.map { $0.identifier }, [book.identifier],
                       "EPUB borrow with attemptDownload=true MUST call delegate.startDownload exactly once — " +
                       "the guard must NOT over-apply to non-streaming books")
    }

    /// Edge case: streamingHTML book with `attemptDownload: false` must also
    /// not call startDownload (already covered by the attemptDownload guard,
    /// but pinning it here proves the streaming clause is additive, not
    /// substitutive).
    func testBorrowOperation_borrowSucceeded_streamingHTMLBook_attemptDownloadFalse_doesNotCallStartDownload() async throws {
        let book = makeStreamingHTMLBook(id: "streaming-attempt-false")
        configureOperation(returning: book)

        _ = try await operation.borrowAsync(book, attemptDownload: false)

        XCTAssertEqual(spyDelegate.startDownloadCalls.count, 0,
                       "attemptDownload=false + streamingHTML must still not call startDownload — " +
                       "the streaming guard layers on top of the attemptDownload gate")
    }
}

// MARK: - Stub delegate

@MainActor
private final class StreamingSpyDelegate: BorrowOperationDelegate {
    private(set) var startDownloadCalls: [(book: TPPBook, identifier: String)] = []

    func startDownload(for book: TPPBook, withRequest initedRequest: URLRequest?) {
        startDownloadCalls.append((book, book.identifier))
    }

    nonisolated func startBorrow(for book: TPPBook, attemptDownload: Bool, borrowCompletion: (() -> Void)?) {
        // No-op for these tests — startBorrow is invoked from the
        // higher-level borrow flow, not BorrowOperation directly.
    }
}
