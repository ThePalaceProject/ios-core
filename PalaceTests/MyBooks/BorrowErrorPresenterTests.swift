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

    /// One-shot continuation resumed the moment the error publisher emits.
    /// Lets `awaitPublishedError()` JOIN the `@MainActor` Task that
    /// `BorrowErrorPresenter.process` spins to publish the alert — instead
    /// of polling a wall-clock deadline (which starves under CI
    /// oversubscription and blows the 120s executionTimeAllowance).
    private var errorContinuation: CheckedContinuation<Void, Never>?

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
            guard let self else { return }
            self.capturedErrors.append(info)
            self.errorContinuation?.resume()
            self.errorContinuation = nil
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

    /// Joins the next error-publisher emission via a continuation resumed
    /// from the subscription sink. Deterministic — the `@MainActor` publish
    /// Task runs while this `@MainActor` test is suspended at the `await`,
    /// resumes the continuation, and we return the instant the alert lands.
    /// No wall-clock deadline to starve.
    ///
    /// Fast-paths when the emission already landed (the sink appends
    /// synchronously) so we never suspend on an event that has passed.
    private func awaitPublishedError() async {
        if !capturedErrors.isEmpty { return }
        await withCheckedContinuation { continuation in
            errorContinuation = continuation
        }
    }

    // MARK: - Branch 1: nil error type → generic

    func testProcess_noErrorDict_publishesGenericBorrowFailedAlert() async throws {
        presenter.process(error: nil, for: book)
        await awaitPublishedError()

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
        await awaitPublishedError()

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

        // Await the behavior-identical async sibling of `process` so the
        // reauth dispatch + post-reauth startDownload retry are JOINED — no
        // deadline poll (which starved under CI oversubscription).
        await presenter.processAsync(
            error: ["type": TPPProblemDocument.TypeInvalidCredentials],
            for: book
        )

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
        // Awaited join so the latch is set before the second call.
        await presenter.processAsync(
            error: ["type": TPPProblemDocument.TypeInvalidCredentials],
            for: book
        )
        XCTAssertEqual(reauthenticator.authenticateCallCount, 1)

        // Second call on same book — falls through to alert. `showAlert`
        // publishes via a main-actor hop, so join the emission explicitly.
        capturedErrors.removeAll()
        await presenter.processAsync(
            error: ["type": TPPProblemDocument.TypeInvalidCredentials,
                    "detail": "second attempt detail"],
            for: book
        )
        await awaitPublishedError()

        XCTAssertEqual(reauthenticator.authenticateCallCount, 1,
                       "Second invalid-credentials does NOT re-trigger reauth (per-borrow latch)")
        let info = try XCTUnwrap(capturedErrors.first)
        XCTAssertTrue(info.message.contains("second attempt detail"),
                      "Second invalid-credentials surfaces the problem-doc detail in an alert")
    }

    func testProcess_invalidCredentialsWhileAlreadyRequesting_skipsBoth() async throws {
        // Pre-flag the credential state so both gates short-circuit.
        credentialState.isRequestingCredentials = true

        // Awaited join: processAsync's `isRequestingCredentials` guard
        // short-circuits synchronously (no reauth, no publish), so by the
        // time the await returns the absence is fully settled — no poll.
        await presenter.processAsync(
            error: ["type": TPPProblemDocument.TypeInvalidCredentials],
            for: book
        )

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
        await awaitPublishedError()

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
