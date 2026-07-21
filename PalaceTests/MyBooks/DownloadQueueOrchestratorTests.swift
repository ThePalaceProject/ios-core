//
//  DownloadQueueOrchestratorTests.swift
//  PalaceTests
//
//  Coverage for DownloadQueueOrchestrator: the pending-queue policy
//  extracted from MyBooksDownloadCenter. enqueuePending must mark the
//  book .downloading in the registry (UI-feedback fix), append to the
//  coordinator's pending queue, and broadcast the
//  TPPMyBooksDownloadCenterDidChange notification on the injected center.
//  schedulePendingStartsAsync must respect the active-cap, FIFO-dequeue
//  up to remaining capacity, and fan out via the delegate; it must
//  no-op at-cap and on an empty queue. The sync wrapper must drive the
//  same delegate path.
//

import XCTest
@testable import Palace

@MainActor
final class DownloadQueueOrchestratorTests: XCTestCase {

    private var bookRegistry: TPPBookRegistryMock!
    private var stateManager: DownloadStateManager!
    private var notificationCenter: NotificationCenter!
    private var spyDelegate: SpyDelegate!
    private var orchestrator: DownloadQueueOrchestrator!

    override func setUpWithError() throws {
        try super.setUpWithError()
        bookRegistry = TPPBookRegistryMock()
        stateManager = DownloadStateManager()
        notificationCenter = NotificationCenter()
        spyDelegate = SpyDelegate()
        orchestrator = DownloadQueueOrchestrator(
            bookRegistry: bookRegistry,
            stateManager: stateManager,
            notificationCenter: notificationCenter
        )
        orchestrator.delegate = spyDelegate
    }

