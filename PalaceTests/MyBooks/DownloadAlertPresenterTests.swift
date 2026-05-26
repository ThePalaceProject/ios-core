//
//  DownloadAlertPresenterTests.swift
//  PalaceTests
//
//  Coverage for the failure-path alert publisher extracted into
//  DownloadAlertPresenter. Asserts on the DownloadErrorInfo published
//  via the shared progress reporter, registry mutation,
//  announceDownloadFailed invocation, and the no-active-loan
//  remove-from-registry branch in alertForProblemDocument.
//

import XCTest
import Combine
import PalaceCatalog
@testable import Palace

@MainActor
final class DownloadAlertPresenterTests: XCTestCase {

    private var registry: TPPBookRegistryMock!
    private var stateManager: DownloadStateManager!
    private var reporter: DownloadProgressReporter!
    private var announcer: SpyAnnouncementService!
    private var spyDelegate: SpyDelegate!
    private var presenter: DownloadAlertPresenter!
    private var book: TPPBook!
    private var capturedErrors: [DownloadErrorInfo] = []
    private var subscription: AnyCancellable?

    override func setUpWithError() throws {
        try super.setUpWithError()
        registry = TPPBookRegistryMock()
        stateManager = DownloadStateManager()
        announcer = SpyAnnouncementService()
        reporter = DownloadProgressReporter(
            accessibilityAnnouncements: TPPAccessibilityAnnouncementCenter(),
            downloadAnnouncementService: announcer
        )
        spyDelegate = SpyDelegate()

        capturedErrors = []
        subscription = reporter.downloadErrorPublisher.sink { [weak self] info in
            self?.capturedErrors.append(info)
        }

        presenter = DownloadAlertPresenter(
            bookRegistry: registry,
            stateManager: stateManager,
            progressReporter: reporter,
            downloadAnnouncementService: announcer
        )
        presenter.delegate = spyDelegate

        book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        registry.addBook(book, location: nil, state: .downloading,
                         fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)
    }

    override func tearDownWithError() throws {
        subscription?.cancel()
        subscription = nil
        registry = nil
        stateManager = nil
        reporter = nil
        announcer = nil
        spyDelegate = nil
        presenter = nil
        book = nil
        capturedErrors = []
        try super.tearDownWithError()
    }

    private func makeProblemDoc(type: String? = nil, detail: String? = nil) throws -> TPPProblemDocument {
        var dict: [String: Any] = [:]
        if let type { dict["type"] = type }
        if let detail { dict["detail"] = detail }
        if dict.isEmpty { dict["title"] = "x" }
        let data = try JSONSerialization.data(withJSONObject: dict)
        return try XCTUnwrap(TPPProblemDocument.fromProblemResponseData(data))
    }

