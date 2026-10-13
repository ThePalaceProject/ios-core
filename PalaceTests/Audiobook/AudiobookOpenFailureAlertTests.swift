//
//  AudiobookOpenFailureAlertTests.swift
//  PalaceTests
//
//  Pins the audiobook open-failure alert: the non-fatal it files (fixed domain
//  and code, PP-5242), the bounded Retry (PP-3707), and the session manager
//  call site that hands it a loader failure.
//

import XCTest
import PalaceCatalog
@preconcurrency import PalaceAudiobookToolkit
@testable import Palace
import PalaceBookModel

@MainActor
final class AudiobookOpenFailureAlertTests: XCTestCase {

    private var logger: ErrorLoggerSpy!
    private var tracker: UserRetryTracker!
    private var presented: [UIAlertController] = []
    private var reopened: [String] = []
    private var book: TPPBook!

    override func setUp() {
        super.setUp()
        logger = ErrorLoggerSpy()
        tracker = UserRetryTracker()
        presented = []
        reopened = []
        book = TPPBookMocker.mockBook(identifier: "open-failure-book", title: "Fixture", distributorType: .OpenAccessAudiobook)
    }

    override func tearDown() {
        logger = nil
        tracker = nil
        presented = []
        reopened = []
        book = nil
        super.tearDown()
    }

    private func makeSUT() -> AudiobookOpenFailureAlert {
        AudiobookOpenFailureAlert(
            errorLogger: logger,
            retryTracker: tracker,
            present: { [unowned self] in self.presented.append($0) },
            reopen: { [unowned self] in self.reopened.append($0.identifier) }
        )
    }

    private func tap(_ title: String, in alert: UIAlertController?) {
        typealias Handler = @convention(block) (UIAlertAction) -> Void
        guard let action = alert?.actions.first(where: { $0.title == title }),
              let block = action.value(forKey: "handler") else {
            return XCTFail("no tappable '\(title)' action in \(String(describing: alert?.actions.map(\.title)))")
        }
        unsafeBitCast(block as AnyObject, to: Handler.self)(action)
    }

    /// The Crashlytics issue groups on this domain and code; the cause rides in metadata.
    func testShow_LogsFixedDomainAndCodeWithFailureMetadata() throws {
        makeSUT().show(book: book, failureMetadata: ["loadError": "manifestFetchFailed"])

        XCTAssertEqual(logger.loggedSummaries, ["Audiobook failed to open - showing try again error"])
        XCTAssertEqual(logger.loggedCodes, [.ignore], "reported through the error overload, not a TPPErrorCode bucket")
        let error = try XCTUnwrap(logger.firstReportedNSError)
        XCTAssertEqual(error.domain, "AudiobookOpenError")
        XCTAssertEqual(error.code, TPPErrorCode.audiobookCorrupted.rawValue)
        XCTAssertEqual(error.localizedDescription, "Failed to open audiobook")
        XCTAssertEqual(error.userInfo["error_type"] as? String, "audiobook_open_failure")
        let metadata = try XCTUnwrap(logger.loggedMetadata.first)
        XCTAssertEqual(metadata["loadError"] as? String, "manifestFetchFailed")
        XCTAssertEqual(metadata["user_message"] as? String, Strings.Error.tryAgain)
    }

    /// A caller-supplied `user_message` must not replace the message the patron saw.
    func testShow_FailureMetadataCannotOverrideUserMessage() {
        makeSUT().show(book: book, failureMetadata: ["user_message": "caller value"])

        XCTAssertEqual(logger.loggedMetadata.first?["user_message"] as? String, Strings.Error.tryAgain)
    }

    func testShow_WithRetryBudget_PresentsRetryAndCancel() {
        makeSUT().show(book: book)

        XCTAssertEqual(presented.count, 1)
        let alert = presented.first
        XCTAssertEqual(alert?.title, Strings.Error.openFailedError)
        XCTAssertEqual(alert?.message, Strings.Error.tryAgain)
        XCTAssertEqual(alert?.actions.map(\.title), [Strings.MyDownloadCenter.retry, Strings.Generic.cancel])
        XCTAssertEqual(alert?.actions.map(\.style), [.default, .cancel])
        XCTAssertEqual(reopened, [], "showing the alert must not reopen the book")
    }

    func testRetry_ReopensTheSameBook() {
        makeSUT().show(book: book)

        tap(Strings.MyDownloadCenter.retry, in: presented.first)

        XCTAssertEqual(reopened, [book.identifier])
    }

    /// Each Retry spends one of the book's five attempts; the sixth failure offers none.
    func testRetry_SpendsTheBudget_SixthFailureOffersNoRetry() {
        let sut = makeSUT()
        for attempt in 1...5 {
            sut.show(book: book)
            tap(Strings.MyDownloadCenter.retry, in: presented.last)
            XCTAssertEqual(reopened.count, attempt)
        }

        sut.show(book: book)

        XCTAssertEqual(presented.last?.actions.map(\.title), ["OK"], "a spent budget offers only OK")
        XCTAssertEqual(presented.last?.title, Strings.Error.openFailedError)
        XCTAssertEqual(presented.last?.message, Strings.MyDownloadCenter.tryAgainLater)
        XCTAssertEqual(reopened.count, 5)
    }

