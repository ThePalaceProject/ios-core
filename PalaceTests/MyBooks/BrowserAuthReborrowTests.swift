//
//  BrowserAuthReborrowTests.swift
//  PalaceTests
//
//  Browser-based auth treats a `no-active-loan` 400 as a session expiry
//  (PP-3716), so SAML and OIDC patrons re-authenticate and retry the stored
//  book — whose links are scoped to the loan that ended. Re-auth cannot revive
//  a dead link, so they met PP-5397 too.
//

import PalaceAuth
import PalaceBookModel
import PalaceCatalog
import XCTest
@testable import Palace

@MainActor
final class BrowserAuthReborrowTests: XCTestCase {

    private var registry: TPPBookRegistryMock!
    private var stateManager: DownloadStateManager!
    private var reauthenticator: TPPReauthenticatorMock!
    private var alertPresenter: DownloadAlertPresenter!
    private var userAccount: TPPUserAccountMock!
    private var spyDelegate: RetrySpyDelegate!

    /// Separates the two retries the browser path can make: a download of the
    /// stored book (today's session-expiry treatment) and a borrow of a book
    /// carrying a fresh link.
    final class RetrySpyDelegate: DownloadAuthRetryHandlerDelegate {
        private(set) var startedDownloads: [TPPBook] = []
        private(set) var borrowedBooks: [TPPBook] = []

        func startDownload(for book: TPPBook, withRequest request: URLRequest?) {
            startedDownloads.append(book)
        }

        func startBorrow(for book: TPPBook, attemptDownload: Bool, borrowCompletion: (() -> Void)?) {
            borrowedBooks.append(book)
        }
    }

    // MARK: - Fixtures

    private static let fulfillmentHref = "https://example.org/loan/fulfill/9"
    private static let catalogBorrowHref = "https://example.org/works/ISBN/123/borrow"
    private static let alternate = URL(string: "https://example.org/works/ISBN/123")!
    private static let samlType = "http://librarysimplified.org/authtype/SAML-2.0"
    // The real OIDC type string. `AuthType(rawValue:)` falls back to `.none` for
    // anything it does not recognise, whose `reauthStrategy` is `.none` — so a
    // near-miss here routes the test down the barcode path and passes whatever
    // the browser path does.
    private static let oidcType = "http://palaceproject.io/authtype/OpenIDConnect"

    private func deadLoanAcquisition() -> TPPOPDSAcquisition {
        TPPOPDSAcquisition(
            relation: .generic,
            type: "application/epub+zip",
            hrefURL: URL(string: Self.fulfillmentHref)!,
            indirectAcquisitions: [],
            availability: TPPOPDSAcquisitionAvailabilityUnlimited()
        )
    }

    /// The catalog's borrow link. A `.borrow` relation is what tells the
    /// download dispatcher a borrow is needed rather than a download.
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

    /// An entry that still offers the loan rather than a borrow — what the
    /// catalog reads when the session expired but the loan is live.
    private func catalogFulfillmentAcquisition() -> TPPOPDSAcquisition {
        TPPOPDSAcquisition(
            relation: .generic,
            type: "application/epub+zip",
            hrefURL: URL(string: "https://example.org/loan/fulfill/10")!,
            indirectAcquisitions: [],
            availability: TPPOPDSAcquisitionAvailabilityUnlimited()
        )
    }

    private static func copyTaken() -> TPPOPDSAcquisitionAvailability {
        TPPOPDSAcquisitionAvailabilityUnavailable(copiesHeld: 1, copiesTotal: 1)
    }

