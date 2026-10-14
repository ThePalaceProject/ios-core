//
//  OfflineQueueCoordinatorTests.swift
//  PalaceTests
//
//  Reliability WS-C — OfflineQueueCoordinator.
//
//  INV-8 (idempotency): a queued action deduped by bookID+type is applied
//  at most once; a partially-succeeded action must not double-apply. Also
//  pins the dispatch routing (type -> handler) and the failure-rollback
//  path (a genuine failure is retryable).
//

import Combine
import XCTest
@testable import Palace
import PalaceBookModel

@MainActor
final class OfflineQueueCoordinatorTests: XCTestCase {

    // MARK: - Fakes

    /// Records per-type invocation counts; each handler returns a
    /// configurable success value.
    private final class HandlerSpy: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var returnIDs: [String] = []
        private(set) var borrowIDs: [String] = []
        private(set) var holdIDs: [String] = []
        private(set) var cancelHoldIDs: [String] = []
        var returnSucceeds = true
        var borrowSucceeds = true

        func handlers() -> OfflineQueueCoordinator.Handlers {
            OfflineQueueCoordinator.Handlers(
                performReturn: { [weak self] action in
                    self?.lock.withLock { self?.returnIDs.append(action.bookID) }
                    return self?.returnSucceeds ?? false
                },
                performBorrow: { [weak self] action in
                    self?.lock.withLock { self?.borrowIDs.append(action.bookID) }
                    return self?.borrowSucceeds ?? false
                },
                performHold: { [weak self] action in
                    self?.lock.withLock { self?.holdIDs.append(action.bookID) }
                    return true
                },
                performCancelHold: { [weak self] action in
                    self?.lock.withLock { self?.cancelHoldIDs.append(action.bookID) }
                    return true
                })
        }

