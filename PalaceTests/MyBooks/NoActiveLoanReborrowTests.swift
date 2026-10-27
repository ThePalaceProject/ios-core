//
//  NoActiveLoanReborrowTests.swift
//  PalaceTests
//
//  A returned book's stored acquisitions are fulfillment links scoped to the
//  loan that ended, so they answer 400 no-active-loan. The auto-borrow retry
//  re-sent the same book, so it asked the dead link again and failed the same
//  way (PP-5397).
//

import Combine
import PalaceBookModel
import PalaceCatalog
import XCTest
@testable import Palace

@MainActor
final class NoActiveLoanReborrowTests: XCTestCase {

    private var registry: TPPBookRegistryMock!
    private var stateManager: DownloadStateManager!
    private var reauthenticator: TPPReauthenticatorMock!
    private var alertPresenter: DownloadAlertPresenter!
    private var userAccount: TPPUserAccountMock!
    private var spyDelegate: BorrowCapturingDelegate!

    /// Captures the book handed to `startBorrow`, which is the thing that
    /// decides which URL `BorrowOperation` will ask for the loan.
    final class BorrowCapturingDelegate: DownloadAuthRetryHandlerDelegate {
        private(set) var borrowedBooks: [TPPBook] = []
        private(set) var startedDownloads: [TPPBook] = []
        private(set) var borrowCompletions: [(() -> Void)?] = []

        func startDownload(for book: TPPBook, withRequest request: URLRequest?) {
            startedDownloads.append(book)
        }

        func startBorrow(for book: TPPBook, attemptDownload: Bool, borrowCompletion: (() -> Void)?) {
            borrowedBooks.append(book)
            borrowCompletions.append(borrowCompletion)
        }
    }

    // MARK: - Fixtures

    private static let fulfillmentHref = "https://example.org/loan/fulfill/9"
    private static let catalogBorrowHref = "https://example.org/works/ISBN/123/borrow"

    /// What the app stored while the book was on loan: a fulfillment link, with
    /// no borrow relation. Once the loan ends this answers 400 no-active-loan.
    private func deadLoanAcquisition() -> TPPOPDSAcquisition {
        TPPOPDSAcquisition(
            relation: .generic,
            type: "application/epub+zip",
            hrefURL: URL(string: Self.fulfillmentHref)!,
            indirectAcquisitions: [],
            availability: TPPOPDSAcquisitionAvailabilityUnlimited()
        )
    }

    /// What the catalog advertises for the same work, and the only link that
    /// can still produce a loan.
    private func catalogBorrowAcquisition() -> TPPOPDSAcquisition {
        TPPOPDSAcquisition(
            relation: .borrow,
            type: "application/atom+xml;type=entry;profile=opds-catalog",
            hrefURL: URL(string: Self.catalogBorrowHref)!,
            indirectAcquisitions: [],
            availability: TPPOPDSAcquisitionAvailabilityUnlimited()
        )
    }

    private func book(with acquisitions: [TPPOPDSAcquisition], alternate: URL?) -> TPPBook {
        TPPBook(
            acquisitions: acquisitions,
            authors: nil,
            categoryStrings: nil,
            distributor: nil,
            identifier: "pp5397-book",
            imageURL: nil,
            imageThumbnailURL: nil,
            published: nil,
            publisher: nil,
            subtitle: nil,
            summary: nil,
            title: "A Returned Book",
            updated: Date(timeIntervalSince1970: 1_000_000),
            annotationsURL: nil,
            analyticsURL: nil,
            alternateURL: alternate,
            relatedWorksURL: nil,
            previewLink: nil,
            seriesURL: nil,
            seriesName: nil,
            revokeURL: nil,
            reportURL: nil,
            timeTrackingURL: nil,
            contributors: nil,
            bookDuration: nil,
            imageCache: MockImageCache()
        )
    }

    private func noActiveLoanProblemDocument() throws -> TPPProblemDocument {
        let dict: [String: Any] = [
            "type": "http://librarysimplified.org/terms/problem/no-active-loan",
            "title": "No Active Loan",
            "detail": "You have no active loan for this title."
        ]
        let data = try JSONSerialization.data(withJSONObject: dict)
        return try XCTUnwrap(TPPProblemDocument.fromProblemResponseData(data))
    }

    private func makeHandler(catalogEntryFetcher: CatalogEntryFetcher?) -> DownloadAuthRetryHandler {
        let reporter = DownloadProgressReporter(
            accessibilityAnnouncements: TPPAccessibilityAnnouncementCenter(),
            downloadAnnouncementService: DownloadAnnouncementService()
        )
        alertPresenter = DownloadAlertPresenter(
            bookRegistry: registry,
            stateManager: stateManager,
            progressReporter: reporter,
            downloadAnnouncementService: DownloadAnnouncementService()
        )
        let handler = DownloadAuthRetryHandler(
            stateManager: stateManager,
            bookRegistry: registry,
            reauthenticator: reauthenticator,
            alertPresenter: alertPresenter,
            userAccountProvider: { [unowned self] in self.userAccount },
            catalogEntryFetcher: catalogEntryFetcher
        )
        handler.delegate = spyDelegate
        return handler
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        registry = TPPBookRegistryMock()
        stateManager = DownloadStateManager()
        reauthenticator = TPPReauthenticatorMock()
        userAccount = TPPUserAccountMock()
        userAccount._credentials = .barcodeAndPin(barcode: "b", pin: "p")
        spyDelegate = BorrowCapturingDelegate()
    }

    override func tearDownWithError() throws {
        registry = nil
        stateManager = nil
        reauthenticator = nil
        alertPresenter = nil
        userAccount = nil
        spyDelegate = nil
        try super.tearDownWithError()
    }

