//
//  BookDetailBorrowFailureRecoveryTests.swift
//  PalaceTests
//
//  The book detail half-sheet shows Cancel as soon as Borrow is tapped, before
//  the request runs. A borrow that fails never touches the registry, so the two
//  ways out of that optimistic state are the published borrow error and the
//  Cancel button itself. Both are pinned here (PP-5407).
//

import XCTest
import PalaceCatalog
import PalaceBookModel
import PalacePreferences
@testable import Palace

@MainActor
final class BookDetailBorrowFailureRecoveryTests: XCTestCase {

    private var appContainer: AppContainer!
    private var registry: TPPBookRegistryMock!

    override func setUp() {
        super.setUp()
        appContainer = makeTestAppContainer()
        registry = TPPBookRegistryMock()
    }

    override func tearDown() {
        registry = nil
        appContainer = nil
        super.tearDown()
    }

    private func makeViewModel(for book: TPPBook) -> BookDetailViewModel {
        BookDetailViewModel(
            book: book,
            registry: registry,
            downloadCenter: appContainer.downloadCenter,
            accountsManager: appContainer.accountsManager,
            settings: TPPSettings(),
            opdsFeedService: appContainer.opdsFeedService,
            samplePreviewManager: appContainer.samplePreviewManager,
            readerService: appContainer.readerService,
            metadataHydrator: { _ in nil }
        )
    }

    /// Reproduces the state the sheet is in between the Borrow tap and the
    /// failure: `startDownloadAfterAuth` has written `.downloading` and `.get`
    /// is still in `processingButtons`, which is what pins the button set to
    /// Cancel only.
    private func putInOptimisticBorrowState(_ viewModel: BookDetailViewModel) {
        viewModel.bookState = .downloading
        viewModel.processingButtons.insert(.get)
        viewModel.showHalfSheet = true
        viewModel.downloadProgress = 0
    }

    // MARK: - Published borrow error

    func testPublishedBorrowError_resyncsTheSheetOutOfTheOptimisticDownloadingState() async {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        let viewModel = makeViewModel(for: book)
        putInOptimisticBorrowState(viewModel)

        appContainer.downloadCenter.progressReporter.publishAndAnnounceError(
            DownloadErrorInfo(
                bookId: book.identifier,
                title: "Borrow Failed",
                message: "Borrowing could not be completed.",
                kind: .borrow
            )
        )

        // The sink sets the alert and resyncs the sheet in one body, so waiting
        // on the alert joins both.
        await awaitConditionAsync { viewModel.downloadErrorAlert != nil }

        XCTAssertEqual(viewModel.bookState, .unregistered,
                       "The sheet must take the registry's answer once the borrow has failed")
        XCTAssertFalse(viewModel.processingButtons.contains(.get),
                       "A .get left in processingButtons keeps BookButtonMapper on Cancel only")
        XCTAssertNotNil(viewModel.downloadErrorAlert,
                        "The patron must be told why the borrow failed")
        XCTAssertTrue(viewModel.showHalfSheet,
                      "The ticket's outcome is a sheet that recovers onto Get, not one that vanishes. It also hosts the alert: the UIKit alert resolves to the top view controller, so tearing the sheet down here would take its presenter with it and tell the patron nothing.")
    }

    func testPublishedBorrowErrorForAnotherBook_leavesThisSheetAlone() async {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        let other = TPPBookMocker.mockBook(distributorType: .EpubZip)
        let viewModel = makeViewModel(for: book)
        putInOptimisticBorrowState(viewModel)

        appContainer.downloadCenter.progressReporter.publishAndAnnounceError(
            DownloadErrorInfo(
                bookId: other.identifier,
                title: "Borrow Failed",
                message: "Borrowing could not be completed.",
                kind: .borrow
            )
        )

        await drainMainQueueAsync()
        await Task.yield()
        await drainMainQueueAsync()

        XCTAssertEqual(viewModel.bookState, .downloading,
                       "Another book's borrow failure must not tear down this sheet")
        XCTAssertNil(viewModel.downloadErrorAlert,
                     "Another book's borrow failure must not alert here")
    }

