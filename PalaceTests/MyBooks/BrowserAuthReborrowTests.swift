//
//  BrowserAuthReborrowTests.swift
//  PalaceTests
//
//  Browser-based auth treats a `no-active-loan` 400 as a session expiry
//  (PP-3716), so SAML and OIDC patrons re-authenticate and retry the stored
//  book — whose links are scoped to the loan that ended. Re-auth cannot revive
//  a dead link, so they met PP-5397 too.
//
//  The two causes are told apart by asking the server again, not by reading the
//  catalog: a catalog entry advertises a borrow link for a book that IS on loan
//  (PP-5400). So the first failure re-authenticates as before, and only a
//  second failure with fresh credentials means the loan itself ended.
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

    private func book(
        with acquisitions: [TPPOPDSAcquisition],
        identifier: String = "pp5397-browser-book"
    ) -> TPPBook {
        TPPBook(
            acquisitions: acquisitions,
            authors: nil,
            categoryStrings: nil,
            distributor: nil,
            identifier: identifier,
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

    /// Drives the handler's clock so the episode window has an exact boundary
    /// to assert, rather than one that only wall-clock time could reach.
    private let clock = TestClock()

    final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var _now = Date(timeIntervalSince1970: 1_700_000_000)
        var now: Date { lock.withLock { _now } }
        func advance(by seconds: TimeInterval) { lock.withLock { _now += seconds } }
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
            catalogEntryFetcher: catalogEntryFetcher,
            now: { [clock] in clock.now }
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

    /// Drives one no-active-loan download failure.
    ///
    /// Returns without waiting; callers wait on the specific outcome they are
    /// asserting, so an absence is never read before the decision was made.
    @discardableResult
    private func driveNoActiveLoan(on handler: DownloadAuthRetryHandler, book: TPPBook) throws -> Bool {
        if registry.state(for: book.identifier) != .downloading {
            registry.addBook(book, location: nil, state: .downloading,
                             fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)
        }
        let handled = handler.handleAuthFailureIfApplicable(
            book: book,
            task: makeFakeTask(),
            problemDoc: try noActiveLoanProblemDocument(),
            failureError: nil
        )
        XCTAssertTrue(handled, "the handler must claim a no-active-loan failure")
        return handled
    }

    /// Drives the first failure, waits for the session-expiry retry to land,
    /// then drives the second — which is the one that means the loan ended.
    ///
    /// Asserts the first failure really took the browser arm.
    /// `markCredentialsStale` runs only there, so this also fails if a fixture
    /// typo routed the test down the barcode path.
    private func driveFirstThenSecondFailure(
        on handler: DownloadAuthRetryHandler,
        book: TPPBook
    ) throws {
        try driveNoActiveLoan(on: handler, book: book)
        awaitCondition(timeout: 10) { [spyDelegate] in
            !(spyDelegate?.startedDownloads.isEmpty ?? true)
        }
        XCTAssertEqual(
            userAccount.authState, .credentialsStale,
            "the first failure must take the browser session-expiry arm; a fixture whose auth "
            + "type does not resolve would route down the barcode path and borrow immediately"
        )
        XCTAssertEqual(spyDelegate.borrowedBooks.count, 0,
                       "the first failure must not borrow — the loan may simply be behind a dead session")
        try driveNoActiveLoan(on: handler, book: book)
        awaitCondition(timeout: 10) { [spyDelegate] in
            !(spyDelegate?.borrowedBooks.isEmpty ?? true)
        }
    }

    /// A task with no response, which is what the no-active-loan branch needs:
    /// `task.response as? HTTPURLResponse` is nil, so the 401-detection branch
    /// is never consulted and the problem-doc type alone decides.
    private func makeFakeTask() -> URLSessionTask {
        URLSession.shared.downloadTask(with: URL(string: Self.fulfillmentHref)!)
    }

    // MARK: - The first failure: the session may simply have expired

    /// A SAML patron's first no-active-loan is still treated as a session expiry.
    ///
    /// PP-3716's case, and the reason the catalog cannot decide this: a catalog
    /// entry advertises a borrow link for a book that IS on loan (PP-5400), so
    /// reading one here would divert every live loan into a borrow.
    func test_samlPatron_firstFailure_isStillTreatedAsASessionExpiry() throws {
        userAccount._authDefinition = makeAuth(typeRaw: Self.samlType)
        let stored = book(with: [deadLoanAcquisition()])
        let fromCatalog = book(with: [catalogBorrowAcquisition()])

        let handler = makeHandler(catalogEntryFetcher: { _ in fromCatalog })
        try driveNoActiveLoan(on: handler, book: stored)
        awaitCondition(timeout: 10) { [registry] in
            registry?.state(for: stored.identifier) == .SAMLStarted
        }

        XCTAssertEqual(spyDelegate.borrowedBooks.count, 0,
                       "a borrow link in the catalog is not evidence the loan ended")
        XCTAssertEqual(spyDelegate.startedDownloads.map(\.identifier), [stored.identifier],
                       "the session-expiry retry must still download the stored book")
        XCTAssertEqual(userAccount.authState, .credentialsStale)
    }

    /// A non-SAML browser patron's first failure re-authenticates as before.
    func test_oidcPatron_firstFailure_isStillTreatedAsASessionExpiry() throws {
        userAccount._authDefinition = makeAuth(typeRaw: Self.oidcType)
        let stored = book(with: [deadLoanAcquisition()])
        let fromCatalog = book(with: [catalogBorrowAcquisition()])

        let handler = makeHandler(catalogEntryFetcher: { _ in fromCatalog })
        try driveNoActiveLoan(on: handler, book: stored)
        awaitCondition(timeout: 10) { [reauthenticator] in
            reauthenticator?.authenticateIfNeededCalled == true
        }

        XCTAssertEqual(spyDelegate.borrowedBooks.count, 0)
        XCTAssertEqual(userAccount.authState, .credentialsStale,
                       "OIDC resolves to the browser strategy, so the session-expiry arm must run")
    }

    // MARK: - The second failure: the loan itself ended

    /// A second failure with fresh credentials borrows the catalog's link.
    ///
    /// This is the defect for browser patrons: re-auth succeeded, the server
    /// still says no active loan, so the loan ended rather than the session —
    /// and no amount of authenticating revives a loan-scoped link.
    func test_samlPatron_secondFailure_borrowsTheCatalogsLink() throws {
        userAccount._authDefinition = makeAuth(typeRaw: Self.samlType)
        let stored = book(with: [deadLoanAcquisition()])
        let fromCatalog = book(with: [catalogBorrowAcquisition()])

        let handler = makeHandler(catalogEntryFetcher: { _ in fromCatalog })
        try driveFirstThenSecondFailure(on: handler, book: stored)

        let borrowed = try XCTUnwrap(
            spyDelegate.borrowedBooks.last,
            "the second failure means the loan ended, so a borrow must be attempted"
        )
        XCTAssertEqual(borrowed.defaultAcquisition?.hrefURL.absoluteString, Self.catalogBorrowHref,
                       "the borrow must go to the catalog's link, not the one that just failed twice")
    }

    /// The same, for a coordinator-routed patron.
    func test_coordinatorRouted_secondFailure_borrowsTheCatalogsLink() throws {
        let (coordinator, _, modal, _, _) = SpyAuthCoordinatorFactory.make(
            mechanism: .saml, stubModalResult: true
        )
        userAccount._authDefinition = makeAuth(typeRaw: Self.samlType)
        let stored = book(with: [deadLoanAcquisition()])
        let fromCatalog = book(with: [catalogBorrowAcquisition()])

        let handler = makeHandler(catalogEntryFetcher: { _ in fromCatalog },
                                  authCoordinator: coordinator)
        try driveFirstThenSecondFailure(on: handler, book: stored)

        XCTAssertEqual(modal.presentCallCount, 1,
                       "the first failure must have gone through the coordinator, not the barcode path")
        XCTAssertEqual(
            spyDelegate.borrowedBooks.last?.defaultAcquisition?.hrefURL.absoluteString,
            Self.catalogBorrowHref
        )
    }

    /// A second failure with no fetcher wired still attempts the borrow.
    func test_secondFailure_withNoFetcherWired_stillAttemptsTheBorrow() throws {
        userAccount._authDefinition = makeAuth(typeRaw: Self.samlType)
        let stored = book(with: [deadLoanAcquisition()])

        let handler = makeHandler(catalogEntryFetcher: nil)
        try driveFirstThenSecondFailure(on: handler, book: stored)

        XCTAssertEqual(
            spyDelegate.borrowedBooks.last?.defaultAcquisition?.hrefURL.absoluteString,
            Self.fulfillmentHref,
            "without a re-read the stored link is all there is, and the attempt must still happen"
        )
    }

    /// A third failure is treated as a new session expiry.
    ///
    /// The episode is consumed by the borrow it triggers, so a later genuine
    /// expiry for the same book is not misread as a lapsed loan.
    func test_thirdFailure_isTreatedAsANewSessionExpiry() throws {
        userAccount._authDefinition = makeAuth(typeRaw: Self.samlType)
        let stored = book(with: [deadLoanAcquisition()])
        let fromCatalog = book(with: [catalogBorrowAcquisition()])

        let handler = makeHandler(catalogEntryFetcher: { _ in fromCatalog })
        try driveFirstThenSecondFailure(on: handler, book: stored)
        let downloadsAfterSecond = spyDelegate.startedDownloads.count

        try driveNoActiveLoan(on: handler, book: stored)
        awaitCondition(timeout: 10) { [spyDelegate] in
            (spyDelegate?.startedDownloads.count ?? 0) > downloadsAfterSecond
        }

        XCTAssertEqual(spyDelegate.borrowedBooks.count, 1,
                       "the episode was consumed, so the next failure re-authenticates rather than borrowing again")
    }

    /// A failure one second inside the window is the same episode.
    func test_secondFailure_justInsideTheWindow_borrows() throws {
        userAccount._authDefinition = makeAuth(typeRaw: Self.samlType)
        let stored = book(with: [deadLoanAcquisition()])
        let fromCatalog = book(with: [catalogBorrowAcquisition()])

        let handler = makeHandler(catalogEntryFetcher: { _ in fromCatalog })
        try driveNoActiveLoan(on: handler, book: stored)
        awaitCondition(timeout: 10) { [spyDelegate] in
            !(spyDelegate?.startedDownloads.isEmpty ?? true)
        }

        clock.advance(by: 119)
        try driveNoActiveLoan(on: handler, book: stored)
        awaitCondition(timeout: 10) { [spyDelegate] in
            !(spyDelegate?.borrowedBooks.isEmpty ?? true)
        }

        XCTAssertEqual(
            spyDelegate.borrowedBooks.last?.defaultAcquisition?.hrefURL.absoluteString,
            Self.catalogBorrowHref
        )
    }

    /// A failure at exactly the window length is a new episode.
    ///
    /// Pins the boundary itself: the window is elapsed-time strictly less than
    /// its length, so the moment it is reached the next failure re-authenticates
    /// rather than borrowing.
    func test_secondFailure_exactlyAtTheWindow_isANewSessionExpiry() throws {
        userAccount._authDefinition = makeAuth(typeRaw: Self.samlType)
        let stored = book(with: [deadLoanAcquisition()])
        let fromCatalog = book(with: [catalogBorrowAcquisition()])

        let handler = makeHandler(catalogEntryFetcher: { _ in fromCatalog })
        try driveNoActiveLoan(on: handler, book: stored)
        awaitCondition(timeout: 10) { [spyDelegate] in
            !(spyDelegate?.startedDownloads.isEmpty ?? true)
        }
        let downloadsAfterFirst = spyDelegate.startedDownloads.count

        clock.advance(by: 120)
        try driveNoActiveLoan(on: handler, book: stored)
        awaitCondition(timeout: 10) { [spyDelegate] in
            (spyDelegate?.startedDownloads.count ?? 0) > downloadsAfterFirst
        }

        XCTAssertEqual(spyDelegate.borrowedBooks.count, 0,
                       "at the window's edge the episode is over, so this is a fresh session expiry")
    }

    // MARK: - The catalog read, on the second failure

    /// The re-read's link is used whatever its relation.
    ///
    /// By the second failure the server has said twice that there is no loan,
    /// so a borrow is what must happen and the response decides what it means.
    func test_secondFailure_whenTheEntryOffersAFulfillmentLink_stillBorrows() throws {
        userAccount._authDefinition = makeAuth(typeRaw: Self.samlType)
        let stored = book(with: [deadLoanAcquisition()])
        let freshFulfillment = book(with: [catalogFulfillmentAcquisition()])

        let handler = makeHandler(catalogEntryFetcher: { _ in freshFulfillment })
        try driveFirstThenSecondFailure(on: handler, book: stored)

        XCTAssertEqual(
            spyDelegate.borrowedBooks.last?.defaultAcquisition?.hrefURL.absoluteString,
            "https://example.org/loan/fulfill/10",
            "the re-read replaces the link that failed twice, whatever relation it carries"
        )
    }

    // MARK: - A declined sign-in

    /// A declined re-authentication retries nothing.
    ///
    /// Waits for the state transition the decline itself makes, so the absence
    /// below is read after the decision rather than before it.
    func test_whenTheCoordinatorDeclinesToRefresh_nothingIsRetried() throws {
        let (coordinator, _, modal, _, _) = SpyAuthCoordinatorFactory.make(
            mechanism: .saml, stubReauthResult: false, stubModalResult: false
        )
        userAccount._authDefinition = makeAuth(typeRaw: Self.samlType)
        let stored = book(with: [deadLoanAcquisition()])
        let fromCatalog = book(with: [catalogBorrowAcquisition()])

        let handler = makeHandler(catalogEntryFetcher: { _ in fromCatalog },
                                  authCoordinator: coordinator)
        try driveNoActiveLoan(on: handler, book: stored)
        awaitCondition(timeout: 10) { [registry] in
            registry?.state(for: stored.identifier) == .SAMLStarted
        }

        XCTAssertEqual(modal.presentCallCount, 1, "the coordinator must have been consulted")
        XCTAssertEqual(spyDelegate.borrowedBooks.count, 0,
                       "a patron who dismissed sign-in must not have a borrow made for them")
        XCTAssertEqual(spyDelegate.startedDownloads.count, 0,
                       "a declined refresh must not retry the download either")
    }

    /// A declined sign-in does not become a borrow on the next attempt.
    ///
    /// The episode is recorded where the retry is dispatched, so a patron who
    /// dismissed sign-in has no episode at all: their next failure takes the
    /// session-expiry branch again rather than the re-borrow. Recording it when
    /// the failure first arrived would have borrowed for them on this tap.
    ///
    /// The second pass is observed through the registry rather than the sign-in
    /// sheet: `AuthCoordinator` keeps its own real-time failure cooldown, so a
    /// declined refresh may answer the next request without presenting again.
    func test_afterADeclinedSignIn_aSecondFailureIsStillASessionExpiry() throws {
        let (coordinator, _, modal, _, _) = SpyAuthCoordinatorFactory.make(
            mechanism: .saml, stubReauthResult: false, stubModalResult: false
        )
        userAccount._authDefinition = makeAuth(typeRaw: Self.samlType)
        let stored = book(with: [deadLoanAcquisition()])
        let fromCatalog = book(with: [catalogBorrowAcquisition()])

        let handler = makeHandler(catalogEntryFetcher: { _ in fromCatalog },
                                  authCoordinator: coordinator)
        try driveNoActiveLoan(on: handler, book: stored)
        awaitCondition(timeout: 10) { [registry] in
            registry?.state(for: stored.identifier) == .SAMLStarted
        }
        XCTAssertEqual(modal.presentCallCount, 1, "the sign-in must have been offered and declined")

        // Moved off the state the session-expiry branch writes, so the second
        // pass returning to it is a positive signal that that branch ran and
        // the re-borrow branch — which writes `.unregistered` — did not.
        // `driveNoActiveLoan` would also move it off `.SAMLStarted` by re-adding
        // the book as `.downloading`; this is deliberate rather than redundant,
        // so the barrier does not depend on that side effect.
        registry.setState(.downloadNeeded, for: stored.identifier)

        // Well inside the window, so only the missing episode can keep this
        // from being read as a lapsed loan.
        clock.advance(by: 5)
        try driveNoActiveLoan(on: handler, book: stored)
        awaitCondition(timeout: 10) { [registry] in
            registry?.state(for: stored.identifier) == .SAMLStarted
        }

        XCTAssertEqual(spyDelegate.borrowedBooks.count, 0,
                       "a patron who dismissed sign-in must not have a borrow made on their next tap")
    }

    /// One book's dispatch does not discard another's open episode.
    ///
    /// Pruning lapsed entries runs on every dispatch, and the dispatching book
    /// re-records itself on the next line, so with a single book the filter's
    /// polarity cannot be observed at all. Inverted, it would drop other books'
    /// still-open episodes and their next failure would read as a first one —
    /// PP-5397 persisting for every book but the last one retried.
    func test_aDispatchForOneBookKeepsAnotherBooksOpenEpisode() throws {
        userAccount._authDefinition = makeAuth(typeRaw: Self.samlType)
        let first = book(with: [deadLoanAcquisition()], identifier: "pp5397-book-a")
        let second = book(with: [deadLoanAcquisition()], identifier: "pp5397-book-b")
        let fromCatalog = book(with: [catalogBorrowAcquisition()])

        let handler = makeHandler(catalogEntryFetcher: { _ in fromCatalog })

        // A's episode opens.
        try driveNoActiveLoan(on: handler, book: first)
        awaitCondition(timeout: 10) { [spyDelegate] in
            spyDelegate?.startedDownloads.contains { $0.identifier == first.identifier } == true
        }

        // B dispatches, which is what runs the prune while A's episode is open.
        try driveNoActiveLoan(on: handler, book: second)
        awaitCondition(timeout: 10) { [spyDelegate] in
            spyDelegate?.startedDownloads.contains { $0.identifier == second.identifier } == true
        }

        // A's second failure must still be read as the same episode.
        try driveNoActiveLoan(on: handler, book: first)
        awaitCondition(timeout: 10) { [spyDelegate] in
            !(spyDelegate?.borrowedBooks.isEmpty ?? true)
        }

        XCTAssertEqual(
            spyDelegate.borrowedBooks.map(\.identifier), [first.identifier],
            "B's dispatch discarded A's open episode, so A's second failure read as a first one"
        )
    }

    // MARK: - The hold guard, on the browser path too

    /// An unavailable entry plus a hold response still raises the PP-4178 alert.
    func test_unavailableEntryAndAHoldResponse_stillRaisesTheHoldAlert() throws {
        userAccount._authDefinition = makeAuth(typeRaw: Self.samlType)
        let stored = book(with: [deadLoanAcquisition()])
        let fromCatalog = book(with: [catalogBorrowAcquisition(availability: Self.copyTaken())])

        let handler = makeHandler(catalogEntryFetcher: { _ in fromCatalog })
        try driveFirstThenSecondFailure(on: handler, book: stored)

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
        try driveFirstThenSecondFailure(on: handler, book: stored)

        XCTAssertEqual(
            spyDelegate.borrowedBooks.last?.defaultAcquisition?.hrefURL.absoluteString,
            Self.catalogBorrowHref,
            "the borrow must be attempted whatever the entry says about copies"
        )
    }

    // MARK: - The barcode path is untouched

    /// A barcode patron borrows on the first failure, as before.
    ///
    /// Control for the browser tests above: this is the path an unresolved auth
    /// type silently falls down, so its distinct behaviour is worth pinning.
    func test_barcodePatron_borrowsOnTheFirstFailure() throws {
        userAccount._authDefinition = makeAuth(typeRaw: "http://opds-spec.org/auth/basic")
        let stored = book(with: [deadLoanAcquisition()])
        let fromCatalog = book(with: [catalogBorrowAcquisition()])

        let handler = makeHandler(catalogEntryFetcher: { _ in fromCatalog })
        try driveNoActiveLoan(on: handler, book: stored)
        awaitCondition(timeout: 10) { [spyDelegate] in
            !(spyDelegate?.borrowedBooks.isEmpty ?? true)
        }

        XCTAssertEqual(
            spyDelegate.borrowedBooks.last?.defaultAcquisition?.hrefURL.absoluteString,
            Self.catalogBorrowHref
        )
        XCTAssertEqual(userAccount.authState, .loggedIn,
                       "the barcode path does not mark credentials stale")
    }
}
