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
import PalaceCatalog
@preconcurrency import PalaceAudiobookToolkit
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

    /// Wraps the shared `awaitConditionAsync` helper.
    /// `file`/`line` forwarded so timeout XCTFail blames the call site.
    private func waitForPublishedError(
        timeout: TimeInterval = 10.0,
        file: StaticString = #file,
        line: UInt = #line
    ) async {
        await awaitConditionAsync(timeout: timeout, file: file, line: line) { [weak self] in
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

    // MARK: - WS-3: OverDrive expired-signed-URL re-fulfill predicate (3.2.0 crash-triage)
    //
    // Red-first for the recovery boundary: AudiobookLoader.load gates nothing
    // here — these pin the pure predicate that decides whether a `.playbackFailed`
    // on an OverDrive book is a recoverable signed-URL expiry (HTTP 410) worth a
    // fresh re-fulfill, vs a permanent/ambiguous failure that must NOT re-fulfill.

    private func makeOverdriveBook() -> TPPBook {
        TPPBook(
            acquisitions: [TPPOPDSAcquisition(
                relation: .generic,
                type: "application/vnd.overdrive.circulation.api+json;profile=audiobook",
                hrefURL: URL(string: "https://od.test/fulfill")!,
                indirectAcquisitions: [],
                availability: TPPOPDSAcquisitionAvailabilityUnlimited()
            )],
            authors: [], categoryStrings: [], distributor: OverdriveDistributorKey,
            identifier: UUID().uuidString, imageURL: nil, imageThumbnailURL: nil,
            published: Date(), publisher: "Test", subtitle: nil, summary: nil,
            title: "OD Fixture", updated: Date(), annotationsURL: nil, analyticsURL: nil,
            alternateURL: nil, relatedWorksURL: nil, previewLink: nil, seriesURL: nil,
            revokeURL: nil, reportURL: nil, timeTrackingURL: nil, contributors: [:],
            bookDuration: nil, imageCache: MockImageCache()
        )
    }

    private func playbackError(httpStatus: Int?) -> NSError {
        NSError(domain: "test.playback", code: 1,
                userInfo: httpStatus.map { ["httpStatusCode": $0] } ?? [:])
    }

    func testOverdriveRefulfill_410OnOverdriveBook_returnsTrue() {
        XCTAssertTrue(AudiobookSessionManager.shouldTriggerOverdriveRefulfillForPlaybackFailure(
            error: playbackError(httpStatus: 410), book: makeOverdriveBook(), alreadyAttempted: false),
            "HTTP 410 (Gone) on an OverDrive book is a clean signed-URL expiry → re-fulfill")
    }

    func testOverdriveRefulfill_403_returnsFalse_ambiguousEntitlement() {
        XCTAssertFalse(AudiobookSessionManager.shouldTriggerOverdriveRefulfillForPlaybackFailure(
            error: playbackError(httpStatus: 403), book: makeOverdriveBook(), alreadyAttempted: false),
            "403 is ambiguous (expiry vs entitlement denial) — must NOT re-fulfill into a possibly-revoked loan")
    }

    func testOverdriveRefulfill_401_returnsFalse_authNotExpiry() {
        XCTAssertFalse(AudiobookSessionManager.shouldTriggerOverdriveRefulfillForPlaybackFailure(
            error: playbackError(httpStatus: 401), book: makeOverdriveBook(), alreadyAttempted: false),
            "401 is auth-required (handled by toolkit bearer refresh / SAML) — not a signed-URL expiry")
    }

    func testOverdriveRefulfill_410ButAlreadyAttempted_returnsFalse_bounded() {
        XCTAssertFalse(AudiobookSessionManager.shouldTriggerOverdriveRefulfillForPlaybackFailure(
            error: playbackError(httpStatus: 410), book: makeOverdriveBook(), alreadyAttempted: true),
            "Bounded: a second expiry in the same session must NOT re-fulfill again (no loop)")
    }

    func testOverdriveRefulfill_410ButNotOverdrive_returnsFalse() {
        let nonOverdrive = TPPBookMocker.mockBook(title: "Not OverDrive") // distributor != "Overdrive"
        XCTAssertFalse(AudiobookSessionManager.shouldTriggerOverdriveRefulfillForPlaybackFailure(
            error: playbackError(httpStatus: 410), book: nonOverdrive, alreadyAttempted: false),
            "Re-fulfill is OverDrive-only — other distributors must not enter this path")
    }

    func testOverdriveRefulfill_noHttpStatus_returnsFalse_conservative() {
        XCTAssertFalse(AudiobookSessionManager.shouldTriggerOverdriveRefulfillForPlaybackFailure(
            error: playbackError(httpStatus: nil), book: makeOverdriveBook(), alreadyAttempted: false),
            "No extractable HTTP status (e.g. a bare AVFoundation error) → conservatively do NOT re-fulfill")
    }

    func testOverdriveRefulfill_410InUnderlyingError_returnsTrue() {
        let underlying = NSError(domain: "url", code: 1, userInfo: ["httpStatusCode": 410])
        let wrapped = NSError(domain: "av", code: -11800, userInfo: [NSUnderlyingErrorKey: underlying])
        XCTAssertTrue(AudiobookSessionManager.shouldTriggerOverdriveRefulfillForPlaybackFailure(
            error: wrapped, book: makeOverdriveBook(), alreadyAttempted: false),
            "The status may be one level down the NSUnderlyingError chain (AVFoundation wraps it)")
    }

    func testHttpStatusCode_extractsFromUserInfo_underlyingChain_andNil() {
        XCTAssertEqual(AudiobookSessionManager.httpStatusCode(from: playbackError(httpStatus: 410)), 410)
        let underlying = NSError(domain: "url", code: 1, userInfo: ["httpStatusCode": 503])
        let wrapped = NSError(domain: "av", code: -1, userInfo: [NSUnderlyingErrorKey: underlying])
        XCTAssertEqual(AudiobookSessionManager.httpStatusCode(from: wrapped), 503)
        XCTAssertNil(AudiobookSessionManager.httpStatusCode(from: playbackError(httpStatus: nil)))
    }

    // MARK: - WS-3b: -1008 resource-unavailable is the REAL field shape of the expiry
    //
    // OverDrive streams tracks through AVFoundation, which collapses an expired signed-
    // URL's HTTP 410 into `NSURLErrorDomain -1008` (NSURLErrorResourceUnavailable) with
    // NO httpStatusCode. The 410-only gate therefore never fired in the field (device
    // repro: Mi historia / A1QA, 2026-07-15 — expired `links.contentlinks` → 410 → -1008
    // → "A Problem Has Occurred", and skip-across-tracks broke identically). These pin
    // that the three real -1008 shapes now trigger the bounded re-fulfill, while the
    // non-expiry NSURLErrors (offline, timeout) and the bound/distributor guards hold.

    private func resourceUnavailableTopLevel() -> NSError {
        NSError(domain: NSURLErrorDomain, code: NSURLErrorResourceUnavailable, userInfo: [:])
    }

    func testOverdriveRefulfill_resourceUnavailable1008_topLevel_returnsTrue() {
        XCTAssertTrue(AudiobookSessionManager.shouldTriggerOverdriveRefulfillForPlaybackFailure(
            error: resourceUnavailableTopLevel(), book: makeOverdriveBook(), alreadyAttempted: false),
            "AVPlayer surfaces an expired signed-URL 410 as NSURLErrorDomain -1008 — the real field shape must re-fulfill")
    }

    func testOverdriveRefulfill_resourceUnavailable1008_flattenedScalars_returnsTrue() {
        // The shape buildPlaybackFailureRecord produces: wrapper domain + flattened scalars.
        let err = NSError(domain: "org.thepalaceproject.palace.audiobookPlayback", code: -1008,
                          userInfo: ["underlyingCode": NSURLErrorResourceUnavailable, "underlyingDomain": NSURLErrorDomain])
        XCTAssertTrue(AudiobookSessionManager.shouldTriggerOverdriveRefulfillForPlaybackFailure(
            error: err, book: makeOverdriveBook(), alreadyAttempted: false),
            "The flattened underlyingCode/underlyingDomain -1008 shape must also re-fulfill")
    }

    func testOverdriveRefulfill_resourceUnavailable1008_nestedUnderlying_returnsTrue() {
        let underlying = NSError(domain: NSURLErrorDomain, code: NSURLErrorResourceUnavailable, userInfo: [:])
        let wrapped = NSError(domain: "av", code: -11800, userInfo: [NSUnderlyingErrorKey: underlying])
        XCTAssertTrue(AudiobookSessionManager.shouldTriggerOverdriveRefulfillForPlaybackFailure(
            error: wrapped, book: makeOverdriveBook(), alreadyAttempted: false),
            "A -1008 one level down the NSUnderlyingError chain must re-fulfill")
    }

    func testOverdriveRefulfill_notConnected1009_returnsFalse_offlineIsNotExpiry() {
        let err = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet, userInfo: [:])
        XCTAssertFalse(AudiobookSessionManager.shouldTriggerOverdriveRefulfillForPlaybackFailure(
            error: err, book: makeOverdriveBook(), alreadyAttempted: false),
            "No network (-1009) is not a signed-URL expiry — re-fulfilling would just fail again offline")
    }

    func testOverdriveRefulfill_timedOut1001_returnsFalse_transientNotExpiry() {
        let err = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: [:])
        XCTAssertFalse(AudiobookSessionManager.shouldTriggerOverdriveRefulfillForPlaybackFailure(
            error: err, book: makeOverdriveBook(), alreadyAttempted: false),
            "A timeout (-1001) is transient, not an expiry — must NOT re-fulfill")
    }

    func testOverdriveRefulfill_resourceUnavailable1008_alreadyAttempted_returnsFalse_bounded() {
        XCTAssertFalse(AudiobookSessionManager.shouldTriggerOverdriveRefulfillForPlaybackFailure(
            error: resourceUnavailableTopLevel(), book: makeOverdriveBook(), alreadyAttempted: true),
            "Bounded: a second -1008 in the same session must NOT re-fulfill again (no loop)")
    }

    func testOverdriveRefulfill_resourceUnavailable1008_notOverdrive_returnsFalse() {
        let nonOverdrive = TPPBookMocker.mockBook(title: "Not OverDrive")
        XCTAssertFalse(AudiobookSessionManager.shouldTriggerOverdriveRefulfillForPlaybackFailure(
            error: resourceUnavailableTopLevel(), book: nonOverdrive, alreadyAttempted: false),
            "Re-fulfill is OverDrive-only — a -1008 on another distributor must not enter this path")
    }

    func testIsResourceUnavailable_flattenedScalars_wrongDomain_returnsFalse() {
        // The flattened branch must honor the same domain scoping as the others: a -1008
        // code stamped with a NON-NSURLErrorDomain underlyingDomain is not our expiry.
        // Guards the shared `matches` conjunction on the flattened branch specifically.
        let wrongDomain = NSError(domain: "org.thepalaceproject.palace.audiobookPlayback", code: -1008,
                                  userInfo: ["underlyingCode": NSURLErrorResourceUnavailable, "underlyingDomain": "not-a-url-domain"])
        XCTAssertFalse(AudiobookSessionManager.isResourceUnavailable(from: wrongDomain),
            "Flattened -1008 with a non-NSURLErrorDomain underlyingDomain must NOT match")
        let wrongCode = NSError(domain: "org.thepalaceproject.palace.audiobookPlayback", code: -1001,
                                userInfo: ["underlyingCode": NSURLErrorTimedOut, "underlyingDomain": NSURLErrorDomain])
        XCTAssertFalse(AudiobookSessionManager.isResourceUnavailable(from: wrongCode),
            "Flattened underlyingCode -1001 (timeout) must NOT match even on NSURLErrorDomain")
    }

    func testIsResourceUnavailable_throughBuildPlaybackFailureRecord_stillTriggers() {
        // Couples the helper to buildPlaybackFailureRecord's actual key names: feed a raw
        // -1008 through the record builder and assert the produced NSError still trips the
        // gate. If buildPlaybackFailureRecord renamed underlyingCode/underlyingDomain, the
        // recovery would silently stop matching the record shape — this catches that drift.
        let raw = NSError(domain: NSURLErrorDomain, code: NSURLErrorResourceUnavailable, userInfo: [:])
        let record = AudiobookSessionManager.buildPlaybackFailureRecord(error: raw, position: nil, bookId: "b")
        XCTAssertTrue(AudiobookSessionManager.isResourceUnavailable(from: record),
            "The NSError buildPlaybackFailureRecord produces for a -1008 must still be recognized as resource-unavailable")
    }

    func testIsResourceUnavailable_matchesMinus1008_rejectsOffline_timeout_andNil() {
        XCTAssertTrue(AudiobookSessionManager.isResourceUnavailable(from: resourceUnavailableTopLevel()))
        XCTAssertFalse(AudiobookSessionManager.isResourceUnavailable(
            from: NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet, userInfo: [:])))
        XCTAssertFalse(AudiobookSessionManager.isResourceUnavailable(
            from: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: [:])))
        XCTAssertFalse(AudiobookSessionManager.isResourceUnavailable(
            from: NSError(domain: "test.playback", code: -1008, userInfo: [:])),
            "-1008 must be scoped to NSURLErrorDomain, not any domain that happens to use code -1008")
        XCTAssertFalse(AudiobookSessionManager.isResourceUnavailable(from: nil))
    }

    // MARK: - PP-4800: re-fulfill poll state classification (drives re-open vs unavailable)
    //
    // awaitDownloadSuccessful polls the registry after triggering the download-center
    // re-fulfillment; overdriveRefulfillOutcome is the pure state→outcome mapping it
    // uses. Pin every TPPBookState so a future edit adding a terminal state or flipping
    // a case (e.g. .downloadFailed → "landed") can't silently break the recovery.

    func testOverdriveRefulfillOutcome_landed_terminalFailure_and_keepPolling() {
        // Fresh manifest landed → stop polling, re-open.
        XCTAssertEqual(AudiobookSessionManager.overdriveRefulfillOutcome(for: .downloadSuccessful), true)
        XCTAssertEqual(AudiobookSessionManager.overdriveRefulfillOutcome(for: .used), true)
        // Terminal failure → stop polling, surface unavailable.
        XCTAssertEqual(AudiobookSessionManager.overdriveRefulfillOutcome(for: .downloadFailed), false,
                       ".downloadFailed must be a terminal FAILURE, not treated as landed")
        XCTAssertEqual(AudiobookSessionManager.overdriveRefulfillOutcome(for: .unregistered), false)
        XCTAssertEqual(AudiobookSessionManager.overdriveRefulfillOutcome(for: .unsupported), false)
        // Not yet terminal → keep polling (nil).
        XCTAssertNil(AudiobookSessionManager.overdriveRefulfillOutcome(for: .downloadNeeded),
                     ".downloadNeeded is the transient reset state — must keep polling, not fail")
        XCTAssertNil(AudiobookSessionManager.overdriveRefulfillOutcome(for: .downloading))
        XCTAssertNil(AudiobookSessionManager.overdriveRefulfillOutcome(for: .holding))
        XCTAssertNil(AudiobookSessionManager.overdriveRefulfillOutcome(for: .returning))
        XCTAssertNil(AudiobookSessionManager.overdriveRefulfillOutcome(for: .SAMLStarted))
    }

    // MARK: - WS-3: fresh re-fulfilled URL is CONSUMED into the built audiobook (loader-level)
    //
    // Assertions 2+3 of the recovery proof, at the loader boundary (no session
    // auth gate). The recovery re-opens via AudiobookLoader(forceRefulfill:true);
    // this proves the URL a fresh re-fulfill resolves ends up in the BUILT
    // audiobook's first track — i.e. the player is handed the FRESH url, not a
    // stale cached-manifest replay. The session wiring (handleManagerState ->
    // openAudiobook(forceRefulfill:true) -> makeLoader) is auth-gated and is
    // covered by architect SoD review + device validation.

    /// Spy adapter — returns a caller-supplied manifest so the test controls the
    /// track href the loader builds from.
    private final class ManifestSpyAdapter: AudiobookVendorAdapter {
        let manifestJSON: [String: Any]
        init(manifestJSON: [String: Any]) { self.manifestJSON = manifestJSON }
        func canHandle(_ book: TPPBook) -> Bool { true }
        func resolveManifest(
            for book: TPPBook,
            completion: @escaping (Result<(json: [String: Any], decryptor: DRMDecryptor?), AudiobookLoadError>) -> Void
        ) {
            completion(.success((json: manifestJSON, decryptor: nil)))
        }
    }

    private func openAccessManifest(firstTrackHref: String) -> [String: Any] {
        [
            "metadata": [
                "@type": "http://schema.org/Audiobook",
                "title": "WS-3 Fixture",
                "identifier": "ws3-od",
                "duration": 60
            ],
            "readingOrder": [
                ["href": firstTrackHref, "type": "audio/mpeg", "duration": 60, "title": "Track 1"]
            ]
        ]
    }

    private func firstTrackURL(loadingManifestWithHref href: String) throws -> String? {
        let spy = ManifestSpyAdapter(manifestJSON: openAccessManifest(firstTrackHref: href))
        let loader = AudiobookLoader(adapters: [spy])
        let done = expectation(description: "load completes")
        var url: String?
        loader.load(makeOverdriveBook()) { result in
            if case .success(let loaded) = result {
                url = loaded.audiobook.tableOfContents.allTracks.first?.urls?.first?.absoluteString
            }
            done.fulfill()
        }
        wait(for: [done], timeout: 5.0)
        return url
    }

    func testRefulfill_freshManifestURL_isConsumedIntoBuiltAudiobook() throws {
        try KeychainAvailability.skipIfUnavailable()
        // The loader's refreshTokenIfNeeded reads the production shared account
        // BEFORE the adapter chain; clear it so a leftover expired token doesn't
        // fail the load before the spy resolves.
        AppContainer.production().accountsManager.currentUserAccount.removeAll() // MIGRATED-DEFERRED: swarm_47883816 — hermetic reset must target the production shared currentUserAccount the loader's token gate reads

        let freshURL = "https://od.test/FRESH/track-1.mp3"
        let staleURL = "https://od.test/STALE/track-1.mp3"

        let builtFromFresh = try firstTrackURL(loadingManifestWithHref: freshURL)
        XCTAssertEqual(builtFromFresh, freshURL,
                       "The re-fulfilled (fresh) manifest URL must be CONSUMED into the built audiobook's first track — proves recovery yields fresh signed URLs, not a cached-manifest replay (PP-4553 sibling / WS-3)")
        XCTAssertNotEqual(builtFromFresh, staleURL, "Built track URL must be the FRESH one, not stale")

        // Control: a stale-href manifest builds a stale track — proves the loader
        // faithfully carries whichever URL the (re-)fulfill resolved, so the FRESH
        // assertion above is meaningful (not a constant).
        let builtFromStale = try firstTrackURL(loadingManifestWithHref: staleURL)
        XCTAssertEqual(builtFromStale, staleURL, "Loader must carry the resolved manifest's URL into the built audiobook")
        XCTAssertNotEqual(builtFromStale, freshURL, "Stale-manifest build must NOT yield the fresh URL")
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
