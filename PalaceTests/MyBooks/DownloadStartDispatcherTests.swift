//
//  DownloadStartDispatcherTests.swift
//  PalaceTests
//
//  Coverage for the start-download dispatch flow lifted out of MBDC:
//  processUnregisteredState (state seed), processDownloadWithCredentials
//  (route to borrow / regular), and processRegularDownload (re-borrow,
//  auto-borrow, Wi-Fi guard, request resolution, SAML branch,
//  addDownloadTask handoff).
//

import XCTest
import Combine
import PalaceCatalog
@testable import Palace

@MainActor
final class DownloadStartDispatcherTests: XCTestCase {

    private var registry: TPPBookRegistryMock!
    private var userAccount: TPPUserAccountMock!
    private var settings: TPPSettings!
    private var isOnWiFiValue = true
    private var memoryMonitor: MemoryPressureMonitor!
    private var spyDelegate: SpyDispatcherDelegate!
    private var dispatcher: DownloadStartDispatcher!

    override func setUpWithError() throws {
        registry = TPPBookRegistryMock()
        userAccount = TPPUserAccountMock()
        settings = TPPSettings()
        settings.downloadOnlyOnWiFi = false
        isOnWiFiValue = true
        memoryMonitor = MemoryPressureMonitor.shared
        spyDelegate = SpyDispatcherDelegate(registry: registry)
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
            userAccountProvider: { [unowned self] in self.userAccount }
        )
        dispatcher = DownloadStartDispatcher(
            userAccountProvider: { [unowned self] in self.userAccount },
            settings: settings,
            isOnWiFi: { [unowned self] in self.isOnWiFiValue },
            memoryPressureMonitor: memoryMonitor,
            overdriveHandler: overdrive
        )
        #else
        dispatcher = DownloadStartDispatcher(
            userAccountProvider: { [unowned self] in self.userAccount },
            settings: settings,
            isOnWiFi: { [unowned self] in self.isOnWiFiValue },
            memoryPressureMonitor: memoryMonitor
        )
        #endif
        dispatcher.delegate = spyDelegate
    }

    override func tearDownWithError() throws {
        registry = nil
        userAccount = nil
        settings = nil
        memoryMonitor = nil
        spyDelegate = nil
        dispatcher = nil
    }

    // MARK: - Helpers

    private func makeBook(
        relation: TPPOPDSAcquisitionRelation,
        distributor: String = "Open Access",
        url: URL = URL(string: "https://example.com/payload")!
    ) -> TPPBook {
        let acquisition = TPPOPDSAcquisition(
            relation: relation,
            type: "application/epub+zip",
            hrefURL: url,
            indirectAcquisitions: [],
            availability: TPPOPDSAcquisitionAvailabilityUnlimited()
        )
        return TPPBook(
            acquisitions: [acquisition],
            authors: [TPPBookAuthor(authorName: "Author", relatedBooksURL: nil)],
            categoryStrings: ["Fiction"],
            distributor: distributor,
            identifier: UUID().uuidString,
            imageURL: nil,
            imageThumbnailURL: nil,
            published: Date(),
            publisher: nil,
            subtitle: nil,
            summary: nil,
            title: "Test Book",
            updated: Date(),
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

    private func openAccessBook() -> TPPBook { makeBook(relation: .openAccess) }
    private func borrowableBook() -> TPPBook { makeBook(relation: .borrow) }
    private func genericBook() -> TPPBook { makeBook(relation: .generic) }

    // MARK: - processUnregisteredState

    func testProcessUnregisteredState_openAccessBook_registersAndReturnsDownloadNeeded() {
        let book = openAccessBook()

        let state = dispatcher.processUnregisteredState(for: book, location: nil, loginRequired: false)

        XCTAssertEqual(state, .downloadNeeded)
        XCTAssertEqual(spyDelegate.addBookCalls.map { $0.identifier }, [book.identifier])
    }

    func testProcessUnregisteredState_loginNotRequired_noBorrowLink_registersAsDownloadNeeded() {
        let book = openAccessBook()

        let state = dispatcher.processUnregisteredState(for: book, location: nil, loginRequired: false)

        XCTAssertEqual(state, .downloadNeeded)
    }

    func testProcessUnregisteredState_hasBorrowLink_doesNotRegister() {
        let book = borrowableBook()

        let state = dispatcher.processUnregisteredState(for: book, location: nil, loginRequired: true)

        XCTAssertEqual(state, .unregistered, "Books with a borrow relation must NOT auto-register as downloadNeeded")
        XCTAssertTrue(spyDelegate.addBookCalls.isEmpty)
    }

    func testProcessUnregisteredState_loginRequiredNoOpenAccess_returnsUnregistered() {
        let book = genericBook()

        let state = dispatcher.processUnregisteredState(for: book, location: nil, loginRequired: true)

        // No borrow link, but no open-access acquisition either, AND loginRequired true.
        // Should NOT register — falls through to .unregistered.
        XCTAssertEqual(state, .unregistered)
        XCTAssertTrue(spyDelegate.addBookCalls.isEmpty)
    }

    // MARK: - processDownloadWithCredentials routing

    func testProcessDownloadWithCredentials_unregistered_routesToStartBorrow() {
        let book = borrowableBook()

        dispatcher.processDownloadWithCredentials(for: book, withState: .unregistered, andRequest: nil)

        XCTAssertEqual(spyDelegate.startBorrowCalls.count, 1)
        XCTAssertEqual(spyDelegate.startBorrowCalls.first?.book.identifier, book.identifier)
        XCTAssertTrue(spyDelegate.addDownloadTaskCalls.isEmpty)
    }

    func testProcessDownloadWithCredentials_holding_routesToStartBorrow() {
        let book = borrowableBook()

        dispatcher.processDownloadWithCredentials(for: book, withState: .holding, andRequest: nil)

        XCTAssertEqual(spyDelegate.startBorrowCalls.count, 1)
        XCTAssertEqual(spyDelegate.startBorrowCalls.first?.book.identifier, book.identifier)
    }

    // MARK: - processRegularDownload branches

    func testProcessRegularDownload_wifiOnlyEnforced_failsAndDoesNotStartDownload() {
        settings.downloadOnlyOnWiFi = true
        isOnWiFiValue = false
        let book = openAccessBook()
        registry.addBook(book, location: nil, state: .downloadNeeded, fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)
        // (registry already populated; addBookCalls computed from registry contents)  // setup noise — clear it

        dispatcher.processRegularDownload(for: book, withState: .downloadNeeded, andRequest: nil)

        XCTAssertEqual(spyDelegate.failWithWifiCalls.map { $0.identifier }, [book.identifier])
        XCTAssertTrue(spyDelegate.addDownloadTaskCalls.isEmpty)
    }

    func testProcessRegularDownload_normalOpenAccess_callsAddDownloadTaskWithBearerRequest() {
        let book = openAccessBook()
        registry.addBook(book, location: nil, state: .downloadNeeded, fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)
        // (registry already populated; addBookCalls computed from registry contents)

        dispatcher.processRegularDownload(for: book, withState: .downloadSuccessful, andRequest: nil)

        XCTAssertEqual(spyDelegate.clearAndSetCookiesCalls, 1, "Cookies must be cleared before the task is added")
        XCTAssertEqual(spyDelegate.addDownloadTaskCalls.count, 1)
        XCTAssertEqual(spyDelegate.addDownloadTaskCalls.first?.book.identifier, book.identifier)
        XCTAssertNotNil(spyDelegate.addDownloadTaskCalls.first?.request.url)
    }

    func testProcessRegularDownload_initedRequestPassedThrough_overridesAcquisitionURL() {
        let book = openAccessBook()
        registry.addBook(book, location: nil, state: .downloadNeeded, fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)
        // (registry already populated; addBookCalls computed from registry contents)
        let injected = URLRequest(url: URL(string: "https://injected.example/payload")!)

        dispatcher.processRegularDownload(for: book, withState: .downloadSuccessful, andRequest: injected)

        XCTAssertEqual(
            spyDelegate.addDownloadTaskCalls.first?.request.url?.absoluteString,
            "https://injected.example/payload",
            "An init-supplied request must take priority over the book's acquisition URL"
        )
    }

    func testProcessRegularDownload_samlState_routesThroughSAMLHandler() {
        let book = openAccessBook()
        registry.addBook(book, location: nil, state: .SAMLStarted, fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)
        // (registry already populated; addBookCalls computed from registry contents)
        userAccount.setCookies([HTTPCookie(properties: [.name: "S", .value: "abc", .domain: "example.com", .path: "/"])!])

        dispatcher.processRegularDownload(for: book, withState: .SAMLStarted, andRequest: nil)

        XCTAssertEqual(spyDelegate.samlHandlerCalls.map { $0.book.identifier }, [book.identifier])
        XCTAssertTrue(spyDelegate.addDownloadTaskCalls.isEmpty, "SAML branch must NOT call addDownloadTask")
    }

    func testProcessRegularDownload_downloadNeededWithBorrowLink_triggersAutoBorrow() {
        let book = borrowableBook()
        registry.addBook(book, location: nil, state: .downloadNeeded, fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)
        // (registry already populated; addBookCalls computed from registry contents)

        dispatcher.processRegularDownload(for: book, withState: .downloadNeeded, andRequest: nil)

        XCTAssertEqual(spyDelegate.startBorrowCalls.count, 1, "downloadNeeded + borrow link must auto-borrow")
        XCTAssertTrue(spyDelegate.addDownloadTaskCalls.isEmpty, "Auto-borrow branch must NOT addDownloadTask itself")
    }
}

// MARK: - SpyDispatcherDelegate

@MainActor
private final class SpyDispatcherDelegate: DownloadStartDispatcherDelegate {
    let bookRegistry: TPPBookRegistryProvider
    init(registry: TPPBookRegistryProvider) { self.bookRegistry = registry }

    /// Surfaces the books currently in the registry. The dispatcher's
    /// `processUnregisteredState` calls `bookRegistry.addBook(...)` directly,
    /// not into this spy — so we query the registry mock's internal state
    /// instead of recording invocations.
    var addBookCalls: [TPPBook] {
        guard let mock = bookRegistry as? TPPBookRegistryMock else { return [] }
        return mock.registry.values.map { $0.book }
    }
    private(set) var startBorrowCalls: [(book: TPPBook, attemptDownload: Bool)] = []
    private(set) var addDownloadTaskCalls: [(request: URLRequest, book: TPPBook)] = []
    private(set) var clearAndSetCookiesCalls = 0
    private(set) var samlHandlerCalls: [(book: TPPBook, request: URLRequest, cookies: [HTTPCookie])] = []
    private(set) var failWithWifiCalls: [TPPBook] = []
    private(set) var logInvalidCalls: [(book: TPPBook, state: TPPBookState, url: URL?)] = []

    func startBorrow(for book: TPPBook, attemptDownload: Bool, borrowCompletion: (() -> Void)?) {
        startBorrowCalls.append((book, attemptDownload))
    }
    func addDownloadTask(with request: URLRequest, book: TPPBook) {
        addDownloadTaskCalls.append((request, book))
    }
    func clearAndSetCookies() { clearAndSetCookiesCalls += 1 }
    func handleSAMLStartedState(for book: TPPBook, withRequest request: URLRequest, cookies: [HTTPCookie]) {
        samlHandlerCalls.append((book, request, cookies))
    }
    func failWithWifiRequired(for book: TPPBook) { failWithWifiCalls.append(book) }
    func logInvalidURLRequest(for book: TPPBook, withState state: TPPBookState, url: URL?, request: URLRequest?) {
        logInvalidCalls.append((book, state, url))
    }
}

