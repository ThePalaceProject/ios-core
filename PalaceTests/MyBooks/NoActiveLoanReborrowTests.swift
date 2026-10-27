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
    private func deadLoanAcquisition(
        availability: TPPOPDSAcquisitionAvailability = TPPOPDSAcquisitionAvailabilityUnlimited()
    ) -> TPPOPDSAcquisition {
        TPPOPDSAcquisition(
            relation: .generic,
            type: "application/epub+zip",
            hrefURL: URL(string: Self.fulfillmentHref)!,
            indirectAcquisitions: [],
            availability: availability
        )
    }

    /// What the catalog advertises for the same work, and the only link that
    /// can still produce a loan.
    private func catalogBorrowAcquisition(
        availability: TPPOPDSAcquisitionAvailability = TPPOPDSAcquisitionAvailabilityUnlimited()
    ) -> TPPOPDSAcquisition {
        TPPOPDSAcquisition(
            relation: .borrow,
            type: "application/atom+xml;type=entry;profile=opds-catalog",
            hrefURL: URL(string: Self.catalogBorrowHref)!,
            indirectAcquisitions: [],
            availability: availability
        )
    }

    /// Every copy out: what the catalog reads once someone else takes the copy
    /// the patron gave back.
    private static func copyTaken() -> TPPOPDSAcquisitionAvailability {
        TPPOPDSAcquisitionAvailabilityUnavailable(copiesHeld: 1, copiesTotal: 1)
    }

    private static func readsUnavailable(_ book: TPPBook) -> Bool {
        var unavailable = false
        book.defaultAcquisition?.availability.match(
            unavailable: { _ in unavailable = true },
            limited: nil, unlimited: nil, reserved: nil, ready: nil
        )
        return unavailable
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

    /// Drives the no-active-loan download failure the patron met, and waits for
    /// the retry's catalog read to land.
    private func driveNoActiveLoan(on handler: DownloadAuthRetryHandler, book: TPPBook) async throws {
        let task = URLSession.shared.downloadTask(with: URL(string: Self.fulfillmentHref)!)
        _ = handler.handleAuthFailureIfApplicable(
            book: book,
            task: task,
            problemDoc: try noActiveLoanProblemDocument(),
            failureError: nil
        )
        await drainMainQueue()
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

    // MARK: - The catalog's availability must not decide the borrow

    /// An entry the catalog calls unavailable is still borrowed from its link.
    ///
    /// A copy taken between the loan ending and the retry makes the catalog
    /// read `unavailable`. The retry must still ask, because only the
    /// circulation manager's answer to the borrow can tell a loan from a hold.
    func test_whenTheCatalogEntryReadsUnavailable_theRetryStillBorrowsFromItsLink() async throws {
        let alternate = URL(string: "https://example.org/works/ISBN/123")!
        let stored = book(with: [deadLoanAcquisition()], alternate: alternate)
        let fromCatalog = book(with: [catalogBorrowAcquisition(availability: Self.copyTaken())],
                               alternate: alternate)

        let handler = makeHandler(catalogEntryFetcher: { _ in fromCatalog })
        try await driveNoActiveLoan(on: handler, book: stored)

        guard let borrowed = spyDelegate.borrowedBooks.last else {
            return XCTFail("an unavailable catalog entry must not skip the borrow")
        }
        XCTAssertEqual(
            borrowed.defaultAcquisition?.hrefURL.absoluteString, Self.catalogBorrowHref,
            "the retry must ask the catalog's link whatever the entry says about copies"
        )
    }

    /// The retry book carries the availability the patron was acting on.
    ///
    /// `BorrowReducerCore` reads the pre-borrow book's availability to tell a
    /// deliberate Place Hold from a borrow the circulation manager downgraded
    /// to a hold (PP-4178). The patron reached this path from Download, so the
    /// loan-era availability is the faithful record of what they acted on;
    /// taking the catalog's would read as a Place Hold.
    func test_theRetryBookKeepsTheAvailabilityThePatronWasActingOn() async throws {
        let alternate = URL(string: "https://example.org/works/ISBN/123")!
        let stored = book(with: [deadLoanAcquisition()], alternate: alternate)
        let fromCatalog = book(with: [catalogBorrowAcquisition(availability: Self.copyTaken())],
                               alternate: alternate)

        let handler = makeHandler(catalogEntryFetcher: { _ in fromCatalog })
        try await driveNoActiveLoan(on: handler, book: stored)

        let retried = try XCTUnwrap(spyDelegate.borrowedBooks.last)
        XCTAssertFalse(
            Self.readsUnavailable(retried),
            "the retry book took the catalog's unavailable reading, which reads as a deliberate Place Hold"
        )
    }

    /// Unavailable entry + a hold response still raises the PP-4178 alert.
    ///
    /// This is the risk the catalog re-read could have introduced: an
    /// `unavailable` pre-borrow reading silences the Loan→Hold race error, so a
    /// hold the patron never asked for would be announced as a successful
    /// borrow. Drives the handler's own output through the real reducer.
    func test_unavailableEntryAndAHoldResponse_stillRaisesTheHoldAlert() async throws {
        let alternate = URL(string: "https://example.org/works/ISBN/123")!
        let stored = book(with: [deadLoanAcquisition()], alternate: alternate)
        let fromCatalog = book(with: [catalogBorrowAcquisition(availability: Self.copyTaken())],
                               alternate: alternate)

        let handler = makeHandler(catalogEntryFetcher: { _ in fromCatalog })
        try await driveNoActiveLoan(on: handler, book: stored)

        let preBorrow = try XCTUnwrap(spyDelegate.borrowedBooks.last,
                                      "no borrow was attempted, so the hold path cannot be reached")
        let heldInstead = book(with: [catalogBorrowAcquisition(availability: Self.copyTaken())],
                               alternate: alternate)

        let mapping = BorrowReducerCore.responseState(for: heldInstead, preBorrowBook: preBorrow)

        XCTAssertEqual(mapping.state, .holding, "a hold response must still land the book in .holding")
        guard case .bookRegistry(.holdCopyUnavailable)? = mapping.error else {
            return XCTFail(
                "the Loan→Hold race alert (PP-4178) was suppressed, so a hold the patron did not "
                + "ask for would be reported as a borrow; error was \(String(describing: mapping.error))"
            )
        }
        XCTAssertEqual(
            BorrowReducerCore.postResponseEffects(
                state: mapping.state,
                isStreamingHTML: false,
                attemptDownload: true,
                hasRaceError: mapping.error != nil
            ),
            [.failWithRaceError],
            "the only effect of a hold the patron did not ask for is the throw that surfaces the alert"
        )
    }

    /// A deliberate Place Hold is still not reported as a failure.
    ///
    /// The sibling cell of the test above: when the record the patron acted on
    /// already read unavailable, a hold response is the expected queue
    /// placement and must stay silent.
    func test_whenTheStoredRecordAlreadyReadUnavailable_aHoldResponseStaysSilent() async throws {
        let alternate = URL(string: "https://example.org/works/ISBN/123")!
        let stored = book(with: [deadLoanAcquisition(availability: Self.copyTaken())], alternate: alternate)
        let fromCatalog = book(with: [catalogBorrowAcquisition(availability: Self.copyTaken())],
                               alternate: alternate)

        let handler = makeHandler(catalogEntryFetcher: { _ in fromCatalog })
        try await driveNoActiveLoan(on: handler, book: stored)

        let preBorrow = try XCTUnwrap(spyDelegate.borrowedBooks.last)
        let heldInstead = book(with: [catalogBorrowAcquisition(availability: Self.copyTaken())],
                               alternate: alternate)

        let mapping = BorrowReducerCore.responseState(for: heldInstead, preBorrowBook: preBorrow)

        XCTAssertEqual(mapping.state, .holding)
        XCTAssertNil(mapping.error,
                     "a hold placed on a record that already read unavailable is the expected outcome")
    }

    /// Unavailable entry + a granted loan is a plain success.
    ///
    /// The cell the fix exists for: the catalog read says the copy is gone, the
    /// circulation manager grants the loan anyway, and the patron gets the book
    /// with no alert. Drives the handler's own output through the real reducer.
    func test_unavailableEntryAndAGrantedLoan_succeedsWithNoAlert() async throws {
        let alternate = URL(string: "https://example.org/works/ISBN/123")!
        let stored = book(with: [deadLoanAcquisition()], alternate: alternate)
        let fromCatalog = book(with: [catalogBorrowAcquisition(availability: Self.copyTaken())],
                               alternate: alternate)

        let handler = makeHandler(catalogEntryFetcher: { _ in fromCatalog })
        try await driveNoActiveLoan(on: handler, book: stored)

        let preBorrow = try XCTUnwrap(spyDelegate.borrowedBooks.last)
        let lent = book(with: [catalogBorrowAcquisition(
            availability: TPPOPDSAcquisitionAvailabilityLimited(
                copiesAvailable: 1, copiesTotal: 1, since: nil, until: nil)
        )], alternate: alternate)

        let mapping = BorrowReducerCore.responseState(for: lent, preBorrowBook: preBorrow)

        XCTAssertEqual(mapping.state, .downloadNeeded, "a granted loan must leave the book downloadable")
        XCTAssertNil(mapping.error, "a granted loan is not a failure")
        XCTAssertEqual(
            BorrowReducerCore.postResponseEffects(
                state: mapping.state,
                isStreamingHTML: false,
                attemptDownload: true,
                hasRaceError: mapping.error != nil
            ),
            [.announceBorrowSucceeded, .noteBorrowSucceeded, .startDownload],
            "the retry must carry straight on into the download the patron asked for"
        )
    }

    /// No alternate URL and no fetcher still attempts the borrow.
    ///
    /// Both halves of the re-read guard are absent at once, which is the cell
    /// neither single-cause test reaches.
    func test_withNeitherAnAlternateURLNorAFetcher_theRetryIsStillAttempted() async throws {
        let stored = book(with: [deadLoanAcquisition()], alternate: nil)

        let handler = makeHandler(catalogEntryFetcher: nil)
        try await driveNoActiveLoan(on: handler, book: stored)

        XCTAssertEqual(
            spyDelegate.borrowedBooks.last?.defaultAcquisition?.hrefURL.absoluteString,
            Self.fulfillmentHref,
            "with nothing to re-read the stored link is all there is, and the attempt must still happen"
        )
    }

    /// With no fetcher wired, the retry proceeds with the stored book.
    ///
    /// The fifth cell of the retry table: the capability is absent, so the old
    /// path is the only one available and must still attempt the borrow.
    func test_whenNoFetcherIsInjected_theRetryProceedsWithTheStoredBook() async throws {
        let stored = book(with: [deadLoanAcquisition()],
                          alternate: URL(string: "https://example.org/works/ISBN/123")!)

        let handler = makeHandler(catalogEntryFetcher: nil)
        try await driveNoActiveLoan(on: handler, book: stored)

        XCTAssertEqual(spyDelegate.borrowedBooks.count, 1, "the retry must still be attempted")
        XCTAssertEqual(
            spyDelegate.borrowedBooks.last?.defaultAcquisition?.hrefURL.absoluteString,
            Self.fulfillmentHref,
            "without a fetcher there is nothing to re-read, so the stored link is all there is"
        )
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
