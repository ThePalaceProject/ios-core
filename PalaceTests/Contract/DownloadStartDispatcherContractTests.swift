//
//  DownloadStartDispatcherContractTests.swift
//  PalaceTests
//
//  E1 (WS6) characterization contract-snapshot coverage for
//  `DownloadStartDispatcher`. The dispatcher owns the start-download
//  decision tree lifted out of MyBooksDownloadCenter:
//
//    - processUnregisteredState  (open-access seed vs stay-unregistered)
//    - processDownloadWithCredentials (streaming-HTML skip, borrow route,
//      Overdrive-audiobook divert, fall-through to regular)
//    - processRegularDownload    (re-borrow-on-expired, auto-borrow-on-
//      downloadNeeded, Wi-Fi guard, request resolution + bearer auth,
//      SAML-cookies branch, invalid-URL log, addDownloadTask handoff)
//
//  WHY A CONTRACT SNAPSHOT (vs the existing `DownloadStartDispatcherTests`
//  unit tests): the sibling unit tests assert per-branch call *counts* and
//  *absence*. They do NOT pin the ORDERED sequence of collaborator calls
//  (e.g. `clearAndSetCookies` THEN `addDownloadTask`; `setState(.unregistered)`
//  THEN `startBorrow`). E2 (WS7) extracts the dispatcher's branch logic into
//  a pure `DownloadStartReducer`; the behavior-preservation proof required by
//  Contract E is "the E2 core's emitted sequence is shape-equal to this E1
//  service snapshot." That proof needs the ordered emission pinned as JSON —
//  which is exactly what these snapshots lock. A refactor that reorders,
//  drops, or adds a collaborator call drifts the snapshot and fails loudly.
//
//  All collaborator calls (delegate surface + the delegate's registry) are
//  recorded into a single `CallLog` in call order. Books use deterministic
//  identifiers so the JSON stays stable across runs.
//
//  Coverage map (each row → one snapshot):
//    unregisteredState_openAccess_seedsDownloadNeeded
//    unregisteredState_borrowLink_staysUnregistered_emitsNothing
//    withCredentials_streamingHTML_returnsEarly_emitsNothing
//    withCredentials_unregistered_routesStartBorrow
//    withCredentials_holding_routesStartBorrow
//    regular_expiredWithBorrow_setUnregisteredThenReBorrow
//    regular_downloadNeededWithBorrow_setUnregisteredThenAutoBorrow
//    regular_wifiOnlyEnforced_failsWifi_noDownloadTask
//    regular_normal_clearCookiesThenAddDownloadTask
//    regular_samlWithCookies_routesSAMLHandler_noDownloadTask
//    regular_noAcquisitionURL_logsInvalidRequest
//  #if FEATURE_OVERDRIVE
//    withCredentials_overdriveAudiobook_divertsToOverdriveHandler
//  #endif
//
//  DEFERRED (documented seam-gaps, not faked):
//    - The Overdrive DEFER branch (`shouldDeferOverdriveFulfillment == true`,
//      i.e. audiobook whose default acquisition is still a borrow link) routes
//      into `OverdriveDownloadHandler.deferOverdriveFulfillment`, which does a
//      live `bookRegistry.sync()` + a MainActor progress-reporter hop with no
//      dispatcher-delegate emission — there is no deterministic dispatcher-
//      level contract to pin (the handler is a `final` class, not spyable at
//      the dispatcher boundary). Covered by `OverdriveDeferredFulfillmentTests`
//      at the handler layer.
//

import XCTest
import PalacePreferences
import PalaceCatalog
@testable import Palace
import PalaceBookModel

@MainActor
final class DownloadStartDispatcherContractTests: XCTestCase {

    private var log: CallLog!
    private var registry: RecordingDispatcherRegistry!
    private var userAccount: TPPUserAccountMock!
    private var settings: TPPSettings!
    private var isOnWiFiValue = true
    private var delegate: RecordingDispatcherDelegate!
    private var dispatcher: DownloadStartDispatcher!