    override func tearDownWithError() throws {
        bookRegistry = nil
        stateManager = nil
        notificationCenter = nil
        spyDelegate = nil
        orchestrator = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    /// Registers `book` in the mock registry so subsequent setState() calls
    /// actually persist (the mock's setState uses optional chaining and
    /// silently drops writes for unknown identifiers).
    private func register(_ book: TPPBook, state: TPPBookState = .unregistered) {
        bookRegistry.addBook(book, state: state)
    }

    /// Wraps the shared `awaitConditionAsync` helper. `file`/`line`
    /// forwarded so timeout XCTFail blames the call site.
    private func waitForAsync(
        timeout: TimeInterval = 10.0,
        file: StaticString = #file,
        line: UInt = #line,
        _ predicate: @escaping () -> Bool
    ) async {
        await awaitConditionAsync(timeout: timeout, file: file, line: line, predicate)
    }

    /// Marks `book` active in the coordinator so `activeCount` reflects an
    /// in-flight download without needing a real URLSessionDownloadTask.
    private func markActive(_ book: TPPBook) async {
        await stateManager.downloadCoordinator.registerStart(identifier: book.identifier)
    }

    // MARK: - enqueuePending

    func testEnqueuePending_marksBookAsDownloadingInRegistry() async {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        register(book, state: .unregistered)

        // enqueuePending sets .downloading SYNCHRONOUSLY (before the Task hop)
        // so the borrow button shows feedback immediately. Assert directly —
        // no wait needed, and no dependency on the async coordinator hop.
        orchestrator.enqueuePending(book)

        XCTAssertEqual(bookRegistry.state(for: book.identifier), .downloading,
                       "enqueuePending must immediately set state to .downloading so the borrow button shows feedback while parked behind the cap")
    }

    func testEnqueuePending_appendsToCoordinatorPendingQueue() async {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        register(book)

        // Join the actor-hopping enqueue directly instead of polling the
        // coordinator's queueCount against a wall-clock deadline (which
        // starves under CI oversubscription). enqueuePendingAsync runs the
        // exact same coordinator append + notification the fire-and-forget
        // Task does.
        await orchestrator.enqueuePendingAsync(book)
        let observedCount = await stateManager.downloadCoordinator.queueCount

        XCTAssertEqual(observedCount, 1,
                       "enqueuePending must append the book onto the DownloadCoordinator pending queue")
    }

    func testEnqueuePending_postsDidChangeNotificationOnInjectedCenter() async {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        register(book)

        var observedCount = 0
        let token = notificationCenter.addObserver(
            forName: .TPPMyBooksDownloadCenterDidChange,
            object: nil,
            queue: nil
        ) { _ in
            observedCount += 1
        }
        defer { notificationCenter.removeObserver(token) }

        // The DidChange post lands via runOnMainAsync (a `Task { @MainActor }`),
        // which drainMainQueueAsync does NOT flush. Synchronize on the post
        // itself with an expectation the SUT fulfills — prompt-firing, so it
        // completes the instant the notification fires (not a deadline-poll).
        let posted = XCTNSNotificationExpectation(
            name: .TPPMyBooksDownloadCenterDidChange,
            object: nil,
            notificationCenter: notificationCenter
        )
        await orchestrator.enqueuePendingAsync(book)
        await fulfillment(of: [posted], timeout: 5.0)

        XCTAssertEqual(observedCount, 1,
                       "enqueuePending must post TPPMyBooksDownloadCenterDidChange so MyBooks/detail/cell views refresh")
    }

    func testEnqueuePending_doesNotPostOnDefaultCenter_whenInjectedCenterDiffers() async {
        // Regression guard: the orchestrator must use the *injected*
        // notificationCenter, not NotificationCenter.default. If someone
        // swaps the property to .default the rest of the suite still
        // appears green — this test catches that drift.
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        register(book)

        var defaultCenterCount = 0
        let token = NotificationCenter.default.addObserver(
            forName: .TPPMyBooksDownloadCenterDidChange,
            object: nil,
            queue: nil
        ) { _ in
            defaultCenterCount += 1
        }
        defer { NotificationCenter.default.removeObserver(token) }

        // Also observe the injected center so we can synchronize on the
        // post landing (rather than guessing how long the Task hop takes).
        var injectedCount = 0
        let injectedToken = notificationCenter.addObserver(
            forName: .TPPMyBooksDownloadCenterDidChange,
            object: nil,
            queue: nil
        ) { _ in
            injectedCount += 1
        }
        defer { notificationCenter.removeObserver(injectedToken) }

        // Synchronize on the post via an expectation on the injected center —
        // prompt-firing (fulfills the instant the SUT posts), not a deadline
        // poll. This also lets the runOnMainAsync `Task { @MainActor }` hop
        // (which drainMainQueueAsync can't flush) complete deterministically.
        let posted = XCTNSNotificationExpectation(
            name: .TPPMyBooksDownloadCenterDidChange,
            object: nil,
            notificationCenter: notificationCenter
        )
        await orchestrator.enqueuePendingAsync(book)
        await fulfillment(of: [posted], timeout: 5.0)

        XCTAssertEqual(injectedCount, 1, "sanity: injected center received the post")
        XCTAssertEqual(defaultCenterCount, 0,
                       "Notifications must be routed through the injected center; .default must NOT see this post when a custom center is injected")
    }

    // MARK: - schedulePendingStartsAsync — capacity gating

    func testSchedulePendingStartsAsync_atCap_doesNotDequeueOrCallDelegate() async {
        stateManager.maxConcurrentDownloads = 2
        let active1 = TPPBookMocker.mockBook(distributorType: .EpubZip)
        let active2 = TPPBookMocker.mockBook(distributorType: .EpubZip)
        let pending = TPPBookMocker.mockBook(distributorType: .EpubZip)
        await markActive(active1)
        await markActive(active2)
        await stateManager.downloadCoordinator.enqueuePending(pending)

        await orchestrator.schedulePendingStartsAsync()

        XCTAssertEqual(spyDelegate.startCalls.count, 0,
                       "At-cap (active=2, max=2): scheduler must NOT pull from the queue")
        let remainingQueue = await stateManager.downloadCoordinator.queueCount
        XCTAssertEqual(remainingQueue, 1,
                       "At-cap: pending book must remain on the queue, not be dropped")
    }

    func testSchedulePendingStartsAsync_emptyQueue_doesNotCallDelegate() async {
        stateManager.maxConcurrentDownloads = 4
        // No actives, no pending — nothing to do.

        await orchestrator.schedulePendingStartsAsync()

        XCTAssertEqual(spyDelegate.startCalls.count, 0,
                       "Empty queue must early-return without invoking the delegate")
    }

    func testSchedulePendingStartsAsync_underCap_dequeuesUpToRemainingCapacityInFIFOOrder() async {
        stateManager.maxConcurrentDownloads = 3
        let active = TPPBookMocker.mockBook(distributorType: .EpubZip)
        await markActive(active)

        // Enqueue 4 books — capacity is 3-1 = 2, so only the first 2 should fire.
        let p1 = TPPBookMocker.mockBook(distributorType: .EpubZip)
        let p2 = TPPBookMocker.mockBook(distributorType: .EpubZip)
        let p3 = TPPBookMocker.mockBook(distributorType: .EpubZip)
        let p4 = TPPBookMocker.mockBook(distributorType: .EpubZip)
        for book in [p1, p2, p3, p4] {
            await stateManager.downloadCoordinator.enqueuePending(book)
        }

        await orchestrator.schedulePendingStartsAsync()

        XCTAssertEqual(spyDelegate.startCalls.map { $0.book.identifier },
                       [p1.identifier, p2.identifier],
                       "Must dequeue exactly capacity (=2) books in FIFO order — not 1, not 3, not LIFO")
        let queueRemaining = await stateManager.downloadCoordinator.queueCount
        XCTAssertEqual(queueRemaining, 2,
                       "Two books must remain on the queue for the next capacity opening")
    }

    func testSchedulePendingStartsAsync_passesNilRequestToDelegate() async {
        // The orchestrator hands off to startDownloadAsync(for:withRequest:)
        // with `nil` — the start path will resolve the request itself. If
        // someone refactors and silently passes a stale request, this fails.
        stateManager.maxConcurrentDownloads = 2
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        await stateManager.downloadCoordinator.enqueuePending(book)

        await orchestrator.schedulePendingStartsAsync()

        XCTAssertEqual(spyDelegate.startCalls.count, 1)
        XCTAssertNil(spyDelegate.startCalls.first?.request,
                     "Orchestrator must pass nil request — the start path resolves the URL from the registry, not from a cached request")
    }

    // MARK: - schedulePendingStartsIfPossible (sync wrapper)

    func testSchedulePendingStartsIfPossible_drivesDelegateAsynchronously() async {
        stateManager.maxConcurrentDownloads = 2
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        await stateManager.downloadCoordinator.enqueuePending(book)

        // UNJOINABLE: schedulePendingStartsIfPossible() is an intentional
        // fire-and-forget `Task { await schedulePendingStartsAsync() }` that
        // returns no handle — this test's whole point is to prove the sync
        // wrapper is wired to the delegate path (guards against it being
        // silently neutered), so we must exercise the wrapper itself, not the
        // async sibling. No seam to await; the poll stays. The delegate call
        // is cheap and lands within one Task hop, so starvation risk is low.
        orchestrator.schedulePendingStartsIfPossible()
        await waitForAsync { [self] in self.spyDelegate.startCalls.count > 0 }

        XCTAssertEqual(spyDelegate.startCalls.map { $0.book.identifier },
                       [book.identifier],
                       "schedulePendingStartsIfPossible must reach the same delegate path as the async variant — guards against the wrapper being silently neutered")
    }
}

// MARK: - Test fakes

private final class SpyDelegate: DownloadQueueOrchestratorDelegate {
    private(set) var startCalls: [(book: TPPBook, request: URLRequest?)] = []

    func startDownloadAsync(for book: TPPBook, withRequest request: URLRequest?) async {
        startCalls.append((book, request))
    }
}
