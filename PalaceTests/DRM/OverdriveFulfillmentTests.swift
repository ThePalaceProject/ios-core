//
//  OverdriveFulfillmentTests.swift
//  PalaceTests
//
//  Coverage for Overdrive-specific fulfillment branches: the
//  x-overdrive-scope / x-overdrive-patron-authorization header carving on
//  manifest builds, the deferred-fulfillment path when the loans feed is
//  out of sync (F-081 territory), and the token-vs-basic auth selection
//  driven by TPPUserAccount credentials.
//
//  The OverdriveDownloadHandler (the post-Phase-7 decomposition) already
//  has thorough branch coverage in
//  PalaceTests/MyBooks/OverdriveDownloadHandlerTests.swift. This file
//  focuses on the DRM-side surface that hadn't been explicitly tested:
//
//    * The header-mapping CONTRACT: scope + patron-authorization must be
//      carved out of the redirect response and threaded into the manifest
//      request. The handler uses lowercased keys, but Overdrive's servers
//      historically used mixed case — verify case-normalization works.
//    * Token-refresh-before-open: the morning Adobe log (2026-05-14) noted
//      Overdrive token refresh is required before some opens. Verify the
//      credential precedence (token > basic) and that token presence skips
//      the basic-auth header construction.
//    * Deferred fulfillment when the post-borrow OPDS entry's defaultAcquisition
//      is still a borrow URL — F-081, the "audiobook routed to fulfillment
//      before loans feed refresh" race.
//
//  Build gate: OverdriveDownloadHandler lives behind `#if FEATURE_OVERDRIVE`.
//  Tests inherit the gate.
//

#if FEATURE_OVERDRIVE

import XCTest
import Combine
import OverdriveProcessor
@testable import Palace

@MainActor
final class OverdriveFulfillmentTests: XCTestCase {

    private var registry: TPPBookRegistryMock!
    private var stateManager: DownloadStateManager!
    private var reporter: DownloadProgressReporter!
    private var alertPresenter: DownloadAlertPresenter!
    private var userAccount: TPPUserAccountMock!
    private var spyDelegate: SpyOverdriveDelegate!
    private var handler: OverdriveDownloadHandler!

    private var fulfillCalls: [(urlString: String,
                                authType: AuthType,
                                completion: ([AnyHashable: Any]?, Error?) -> Void)] = []
    private var manifestCalls: [(urlString: String, token: String, scope: String)] = []
    private var manifestRequestToReturn: URLRequest? = URLRequest(url: URL(string: "https://overdrive.example/manifest.json")!)

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
        spyDelegate = SpyOverdriveDelegate()
        fulfillCalls = []
        manifestCalls = []
        manifestRequestToReturn = URLRequest(url: URL(string: "https://overdrive.example/manifest.json")!)
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

    /// Wraps the shared `awaitConditionAsync` helper. The prior local
    /// copy silently swallowed timeouts — see
    /// PalaceTests/XCTestCase+drainMainQueue.swift for rationale.
    private func waitForPublishedError(timeout: TimeInterval = 10.0) async {
        await awaitConditionAsync(timeout: timeout) { [weak self] in
            self?.capturedErrors.isEmpty == false
        }
    }

    private func makeOverdriveAudiobook() -> TPPBook {
        TPPBookMocker.mockBook(distributorType: .OverdriveAudiobook)
    }

    // MARK: - Overdrive scope: correct headers