    override func setUpWithError() throws {
        try super.setUpWithError()
        log = CallLog()
        registry = RecordingDispatcherRegistry(log: log)
        userAccount = TPPUserAccountMock()
        settings = TPPSettings()
        settings.downloadOnlyOnWiFi = false
        isOnWiFiValue = true
        delegate = RecordingDispatcherDelegate(log: log, registry: registry)

        #if FEATURE_OVERDRIVE
        let overdrive = OverdriveDownloadHandler(
            bookRegistry: registry,
            stateManager: DownloadStateManager(),
            progressReporter: DownloadProgressReporter(
                accessibilityAnnouncements: TPPAccessibilityAnnouncementCenter(),
                downloadAnnouncementService: DownloadAnnouncementService()
            ),
            alertPresenter: DownloadAlertPresenter(
                bookRegistry: registry,
                stateManager: DownloadStateManager(),
                progressReporter: DownloadProgressReporter(
                    accessibilityAnnouncements: TPPAccessibilityAnnouncementCenter(),
                    downloadAnnouncementService: DownloadAnnouncementService()
                ),
                downloadAnnouncementService: DownloadAnnouncementService(),
                errorActivityTracker: .shared,
                userRetryTracker: .shared
            ),
            userAccountProvider: { [unowned self] in self.userAccount },
            // Recorder: pins that the dispatcher DIVERTED an Overdrive audiobook
            // into the handler's fulfillment request instead of the regular
            // download path. Never touches the live Overdrive API.
            fulfillBookRequest: { [log] urlString, _, _ in
                log?.record("overdrive.fulfillBookRequest",
                            args: ["url": URL(string: urlString)?.lastPathComponent ?? urlString])
            }
        )
        dispatcher = DownloadStartDispatcher(
            userAccountProvider: { [unowned self] in self.userAccount },
            applyBearerAuth: { req, _ in req },
            settings: settings,
            isOnWiFi: { [unowned self] in self.isOnWiFiValue },
            memoryPressureMonitor: .shared,
            overdriveHandler: overdrive
        )
        #else
        dispatcher = DownloadStartDispatcher(
            userAccountProvider: { [unowned self] in self.userAccount },
            applyBearerAuth: { req, _ in req },
            settings: settings,
            isOnWiFi: { [unowned self] in self.isOnWiFiValue },
            memoryPressureMonitor: .shared
        )
        #endif
        dispatcher.delegate = delegate
    }

    override func tearDownWithError() throws {
        log = nil
        registry = nil
        userAccount = nil
        settings = nil
        delegate = nil
        dispatcher = nil
        try super.tearDownWithError()
    }

    // MARK: - processUnregisteredState

    /// Open-access book, no borrow link → seeds the registry to
    /// `.downloadNeeded` and returns `.downloadNeeded`. Pins the addBook
    /// emission (the one collaborator call this branch makes).
    func test_unregisteredState_openAccess_seedsDownloadNeeded() {
        let book = Self.makeBook(identifier: "DSD-UNREG-OA", relation: .openAccess)

        let state = dispatcher.processUnregisteredState(for: book, location: nil, loginRequired: false)

        XCTAssertEqual(state, .downloadNeeded)
        ContractSnapshot.assert(log, named: "unregisteredState_openAccess_seedsDownloadNeeded")
    }

    /// Borrow-link book + loginRequired → stays `.unregistered`, emits NO
    /// collaborator calls. The empty-sequence snapshot IS the contract: this
    /// decision must not touch the registry.
    func test_unregisteredState_borrowLink_staysUnregistered_emitsNothing() {
        let book = Self.makeBook(identifier: "DSD-UNREG-BORROW", relation: .borrow)

        let state = dispatcher.processUnregisteredState(for: book, location: nil, loginRequired: true)

        XCTAssertEqual(state, .unregistered)
        ContractSnapshot.assert(log, named: "unregisteredState_borrowLink_staysUnregistered_emitsNothing")
    }

    // MARK: - processDownloadWithCredentials routing

    /// PP-4161 Path X: a streaming-HTML title has no downloadable asset. The
    /// dispatcher must early-return — NO startBorrow, NO addDownloadTask.
    func test_withCredentials_streamingHTML_returnsEarly_emitsNothing() {
        let book = Self.makeStreamingHTMLBook(identifier: "DSD-STREAM")
        registry.addBookStub(book, state: .downloadNeeded)

        dispatcher.processDownloadWithCredentials(for: book, withState: .downloadNeeded, andRequest: nil)

        ContractSnapshot.assert(log, named: "withCredentials_streamingHTML_returnsEarly_emitsNothing")
    }

