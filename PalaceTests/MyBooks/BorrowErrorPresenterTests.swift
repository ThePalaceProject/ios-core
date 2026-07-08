//
//  BorrowErrorPresenterTests.swift
//  PalaceTests
//
//  Coverage for the 4 borrow-failure decision branches in
//  BorrowErrorPresenter: loan-already-exists, invalid-credentials
//  reauth, default-with-problem-doc-detail, generic borrow-failed.
//  Asserts on the published DownloadErrorInfo via the shared progress
//  reporter, plus retry-action wiring + reauthenticator invocation.
//

import XCTest
import Combine
import PalaceCatalog
@testable import Palace

@MainActor
final class BorrowErrorPresenterTests: XCTestCase {

    private var reporter: DownloadProgressReporter!
    private var retryTracker: UserRetryTracker!
    private var reauthenticator: TPPReauthenticatorMock!
    private var userAccount: TPPUserAccountMock!
    private var credentialState: CredentialRequestState!
    private var spyDelegate: SpyDelegate!
    private var presenter: BorrowErrorPresenter!
    private var book: TPPBook!
    private var capturedErrors: [DownloadErrorInfo] = []
    private var subscription: AnyCancellable?

    override func setUpWithError() throws {
        try super.setUpWithError()
        reporter = DownloadProgressReporter(
            accessibilityAnnouncements: TPPAccessibilityAnnouncementCenter(),
            downloadAnnouncementService: DownloadAnnouncementService()
        )
        retryTracker = .shared
        reauthenticator = TPPReauthenticatorMock()
        userAccount = TPPUserAccountMock()
        credentialState = CredentialRequestState()
        spyDelegate = SpyDelegate()

        capturedErrors = []
        subscription = reporter.downloadErrorPublisher.sink { [weak self] info in
            self?.capturedErrors.append(info)
        }

        presenter = BorrowErrorPresenter(
            progressReporter: reporter,
            userRetryTracker: retryTracker,
            reauthenticator: reauthenticator,
            userAccountProvider: { [unowned self] in self.userAccount },
            credentialRequestState: credentialState
        )
        presenter.delegate = spyDelegate

        book = TPPBookMocker.mockBook(distributorType: .EpubZip)
    }

    override func tearDownWithError() throws {
        subscription?.cancel()
        subscription = nil
        reporter = nil
        retryTracker = nil
        reauthenticator = nil
        userAccount = nil
        credentialState = nil
        spyDelegate = nil
        presenter = nil
        book = nil
        capturedErrors = []
        try super.tearDownWithError()
    }

    /// Wraps the shared `awaitConditionAsync` helper. `file`/`line`
    /// forwarded so timeout XCTFail blames the call site.
    private func waitForPublishedError(
        timeout: TimeInterval = 10.0,
        file: StaticString = #file,
        line: UInt = #line
    ) async {
        await awaitConditionAsync(timeout: timeout, file: file, line: line) { [weak self] in
            self?.capturedErrors.isEmpty == false
        }
    }

    // MARK: - Branch 1: nil error type → generic

    func testProcess_noErrorDict_publishesGenericBorrowFailedAlert() async throws {
        presenter.process(error: nil, for: book)
        await waitForPublishedError()

        let info = try XCTUnwrap(capturedErrors.first)
        XCTAssertEqual(info.bookId, book.identifier)
        XCTAssertEqual(info.kind, .borrow)
        XCTAssertNotNil(info.retryAction,
                       "Generic borrow failure must offer retry while userRetryTracker has budget")
    }

    // MARK: - Branch 2: loan-already-exists

    func testProcess_loanAlreadyExists_publishesLoanAlreadyExistsAlertWithoutRetry() async throws {
        presenter.process(
            error: ["type": TPPProblemDocument.TypeLoanAlreadyExists],
            for: book
        )
        await waitForPublishedError()

        let info = try XCTUnwrap(capturedErrors.first)
        XCTAssertNil(info.retryAction,
                     "loan-already-exists is not retryable — the loan is already there")
        XCTAssertEqual(info.message, Strings.MyDownloadCenter.loanAlreadyExistsAlertMessage)
    }

    // MARK: - Branch 3: invalid-credentials reauth