    /// The budget is keyed per book, so another book's spent budget does not gate this one.
    func testShow_BudgetIsKeyedByBookIdentifier() {
        for _ in 0..<5 { tracker.recordRetry(operationId: "audiobook-open-\(book.identifier)") }
        let otherBook = TPPBookMocker.mockBook(identifier: "other-book", title: "Other", distributorType: .OpenAccessAudiobook)

        makeSUT().show(book: otherBook)
        makeSUT().show(book: book)

        XCTAssertEqual(presented.first?.actions.map(\.title), [Strings.MyDownloadCenter.retry, Strings.Generic.cancel])
        XCTAssertEqual(presented.last?.actions.map(\.title), ["OK"])
    }
}

// MARK: - Session manager call site

/// Fails every manifest resolve at once with the error it was built with.
private final class FailingAudiobookVendorAdapter: AudiobookVendorAdapter {
    private let error: AudiobookLoadError
    init(_ error: AudiobookLoadError) { self.error = error }
    func canHandle(_ book: TPPBook) -> Bool { true }
    func resolveManifest(for book: TPPBook) async -> Result<(json: [String: Any], decryptor: DRMDecryptor?), AudiobookLoadError> {
        .failure(error)
    }
}

/// A loader failure reaches the open-failure alert with the book and the cause;
/// a cancelled load does not, so a superseded open flashes nothing.
@MainActor
final class AudiobookSessionManagerOpenFailureAlertTests: PalaceWiringTestCase {

    private var registry: TPPBookRegistryMock!
    private var accountsManager: AccountsManager!
    private var removeSeededAccount: (() -> Void)?
    private var alerts: [(bookId: String, metadata: [String: Any])] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        let defaults = Self.testUserDefaults()
        accountsManager = makeFreshAccountsManager(defaults: defaults)
        let seeded = seedAccountIfNeeded(on: accountsManager, fixtureId: "open-failure-\(UUID().uuidString)")
        removeSeededAccount = seeded.1
        // A library with no authentication methods, so the open's sign-in check
        // passes without reading the keychain.
        let doc = try OPDS2AuthenticationDocument.fromData(
            JSONSerialization.data(withJSONObject: ["id": seeded.0.uuid, "title": "No Auth"]))
        seeded.0._setState(.detailsLoaded(AccountDetails(authenticationDocument: doc, uuid: seeded.0.uuid, defaults: defaults)))
        registry = TPPBookRegistryMock()
        alerts = []
    }

    override func tearDownWithError() throws {
        removeSeededAccount?()
        removeSeededAccount = nil
        accountsManager = nil
        registry = nil
        alerts = []
        try super.tearDownWithError()
    }

    private func makeSUT(failingWith error: AudiobookLoadError) -> AudiobookSessionManager {
        AudiobookSessionManager(
            appContainer: makeTestAppContainer(accountsManager: accountsManager, bookRegistry: registry),
            inAppPlaybackNavEnabledProvider: { false },
            showOpenFailureAlert: { [unowned self] book, metadata in
                self.alerts.append((book.identifier, metadata))
            },
            makeLoader: { _ in
                let userAccount = TPPUserAccountMock()
                return AudiobookLoader(adapters: [FailingAudiobookVendorAdapter(error)], currentUserAccount: { userAccount })
            }
        )
    }

    private func downloadedBook() -> TPPBook {
        let book = TPPBookMocker.mockBook(identifier: "failing-book", title: "Failing", distributorType: .OpenAccessAudiobook)
        registry.addBook(book, state: .downloadSuccessful)
        return book
    }

    func testLoaderFailure_ShowsAlertWithBookAndCause() async {
        let sut = makeSUT(failingWith: .manifestFetchFailed)

        let result = await sut.openAudiobook(downloadedBook(), startPlaying: false)

        guard case .failure(.manifestLoadFailed) = result else {
            return XCTFail("expected .manifestLoadFailed, got \(result)")
        }
        XCTAssertEqual(alerts.map(\.bookId), ["failing-book"])
        XCTAssertEqual(alerts.first?.metadata["loadError"] as? String, "manifestFetchFailed")
        XCTAssertNotNil(alerts.first?.metadata["contentSource"], "the content source rides with the cause (PP-5242)")
    }

    func testCancelledLoad_ShowsNoAlert() async {
        let sut = makeSUT(failingWith: .cancelled)

        _ = await sut.openAudiobook(downloadedBook(), startPlaying: false)

        XCTAssertTrue(alerts.isEmpty, "a cancelled load must not show the open-failure alert")
    }
}