    /// `.unregistered` state + borrow link → routes to `startBorrow`
    /// (attemptDownload=true), NOT the asset path.
    func test_withCredentials_unregistered_routesStartBorrow() {
        let book = Self.makeBook(identifier: "DSD-WC-UNREG", relation: .borrow)
        registry.addBookStub(book, state: .unregistered)

        dispatcher.processDownloadWithCredentials(for: book, withState: .unregistered, andRequest: nil)

        ContractSnapshot.assert(log, named: "withCredentials_unregistered_routesStartBorrow")
    }

    /// `.holding` state + borrow link → same borrow route as `.unregistered`.
    func test_withCredentials_holding_routesStartBorrow() {
        let book = Self.makeBook(identifier: "DSD-WC-HOLD", relation: .borrow)
        registry.addBookStub(book, state: .holding)

        dispatcher.processDownloadWithCredentials(for: book, withState: .holding, andRequest: nil)

        ContractSnapshot.assert(log, named: "withCredentials_holding_routesStartBorrow")
    }

    #if FEATURE_OVERDRIVE
    /// Overdrive audiobook whose default acquisition is NOT a borrow link
    /// (so `shouldDeferOverdriveFulfillment == false`) → the dispatcher must
    /// DIVERT into `processOverdriveDownload`, which issues the fulfillment
    /// request. The contract: `overdrive.fulfillBookRequest` fires and the
    /// regular `addDownloadTask` / `startBorrow` path does NOT.
    func test_withCredentials_overdriveAudiobook_divertsToOverdriveHandler() {
        let book = Self.makeOverdriveAudiobook(identifier: "DSD-OD-AUDIO")
        registry.addBookStub(book, state: .downloadSuccessful)
        userAccount.setAuthToken("tok", barcode: "b", pin: "p", expirationDate: nil)

        dispatcher.processDownloadWithCredentials(for: book, withState: .downloadSuccessful, andRequest: nil)

        ContractSnapshot.assert(log, named: "withCredentials_overdriveAudiobook_divertsToOverdriveHandler")
    }
    #endif

    // MARK: - processRegularDownload branches

    /// Expired book + borrow link → `setState(.unregistered)` THEN
    /// `startBorrow`. Pins the ordered re-borrow-on-expired contract.
    func test_regular_expiredWithBorrow_setUnregisteredThenReBorrow() {
        let book = Self.makeExpiredBorrowableBook(identifier: "DSD-EXPIRED")
        registry.addBookStub(book, state: .downloadSuccessful)

        dispatcher.processRegularDownload(for: book, withState: .downloadSuccessful, andRequest: nil)

        ContractSnapshot.assert(log, named: "regular_expiredWithBorrow_setUnregisteredThenReBorrow")
    }

    /// `.downloadNeeded` + borrow link → `setState(.unregistered)` THEN
    /// `startBorrow` (with a completion closure). Auto-borrow-before-download.
    func test_regular_downloadNeededWithBorrow_setUnregisteredThenAutoBorrow() {
        let book = Self.makeBook(identifier: "DSD-AUTOBORROW", relation: .borrow)
        registry.addBookStub(book, state: .downloadNeeded)

        dispatcher.processRegularDownload(for: book, withState: .downloadNeeded, andRequest: nil)

        ContractSnapshot.assert(log, named: "regular_downloadNeededWithBorrow_setUnregisteredThenAutoBorrow")
    }

    /// Wi-Fi-only enforced (setting on + off Wi-Fi) → `failWithWifiRequired`,
    /// NO addDownloadTask.
    func test_regular_wifiOnlyEnforced_failsWifi_noDownloadTask() {
        settings.downloadOnlyOnWiFi = true
        isOnWiFiValue = false
        let book = Self.makeBook(identifier: "DSD-WIFI", relation: .openAccess)
        registry.addBookStub(book, state: .downloadNeeded)

        dispatcher.processRegularDownload(for: book, withState: .downloadNeeded, andRequest: nil)

        ContractSnapshot.assert(log, named: "regular_wifiOnlyEnforced_failsWifi_noDownloadTask")
    }

