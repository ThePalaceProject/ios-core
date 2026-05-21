//
//  OverdriveDownloadHandlerTests.swift
//  PalaceTests
//
//  Coverage for OverdriveDownloadHandler — the Overdrive 302-redirect
//  fulfillment flow (`processOverdriveDownload` → `handleOverdriveResponse`)
//  and the loans-feed-out-of-sync defer path (`deferOverdriveFulfillment`).
//
//  The class is gated `#if FEATURE_OVERDRIVE` because it imports the
//  external OverdriveProcessor module; this test file inherits the same
//  gate.
//
//  Branches covered:
//    - Wi-Fi-only enforcement short-circuits before any Overdrive API call.
//    - Token-auth path issues a `.token(...)` fulfillBook request.
//    - Basic-auth path issues a `.basic(...)` fulfillBook request when
//      no token is present.
//    - Successful response → manifest-request factory invoked with the
//      parsed `x-overdrive-scope` + `x-overdrive-patron-authorization`
//      headers; resulting URLRequest handed off to the delegate.
//    - Header keys are normalized to lowercase (uppercase keys still
//      route to manifest-request build).
//    - Response error → publishes a download-failed alert (no manifest
//      request, no addDownloadTask).
//    - Missing `location` header → publishes "wrong headers" alert.
//    - Manifest factory returns nil → publishes "wrong headers" alert.
//    - `deferOverdriveFulfillment` publishes the "loan already exists"
//      borrow alert.
//

#if FEATURE_OVERDRIVE

import XCTest
import Combine
import OverdriveProcessor
@testable import Palace

@MainActor
final class OverdriveDownloadHandlerTests: XCTestCase {

    private var registry: TPPBookRegistryMock!
    private var stateManager: DownloadStateManager!
    private var reporter: DownloadProgressReporter!
    private var alertPresenter: DownloadAlertPresenter!
    private var userAccount: TPPUserAccountMock!
    private var spyDelegate: SpyDelegate!
    private var handler: OverdriveDownloadHandler!

    /// Captures every `fulfillBookRequest` invocation. Tests fire the
    /// stashed completion to drive the redirect-success / error
    /// branches of `handleOverdriveResponse`.
    private var fulfillCalls: [(urlString: String,
                                authType: AuthType,
                                completion: ([AnyHashable: Any]?, Error?) -> Void)] = []

    /// Captures every `manifestRequestFactory` invocation. The next
    /// returned URLRequest comes from `manifestRequestToReturn`.
    private var manifestCalls: [(urlString: String, token: String, scope: String)] = []
    private var manifestRequestToReturn: URLRequest? = URLRequest(url: URL(string: "https://example.com/manifest.json")!)

    private var capturedErrors: [DownloadErrorInfo] = []
    private var subscription: AnyCancellable?

    override func setUpWithError() throws {
        try super.setUpWithError()
        registry = TPPBookRegistryMock()
        stateManager = DownloadStateManager()
        reporter = DownloadProgressReporter(
            accessibilityAnnouncements: TPPAccessibilityAnnouncementCenter(),
            downloadAnnouncementService: DownloadAnnouncementService()
        )
        alertPresenter = DownloadAlertPresenter(
            bookRegistry: registry,
            stateManager: stateManager,
            progressReporter: reporter,
            downloadAnnouncementService: DownloadAnnouncementService()
        )
        userAccount = TPPUserAccountMock()
        spyDelegate = SpyDelegate()
        fulfillCalls = []
        manifestCalls = []
        manifestRequestToReturn = URLRequest(url: URL(string: "https://example.com/manifest.json")!)
        capturedErrors = []
        subscription = reporter.downloadErrorPublisher.sink { [weak self] info in
            self?.capturedErrors.append(info)
        }

        handler = OverdriveDownloadHandler(
            bookRegistry: registry,
            stateManager: stateManager,
            progressReporter: reporter,
            alertPresenter: alertPresenter,
            userAccountProvider: { [unowned self] in self.userAccount },
            fulfillBookRequest: { [unowned self] urlString, authType, completion in
                self.fulfillCalls.append((urlString, authType, completion))
            },
            manifestRequestFactory: { [unowned self] urlString, token, scope in
                self.manifestCalls.append((urlString, token, scope))
                return self.manifestRequestToReturn
            }
        )
        handler.delegate = spyDelegate
    }

