//
//  TPPNetworkExecutorConcurrencyTests.swift
//  PalaceTests
//
//  PP-4769 — concurrent-teardown regression coverage for
//  `TPPNetworkExecutor.executeRequest(_:enableTokenRefresh:completion:)`.
//
//  Issue #1 (crash fingerprint abfef568, EXC_BAD_ACCESS `objc_release` at the
//  tail of `executeRequest`): the crash was an ARC over-release / use-after-free
//  driven from an async continuation (OPDSFeedService.fetchFeed →
//  `withCheckedContinuation` on a cooperative-pool thread) firing many concurrent
//  `executeRequest` / GET calls. The Swift 6 rework routes completions through the
//  single-ownership `CompletionBox` handoff, but there was NO concurrent-teardown
//  test proving the completion path is race-clean end to end.
//
//  These tests fire many concurrent requests through the REAL production
//  completion seam (`TPPNetworkExecutor` → `TPPNetworkResponder` →
//  `NYPLResult` completion) using `HTTPStubURLProtocol`, and assert that EVERY
//  completion fires EXACTLY once — no double-fire, no drop, no crash. They are
//  designed to survive the 3× CI harness (`-test-iterations 3
//  -retry-tests-on-failure`): deterministic stubbed HTTP, no real network, no
//  sleeps.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class TPPNetworkExecutorConcurrencyTests: XCTestCase {

    private var executor: TPPNetworkExecutor!
    private var libraryAccount: TPPLibraryAccountMock!

    /// How many concurrent requests each stress test fans out. Kept well above
    /// the 7-patron crash sample so a lingering race has many chances to trip.
    private let concurrency = 64

    override func setUp() {
        super.setUp()
        HTTPStubURLProtocol.reset()

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HTTPStubURLProtocol.self]

        // Full-DI init so the executor's account reads target a test-controlled
        // mock instead of `AppContainer.production().accountsManager`. We pass
        // `useTokenIfAvailable: false` on every call below so no token / auth
        // branch is taken — this isolates the exact crashed seam
        // (`executeRequest` → `performDataTask` → responder completion).
        libraryAccount = TPPLibraryAccountMock()
        executor = TPPNetworkExecutor(
            credentialsProvider: nil,
            cachingStrategy: .ephemeral,
            sessionConfiguration: config,
            accountsManager: libraryAccount,
            delegateQueue: nil
        )
    }

    override func tearDown() {
        HTTPStubURLProtocol.reset()
        executor = nil
        libraryAccount = nil
        super.tearDown()
    }

    // MARK: - Helpers

    /// Thread-safe counter of how many times a given request index's completion
    /// fired. Used to prove single-fire under concurrency.
    private final class FireLedger: @unchecked Sendable {
        private var counts: [Int: Int] = [:]
        private let lock = NSLock()

        func record(_ index: Int) {
            lock.lock(); defer { lock.unlock() }
            counts[index, default: 0] += 1
        }

        /// Returns (indices that fired exactly once, indices that fired more
        /// than once, total fire events).
        func snapshot() -> (uniqueCount: Int, doubleFired: [Int], totalFires: Int) {
            lock.lock(); defer { lock.unlock() }
            let unique = counts.filter { $0.value == 1 }.count
            let doubles = counts.filter { $0.value > 1 }.map { $0.key }.sorted()
            let total = counts.values.reduce(0, +)
            return (unique, doubles, total)
        }
    }

    // MARK: - Concurrent success — every completion fires exactly once

    /// Fires `concurrency` concurrent GET requests through the async
    /// `GET(_:useTokenIfAvailable:)` continuation bridge — the exact shape of
    /// the crashed call site (`OPDSFeedService.fetchFeed` →
    /// `withCheckedContinuation`). Asserts every request completes once and
    /// returns the stubbed body.
    ///
    /// What this arm actually pins: NO DROP and NO CRASH. A dropped completion
    /// leaves its continuation un-resumed → the task never finishes → the task
    /// group hangs → the test times out. An over-release / use-after-free of the
    /// boxed completion crashes (EXC_BAD_ACCESS). A *double*-fire at the
    /// responder is deliberately NOT pinned here: the async bridge's
    /// `ContinuationGuard` (`tryConsume`) absorbs the second fire before it
    /// reaches the ledger, so `doubles.isEmpty` cannot observe it on this path.
    /// The single-fire-under-double-fire property is proven by the raw
    /// completion-handler path in
    /// `testConcurrentExecuteRequest_completionHandlerPath_firesExactlyOnce`,
    /// which has no such guard.
    func testConcurrentGET_viaContinuations_eachCompletionFiresExactlyOnce() async {
        let body = "{\"ok\":true}".data(using: .utf8)!
        HTTPStubURLProtocol.register { _ in
            .init(statusCode: 200, headers: ["Content-Type": "application/json"], body: body)
        }

        let ledger = FireLedger()
        let n = concurrency

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<n {
                group.addTask { [executor] in
                    // Distinct URL per task so each maps to its own task id in
                    // the responder — a shared completion map bug would surface
                    // as a cross-delivered / duplicated fire.
                    let url = URL(string: "https://api.example.com/feed/\(i)")!
                    do {
                        let (data, _) = try await executor!.GET(url, useTokenIfAvailable: false)
                        XCTAssertEqual(data, body, "request \(i) received the wrong body")
                    } catch {
                        XCTFail("request \(i) unexpectedly failed: \(error)")
                    }
                    ledger.record(i)
                }
            }
        }

        let (unique, doubles, total) = ledger.snapshot()
        XCTAssertEqual(unique, n, "expected all \(n) requests to complete exactly once")
        XCTAssertTrue(doubles.isEmpty, "requests double-fired: \(doubles)")
        XCTAssertEqual(total, n, "total fire count \(total) != \(n) (dropped completion)")
    }

    // MARK: - Concurrent failure — error completions also fire exactly once

    /// Same fan-out but every request gets a 500. The failure branch of the
    /// completion path (`.failure(err, response)`) must also complete once per
    /// request. Like the success arm, this pins no-drop (a lost failure hangs
    /// the group → timeout) and no-crash on the `.failure` arm; a responder
    /// double-fire is again absorbed by the async `ContinuationGuard` and is
    /// pinned instead by the raw completion-handler test. Mixing this with the
    /// success test proves BOTH arms of the `NYPLResult` switch are race-clean,
    /// not just the happy path.
    func testConcurrentGET_serverError_eachFailureFiresExactlyOnce() async {
        HTTPStubURLProtocol.register { _ in
            .init(statusCode: 500, headers: nil, body: "boom".data(using: .utf8))
        }

        let ledger = FireLedger()
        let n = concurrency

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<n {
                group.addTask { [executor] in
                    let url = URL(string: "https://api.example.com/fail/\(i)")!
                    do {
                        _ = try await executor!.GET(url, useTokenIfAvailable: false)
                        XCTFail("request \(i) should have thrown on a 500")
                    } catch {
                        // Expected — a 500 surfaces as a thrown failure.
                    }
                    ledger.record(i)
                }
            }
        }

        let (unique, doubles, total) = ledger.snapshot()
        XCTAssertEqual(unique, n, "expected all \(n) failures to complete exactly once")
        XCTAssertTrue(doubles.isEmpty, "failures double-fired: \(doubles)")
        XCTAssertEqual(total, n, "total failure fire count \(total) != \(n)")
    }

    // MARK: - Concurrent teardown — completions fire once even mid-flight

    /// Drives the crash's precise scenario: many requests are in flight through
    /// the raw completion-handler `GET` overload (not the async bridge) so the
    /// completion closure — the one the crash captured across the concurrency
    /// boundary — is exercised directly, while completions are being registered
    /// (addCompletion) and delivered (didCompleteWithError) simultaneously
    /// across threads. Counts fires through a shared ledger rather than relying
    /// solely on XCTestExpectation's over-fulfill trap, so a double-fire names a
    /// precise culprit index.
    func testConcurrentExecuteRequest_completionHandlerPath_firesExactlyOnce() {
        let body = "payload".data(using: .utf8)!
        HTTPStubURLProtocol.register { _ in
            .init(statusCode: 200, headers: nil, body: body)
        }

        let ledger = FireLedger()
        let n = concurrency
        let allDone = expectation(description: "all completions delivered")
        allDone.expectedFulfillmentCount = n

        // Fan out from a concurrent queue so registration and delivery race —
        // the interleave that produced the use-after-free.
        let queue = DispatchQueue(label: "pp4769.concurrent.fanout", attributes: .concurrent)
        for i in 0..<n {
            queue.async { [executor] in
                let url = URL(string: "https://api.example.com/exec/\(i)")!
                executor!.GET(url, useTokenIfAvailable: false) { result in
                    if case let .success(data, _) = result {
                        XCTAssertEqual(data, body, "request \(i) got wrong body")
                    }
                    ledger.record(i)
                    allDone.fulfill()
                }
            }
        }

        wait(for: [allDone], timeout: 30.0)

        let (unique, doubles, total) = ledger.snapshot()
        XCTAssertEqual(unique, n, "expected all \(n) completions exactly once")
        XCTAssertTrue(doubles.isEmpty, "completions double-fired: \(doubles)")
        XCTAssertEqual(total, n, "total completion fire count \(total) != \(n)")
    }

    // MARK: - Concurrent cancellation — cancelled OR completed, always exactly once

    /// Fans out ~30 concurrent requests through the raw completion-handler
    /// `GET(_:useTokenIfAvailable:completion:)` overload — the overload that
    /// RETURNS the `URLSessionDataTask`, which is the real per-request
    /// cancellation entry point (the executor exposes no `cancel(request:)`;
    /// production callers cancel by holding the returned task handle, and the
    /// account-switch path funnels through the same `URLSessionTask.cancel()`
    /// via `transport.cancelNonEssentialTasks()`). Roughly half the tasks are
    /// cancelled while requests are being registered (`addCompletion`) and
    /// delivered (`didCompleteWithError`) concurrently — the exact interleave
    /// that produced the use-after-free.
    ///
    /// What this pins: EVERY task's completion arm fires EXACTLY once, whoever
    /// wins the cancel-vs-deliver race. A `.cancel()` surfaces in the responder
    /// as `didCompleteWithError` with `NSURLErrorCancelled`, which
    /// `removeValue(forKey:)`s the taskInfo (single ownership) and fires one
    /// `.failure`. If the natural response already landed first, the later
    /// cancel event finds no taskInfo and fires nothing. So a cancelled task
    /// resolves once (cancelled `.failure` OR success, depending on the race)
    /// and a non-cancelled task completes once — never dropped, never doubled.
    ///
    /// This uses the raw completion-handler seam (NOT the async
    /// `ContinuationGuard`-guarded bridge), so a genuine responder double-fire
    /// would reach the ledger and FAIL here — it is not absorbed upstream. A
    /// dropped completion leaves a task un-fulfilled → the expectation times
    /// out → FAIL. The test therefore fails on a real drop OR a real
    /// double-fire; it is not a tautology.
    func testConcurrentNetworkCancellation_allTasksCancelOrComplete() {
        let body = "payload".data(using: .utf8)!
        HTTPStubURLProtocol.register { _ in
            .init(statusCode: 200, headers: nil, body: body)
        }

        let ledger = FireLedger()
        let n = 30
        let allDone = expectation(description: "all requests resolved (cancelled or completed)")
        allDone.expectedFulfillmentCount = n

        // Fan out from a concurrent queue so registration, delivery, and
        // cancellation all race against each other.
        let queue = DispatchQueue(label: "pp4769.cancel.fanout", attributes: .concurrent)
        for i in 0..<n {
            // Cancel roughly half (the even indices) mid-flight.
            let shouldCancel = (i % 2 == 0)
            queue.async { [executor] in
                let url = URL(string: "https://api.example.com/cancel/\(i)")!
                let task = executor!.GET(url, useTokenIfAvailable: false) { _, _, _ in
                    // Both arms — cancelled (`.failure` → error non-nil) and
                    // completed (`.success` → data) — funnel here. We assert
                    // fire-count, not which arm won, because the cancel-vs-
                    // deliver race is inherently nondeterministic; the invariant
                    // under test is EXACTLY ONCE, not WHICH outcome.
                    ledger.record(i)
                    allDone.fulfill()
                }
                if shouldCancel {
                    // The real cancellation mechanism: cancel the returned
                    // URLSession task. Racing this against the synchronous stub
                    // delivery is the point — either the cancel wins (one
                    // `.failure(NSURLErrorCancelled)`) or delivery already won
                    // (one `.success`); the responder's `removeValue` guarantees
                    // the loser fires nothing.
                    task?.cancel()
                }
            }
        }

        wait(for: [allDone], timeout: 30.0)

        let (unique, doubles, total) = ledger.snapshot()
        XCTAssertEqual(unique, n, "expected all \(n) requests to resolve exactly once (cancelled or completed)")
        XCTAssertTrue(doubles.isEmpty, "requests double-fired (cancel + delivery both reached completion): \(doubles)")
        XCTAssertEqual(total, n, "total resolution count \(total) != \(n) (a cancelled or completed request was dropped)")
    }
}