    /// Normal open-access download → `clearAndSetCookies` THEN
    /// `addDownloadTask`. The ORDER is the load-bearing contract (cookies
    /// must be cleared before the task is enqueued).
    func test_regular_normal_clearCookiesThenAddDownloadTask() {
        let book = Self.makeBook(identifier: "DSD-NORMAL", relation: .openAccess)
        registry.addBookStub(book, state: .downloadSuccessful)

        dispatcher.processRegularDownload(for: book, withState: .downloadSuccessful, andRequest: nil)

        ContractSnapshot.assert(log, named: "regular_normal_clearCookiesThenAddDownloadTask")
    }

    /// `.SAMLStarted` state + cookies present → routes through
    /// `handleSAMLStartedState`, NOT addDownloadTask.
    func test_regular_samlWithCookies_routesSAMLHandler_noDownloadTask() {
        let book = Self.makeBook(identifier: "DSD-SAML", relation: .openAccess)
        registry.addBookStub(book, state: .SAMLStarted)
        userAccount.setCookies([
            HTTPCookie(properties: [.name: "S", .value: "abc", .domain: "example.com", .path: "/"])!
        ])

        dispatcher.processRegularDownload(for: book, withState: .SAMLStarted, andRequest: nil)

        ContractSnapshot.assert(log, named: "regular_samlWithCookies_routesSAMLHandler_noDownloadTask")
    }

    /// No acquisition URL and no inited request → `logInvalidURLRequest`,
    /// nothing else. Pins the invalid-request dead-end.
    func test_regular_noAcquisitionURL_logsInvalidRequest() {
        let book = Self.makeBookNoAcquisition(identifier: "DSD-NOURL")
        registry.addBookStub(book, state: .downloadSuccessful)

        dispatcher.processRegularDownload(for: book, withState: .downloadSuccessful, andRequest: nil)

        ContractSnapshot.assert(log, named: "regular_noAcquisitionURL_logsInvalidRequest")
    }

    // MARK: - Book builders (deterministic identifiers)

    private static func makeBook(
        identifier: String,
        relation: TPPOPDSAcquisitionRelation,
        distributor: String = "Open Access",
        type: String = ContentTypeEpubZip,
        availability: TPPOPDSAcquisitionAvailability = TPPOPDSAcquisitionAvailabilityUnlimited(),
        indirect: [TPPOPDSIndirectAcquisition] = [],
        url: URL? = nil
    ) -> TPPBook {
        let acquisition = TPPOPDSAcquisition(
            relation: relation,
            type: type,
            hrefURL: url ?? URL(string: "https://example.com/\(identifier)")!,
            indirectAcquisitions: indirect,
            availability: availability
        )
        return makeBook(identifier: identifier, distributor: distributor, acquisitions: [acquisition])
    }

    private static func makeStreamingHTMLBook(identifier: String) -> TPPBook {
        let leaf = TPPOPDSIndirectAcquisition(type: ContentTypeStreamingHTML, indirectAcquisitions: [])
        return makeBook(identifier: identifier, relation: .openAccess,
                        distributor: "Streaming Distributor",
                        type: ContentTypeOPDSPublication, indirect: [leaf])
    }

    private static func makeOverdriveAudiobook(identifier: String) -> TPPBook {
        // .generic relation → no borrow link → shouldDeferOverdriveFulfillment == false.
        // Overdrive audiobook MIME → defaultBookContentType == .audiobook.
        return makeBook(identifier: identifier, relation: .generic,
                        distributor: "Overdrive", type: ContentTypeOverdriveAudiobook)
    }

    private static func makeExpiredBorrowableBook(identifier: String) -> TPPBook {
        let yesterday = Date(timeIntervalSinceNow: -86_400)
        let availability = TPPOPDSAcquisitionAvailabilityLimited(
            copiesAvailable: TPPOPDSAcquisitionAvailabilityCopiesUnknown,
            copiesTotal: TPPOPDSAcquisitionAvailabilityCopiesUnknown,
            since: nil,
            until: yesterday
        )
        return makeBook(identifier: identifier, relation: .borrow, availability: availability)
    }

    private static func makeBookNoAcquisition(identifier: String) -> TPPBook {
        return makeBook(identifier: identifier, distributor: "Open Access", acquisitions: [])
    }