    func testProcess_invalidCredentials_triggersReauthAndRetriesViaDelegate() async throws {
        userAccount._credentials = .barcodeAndPin(barcode: "b", pin: "p")
        reauthenticator.onAuthenticate = { [weak self] _, _ in
            self?.userAccount._credentials = .barcodeAndPin(barcode: "b2", pin: "p2")
        }

        presenter.process(
            error: ["type": TPPProblemDocument.TypeInvalidCredentials],
            for: book
        )

        // Allow the Task hop to run.
        for _ in 0..<5 {
            try? await Task.sleep(nanoseconds: 30_000_000)
            await Task.yield()
        }

        XCTAssertTrue(reauthenticator.authenticateIfNeededCalled,
                      "Invalid-credentials must trigger reauthenticate")
        XCTAssertEqual(spyDelegate.startDownloadCalls.map { $0.identifier }, [book.identifier],
                       "Successful re-auth retries the download")
    }

    func testProcess_invalidCredentialsTwice_secondCallSkipsReauthAndShowsAlert() async throws {
        userAccount._credentials = .barcodeAndPin(barcode: "b", pin: "p")
        reauthenticator.onAuthenticate = { [weak self] _, _ in
            self?.userAccount._credentials = .barcodeAndPin(barcode: "b2", pin: "p2")
        }

        // First call — kicks reauth, latches hasAttemptedAuthentication.
        presenter.process(
            error: ["type": TPPProblemDocument.TypeInvalidCredentials],
            for: book
        )
        for _ in 0..<5 {
            try? await Task.sleep(nanoseconds: 30_000_000)
            await Task.yield()
        }
        XCTAssertEqual(reauthenticator.authenticateCallCount, 1)

        // Second call on same book — falls through to alert.
        capturedErrors.removeAll()
        presenter.process(
            error: ["type": TPPProblemDocument.TypeInvalidCredentials,
                    "detail": "second attempt detail"],
            for: book
        )
        await waitForPublishedError()

        XCTAssertEqual(reauthenticator.authenticateCallCount, 1,
                       "Second invalid-credentials does NOT re-trigger reauth (per-borrow latch)")
        let info = try XCTUnwrap(capturedErrors.first)
        XCTAssertTrue(info.message.contains("second attempt detail"),
                      "Second invalid-credentials surfaces the problem-doc detail in an alert")
    }

    func testProcess_invalidCredentialsWhileAlreadyRequesting_skipsBoth() async throws {
        // Pre-flag the credential state so both gates short-circuit.
        credentialState.isRequestingCredentials = true

        presenter.process(
            error: ["type": TPPProblemDocument.TypeInvalidCredentials],
            for: book
        )
        for _ in 0..<3 {
            try? await Task.sleep(nanoseconds: 20_000_000)
            await Task.yield()
        }

        XCTAssertFalse(reauthenticator.authenticateIfNeededCalled,
                       "If a sign-in modal is already in flight elsewhere, this path must short-circuit")
        XCTAssertTrue(capturedErrors.isEmpty,
                      "And we DON'T fall through to an alert — the in-flight modal will resolve it")
    }

    // MARK: - Branch 4: default (with problem-doc detail)

    func testProcess_genericProblemDoc_publishesAlertWithProblemDocDetail() async throws {
        presenter.process(
            error: [
                "type": "https://example.com/some-other-error",
                "detail": "Server is having a moment"
            ],
            for: book
        )
        await waitForPublishedError()

        let info = try XCTUnwrap(capturedErrors.first)
        XCTAssertTrue(info.message.contains("Server is having a moment"),
                      "Problem-doc detail must surface in the alert message")
        XCTAssertNotNil(info.retryAction,
                       "Generic problem-doc errors are retryable")
    }
}

// MARK: - Spy

private final class SpyDelegate: BorrowErrorPresenterDelegate {
    private(set) var startBorrowCalls: [(book: TPPBook, identifier: String)] = []
    private(set) var startDownloadCalls: [(book: TPPBook, identifier: String)] = []

    func startBorrow(for book: TPPBook, attemptDownload: Bool, borrowCompletion: (() -> Void)?) {
        startBorrowCalls.append((book, book.identifier))
    }

    func startDownload(for book: TPPBook, withRequest request: URLRequest?) {
        startDownloadCalls.append((book, book.identifier))
    }
}