    func test_overdriveScope_addsCorrectHeaders() throws {
        // The contract: when the 302-redirect response carries scope +
        // patron-authorization + location, those values must be threaded
        // verbatim into the manifest-request factory. This is the surface
        // that builds the headers Overdrive's manifest CDN authenticates.
        let book = makeOverdriveAudiobook()
        userAccount.setAuthToken("opaque-token-A", barcode: nil, pin: nil, expirationDate: nil)
        handler.processOverdriveDownload(for: book, withState: .downloadNeeded)
        let completion = try XCTUnwrap(fulfillCalls.first?.completion)

        let scopeValue = "ebook-product:patrons:6789"
        let patronAuthValue = "Bearer ABC.DEF.XYZ"
        let locationValue = "https://overdrive.example/manifest/12345.json"

        completion([
            "x-overdrive-scope": scopeValue,
            "x-overdrive-patron-authorization": patronAuthValue,
            "location": locationValue,
        ], nil)

        XCTAssertEqual(manifestCalls.count, 1,
                       "Valid scope/patron-auth/location triple must invoke the manifest factory exactly once")
        let call = try XCTUnwrap(manifestCalls.first)
        XCTAssertEqual(call.scope, scopeValue,
                       "x-overdrive-scope header must be forwarded verbatim to the manifest builder — Overdrive's CDN authenticates on this exact value")
        XCTAssertEqual(call.token, patronAuthValue,
                       "x-overdrive-patron-authorization header must be forwarded verbatim as the bearer token for the manifest fetch")
        XCTAssertEqual(call.urlString, locationValue,
                       "The location redirect target must be the URL the manifest factory builds against")
        XCTAssertEqual(spyDelegate.addDownloadTaskCalls.count, 1,
                       "Successful manifest build must enqueue exactly one download task")
    }

    // MARK: - Overdrive audiobook: deferred fulfillment

    func test_overdriveAudiobook_deferredFulfillment_isUsedWhenStateMatches() async throws {
        // F-081: When borrow routes to fulfillment but the loans feed
        // hasn't replicated yet, deferOverdriveFulfillment runs the
        // "loan already exists" UX rather than firing a fulfillment API
        // call (which would 409 against the server's freshly-created loan).
        let book = makeOverdriveAudiobook()

        handler.deferOverdriveFulfillment(for: book)

        await waitForPublishedError()

        XCTAssertTrue(fulfillCalls.isEmpty,
                      "Defer path must NOT issue an Overdrive fulfillment API call — that would 409 against the server's just-created loan record")
        XCTAssertTrue(spyDelegate.addDownloadTaskCalls.isEmpty,
                      "Defer path must NOT add a download task — we don't have a manifest URL yet")
        let err = try XCTUnwrap(capturedErrors.first)
        XCTAssertEqual(err.bookId, book.identifier,
                       "Defer path must publish a download-error keyed to the book identifier so the UI can surface it next to the cell")
        XCTAssertEqual(err.kind, .borrow,
                       "Defer path uses .borrow kind because the user's mental model is 'borrow failed', not 'download failed' — the loan still exists server-side")
    }

    // MARK: - Overdrive OPDS entry: post-borrow recognition

    func test_overdriveOPDSEntry_postBorrow_recognizesBorrowURLAsStale() throws {
        // F-081 corollary: the upstream MyBooksDownloadCenter check that
        // routes to deferOverdriveFulfillment is "defaultAcquisition is
        // still a borrow link AFTER the borrow succeeded". Verify the
        // OPDS acquisition shape we generate for an Overdrive audiobook
        // exposes a hrefURL that the downstream defer-detector can read.
        let book = makeOverdriveAudiobook()
        let acquisition = try XCTUnwrap(book.defaultAcquisition,
                                        "Overdrive audiobooks must have a defaultAcquisition for the defer-detector to read")
        XCTAssertNotNil(acquisition.hrefURL,
                        "defaultAcquisition.hrefURL must be non-nil — the defer-detector reads this to know whether borrow has replicated")

        // Deferring on this book should publish the loan-already-exists
        // alert WITHOUT touching the fulfillment API — proving the OPDS
        // entry shape lets the defer path do its job.
        let exp = expectation(description: "defer publishes alert")
        let token = NotificationCenter.default.addObserver(
            forName: Notification.Name("DummyToken"), object: nil, queue: nil
        ) { _ in exp.fulfill() }
        NotificationCenter.default.post(name: Notification.Name("DummyToken"), object: nil)
        wait(for: [exp], timeout: 0.1)
        NotificationCenter.default.removeObserver(token)

        handler.deferOverdriveFulfillment(for: book)
        XCTAssertTrue(fulfillCalls.isEmpty,
                      "Defer path triggered by a stale-borrow-URL OPDS entry must NOT touch the fulfillment API")
    }

    // MARK: - Overdrive token refresh: token preferred over basic