    private static func makeBook(
        identifier: String,
        distributor: String,
        acquisitions: [TPPOPDSAcquisition]
    ) -> TPPBook {
        return TPPBook(
            acquisitions: acquisitions,
            authors: [TPPBookAuthor(authorName: "Author", relatedBooksURL: nil)],
            categoryStrings: ["Fiction"],
            distributor: distributor,
            identifier: identifier,
            imageURL: nil,
            imageThumbnailURL: nil,
            published: Date(timeIntervalSince1970: 0),
            publisher: nil,
            subtitle: nil,
            summary: nil,
            title: "Title-\(identifier)",
            updated: Date(timeIntervalSince1970: 0),
            annotationsURL: nil,
            analyticsURL: nil,
            alternateURL: nil,
            relatedWorksURL: nil,
            previewLink: nil,
            seriesURL: nil,
            revokeURL: nil,
            reportURL: nil,
            timeTrackingURL: nil,
            contributors: [:],
            bookDuration: nil,
            imageCache: MockImageCache()
        )
    }
}

// MARK: - Recording collaborators

/// Records the dispatcher-delegate surface + owns the recording registry.
@MainActor
private final class RecordingDispatcherDelegate: @preconcurrency DownloadStartDispatcherDelegate {
    let log: CallLog
    let bookRegistry: TPPBookRegistryProvider

    init(log: CallLog, registry: TPPBookRegistryProvider) {
        self.log = log
        self.bookRegistry = registry
    }

    func startBorrow(for book: TPPBook, attemptDownload: Bool, borrowCompletion: (() -> Void)?) {
        log.record("startBorrow",
                   args: ["bookId": book.identifier,
                          "attemptDownload": "\(attemptDownload)",
                          "hasCompletion": "\(borrowCompletion != nil)"])
    }

    func addDownloadTask(with request: URLRequest, book: TPPBook) {
        log.record("addDownloadTask",
                   args: ["bookId": book.identifier,
                          "hasURL": "\(request.url != nil)"])
    }

    func clearAndSetCookies() {
        log.record("clearAndSetCookies")
    }

    func handleSAMLStartedState(for book: TPPBook, withRequest request: URLRequest, cookies: [HTTPCookie]) {
        log.record("handleSAMLStartedState",
                   args: ["bookId": book.identifier, "cookieCount": "\(cookies.count)"])
    }

    func failWithWifiRequired(for book: TPPBook) {
        log.record("failWithWifiRequired", args: ["bookId": book.identifier])
    }

    func logInvalidURLRequest(for book: TPPBook, withState state: TPPBookState, url: URL?, request: URLRequest?) {
        log.record("logInvalidURLRequest",
                   args: ["bookId": book.identifier,
                          "state": "\(state.stringValue())",
                          "hasURL": "\(url != nil)"])
    }
}

/// Registry double that records `addBook` + `setState` into the CallLog and
/// keeps enough real storage that the dispatcher's `book(forIdentifier:)`
/// re-resolution returns the seeded book. Fixture seeding goes through
/// `addBookStub` (unrecorded) so setup doesn't pollute the contract.
private final class RecordingDispatcherRegistry: TPPBookRegistryMock {
    let log: CallLog
    init(log: CallLog) {
        self.log = log
        super.init()
    }

    func addBookStub(_ book: TPPBook, state: TPPBookState) {
        super.addBook(book, location: nil, state: state,
                      fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)
    }

    override func addBook(_ book: TPPBook,
                          location: TPPBookLocation?,
                          state: TPPBookState,
                          fulfillmentId: String?,
                          readiumBookmarks: [TPPReadiumBookmark]?,
                          genericBookmarks: [TPPBookLocation]?) {
        log.record("registry.addBook",
                   args: ["bookId": book.identifier, "state": "\(state.stringValue())"])
        super.addBook(book, location: location, state: state,
                      fulfillmentId: fulfillmentId, readiumBookmarks: readiumBookmarks,
                      genericBookmarks: genericBookmarks)
    }

    override func setState(_ state: TPPBookState, for bookIdentifier: String) {
        log.record("registry.setState",
                   args: ["bookId": bookIdentifier, "state": "\(state.stringValue())"])
        super.setState(state, for: bookIdentifier)
    }
}