    private func drainMainQueue() async {
        await Task.yield()
        try? await Task.sleep(nanoseconds: 50_000_000)
    }

    // MARK: - The retry must not re-send the link that just failed

    /// On no-active-loan, the retry borrows from the catalog's borrow link.
    ///
    /// This is the defect a patron met: the stored fulfillment link answered
    /// 400, the retry asked the same link, and every tap for the next few
    /// seconds failed the same way with a message about an invalid state.
    func test_onNoActiveLoan_theRetryBorrowsFromTheCatalogsBorrowLink() async throws {
        let alternate = URL(string: "https://example.org/works/ISBN/123")!
        let stored = book(with: [deadLoanAcquisition()], alternate: alternate)
        let fromCatalog = book(with: [catalogBorrowAcquisition()], alternate: alternate)

        let fetchedFrom = URLRecorder()
        let handler = makeHandler(catalogEntryFetcher: { book in
            if let url = book.alternateURL { fetchedFrom.record(url) }
            return fromCatalog
        })

        let task = URLSession.shared.downloadTask(with: URL(string: Self.fulfillmentHref)!)
        _ = handler.handleAuthFailureIfApplicable(
            book: stored,
            task: task,
            problemDoc: try noActiveLoanProblemDocument(),
            failureError: nil
        )
        await drainMainQueue()

        XCTAssertEqual(fetchedFrom.urls, [alternate],
                       "the retry must re-read the catalog entry, which is where the only working link lives")

        guard let borrowed = spyDelegate.borrowedBooks.last else {
            return XCTFail("the retry must attempt a borrow; none was attempted")
        }
        XCTAssertEqual(
            borrowed.defaultAcquisition?.hrefURL.absoluteString,
            Self.catalogBorrowHref,
            "the borrow must go to the catalog's borrow link, not the fulfillment link that just returned 400"
        )
    }

    /// The link that just failed must not be the one retried.
    ///
    /// Stated separately from the assertion above because this is the
    /// regression itself, and it fails with a message naming what went wrong
    /// rather than an equality mismatch.
    func test_onNoActiveLoan_theRetryDoesNotReuseTheDeadFulfillmentLink() async throws {
        let alternate = URL(string: "https://example.org/works/ISBN/123")!
        let stored = book(with: [deadLoanAcquisition()], alternate: alternate)
        let fromCatalog = book(with: [catalogBorrowAcquisition()], alternate: alternate)

        let handler = makeHandler(catalogEntryFetcher: { _ in fromCatalog })
        let task = URLSession.shared.downloadTask(with: URL(string: Self.fulfillmentHref)!)
        _ = handler.handleAuthFailureIfApplicable(
            book: stored,
            task: task,
            problemDoc: try noActiveLoanProblemDocument(),
            failureError: nil
        )
        await drainMainQueue()

        let retried = spyDelegate.borrowedBooks.last?.defaultAcquisition?.hrefURL.absoluteString
        XCTAssertNotEqual(
            retried, Self.fulfillmentHref,
            "this is the defect: the retry asked the same dead fulfillment link again"
        )
    }

    // MARK: - Degrading when the catalog cannot be reached

    /// A failed catalog read must still attempt the borrow.
    ///
    /// A patron offline, or a feed that errors, should be no worse off than
    /// before this change: the retry falls back to the stored book rather than
    /// giving up and leaving them with nothing.
    func test_whenTheCatalogEntryCannotBeFetched_theRetryStillAttemptsTheBorrow() async throws {
        let stored = book(with: [deadLoanAcquisition()],
                          alternate: URL(string: "https://example.org/works/ISBN/123")!)

        let handler = makeHandler(catalogEntryFetcher: { _ in nil })
        let task = URLSession.shared.downloadTask(with: URL(string: Self.fulfillmentHref)!)
        _ = handler.handleAuthFailureIfApplicable(
            book: stored,
            task: task,
            problemDoc: try noActiveLoanProblemDocument(),
            failureError: nil
        )
        await drainMainQueue()

        XCTAssertEqual(spyDelegate.borrowedBooks.count, 1,
                       "a failed catalog read must not cost the patron the retry altogether")
    }

    /// A book with no alternate URL is retried as before.
    ///
    /// There is nowhere to re-read from, so the old behaviour is the only
    /// option and must still happen.
    func test_whenThereIsNoAlternateURL_theRetryProceedsWithTheStoredBook() async throws {
        let stored = book(with: [deadLoanAcquisition()], alternate: nil)

        let fetchedFrom = URLRecorder()
        let handler = makeHandler(catalogEntryFetcher: { book in
            fetchedFrom.record(book.alternateURL ?? URL(string: "about:blank")!)
            return nil
        })
        let task = URLSession.shared.downloadTask(with: URL(string: Self.fulfillmentHref)!)
        _ = handler.handleAuthFailureIfApplicable(
            book: stored,
            task: task,
            problemDoc: try noActiveLoanProblemDocument(),
            failureError: nil
        )
        await drainMainQueue()

        XCTAssertEqual(fetchedFrom.urls.count, 0, "there is no catalog entry to fetch without an alternate URL")
        XCTAssertEqual(spyDelegate.borrowedBooks.count, 1, "the retry must still be attempted")
    }
}

/// Records the URLs a `@Sendable` fetcher was asked for.
///
/// A plain captured array cannot be mutated from inside a `@Sendable` closure
/// under strict concurrency, and the fetcher is `@Sendable` because the task
/// that calls it is.
private final class URLRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _urls: [URL] = []
    var urls: [URL] { lock.withLock { _urls } }
    func record(_ url: URL) { lock.withLock { _urls.append(url) } }
}
