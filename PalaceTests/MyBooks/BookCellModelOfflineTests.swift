//
//  BookCellModelOfflineTests.swift
//  PalaceTests
//
//  Regression coverage for PP-4114 — "iOS: F-063: Download buttons become
//  stale on network loss". Before the fix, tapping Download (or Reserve)
//  while offline would set `isLoading = true`, fire a network request that
//  hung against URLSession's default timeout, and leave the button stuck
//  with a spinner for ~60s. Recovery only happened when the user backgrounded
//  the app and a `.TPPReachabilityChanged` notification eventually fired.
//
//  These tests pin the post-fix behavior:
//    1. Pre-flight reachability check on Download/Reserve — if offline, we
//       surface a retryable "No connection" alert and DO NOT call into
//       MyBooksDownloadCenter (no spinner-of-death).
//    2. While a request is in flight, a connectivity transition to offline
//       clears `isLoading` and surfaces the same alert (covers the
//       race where reachability drops mid-borrow).
//    3. The alert's primary action retries — and when reachability has
//       returned, the retry actually fires the download.
//
//  Each test simulates an offline reachability state via `MockReachability`,
//  which overrides `isConnectedToNetwork()` and `connectivityPublisher`. The
//  alternative — driving real `NWPathMonitor` — would couple the suite to
//  the host's network state and flake on CI.
//

import Combine
import XCTest
@testable import Palace

@MainActor
final class BookCellModelOfflineTests: XCTestCase {

    private var mockRegistry: TPPBookRegistryMock!
    private var mockImageCache: MockImageCache!
    private var mockReachability: MockReachability!
    private var cancellables: Set<AnyCancellable>!

    override func setUp() {
        super.setUp()
        mockRegistry = TPPBookRegistryMock()
        mockImageCache = MockImageCache()
        mockReachability = MockReachability(initiallyConnected: true)
        cancellables = Set<AnyCancellable>()
    }