    /// End to end over the chain the defect broke: a real `BorrowOperation`
    /// reporting through the same publisher call `MyBooksDownloadCenter` uses,
    /// and a real view model subscribed to that download centre. The
    /// registry is never told about a failed borrow, so if the operation does
    /// not publish, nothing in this chain can clear the sheet.
    func testBorrowOperationFailure_recoversTheSheetThroughTheDownloadCentre() async {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        let viewModel = makeViewModel(for: book)
        putInOptimisticBorrowState(viewModel)

        let reporter = appContainer.downloadCenter.progressReporter
        let operation = BorrowOperation(
            bookRegistry: registry,
            downloadAnnouncementService: BorrowFailureRecoverySilentAnnouncer(),
            errorActivityTracker: .shared,
            debugSettings: DebugSettings(),
            userRetryTracker: UserRetryTracker(),
            userAccountProvider: { TPPUserAccountMock() },
            adobeDRMService: AdobeDRMService.shared,
            fetchBook: { _, _, _ in throw PalaceError.network(.serverError) },
            presentBorrowErrorAlert: { _, _, _, _, _, _ in },
            // `send`, as MyBooksDownloadCenter wires it — NOT
            // `publishAndAnnounceError`. Wiring the announcing variant here
            // modelled the pre-fix shape and let the duplicate announcement
            // return without failing anything.
            publishBorrowError: { errorInfo in reporter.downloadErrorPublisher.send(errorInfo) },
            presentSignInModal: { _ in },
            attemptOIDCReauth: { false }
        )

        do {
            _ = try await operation.borrowAsync(book, attemptDownload: true)
            XCTFail("A 500 from the borrow fetch must throw")
        } catch {
            // Expected — the recovery below is the assertion.
        }

        await awaitConditionAsync { !viewModel.processingButtons.contains(.get) }

        XCTAssertEqual(viewModel.bookState, .unregistered,
                       "A failed borrow must leave the sheet on the registry's answer, not the optimistic .downloading")
        XCTAssertFalse(viewModel.processingButtons.contains(.get),
                       "The half-sheet stays pinned to Cancel while .get is still processing")
        XCTAssertNil(viewModel.downloadErrorAlert,
                     "The borrow path presents its own alert, so the sheet must not raise a second one")
    }

    /// The producer-already-alerted case. `BorrowOperation` presents
    /// `TPPAlertUtils.alertWithDetails`, which carries "View Error Details"
    /// (PP-3439); the SwiftUI `Alert` the sheet builds takes two buttons and a
    /// retryable borrow failure uses both, so it cannot offer that. The sheet
    /// must still resync, and must not stack a second dialog on the first.
    func testPublishedBorrowError_markedAsAlreadyPresented_resyncsWithoutASecondAlert() async {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        let viewModel = makeViewModel(for: book)
        putInOptimisticBorrowState(viewModel)

        appContainer.downloadCenter.progressReporter.publishAndAnnounceError(
            DownloadErrorInfo(
                bookId: book.identifier,
                title: "Borrow Failed",
                message: "Borrowing could not be completed.",
                kind: .borrow,
                retryAction: nil,
                presentsAlert: false
            )
        )

        await awaitConditionAsync { !viewModel.processingButtons.contains(.get) }

        XCTAssertEqual(viewModel.bookState, .unregistered,
                       "The resync must run whether or not this error raises its own alert")
        XCTAssertFalse(viewModel.processingButtons.contains(.get),
                       "A .get left in processingButtons keeps BookButtonMapper on Cancel only")
        XCTAssertNil(viewModel.downloadErrorAlert,
                     "Two alerts for one failure: the patron dismisses one and finds another behind it")
    }

    /// PP-4178: when the circulation manager answers a Borrow with a hold, the
    /// operation registers the hold and only then throws. The reducer has
    /// already cleared `.get` and moved the sheet to `.holding` by the time the
    /// borrow error arrives, so a filter keyed only on `.get`/`.unregistered`
    /// drops the one message that explains what happened.
    func testPublishedBorrowError_whileTheBookIsOnHold_stillReachesTheSheet() async {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        let viewModel = makeViewModel(for: book)
        viewModel.bookState = .holding
        viewModel.processingButtons = []
        viewModel.showHalfSheet = true

        appContainer.downloadCenter.progressReporter.publishAndAnnounceError(
            DownloadErrorInfo(
                bookId: book.identifier,
                title: "Borrow Failed",
                message: "This title isn't ready for checkout yet.",
                kind: .borrow
            )
        )

        await awaitConditionAsync { viewModel.downloadErrorAlert != nil }

        XCTAssertNotNil(viewModel.downloadErrorAlert,
                        "A Loan→Hold race must still tell the patron why their Borrow became a hold")
    }

