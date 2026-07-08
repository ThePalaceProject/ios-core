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

import XCTest
@testable import Palace

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

        func handlers() -> OfflineQueueCoordinator.Handlers {
            OfflineQueueCoordinator.Handlers(
                performReturn: { [weak self] id in
                    self?.lock.withLock { self?.returnIDs.append(id) }
                    return self?.returnSucceeds ?? false
                },
                performBorrow: { [weak self] id in
                    self?.lock.withLock { self?.borrowIDs.append(id) }
                    return true
                },
                performHold: { [weak self] id in
                    self?.lock.withLock { self?.holdIDs.append(id) }
                    return true
                },
                performCancelHold: { [weak self] id in
                    self?.lock.withLock { self?.cancelHoldIDs.append(id) }
                    return true
                })
        }

        func withLock<T>(_ body: () -> T) -> T { lock.withLock(body) }
    }

    /// Captures the executor closure installed via `setExecutor`.
    private final class FakeRegistrar: OfflineExecutorRegistering, @unchecked Sendable {
        private let lock = NSLock()
        private var _executor: OfflineActionExecutor?
        var executor: OfflineActionExecutor? { lock.withLock { _executor } }
        func setExecutor(_ executor: @escaping OfflineActionExecutor) async {
            lock.withLock { _executor = executor }
        }
    }

    private func coordinator(_ spy: HandlerSpy, queue: OfflineExecutorRegistering = FakeRegistrar())
        -> OfflineQueueCoordinator {
        OfflineQueueCoordinator(queue: queue, handlers: spy.handlers())
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
}