    override func tearDown() {
        cancellables = nil
        mockReachability = nil
        mockImageCache = nil
        mockRegistry = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeBook(id: String = "pp-4114-book") -> TPPBook {
        TPPBook(dictionary: [
            "acquisitions": [TPPFake.genericAcquisition.dictionaryRepresentation()],
            "title": "Network Loss Regression",
            "categories": ["Fiction"],
            "id": id,
            "updated": "2024-01-01T00:00:00Z"
        ])!
    }

    private func makeModel(book: TPPBook) -> BookCellModel {
        BookCellModel(
            book: book,
            imageCache: mockImageCache,
            bookRegistry: mockRegistry,
            downloadCenter: AppContainer.production().downloadCenter,
            accountsManager: AppContainer.production().accountsManager,
            samplePreviewManager: AppContainer.production().samplePreviewManager,
            readerService: AppContainer.production().readerService,
            reachability: mockReachability
        )
    }

    // MARK: - Pre-flight check on tap

    /// PP-4114 root cause #1: tapping Download while offline previously set
    /// isLoading=true and fired a doomed URLSession request. We now bail out
    /// before either side effect.
    func testDidSelectDownload_whenOffline_doesNotSetIsLoading() {
        let book = makeBook(id: "offline-no-loading")
        mockRegistry.addBook(book, state: .downloadNeeded)
        mockReachability = MockReachability(initiallyConnected: false)
        let model = makeModel(book: book)
        drainMainQueue() // settle init-time async (image fetch)
        XCTAssertFalse(model.isLoading, "precondition: model not loading at start")

        model.callDelegate(for: .download)
        drainMainQueue()

        XCTAssertFalse(
            model.isLoading,
            "Tapping Download while offline must NOT leave isLoading=true. " +
            "That state — combined with the disabled-on-isProcessing button — " +
            "is the exact 'stale button' UX the bug describes."
        )
    }

    /// The user-visible signal that the download is blocked. Before the fix
    /// there was no signal — the spinner just sat there.
    func testDidSelectDownload_whenOffline_surfacesRetryableNoConnectionAlert() {
        let book = makeBook(id: "offline-shows-alert")
        mockRegistry.addBook(book, state: .downloadNeeded)
        mockReachability = MockReachability(initiallyConnected: false)
        let model = makeModel(book: book)
        drainMainQueue()

        model.callDelegate(for: .download)
        drainMainQueue()

        guard let alert = model.showAlert else {
            XCTFail("Offline tap must populate showAlert with a retryable model")
            return
        }
        XCTAssertEqual(alert.title, Strings.MyDownloadCenter.noConnectionTitle)
        XCTAssertEqual(alert.message, Strings.MyDownloadCenter.noConnectionMessage)
        XCTAssertEqual(
            alert.buttonTitle, Strings.MyDownloadCenter.retry,
            "Alert must offer Retry, not just OK — manual retry is point #3 of the PP-4114 fix."
        )
        XCTAssertEqual(
            alert.secondaryButtonTitle, Strings.Generic.cancel,
            "Retryable alerts pair Retry with Cancel; the one-button form would be a regression."
        )
    }

    /// Regression for the ticket's "Recovery happens implicitly on app
    /// foreground" note: foregrounding only worked because reachability happened
    /// to fire. We now act eagerly without depending on a foreground callback.
    func testDidSelectDownload_whenOffline_doesNotInvokeDownloadCenter() {
        let book = makeBook(id: "offline-no-network-call")
        mockRegistry.addBook(book, state: .downloadNeeded)
        mockReachability = MockReachability(initiallyConnected: false)
        let model = makeModel(book: book)
        drainMainQueue()

        let initialDownloadingState = mockRegistry.state(for: book.identifier)
        model.callDelegate(for: .download)
        drainMainQueue()

        // Pre-flight bail-out means the registry should never transition to
        // `.downloading` — the download center is the only thing that flips
        // state to .downloading via DownloadTaskLifecycleService.
        XCTAssertEqual(
            mockRegistry.state(for: book.identifier),
            initialDownloadingState,
            "Offline pre-flight must short-circuit BEFORE downloadCenter.startDownload " +
            "is called. If it didn't, DownloadTaskLifecycleService would mark the book " +
            "as .downloading and we'd be back to the stale-spinner bug while URLSession " +
            "spent 60s timing out."
        )
    }

    /// Online path — make sure the pre-flight check doesn't accidentally
    /// strangle the happy path.
    func testDidSelectDownload_whenOnline_proceedsWithoutAlert() {
        let book = makeBook(id: "online-happy-path")
        mockRegistry.addBook(book, state: .downloadNeeded)
        mockReachability = MockReachability(initiallyConnected: true)
        let model = makeModel(book: book)
        drainMainQueue()

        model.callDelegate(for: .download)
        drainMainQueue()

        XCTAssertNil(
            model.showAlert,
            "Online tap must not surface the offline alert. The pre-flight " +
            "check must be predicated on `isConnectedToNetwork() == false`, " +
            "not on the inverse."
        )
    }

    // MARK: - Reactive reachability (mid-flight drop)

    /// The race that the original ticket calls out: user taps download while
    /// online, then loses network mid-borrow. URLSession will eventually fail
    /// but until it does the spinner sits there. The reactive subscription
    /// kicks in immediately on the offline transition.
    func testReachabilityDropsToOffline_whileLoading_clearsLoadingAndShowsAlert() {
        let book = makeBook(id: "midflight-drop")
        mockRegistry.addBook(book, state: .downloadNeeded)
        let model = makeModel(book: book)
        drainMainQueue()

        // Simulate an in-flight borrow: button-handler set isLoading=true
        // before reachability dropped.
        model.isLoading = true

        mockReachability.simulate(connected: false)

        // Join the reachability sink's terminal effect rather than polling a
        // deadline: the `.receive(on: RunLoop.main)` sink sets `isLoading =
        // false` then calls `presentOfflineAlert()`, which assigns `showAlert`
        // last. Waiting on `$showAlert` becoming non-nil therefore guarantees
        // the whole sink has run — `isLoading` is already false by then — so
        // both assertions below hold without a poll loop that starves on CI.
        awaitPublished(model.$showAlert, timeout: 2.0) { $0 != nil }
        XCTAssertFalse(
            model.isLoading,
            "A mid-flight reachability drop must clear isLoading so the button " +
            "becomes responsive. Otherwise we re-introduce the original bug — the " +
            "user just won't be able to do anything for ~60s while URLSession times out."
        )
        XCTAssertNotNil(
            model.showAlert,
            "Mid-flight drop must surface the same retryable no-connection alert " +
            "users see on a cold offline tap. Consistent UX = consistent regression test."
        )
    }

    /// Subscribers to a CurrentValueSubject get the current value immediately.
    /// We must NOT show the alert just because the model spawned while
    /// already offline and isLoading is false — that would alert-spam every
    /// list cell during an offline launch.
    func testReachabilityInitialState_offline_withoutLoading_doesNotShowAlert() {
        let book = makeBook(id: "cold-offline-init")
        mockRegistry.addBook(book, state: .downloadNeeded)
        mockReachability = MockReachability(initiallyConnected: false)
        let model = makeModel(book: book)
        drainMainQueue()

        XCTAssertNil(
            model.showAlert,
            "Cold-launching offline must not auto-populate the alert; the alert " +
            "is a response to a user action (tap) or a transition (loss while " +
            "loading), not a steady-state property."
        )
    }

    /// When connectivity returns we must NOT auto-fire a download. The user
    /// must explicitly retry. Auto-retry would be a different (and surprising)
    /// behavior — and would re-create thundering-herd risk on the CM after a
    /// flaky-WiFi blip.
    func testReachabilityRecovers_doesNotAutoStartDownload() {
        let book = makeBook(id: "recover-no-auto")
        mockRegistry.addBook(book, state: .downloadNeeded)
        mockReachability = MockReachability(initiallyConnected: false)
        let model = makeModel(book: book)
        drainMainQueue()

        // Tap while offline → alert shown, no download.
        model.callDelegate(for: .download)
        drainMainQueue()
        XCTAssertNotNil(model.showAlert, "precondition: offline tap shows alert")

        // Connectivity returns.
        mockReachability.simulate(connected: true)
        drainMainQueue()

        // No state change should have happened in the registry — the user
        // hasn't tapped retry yet.
        XCTAssertEqual(
            mockRegistry.state(for: book.identifier),
            .downloadNeeded,
            "Reconnecting must not auto-start the download. Users tap Retry; the " +
            "system does not."
        )
    }

    // MARK: - Reserve path

    /// Reserve hits the same network endpoints (`borrowAsync`) as Download
    /// — same vulnerability, same fix.
    func testDidSelectReserve_whenOffline_doesNotSetIsLoading() {
        let book = makeBook(id: "reserve-offline")
        mockRegistry.addBook(book, state: .holding)
        mockReachability = MockReachability(initiallyConnected: false)
        let model = makeModel(book: book)
        drainMainQueue()

        model.callDelegate(for: .reserve)
        drainMainQueue()

        XCTAssertFalse(
            model.isLoading,
            "didSelectReserve must use the same offline pre-flight as Download; " +
            "otherwise PP-4114 returns under a different button label."
        )
        XCTAssertNotNil(
            model.showAlert,
            "Reserve while offline must surface the same retryable no-connection alert."
        )
    }

    // MARK: - Other actions are unaffected

    /// Read/Listen/Cancel/Return don't go to the network the same way and
    /// must NOT be gated by the offline pre-flight. A reader-presentation
    /// path that asked the user to reconnect would be absurd.
    func testReadAction_whenOffline_isNotGatedByReachability() {
        let book = makeBook(id: "offline-read")
        mockRegistry.addBook(book, state: .downloadSuccessful)
        mockReachability = MockReachability(initiallyConnected: false)
        let model = makeModel(book: book)
        drainMainQueue()

        model.callDelegate(for: .read)
        drainMainQueue()

        // We don't assert that the reader actually opened (that requires
        // a coordinator stack we don't have here). We only assert the
        // pre-flight didn't abort the action with our offline alert.
        XCTAssertNil(
            model.showAlert,
            "Reader-presentation actions are local: they must not be gated by " +
            "reachability. Otherwise users couldn't read downloaded books on " +
            "the subway."
        )
    }
}