    /// The ordinary case the half-sheet reaches once the spinner has already
    /// been released: nothing is processing and the registry reports no loan.
    /// A borrow error for that book is still this patron's, and is the only
    /// explanation they get.
    func testPublishedBorrowError_whenNothingIsProcessingAndTheBookIsUnregistered_reachesTheSheet() async {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        let viewModel = makeViewModel(for: book)
        viewModel.bookState = .unregistered
        viewModel.processingButtons = []

        appContainer.downloadCenter.progressReporter.publishAndAnnounceError(
            DownloadErrorInfo(
                bookId: book.identifier,
                title: "Borrow Failed",
                message: "Borrowing could not be completed.",
                kind: .borrow
            )
        )

        await awaitConditionAsync { viewModel.downloadErrorAlert != nil }

        XCTAssertNotNil(viewModel.downloadErrorAlert,
                        "A borrow failure on an unborrowed book must alert even after the spinner cleared")
    }

    /// The filter still has to be able to say no: a borrow error for a book the
    /// patron has already downloaded is stale and must not interrupt them.
    func testPublishedBorrowError_whileTheBookIsDownloaded_isFilteredOut() async {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        let viewModel = makeViewModel(for: book)
        viewModel.bookState = .downloadSuccessful
        viewModel.processingButtons = []

        appContainer.downloadCenter.progressReporter.publishAndAnnounceError(
            DownloadErrorInfo(
                bookId: book.identifier,
                title: "Borrow Failed",
                message: "Borrowing could not be completed.",
                kind: .borrow
            )
        )

        await drainMainQueueAsync()
        await Task.yield()
        await drainMainQueueAsync()

        XCTAssertNil(viewModel.downloadErrorAlert,
                     "A stale borrow error must not alert over a book the patron already has")
    }

    // MARK: - Cancel

    func testCancel_whenNothingIsInFlight_clearsTheOptimisticStateAndClosesTheSheet() {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        let viewModel = makeViewModel(for: book)
        putInOptimisticBorrowState(viewModel)
        XCTAssertEqual(registry.state(for: book.identifier), .unregistered,
                       "precondition: a failed borrow leaves the registry untouched")

        viewModel.didSelectCancel()

        XCTAssertEqual(viewModel.bookState, .unregistered,
                       "Cancel must resolve the optimistic .downloading against the registry")
        XCTAssertFalse(viewModel.processingButtons.contains(.get),
                       "Cancel must release the acquire spinner so Borrow is tappable again")
        XCTAssertFalse(viewModel.showHalfSheet,
                       "With no loan and nothing downloading the sheet has nothing left to show")
    }

    /// Pins the view model's own read of the processing flag, which no reducer
    /// test can reach: the reducer is pure and never touches a registry, so
    /// replacing the argument at the call site with a literal `false` leaves
    /// every reducer test green while the race returns.
    func testCancel_whileTheBorrowIsStillInFlight_leavesTheSheetOnCancel() {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        let viewModel = makeViewModel(for: book)
        putInOptimisticBorrowState(viewModel)
        // What a borrow in flight looks like: the registry has not heard about
        // the loan yet, but it is processing the request.
        registry.setProcessing(true, for: book.identifier)
        XCTAssertEqual(registry.state(for: book.identifier), .unregistered,
                       "precondition: the registry learns of the loan only when the request returns")

        viewModel.didSelectCancel()

        XCTAssertTrue(viewModel.showHalfSheet,
                      "The request is still running, so Cancel must not close the sheet out from under it")
        XCTAssertTrue(viewModel.processingButtons.contains(.get),
                      "Releasing the acquire spinner re-arms Get, letting a second borrow race the one in flight")
    }

    func testCancel_duringALiveDownload_keepsTheSheetOpen() {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        registry.addBook(book, location: nil, state: .downloading,
                         fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)
        let viewModel = makeViewModel(for: book)
        viewModel.showHalfSheet = true
        viewModel.downloadProgress = 0.4

        viewModel.didSelectCancel()

        XCTAssertTrue(viewModel.showHalfSheet,
                      "Cancelling a running download must leave the sheet up to show the outcome")
        XCTAssertEqual(viewModel.downloadProgress, 0.0, accuracy: 0.0001,
                       "The bar resets so a resumed download does not inherit the old fill")
    }
}

/// Keeps the VoiceOver announcer out of the test run.
private final class BorrowFailureRecoverySilentAnnouncer: DownloadAnnouncementService {
    override func announceBorrowStarted(for book: TPPBook) {}
    override func announceBorrowSucceeded(for book: TPPBook) {}
    override func announceBorrowFailed(for book: TPPBook) {}
}