    private func book(with acquisitions: [TPPOPDSAcquisition]) -> TPPBook {
        TPPBook(
            acquisitions: acquisitions,
            authors: nil,
            categoryStrings: nil,
            distributor: nil,
            identifier: "pp5397-browser-book",
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
            alternateURL: Self.alternate,
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

    private func makeAuth(typeRaw: String) -> AccountDetails.Authentication {
        // `OPDS2AuthenticationDocument.Authentication`'s memberwise init is
        // module-internal, so decode a minimal payload instead.
        let json = #"{"type": "\#(typeRaw)"}"#
        let docAuth = try! JSONDecoder().decode(
            OPDS2AuthenticationDocument.Authentication.self,
            from: Data(json.utf8)
        )
        return AccountDetails.Authentication(auth: docAuth)
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

    private func makeHandler(
        catalogEntryFetcher: CatalogEntryFetcher?,
        authCoordinator: AuthCoordinator? = nil
    ) -> DownloadAuthRetryHandler {
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
            authCoordinator: authCoordinator,
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
        spyDelegate = RetrySpyDelegate()
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

    /// Drives the no-active-loan download failure a browser-auth patron met,
    /// and waits for whichever retry the path chose to land.
    private func driveNoActiveLoan(
        on handler: DownloadAuthRetryHandler,
        book: TPPBook,
        expectingRetry: Bool = true
    ) throws {
        registry.addBook(book, location: nil, state: .downloading,
                         fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)
        // A 200 keeps the 401-detection branch out of it: the browser
        // no-active-loan branch fires off the problem-doc type alone.
        let task = makeFakeTask(statusCode: 200)
        let handled = handler.handleAuthFailureIfApplicable(
            book: book,
            task: task,
            problemDoc: try noActiveLoanProblemDocument(),
            failureError: nil
        )
        XCTAssertTrue(handled, "the browser path must claim a no-active-loan failure")
        guard expectingRetry else { return }
        awaitCondition(timeout: 10) { [spyDelegate] in
            guard let spyDelegate else { return false }
            return !spyDelegate.borrowedBooks.isEmpty || !spyDelegate.startedDownloads.isEmpty
        }
    }

    private func makeFakeTask(statusCode: Int) -> URLSessionTask {
        let task = URLSession.shared.downloadTask(with: URL(string: Self.fulfillmentHref)!)
        return task
    }

    // MARK: - The loan ended: re-auth cannot revive the link

    /// A SAML patron whose loan ended borrows the catalog's link.
    ///
    /// This is the defect: re-authenticating restores the session, then the
    /// retry asked the fulfillment link scoped to the loan that ended and
    /// failed the same way a barcode patron's did.
    func test_samlPatron_whenTheLoanEnded_borrowsTheCatalogsLink() throws {
        userAccount._authDefinition = makeAuth(typeRaw: Self.samlType)
        let stored = book(with: [deadLoanAcquisition()])
        let fromCatalog = book(with: [catalogBorrowAcquisition()])

        let handler = makeHandler(catalogEntryFetcher: { _ in fromCatalog })
        try driveNoActiveLoan(on: handler, book: stored)

        let borrowed = try XCTUnwrap(
            spyDelegate.borrowedBooks.last,
            "no borrow was attempted, so the patron is still asking the dead link"
        )
        XCTAssertEqual(borrowed.defaultAcquisition?.hrefURL.absoluteString, Self.catalogBorrowHref)
        XCTAssertEqual(spyDelegate.startedDownloads.count, 0,
                       "a borrow link cannot be downloaded; the download retry must not also fire")
    }

    /// An OIDC patron whose loan ended borrows the catalog's link.
    func test_oidcPatron_whenTheLoanEnded_borrowsTheCatalogsLink() throws {
        userAccount._authDefinition = makeAuth(typeRaw: Self.oidcType)
        let stored = book(with: [deadLoanAcquisition()])
        let fromCatalog = book(with: [catalogBorrowAcquisition()])

        let handler = makeHandler(catalogEntryFetcher: { _ in fromCatalog })
        try driveNoActiveLoan(on: handler, book: stored)

        let borrowed = try XCTUnwrap(spyDelegate.borrowedBooks.last)
        XCTAssertEqual(borrowed.defaultAcquisition?.hrefURL.absoluteString, Self.catalogBorrowHref)
    }

    /// A coordinator-routed patron whose loan ended borrows the catalog's link.
    func test_coordinatorRouted_whenTheLoanEnded_borrowsTheCatalogsLink() throws {
        let (coordinator, _, _, _, _) = SpyAuthCoordinatorFactory.make(
            mechanism: .saml, stubModalResult: true
        )
        userAccount._authDefinition = makeAuth(typeRaw: Self.samlType)
        let stored = book(with: [deadLoanAcquisition()])
        let fromCatalog = book(with: [catalogBorrowAcquisition()])

        let handler = makeHandler(catalogEntryFetcher: { _ in fromCatalog },
                                  authCoordinator: coordinator)
        try driveNoActiveLoan(on: handler, book: stored)

        let borrowed = try XCTUnwrap(spyDelegate.borrowedBooks.last)
        XCTAssertEqual(borrowed.defaultAcquisition?.hrefURL.absoluteString, Self.catalogBorrowHref)
    }

    // MARK: - The session expired: today's treatment must survive

    /// An entry still offering the loan keeps the session-expiry retry.
    ///
    /// PP-3716's case: the session timed out and the server answered 400. The
    /// loan is live, so re-auth plus a download of the stored book is right and
    /// must not become a borrow.
    func test_whenTheCatalogStillOffersTheLoan_theSessionExpiryRetryIsKept() throws {
        userAccount._authDefinition = makeAuth(typeRaw: Self.samlType)
        let stored = book(with: [deadLoanAcquisition()])
        let stillOnLoan = book(with: [catalogFulfillmentAcquisition()])

        let handler = makeHandler(catalogEntryFetcher: { _ in stillOnLoan })
        try driveNoActiveLoan(on: handler, book: stored)

        XCTAssertEqual(spyDelegate.borrowedBooks.count, 0,
                       "an entry with no borrow link is a live loan; borrowing it would be wrong")
        XCTAssertEqual(spyDelegate.startedDownloads.map(\.identifier), [stored.identifier])
        XCTAssertEqual(registry.state(for: stored.identifier), .SAMLStarted,
                       "the SAML session-expiry state transition must be unchanged")
    }

    /// A failed catalog read keeps the session-expiry retry.
    func test_whenTheCatalogCannotBeRead_theSessionExpiryRetryIsKept() throws {
        userAccount._authDefinition = makeAuth(typeRaw: Self.samlType)
        let stored = book(with: [deadLoanAcquisition()])

        let handler = makeHandler(catalogEntryFetcher: { _ in nil })
        try driveNoActiveLoan(on: handler, book: stored)

        XCTAssertEqual(spyDelegate.borrowedBooks.count, 0)
        XCTAssertEqual(spyDelegate.startedDownloads.map(\.identifier), [stored.identifier])
    }

    /// With no fetcher wired the browser path is exactly as it was.
    func test_whenNoFetcherIsWired_theSessionExpiryRetryIsKept() throws {
        userAccount._authDefinition = makeAuth(typeRaw: Self.samlType)
        let stored = book(with: [deadLoanAcquisition()])

        let handler = makeHandler(catalogEntryFetcher: nil)
        try driveNoActiveLoan(on: handler, book: stored)

        XCTAssertEqual(spyDelegate.borrowedBooks.count, 0)
        XCTAssertEqual(spyDelegate.startedDownloads.map(\.identifier), [stored.identifier])
        XCTAssertEqual(registry.state(for: stored.identifier), .SAMLStarted)
    }

    /// A declined re-authentication retries nothing at all.
    ///
    /// The patron dismissed sign-in. Borrowing on their behalf after that would
    /// take an action they just backed out of.
    func test_whenTheCoordinatorDeclinesToRefresh_nothingIsRetried() throws {
        let (coordinator, _, _, _, _) = SpyAuthCoordinatorFactory.make(
            mechanism: .saml, stubReauthResult: false, stubModalResult: false
        )
        userAccount._authDefinition = makeAuth(typeRaw: Self.samlType)
        let stored = book(with: [deadLoanAcquisition()])
        let fromCatalog = book(with: [catalogBorrowAcquisition()])

        let handler = makeHandler(catalogEntryFetcher: { _ in fromCatalog },
                                  authCoordinator: coordinator)
        try driveNoActiveLoan(on: handler, book: stored, expectingRetry: false)
        // No retry is the expected outcome, so settle the path rather than wait
        // for a signal that must never arrive.
        drainMainQueue()

        XCTAssertEqual(spyDelegate.borrowedBooks.count, 0,
                       "a patron who dismissed sign-in must not have a borrow made for them")
        XCTAssertEqual(spyDelegate.startedDownloads.count, 0)
    }

    // MARK: - The hold guard, on the browser path too

    /// An unavailable entry plus a hold response still raises the PP-4178 alert.
    ///
    /// The same guarantee the barcode path has: the catalog reading never
    /// decides, and a hold the patron did not ask for is not a success.
    func test_unavailableEntryAndAHoldResponse_stillRaisesTheHoldAlert() throws {
        userAccount._authDefinition = makeAuth(typeRaw: Self.samlType)
        let stored = book(with: [deadLoanAcquisition()])
        let fromCatalog = book(with: [catalogBorrowAcquisition(availability: Self.copyTaken())])

        let handler = makeHandler(catalogEntryFetcher: { _ in fromCatalog })
        try driveNoActiveLoan(on: handler, book: stored)

        let preBorrow = try XCTUnwrap(
            spyDelegate.borrowedBooks.last,
            "an unavailable entry must still be borrowed, not skipped"
        )
        let heldInstead = book(with: [catalogBorrowAcquisition(availability: Self.copyTaken())])

        let mapping = BorrowReducerCore.responseState(for: heldInstead, preBorrowBook: preBorrow)

        XCTAssertEqual(mapping.state, .holding)
        guard case .bookRegistry(.holdCopyUnavailable)? = mapping.error else {
            return XCTFail(
                "the Loan→Hold race alert was suppressed on the browser path, so a hold the "
                + "patron did not ask for would be reported as a borrow"
            )
        }
    }

    /// An unavailable entry is still borrowed from its link.
    func test_whenTheEntryReadsUnavailable_theRetryStillBorrowsFromItsLink() throws {
        userAccount._authDefinition = makeAuth(typeRaw: Self.samlType)
        let stored = book(with: [deadLoanAcquisition()])
        let fromCatalog = book(with: [catalogBorrowAcquisition(availability: Self.copyTaken())])

        let handler = makeHandler(catalogEntryFetcher: { _ in fromCatalog })
        try driveNoActiveLoan(on: handler, book: stored)

        XCTAssertEqual(
            spyDelegate.borrowedBooks.last?.defaultAcquisition?.hrefURL.absoluteString,
            Self.catalogBorrowHref,
            "the borrow must be attempted whatever the entry says about copies"
        )
    }
}
