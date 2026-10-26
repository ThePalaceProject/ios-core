//
//  BorrowFailurePublishesErrorTests.swift
//  PalaceTests
//
//  A borrow failure has to reach `downloadErrorPublisher`: that is the only
//  signal `BookDetailViewModel` uses to resync the half-sheet out of the
//  optimistic `.downloading` state `startDownloadAfterAuth` writes before the
//  request runs (PP-5407).
//

import XCTest
import PalaceCatalog
import PalaceBookModel
@testable import Palace

@MainActor
final class BorrowFailurePublishesErrorTests: XCTestCase {

    private var bookRegistry: TPPBookRegistryMock!
    private var userAccount: TPPUserAccountMock!
    private var operation: BorrowOperation!
    private var book: TPPBook!

    /// Whole `DownloadErrorInfo` values, not just a title: the book id and the
    /// kind are what the subscribers filter on, so a publish with either wrong
    /// never reaches the sheet.
    private let publishedBox = LockIsolated<[DownloadErrorInfo]>([])
    private var published: [DownloadErrorInfo] { publishedBox.value }

    private let fetchError = LockIsolated<Error?>(nil)

    override func setUpWithError() throws {
        try super.setUpWithError()
        BorrowOperation.clearAllBorrowReauthState()

        bookRegistry = TPPBookRegistryMock()
        userAccount = TPPUserAccountMock()
        book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        publishedBox.value = []
        fetchError.value = nil

        let publishedBox = publishedBox
        let fetchError = fetchError
        operation = BorrowOperation(
            bookRegistry: bookRegistry,
            downloadAnnouncementService: BorrowFailureSilentAnnouncer(),
            errorActivityTracker: .shared,
            debugSettings: DebugSettings(),
            userRetryTracker: UserRetryTracker(),
            userAccountProvider: { [unowned self] in self.userAccount },
            adobeDRMService: AdobeDRMService.shared,
            fetchBook: { _, _, _ in
                if let error = fetchError.value { throw error }
                throw PalaceError.network(.serverError)
            },
            presentBorrowErrorAlert: { _, _, _, _, _, _ in },
            publishBorrowError: { errorInfo in
                publishedBox.withValue { $0.append(errorInfo) }
            },
            presentSignInModal: { _ in },
            attemptOIDCReauth: { false }
        )
    }

    override func tearDownWithError() throws {
        BorrowOperation.clearAllBorrowReauthState()
        bookRegistry = nil
        userAccount = nil
        operation = nil
        book = nil
        try super.tearDownWithError()
    }

    /// The registry is never told about a failed borrow, so `bookStatePublisher`
    /// stays silent. The published error is what tells the half-sheet the
    /// optimistic `.downloading` it is rendering is no longer true.
    func testBorrowFailure_publishesABorrowKindErrorForThatBook() async {
        fetchError.value = PalaceError.network(.serverError)

        do {
            _ = try await operation.borrowAsync(book, attemptDownload: true)
            XCTFail("A 500 from the borrow fetch must throw")
        } catch {
            // Expected — the publish is the assertion below.
        }

        XCTAssertEqual(published.count, 1,
                       "A borrow failure must reach downloadErrorPublisher exactly once")
        XCTAssertEqual(published.first?.bookId, book.identifier,
                       "Both subscribers filter on bookId; a publish for another book is dropped")
        XCTAssertEqual(published.first?.kind, .borrow,
                       "BookDetailViewModel admits a .borrow error while .get is still processing; a .download kind is filtered out")
        XCTAssertEqual(bookRegistry.state(for: book.identifier), .unregistered,
                       "The registry is untouched by a failed borrow, which is why the publish is the only recovery signal")
        XCTAssertEqual(published.first?.presentsAlert, false,
                       "The borrow path presents its own alert; a second one from a subscriber would stack on it")
    }

    /// A timeout is retryable. The alert the patron sees takes its Retry button
    /// from `presentBorrowErrorAlert`, not from here, so this pins the payload
    /// the publish carries for any subscriber that later presents it itself —
    /// today both skip it on `presentsAlert: false`.
    func testRetryableBorrowFailure_publishesARetryAction() async {
        fetchError.value = PalaceError.network(.timeout)

        do {
            _ = try await operation.borrowAsync(book, attemptDownload: true)
            XCTFail("A timeout from the borrow fetch must throw")
        } catch {
            // Expected.
        }

        XCTAssertEqual(published.count, 1)
        XCTAssertNotNil(published.first?.retryAction,
                        "A retryable borrow failure must publish the retry closure the alert's Retry button invokes")
    }

    /// The borrow never started, so nothing should be reported.
    func testBorrowSuccess_publishesNothing() async throws {
        fetchError.value = nil
        let succeedingOperation = makeOperationReturning(book)

        _ = try await succeedingOperation.borrowAsync(book, attemptDownload: false)

        XCTAssertTrue(published.isEmpty,
                      "A successful borrow must not publish an error — the sheet would show an alert over a borrowed book")
    }

    private func makeOperationReturning(_ borrowed: TPPBook) -> BorrowOperation {
        let publishedBox = publishedBox
        let box = UncheckedBookBox(borrowed)
        return BorrowOperation(
            bookRegistry: bookRegistry,
            downloadAnnouncementService: BorrowFailureSilentAnnouncer(),
            errorActivityTracker: .shared,
            debugSettings: DebugSettings(),
            userRetryTracker: UserRetryTracker(),
            userAccountProvider: { [unowned self] in self.userAccount },
            adobeDRMService: AdobeDRMService.shared,
            fetchBook: { _, _, _ in box.book },
            presentBorrowErrorAlert: { _, _, _, _, _, _ in },
            publishBorrowError: { errorInfo in
                publishedBox.withValue { $0.append(errorInfo) }
            },
            presentSignInModal: { _ in },
            attemptOIDCReauth: { false }
        )
    }

    /// `TPPBook` is not `Sendable`; the fetch closure is non-isolated, so the
    /// book rides in a read-only box the way `BorrowOperation`'s own carrier
    /// boxes do.
    private final class UncheckedBookBox: @unchecked Sendable {
        let book: TPPBook
        init(_ book: TPPBook) { self.book = book }
    }
}

/// Keeps the VoiceOver announcer out of the test run; the publish, not the
/// announcement, is what these tests pin.
private final class BorrowFailureSilentAnnouncer: DownloadAnnouncementService {
    override func announceBorrowStarted(for book: TPPBook) {}
    override func announceBorrowSucceeded(for book: TPPBook) {}
    override func announceBorrowFailed(for book: TPPBook) {}
}