        func withLock<T>(_ body: () -> T) -> T { lock.withLock(body) }
    }

    /// Captures the executor closure installed via `setExecutor`.
    private final class FakeRegistrar: OfflineExecutorRegistering, @unchecked Sendable {
        private let lock = NSLock()
        private var _executor: OfflineActionExecutor?
        private var _currentLibraryID: (@Sendable () -> String?)?
        var executor: OfflineActionExecutor? { lock.withLock { _executor } }
        var currentLibraryID: (@Sendable () -> String?)? { lock.withLock { _currentLibraryID } }
        private var _drainCount = 0
        var drainCount: Int { lock.withLock { _drainCount } }
        func setExecutor(
            _ executor: @escaping OfflineActionExecutor,
            currentLibraryID: @escaping @Sendable () -> String?
        ) async {
            lock.withLock {
                _executor = executor
                _currentLibraryID = currentLibraryID
            }
        }
        func drainIfOnline() async {
            lock.withLock { _drainCount += 1 }
        }
    }

    private func coordinator(_ spy: HandlerSpy, queue: OfflineExecutorRegistering = FakeRegistrar())
        -> OfflineQueueCoordinator {
        OfflineQueueCoordinator(queue: queue, handlers: spy.handlers(),
                                runnableLibraryID: { OfflineAction.testLibraryID })
    }

    // MARK: - INV-8: dedupe

    func testDuplicateReturn_isDeduped() async {
        let spy = HandlerSpy()
        let coord = coordinator(spy)

        // Two distinct actions (different UUIDs) with the SAME bookID+type.
        let a1 = OfflineAction(type: .return, bookID: "book-1", bookTitle: "T")
        let a2 = OfflineAction(type: .return, bookID: "book-1", bookTitle: "T")

        let r1 = await coord.execute(a1)
        let r2 = await coord.execute(a2)

        XCTAssertTrue(r1)
        XCTAssertTrue(r2, "the deduped duplicate is reported as already-done")
        XCTAssertEqual(spy.withLock { spy.returnIDs }, ["book-1"],
            "INV-8: the underlying return side effect runs exactly once")
    }

    func testDifferentBooks_areNotDeduped() async {
        let spy = HandlerSpy()
        let coord = coordinator(spy)

        _ = await coord.execute(OfflineAction(type: .return, bookID: "a", bookTitle: "A"))
        _ = await coord.execute(OfflineAction(type: .return, bookID: "b", bookTitle: "B"))

        XCTAssertEqual(spy.withLock { spy.returnIDs }, ["a", "b"])
    }

    func testSameBookDifferentType_areNotDeduped() async {
        let spy = HandlerSpy()
        let coord = coordinator(spy)

        _ = await coord.execute(OfflineAction(type: .return, bookID: "x", bookTitle: "X"))
        _ = await coord.execute(OfflineAction(type: .borrow, bookID: "x", bookTitle: "X"))

        XCTAssertEqual(spy.withLock { spy.returnIDs }, ["x"])
        XCTAssertEqual(spy.withLock { spy.borrowIDs }, ["x"])
    }

    /// A return of a book completed at one library must not suppress a queued
    /// return of the same book ID at another library.
    func testSameBookAndTypeAtDifferentLibraries_areNotDeduped() async {
        let spy = HandlerSpy()
        let coord = coordinator(spy)

        let atA = await coord.execute(OfflineAction(type: .return, bookID: "x", bookTitle: "X", libraryID: "lib-A"))
        let atB = await coord.execute(OfflineAction(type: .return, bookID: "x", bookTitle: "X", libraryID: "lib-B"))

        XCTAssertTrue(atA)
        XCTAssertTrue(atB)
        XCTAssertEqual(spy.withLock { spy.returnIDs }, ["x", "x"],
            "each library's return runs; a completion at A is not a completion at B")
    }

    /// The same holds for a borrow of the same book ID at two libraries.
    func testSameBookBorrowAtDifferentLibraries_areNotDeduped() async {
        let spy = HandlerSpy()
        let coord = coordinator(spy)

        _ = await coord.execute(OfflineAction(type: .borrow, bookID: "x", bookTitle: "X", libraryID: "lib-A"))
        _ = await coord.execute(OfflineAction(type: .borrow, bookID: "x", bookTitle: "X", libraryID: "lib-B"))

        XCTAssertEqual(spy.withLock { spy.borrowIDs }, ["x", "x"])
    }

    // MARK: - Failure rollback (retryable)

    func testFailedReturn_isRetryable_notPermanentlyDeduped() async {
        let spy = HandlerSpy()
        spy.returnSucceeds = false
        let coord = coordinator(spy)

        let r1 = await coord.execute(OfflineAction(type: .return, bookID: "f", bookTitle: "F"))
        let r2 = await coord.execute(OfflineAction(type: .return, bookID: "f", bookTitle: "F"))

        XCTAssertFalse(r1)
        XCTAssertFalse(r2)
        XCTAssertEqual(spy.withLock { spy.returnIDs }, ["f", "f"],
            "a genuine failure rolls back the dedupe key so the queue can retry")
    }

    // MARK: - Dispatch routing

    func testDispatch_routesEachTypeToItsHandler() async {
        let spy = HandlerSpy()
        let coord = coordinator(spy)

        _ = await coord.execute(OfflineAction(type: .return, bookID: "r", bookTitle: "R"))
        _ = await coord.execute(OfflineAction(type: .borrow, bookID: "bo", bookTitle: "Bo"))
        _ = await coord.execute(OfflineAction(type: .hold, bookID: "h", bookTitle: "H"))
        _ = await coord.execute(OfflineAction(type: .cancelHold, bookID: "c", bookTitle: "C"))

        XCTAssertEqual(spy.withLock { spy.returnIDs }, ["r"])
        XCTAssertEqual(spy.withLock { spy.borrowIDs }, ["bo"])
        XCTAssertEqual(spy.withLock { spy.holdIDs }, ["h"])
        XCTAssertEqual(spy.withLock { spy.cancelHoldIDs }, ["c"])
    }

    // MARK: - #1 fail-closed borrow (must-fix)

    /// A borrow whose registry never reaches an active-loan state is NOT
    /// server-confirmed. The executor must return false (fail-closed) so the
    /// queue keeps and retries it — a failed queued borrow must never be
    /// marked done and dropped.
    func testFailedBorrow_isNotMarkedDone_staysQueued() async {
        let spy = HandlerSpy()
        spy.borrowSucceeds = false
        let coord = coordinator(spy)

        let r1 = await coord.execute(OfflineAction(type: .borrow, bookID: "bfail", bookTitle: "B"))
        XCTAssertFalse(r1, "an unconfirmed borrow must return false, not an optimistic true")

        // Not deduped-as-done: a retry re-dispatches (the queue keeps it).
        let r2 = await coord.execute(OfflineAction(type: .borrow, bookID: "bfail", bookTitle: "B"))
        XCTAssertFalse(r2)
        XCTAssertEqual(spy.withLock { spy.borrowIDs }, ["bfail", "bfail"],
            "a failed borrow is retryable, not silently dropped")
    }

    /// The active-loan classification used by the fail-closed borrow branch.
    func testIsActiveLoanState_confirmsOnlyBorrowedStates() {
        for s in [TPPBookState.downloadNeeded, .downloading, .downloadSuccessful, .used] {
            XCTAssertTrue(OfflineQueueCoordinator.isActiveLoanState(s), "\(s) should confirm a loan")
        }
        for s in [TPPBookState.unregistered, .downloadFailed, .holding, .returning] {
            XCTAssertFalse(OfflineQueueCoordinator.isActiveLoanState(s), "\(s) is not a confirmed loan")
        }
    }

    /// Hold confirmation: only `.holding` confirms a placed hold.
    func testIsHeldState_confirmsOnlyHolding() {
        XCTAssertTrue(OfflineQueueCoordinator.isHeldState(.holding))
        for s in [TPPBookState.unregistered, .downloadNeeded, .downloadSuccessful, .returning] {
            XCTAssertFalse(OfflineQueueCoordinator.isHeldState(s), "\(s) is not a confirmed hold")
        }
    }

    /// Return confirmation: confirmed iff the registry unregistered the book
    /// OR no longer knows it. A book still present in an active state is NOT
    /// a confirmed return (fail-closed).
    func testIsReturnConfirmed_requiresUnregisteredOrAbsent() {
        XCTAssertTrue(OfflineQueueCoordinator.isReturnConfirmed(state: .unregistered, bookPresent: true))
        XCTAssertTrue(OfflineQueueCoordinator.isReturnConfirmed(state: .downloadSuccessful, bookPresent: false))
        XCTAssertFalse(OfflineQueueCoordinator.isReturnConfirmed(state: .downloadSuccessful, bookPresent: true),
            "a book still present in an active state is not a confirmed return")
        XCTAssertFalse(OfflineQueueCoordinator.isReturnConfirmed(state: .holding, bookPresent: true))
    }

    // MARK: - #4 dedupe TTL (must-fix polish)

    private final class MutableClock: @unchecked Sendable {
        private let lock = NSLock()
        private var _now: Date
        init(_ start: Date) { _now = start }
        var now: Date { lock.withLock { _now } }
        func advance(_ t: TimeInterval) { lock.withLock { _now = _now.addingTimeInterval(t) } }
    }

    /// A completed action dedupes a same-key duplicate only within the TTL;
    /// after it elapses, a legitimate later same-type action (return ->
    /// re-borrow -> return again) is allowed through, not silently skipped.
    func testDedupe_completedKeyExpiresAfterTTL() async {
        let spy = HandlerSpy()
        let clock = MutableClock(Date(timeIntervalSince1970: 0))
        let coord = OfflineQueueCoordinator(
            queue: FakeRegistrar(), handlers: spy.handlers(),
            runnableLibraryID: { OfflineAction.testLibraryID },
            dedupeTTL: 100, now: { clock.now })

        _ = await coord.execute(OfflineAction(type: .return, bookID: "k", bookTitle: "K"))
        _ = await coord.execute(OfflineAction(type: .return, bookID: "k", bookTitle: "K"))
        XCTAssertEqual(spy.withLock { spy.returnIDs }, ["k"],
            "within TTL, the duplicate is deduped")

        clock.advance(100) // exactly at the TTL edge from completion@0 -> `< ttl` false -> allowed
        _ = await coord.execute(OfflineAction(type: .return, bookID: "k", bookTitle: "K"))
        XCTAssertEqual(spy.withLock { spy.returnIDs }, ["k", "k"],
            "at/after the TTL boundary the completed key no longer blocks (strict <), so a legitimate later same-type action dispatches again")

        // Re-completion at t=100 refreshes the window: an immediate duplicate
        // is deduped again (proves `complete` restamps the timestamp).
        _ = await coord.execute(OfflineAction(type: .return, bookID: "k", bookTitle: "K"))
        XCTAssertEqual(spy.withLock { spy.returnIDs }, ["k", "k"],
            "within the refreshed TTL window the duplicate is deduped again")
    }

    // MARK: - registerExecutor wiring

    func testRegisterExecutor_installsWorkingExecutor() async {
        let spy = HandlerSpy()
        let registrar = FakeRegistrar()
        let coord = coordinator(spy, queue: registrar)

        await coord.registerExecutor()
        let executor = try? XCTUnwrap(registrar.executor)
        XCTAssertNotNil(executor, "setExecutor must have been called")

        let ok = await executor?(OfflineAction(type: .borrow, bookID: "wired", bookTitle: "W"))
        XCTAssertEqual(ok, true)
        XCTAssertEqual(spy.withLock { spy.borrowIDs }, ["wired"],
            "the installed executor dispatches through the coordinator to the handler")
    }

    /// The queue scopes its drain with the coordinator's current-library
    /// reader, installed alongside the executor.
    func testRegisterExecutor_installsCurrentLibraryReader() async {
        let registrar = FakeRegistrar()
        let coord = OfflineQueueCoordinator(queue: registrar, handlers: HandlerSpy().handlers(),
                                            runnableLibraryID: { "library-under-test" })

        await coord.registerExecutor()

        XCTAssertEqual(registrar.currentLibraryID?(), "library-under-test")
    }

    /// Registration drains once, and each library-ready signal drains again.
    func testRegisterExecutor_drainsNowAndOnEachLibraryReadySignal() async {
        let registrar = FakeRegistrar()
        let ready = PassthroughSubject<Void, Never>()
        let coord = OfflineQueueCoordinator(queue: registrar, handlers: HandlerSpy().handlers(),
                                            runnableLibraryID: { "lib" },
                                            libraryReady: ready.eraseToAnyPublisher())

        await coord.registerExecutor()
        XCTAssertEqual(registrar.drainCount, 1)

        ready.send(())
        await coord._awaitTriggeredDrainsForTesting()
        XCTAssertEqual(registrar.drainCount, 2)
    }

    /// A released coordinator stops listening for registry loads; otherwise a
    /// coordinator discarded by a container reset keeps draining the queue.
    func testReleasedCoordinator_noLongerReceivesLibraryReadySignals() async {
        let registrar = FakeRegistrar()
        let ready = PassthroughSubject<Void, Never>()
        let delivered = LockIsolated(0)
        let observed = ready
            .handleEvents(receiveOutput: { _ in delivered.withValue { $0 += 1 } })
            .eraseToAnyPublisher()
        var coord: OfflineQueueCoordinator? = OfflineQueueCoordinator(
            queue: registrar, handlers: HandlerSpy().handlers(),
            runnableLibraryID: { "lib" }, libraryReady: observed)
        await coord?.registerExecutor()
        ready.send(())
        await coord?._awaitTriggeredDrainsForTesting()
        XCTAssertEqual(delivered.value, 1, "precondition: the live coordinator is subscribed")

        coord = nil
        ready.send(())

        XCTAssertEqual(delivered.value, 1, "a released coordinator must not receive the signal")
        XCTAssertEqual(registrar.drainCount, 2, "only the registration drain and the live signal's drain ran")
    }
}