    override func tearDownWithError() throws {
        subscription?.cancel()
        subscription = nil
        registry = nil
        stateManager = nil
        reporter = nil
        alertPresenter = nil
        userAccount = nil
        spyDelegate = nil
        handler = nil
        fulfillCalls = []
        manifestCalls = []
        capturedErrors = []
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    /// Wraps the shared `awaitConditionAsync` helper. Replaces the prior
    /// local copy that silently swallowed timeouts. `file`/`line`
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

    private func makeOverdriveBook() -> TPPBook {
        return TPPBookMocker.mockBook(distributorType: .OverdriveAudiobook)
    }

    // MARK: - processOverdriveDownload — Wi-Fi gate

    func testProcessOverdriveDownload_whenWifiEnforced_failsWithWifiAndDoesNotCallAPI() {
        let book = makeOverdriveBook()
        spyDelegate.isWifiOnlyEnforced = true
        userAccount.setAuthToken("tok", barcode: nil, pin: nil, expirationDate: nil)

        handler.processOverdriveDownload(for: book, withState: .downloadNeeded)

        XCTAssertEqual(spyDelegate.failWithWifiCalls.map { $0.identifier }, [book.identifier],
                       "Wi-Fi-only mode must short-circuit through delegate.failWithWifiRequired")
        XCTAssertTrue(fulfillCalls.isEmpty,
                      "Wi-Fi-only mode must NOT issue an Overdrive fulfillment request")
    }

    // MARK: - processOverdriveDownload — auth-type selection

    func testProcessOverdriveDownload_withAuthToken_issuesTokenFulfillRequest() throws {
        let book = makeOverdriveBook()
        userAccount.setAuthToken("opaque-token", barcode: "b", pin: "p", expirationDate: nil)

        handler.processOverdriveDownload(for: book, withState: .downloadNeeded)

        XCTAssertEqual(fulfillCalls.count, 1)
        let call = try XCTUnwrap(fulfillCalls.first)
        XCTAssertEqual(call.urlString, book.defaultAcquisition?.hrefURL.absoluteString)
        switch call.authType {
        case .token(let t):
            XCTAssertEqual(t, "opaque-token",
                           "Token-bearing credentials must produce a `.token(...)` AuthType, not basic")
        case .basic:
            XCTFail("Token-bearing credentials must NOT fall back to `.basic(...)`")
        }
    }

    func testProcessOverdriveDownload_withBarcodePin_issuesBasicFulfillRequest() throws {
        let book = makeOverdriveBook()
        // No authToken — barcode+pin only.
        userAccount._credentials = .barcodeAndPin(barcode: "barcode-42", pin: "pin-99")

        handler.processOverdriveDownload(for: book, withState: .downloadNeeded)

        XCTAssertEqual(fulfillCalls.count, 1)
        let call = try XCTUnwrap(fulfillCalls.first)
        switch call.authType {
        case .basic(let username, let pin):
            XCTAssertEqual(username, "barcode-42",
                           "Basic-auth path must pass the user's barcode as username")
            XCTAssertEqual(pin, "pin-99",
                           "Basic-auth path must pass the user's PIN")
        case .token:
            XCTFail("Without an auth token, the handler must use `.basic(...)`, not `.token(...)`")
        }
    }

    // MARK: - handleOverdriveResponse — success path

    func testHandleOverdriveResponse_validHeaders_buildsManifestRequestAndAddsDownloadTask() throws {
        let book = makeOverdriveBook()
        userAccount.setAuthToken("tok", barcode: nil, pin: nil, expirationDate: nil)

        handler.processOverdriveDownload(for: book, withState: .downloadNeeded)
        let completion = try XCTUnwrap(fulfillCalls.first?.completion)

        // Drive the redirect-success branch: 302 headers carrying scope +
        // patron-authorization + location (the URL the manifest lives at).
        let headers: [AnyHashable: Any] = [
            "x-overdrive-scope": "scope-foo",
            "x-overdrive-patron-authorization": "patron-bearer-XYZ",
            "location": "https://overdrive.example/manifest.json"
        ]
        completion(headers, nil)

        XCTAssertEqual(manifestCalls.count, 1,
                       "Valid headers must invoke the manifest-request factory exactly once")
        let mc = try XCTUnwrap(manifestCalls.first)
        XCTAssertEqual(mc.urlString, "https://overdrive.example/manifest.json")
        XCTAssertEqual(mc.token, "patron-bearer-XYZ",
                       "Manifest request must be built with the parsed patron-authorization header")
        XCTAssertEqual(mc.scope, "scope-foo",
                       "Manifest request must be built with the parsed scope header")

        XCTAssertEqual(spyDelegate.addDownloadTaskCalls.map { $0.identifier }, [book.identifier],
                       "Successful manifest build must hand the URLRequest to delegate.addDownloadTask")
        XCTAssertTrue(capturedErrors.isEmpty,
                      "Success path must NOT publish a download error")
    }

    func testHandleOverdriveResponse_uppercaseHeaderKeys_arelowercaseNormalized() throws {
        // Regression guard: handler lowercases header keys before lookup.
        let book = makeOverdriveBook()
        userAccount.setAuthToken("tok", barcode: nil, pin: nil, expirationDate: nil)

        handler.processOverdriveDownload(for: book, withState: .downloadNeeded)
        let completion = try XCTUnwrap(fulfillCalls.first?.completion)

        let headers: [AnyHashable: Any] = [
            "X-Overdrive-Scope": "S",
            "X-Overdrive-Patron-Authorization": "P",
            "Location": "https://overdrive.example/manifest"
        ]
        completion(headers, nil)

        XCTAssertEqual(manifestCalls.count, 1,
                       "Headers with uppercase keys must still route to the manifest factory after normalization")
        XCTAssertEqual(spyDelegate.addDownloadTaskCalls.count, 1)
    }

    // MARK: - handleOverdriveResponse — failure paths

    func testHandleOverdriveResponse_completionWithError_failsDownloadAndSkipsManifestBuild() async throws {
        let book = makeOverdriveBook()
        userAccount.setAuthToken("tok", barcode: nil, pin: nil, expirationDate: nil)

        handler.processOverdriveDownload(for: book, withState: .downloadNeeded)
        let completion = try XCTUnwrap(fulfillCalls.first?.completion)

        completion(nil, NSError(domain: "test", code: 7,
                                userInfo: [NSLocalizedDescriptionKey: "no network"]))

        await waitForPublishedError()

        XCTAssertTrue(manifestCalls.isEmpty,
                      "Error response must NOT attempt to build a manifest request")
        XCTAssertTrue(spyDelegate.addDownloadTaskCalls.isEmpty,
                      "Error response must NOT add a download task")
        let err = try XCTUnwrap(capturedErrors.first)
        XCTAssertEqual(err.bookId, book.identifier)
        XCTAssertEqual(err.kind, .download,
                       "Error path uses failDownloadWithAlert which publishes a .download-kind error")
    }

    func testHandleOverdriveResponse_missingLocationHeader_failsDownload() async throws {
        let book = makeOverdriveBook()
        userAccount.setAuthToken("tok", barcode: nil, pin: nil, expirationDate: nil)

        handler.processOverdriveDownload(for: book, withState: .downloadNeeded)
        let completion = try XCTUnwrap(fulfillCalls.first?.completion)

        // Scope + patron-authorization present, but no `location` — guard fails.
        let headers: [AnyHashable: Any] = [
            "x-overdrive-scope": "S",
            "x-overdrive-patron-authorization": "P"
        ]
        completion(headers, nil)

        await waitForPublishedError()

        XCTAssertTrue(manifestCalls.isEmpty,
                      "Missing `location` header must short-circuit before the manifest factory")
        XCTAssertTrue(spyDelegate.addDownloadTaskCalls.isEmpty)
        XCTAssertEqual(capturedErrors.first?.bookId, book.identifier,
                       "Missing-headers path publishes a download-failed alert for the book")
    }

    func testHandleOverdriveResponse_manifestFactoryReturnsNil_failsDownload() async throws {
        let book = makeOverdriveBook()
        userAccount.setAuthToken("tok", barcode: nil, pin: nil, expirationDate: nil)
        manifestRequestToReturn = nil  // Simulate a malformed redirect URL.

        handler.processOverdriveDownload(for: book, withState: .downloadNeeded)
        let completion = try XCTUnwrap(fulfillCalls.first?.completion)

        let headers: [AnyHashable: Any] = [
            "x-overdrive-scope": "S",
            "x-overdrive-patron-authorization": "P",
            "location": "garbage"
        ]
        completion(headers, nil)

        await waitForPublishedError()

        XCTAssertEqual(manifestCalls.count, 1,
                       "Factory is invoked exactly once even when it returns nil")
        XCTAssertTrue(spyDelegate.addDownloadTaskCalls.isEmpty,
                      "A nil URLRequest must NOT be handed to the delegate")
        XCTAssertEqual(capturedErrors.first?.bookId, book.identifier,
                       "Nil manifest request publishes a download-failed alert")
    }

    // MARK: - deferOverdriveFulfillment

    func testDeferOverdriveFulfillment_publishesLoanAlreadyExistsBorrowError() async throws {
        let book = makeOverdriveBook()

        handler.deferOverdriveFulfillment(for: book)

        await waitForPublishedError()

        let err = try XCTUnwrap(capturedErrors.first)
        XCTAssertEqual(err.bookId, book.identifier)
        XCTAssertEqual(err.kind, .borrow,
                       "Defer path publishes a .borrow-kind error (loan-already-exists), not .download")
        XCTAssertTrue(fulfillCalls.isEmpty,
                      "Defer path must NOT trigger a fulfillment API call")
        XCTAssertTrue(spyDelegate.addDownloadTaskCalls.isEmpty,
                      "Defer path must NOT add a download task")
    }
}

// MARK: - Spy

private final class SpyDelegate: OverdriveDownloadHandlerDelegate {
    var isWifiOnlyEnforced: Bool = false

    private(set) var failWithWifiCalls: [(book: TPPBook, identifier: String)] = []
    private(set) var addDownloadTaskCalls: [(request: URLRequest, book: TPPBook, identifier: String)] = []

    func failWithWifiRequired(for book: TPPBook) {
        failWithWifiCalls.append((book, book.identifier))
    }

    func addDownloadTask(with request: URLRequest, book: TPPBook) {
        addDownloadTaskCalls.append((request, book, book.identifier))
    }
}

#endif