    private func waitForPublishedError(timeout: TimeInterval = 1.0) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !capturedErrors.isEmpty { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
            await Task.yield()
        }
    }

    // MARK: - failDownloadWithAlert

    func testFailDownloadWithAlert_setsDownloadFailedAndAnnouncesAndPublishesError() async throws {
        presenter.failDownloadWithAlert(for: book, withMessage: "boom")
        await waitForPublishedError()

        XCTAssertEqual(registry.state(for: book.identifier), .downloadFailed,
                       "fail path must flip the registry state to .downloadFailed")
        XCTAssertEqual(announcer.failedDownloadCalls, [book.identifier],
                       "fail path must announce the failure")
        XCTAssertEqual(capturedErrors.count, 1, "fail path must publish exactly one error")
        let info = try XCTUnwrap(capturedErrors.first)
        XCTAssertEqual(info.bookId, book.identifier)
        XCTAssertEqual(info.kind, .download)
        XCTAssertTrue(info.message.contains("boom"),
                      "Caller-supplied message must reach the published alert")
    }

    func testFailDownloadWithAlert_retryAction_invokesStartDownloadOnce() async throws {
        presenter.failDownloadWithAlert(for: book)
        await waitForPublishedError()
        let info = try XCTUnwrap(capturedErrors.first)
        let retry = try XCTUnwrap(info.retryAction, "Retryable while userRetryTracker has budget")

        retry()

        XCTAssertEqual(spyDelegate.startDownloadCalls.map { $0.identifier }, [book.identifier],
                       "Retry tap routes through the delegate's startDownload")
    }

    // MARK: - placeholder regression (Cinema-beyond-the-human bug, 3.1.0)

    /// Most callers of `failDownloadWithAlert` pass `nil` as the message
    /// (see `DownloadTaskLifecycleService.handleTaskCompletionError`,
    /// `OverdriveDownloadHandler`, `RightsManagementDispatcher`,
    /// `AdobeDRMHandler`). Previously that nil was coalesced to the
    /// placeholder string "No error message" and shipped to production.
    /// The alert must never show that placeholder.
    func testFailDownloadWithAlert_nilMessage_doesNotShowDeveloperPlaceholder() async throws {
        presenter.failDownloadWithAlert(for: book, withMessage: nil)
        await waitForPublishedError()

        let info = try XCTUnwrap(capturedErrors.first)
        XCTAssertFalse(info.message.contains("No error message"),
                       "Developer placeholder \"No error message\" must never reach the user-facing alert")
        XCTAssertFalse(info.message.lowercased().contains("nil"),
                       "Raw \"nil\" must never reach the user-facing alert")
    }

    /// When the caller has no specific failure reason (`nil` message),
    /// the alert must still give the user an actionable hint. The
    /// connectivity-style fallback is what we ship for unknown failures
    /// from background URLSession completions, Adobe/Overdrive failures,
    /// etc. — all of which can be transient.
    func testFailDownloadWithAlert_nilMessage_includesActionableFallback() async throws {
        presenter.failDownloadWithAlert(for: book, withMessage: nil)
        await waitForPublishedError()

        let info = try XCTUnwrap(capturedErrors.first)
        XCTAssertTrue(info.message.contains(Strings.MyDownloadCenter.downloadFailedUnknownReason),
                      "When no specific reason is available, the alert must surface the actionable fallback string")
    }

    /// Empty-string messages (a caller-bug variant of nil) must be
    /// treated identically — both bypass the `??` coalescing and would
    /// produce a useless trailing newline + nothing in the old code.
    func testFailDownloadWithAlert_emptyMessage_alsoFallsBackToActionableText() async throws {
        presenter.failDownloadWithAlert(for: book, withMessage: "")
        await waitForPublishedError()

        let info = try XCTUnwrap(capturedErrors.first)
        XCTAssertFalse(info.message.contains("No error message"))
        XCTAssertTrue(info.message.contains(Strings.MyDownloadCenter.downloadFailedUnknownReason),
                      "Empty-string messages must hit the same actionable fallback as nil")
    }

    // MARK: - alertForProblemDocument

    func testAlertForProblemDocument_noActiveLoan_removesFromRegistryAndDisablesRetry() async throws {
        let problemDoc = try makeProblemDoc(type: TPPProblemDocument.TypeNoActiveLoan)
        presenter.alertForProblemDocument(problemDoc, error: nil, book: book)
        await waitForPublishedError()

        XCTAssertNil(registry.book(forIdentifier: book.identifier),
                     "no-active-loan must remove the book from the registry")
        let info = try XCTUnwrap(capturedErrors.first)
        XCTAssertNil(info.retryAction,
                     "no-active-loan failures are NOT retryable — the loan is gone server-side")
    }

    func testAlertForProblemDocument_genericProblem_keepsBookInRegistryAndAllowsRetry() async throws {
        let problemDoc = try makeProblemDoc(type: "https://example.com/other-error",
                                            detail: "Server is having a moment")
        presenter.alertForProblemDocument(problemDoc, error: nil, book: book)
        await waitForPublishedError()

        XCTAssertNotNil(registry.book(forIdentifier: book.identifier),
                       "Generic problem-doc errors keep the book in the registry")
        let info = try XCTUnwrap(capturedErrors.first)
        XCTAssertNotNil(info.retryAction,
                       "Non-no-active-loan failures are retryable")
        XCTAssertTrue(info.message.contains("Server is having a moment"),
                      "Problem-doc detail field surfaces in the message")
    }

    func testAlertForProblemDocument_errorOnly_includesErrorDescription() async throws {
        let error = NSError(domain: "test", code: 42,
                            userInfo: [NSLocalizedDescriptionKey: "Boom — out of memory"])

        presenter.alertForProblemDocument(nil, error: error, book: book)
        await waitForPublishedError()

        let info = try XCTUnwrap(capturedErrors.first)
        XCTAssertTrue(info.message.contains("Boom"),
                      "Error description appears in the message when no problem doc is present")
    }
}

// MARK: - Test fakes

private final class SpyAnnouncementService: DownloadAnnouncementService {
    var failedDownloadCalls: [String] = []

    override func announceDownloadFailed(for book: TPPBook) {
        failedDownloadCalls.append(book.identifier)
    }
}

private final class SpyDelegate: DownloadAlertPresenterDelegate {
    private(set) var startDownloadCalls: [(book: TPPBook, identifier: String)] = []
    private(set) var schedulePendingCalls = 0

    func startDownload(for book: TPPBook, withRequest request: URLRequest?) {
        startDownloadCalls.append((book, book.identifier))
    }

    func schedulePendingStartsIfPossible() {
        schedulePendingCalls += 1
    }
}