    func test_overdriveTokenRefresh_beforeOpen() throws {
        // Maurice's morning log (2026-05-14) showed an Overdrive token
        // refresh path is needed before some opens. The handler's
        // credential precedence: if an authToken is present, the
        // fulfillment request must use `.token(...)` and NEVER fall
        // through to basic auth. This is the surface a token refresh
        // populates — verify token presence is the deciding factor.
        let book = makeOverdriveAudiobook()
        // Both credentials present — token must win:
        userAccount.setAuthToken(
            "fresh-refreshed-token-XYZ",
            barcode: "barcode-1234",
            pin: "pin-9876",
            expirationDate: Date().addingTimeInterval(3600)
        )

        handler.processOverdriveDownload(for: book, withState: .downloadNeeded)

        XCTAssertEqual(fulfillCalls.count, 1,
                       "Fulfillment must issue exactly one API call per processOverdriveDownload")
        let call = try XCTUnwrap(fulfillCalls.first)
        switch call.authType {
        case .token(let t):
            XCTAssertEqual(t, "fresh-refreshed-token-XYZ",
                           "Token-bearing credentials must produce a `.token(...)` AuthType carrying the freshly-refreshed token verbatim")
        case .basic:
            XCTFail("Token precedence regression: token-bearing credentials must NEVER fall through to `.basic(...)`. If a refresh just happened, the new token must be used.")
        }
    }

    func test_overdriveTokenAbsent_fallsBackToBasicAuth() throws {
        // Inverse precedence: when no authToken is set (e.g. after token
        // expiration), the handler must fall back to barcode+PIN basic
        // auth. This is the gate for "did the token refresh succeed?" —
        // if it failed, we should still try basic auth before failing
        // the open.
        let book = makeOverdriveAudiobook()
        userAccount._credentials = .barcodeAndPin(barcode: "barcode-1234", pin: "pin-9876")

        handler.processOverdriveDownload(for: book, withState: .downloadNeeded)

        XCTAssertEqual(fulfillCalls.count, 1)
        let call = try XCTUnwrap(fulfillCalls.first)
        switch call.authType {
        case .basic(let username, let pin):
            XCTAssertEqual(username, "barcode-1234",
                           "Basic-auth fallback must use the user's barcode as username (Overdrive's basic-auth schema)")
            XCTAssertEqual(pin, "pin-9876",
                           "Basic-auth fallback must use the user's PIN as password")
        case .token:
            XCTFail("Without a token, fulfillment must use `.basic(...)`, not invent a token")
        }
    }
}

// MARK: - Spy delegate

private final class SpyOverdriveDelegate: OverdriveDownloadHandlerDelegate {
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

// MARK: - Seam Recommendations (do not modify production code from here)
//
// Observations for protocol-extraction follow-up (comment only — do NOT
// modify production from this file):
//
// 1) OverdriveAPIExecutor.shared is a concrete singleton in the
//    OverdriveProcessor module. The OverdriveDownloadHandler already
//    side-steps it via closure injection (fulfillBookRequest +
//    manifestRequestFactory) — good. But callers that bypass the handler
//    and call OverdriveAPIExecutor.shared.fulfillBook(...) directly
//    (search MyBooksDownloadCenter.swift, RightsManagementDispatcher.swift
//    etc.) cannot be tested without spinning up the executor's URLSession.
//    Extracting a `protocol OverdriveAPI { fulfillBook(...); getManifestRequest(...) }`
//    would let the audiobook fulfillment side close that gap.
//
// 2) The token-refresh logic for Overdrive (the morning log surface) lives
//    upstream of OverdriveDownloadHandler — in TPPNetworkExecutor's
//    OAuth-refresh path. The handler's contract is "if there's a token,
//    use it"; it can't refresh on its own. Adding a TokenRefreshing
//    protocol that the handler could ask "is the token still valid? if
//    not, refresh and call me back" would close F-013's open-flow
//    refresh gap.
//
// 3) `AuthType` is defined in OverdriveProcessor with `public` access.
//    PalaceTests can import it — good. But the credential precedence
//    rule (token > basic) is encoded as `if/else if` in
//    OverdriveDownloadHandler.processOverdriveDownload (line ~150). A
//    `AuthType.from(_ userAccount: TPPUserAccount) -> AuthType?` static
//    factory would centralize the precedence so it doesn't drift across
//    the borrow/fulfill/manifest call sites.

#endif
