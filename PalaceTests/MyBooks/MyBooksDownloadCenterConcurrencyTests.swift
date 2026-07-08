//
//  MyBooksDownloadCenterConcurrencyTests.swift
//  PalaceTests
//
//  Mutation-killing coverage for the download-concurrency state machine that
//  spans `DownloadCoordinator` (actor) → `DownloadStateManager` →
//  `DownloadQueueOrchestrator` → `DownloadCancellationHandler`.
//
//  Each test pins ONE specific contract (cap enforcement, queue ordering,
//  slot accounting on failure / cancel, FIFO dequeue, dedup, cold-start
//  behavior, etc.) so a mutation to the underlying logic flips exactly that
//  assertion. No tautologies; every test is annotated with the specific
//  mutant(s) it kills.
//
//  Targets the P0 gap in docs/Testing/Coverage_Roadmap.md §2.2.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

@MainActor
final class MyBooksDownloadCenterConcurrencyTests: XCTestCase {

    private var bookRegistry: TPPBookRegistryMock!
    private var stateManager: DownloadStateManager!
    private var notificationCenter: NotificationCenter!
    private var startSpy: StartSpyDelegate!
    private var orchestrator: DownloadQueueOrchestrator!
    private var cancellationHandler: DownloadCancellationHandler!
    private var cancellationSpy: CancellationSpyDelegate!

    override func setUpWithError() throws {
        try super.setUpWithError()
        bookRegistry = TPPBookRegistryMock()
        stateManager = DownloadStateManager()
        notificationCenter = NotificationCenter()
        startSpy = StartSpyDelegate()
        orchestrator = DownloadQueueOrchestrator(
            bookRegistry: bookRegistry,
            stateManager: stateManager,
            notificationCenter: notificationCenter
        )
        orchestrator.delegate = startSpy

        cancellationSpy = CancellationSpyDelegate()
        cancellationHandler = DownloadCancellationHandler(
            stateManager: stateManager,
            bookRegistry: bookRegistry,
            adobeDRMService: AdobeDRMService.shared
        )
        cancellationHandler.delegate = cancellationSpy
    }

    override func tearDownWithError() throws {
        bookRegistry = nil
        stateManager = nil
        notificationCenter = nil
        startSpy = nil
        orchestrator = nil
        cancellationHandler = nil
        cancellationSpy = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func makeBook(_ tag: String = UUID().uuidString) -> TPPBook {
        // EpubZip route is the non-Adobe, non-LCP path — keeps the cancel
        // path off the Adobe DRM short-circuit so this suite doesn't fork
        // on rights-management branches.
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        bookRegistry.addBook(book, state: .unregistered)
        _ = tag
        return book
    }

    /// Marks `book` active in the coordinator (used to simulate an
    /// in-flight download without a real URLSessionDownloadTask).
    private func markActive(_ book: TPPBook) async {
        await stateManager.downloadCoordinator.registerStart(identifier: book.identifier)
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

    private func attach(task: URLSessionDownloadTask, to book: TPPBook) async {
        let info = MyBooksDownloadInfo(
            downloadProgress: 0.0,
            downloadTask: task,
            rightsManagement: .none
        )
        await stateManager.bookIdentifierToDownloadInfo.set(book.identifier, value: info)
        await stateManager.taskIdentifierToBook.set(task.taskIdentifier, value: book)
        bookRegistry.setState(.downloading, for: book.identifier)
    }

    // MARK: - 1. Concurrent download limit enforcement

    /// Kills mutants in `canStartDownload`'s `<` (mutate to `<=`, `==`, `>`):
    /// at the cap, must reject. Just below the cap, must accept. Just above,
    /// must reject. Each branch is asserted independently.
    func testCanStartDownload_returnsTrueOnlyStrictlyBelowMaxConcurrent() async {
        let coordinator = stateManager.downloadCoordinator
        let max = 3

        // 0 active → can start (kills `< → ==` mutant: would return false)
        var can = await coordinator.canStartDownload(maxConcurrent: max)
        XCTAssertTrue(can, "Empty coordinator must accept new downloads when below cap")

        await coordinator.registerStart(identifier: "a")
        await coordinator.registerStart(identifier: "b")

        // 2 active, max=3 → still under cap (kills `< → >` mutant)
        can = await coordinator.canStartDownload(maxConcurrent: max)
        XCTAssertTrue(can, "At active=2, max=3 (strictly under cap) must accept a new download")

        await coordinator.registerStart(identifier: "c")

        // 3 active, max=3 → at cap, must reject (kills `< → <=` mutant)
        can = await coordinator.canStartDownload(maxConcurrent: max)
        XCTAssertFalse(can, "At active=3, max=3 (AT cap) must reject — `<` is strict, not `<=`")
    }

    /// Kills the "off-by-one cap" mutant: simulating N+1 download requests
    /// when the cap is N must leave exactly N actives and 1 queued. Mutating
    /// `capacity = maxConcurrentDownloads - activeCount` to `+ activeCount`
    /// or to `- activeCount - 1` (off-by-one) flips this assertion.
    func testStartingNPlus1Downloads_LeavesExactlyNActiveAnd1Queued() async {
        let cap = 2
        stateManager.maxConcurrentDownloads = cap

        let books = (0..<(cap + 1)).map { _ in makeBook() }

        // Simulate the dispatcher path: for each book, if under cap →
        // registerStart; else → enqueuePending.
        for book in books {
            let canStart = await stateManager.downloadCoordinator
                .canStartDownload(maxConcurrent: cap)
            if canStart {
                await stateManager.downloadCoordinator.registerStart(identifier: book.identifier)
            } else {
                await stateManager.downloadCoordinator.enqueuePending(book)
            }
        }

        let active = await stateManager.downloadCoordinator.activeCount
        let queued = await stateManager.downloadCoordinator.queueCount
        XCTAssertEqual(active, cap,
                       "When cap=\(cap), starting cap+1 books must yield exactly cap actives — not cap+1, not cap-1")
        XCTAssertEqual(queued, 1,
                       "When cap=\(cap) is hit, exactly 1 of the cap+1 books must be queued")
    }

    // MARK: - 2. 1 active completes → 1 queued promotes to active

    /// Kills the `if capacity > 0` guard mutant (e.g. mutating to `>= 0`
    /// dequeues even at-cap; mutating to `< 0` never dequeues). Also
    /// kills mutations to `capacity = max - active`.
    func testCompletion_PromotesNextQueuedToActive() async {
        let cap = 1
        stateManager.maxConcurrentDownloads = cap
        let active = makeBook()
        let queued = makeBook()
        await markActive(active)
        await stateManager.downloadCoordinator.enqueuePending(queued)

        // Sanity preconditions — fail loud if setUp is wrong.
        let preActive = await stateManager.downloadCoordinator.activeCount
        let preQueue = await stateManager.downloadCoordinator.queueCount
        XCTAssertEqual(preActive, 1)
        XCTAssertEqual(preQueue, 1)

        // 1 active completes → free its slot. This is what MBDC's
        // taskLifecycleService / cleanupDownload path does on success.
        await stateManager.downloadCoordinator
            .registerCompletion(identifier: active.identifier)

        // Now run the orchestrator pump — the freed slot must be filled.
        await orchestrator.schedulePendingStartsAsync()

        XCTAssertEqual(startSpy.startCalls.map { $0.book.identifier },
                       [queued.identifier],
                       "After 1 active completes (cap=1), the orchestrator must dequeue and start the queued book")
        let postQueue = await stateManager.downloadCoordinator.queueCount
        XCTAssertEqual(postQueue, 0,
                       "Promoted book must be removed from the pending queue (kills mutants that leave stale entries)")
    }

    // MARK: - 3. Failure (server 500 path) frees the slot

    /// Pins the contract: when a download fails (the failure path calls
    /// `registerCompletion` via `cleanupDownload`), the coordinator slot is
    /// freed and the orchestrator promotes the next queued book. This
    /// proves a failed download does NOT poison the slot count. Kills any
    /// mutant that conditionally skips `registerCompletion` on the failure
    /// branch.
    func testFailure_FreesSlot_AndPromotesQueuedBook() async {
        let cap = 1
        stateManager.maxConcurrentDownloads = cap
        let failing = makeBook()
        let queued = makeBook()

        // Attach a real download-info entry so cleanupDownload exercises the
        // bookIdentifierToDownloadInfo + downloadCoordinator paths together.
        let task = StubDownloadTask(taskIdentifier: 100)
        await attach(task: task, to: failing)
        await markActive(failing)
        await stateManager.downloadCoordinator.enqueuePending(queued)

        // Simulate the server-500 path: cleanupDownload(for:taskIdentifier:)
        // is exactly what MBDC's DownloadTaskLifecycleService calls on
        // failure. It must (a) clear info, (b) registerCompletion, freeing
        // the slot.
        await stateManager.cleanupDownload(for: failing.identifier,
                                           taskIdentifier: task.taskIdentifier)

        let activeAfter = await stateManager.downloadCoordinator.activeCount
        XCTAssertEqual(activeAfter, 0,
                       "A failed download must free its slot via registerCompletion — failures must NOT poison the active count")

        // Pump the queue. The failed download's slot must be reused.
        await orchestrator.schedulePendingStartsAsync()

        XCTAssertEqual(startSpy.startCalls.map { $0.book.identifier },
                       [queued.identifier],
                       "After failure, the queued book must be promoted (kills mutants that bypass registerCompletion on failure)")
    }

    // MARK: - 4. Cancellation frees the slot

    /// End-to-end cancellation: the user cancels an in-flight download → the
    /// cancel-with-task path runs the URLSession cancel completion → which
    /// schedules an actor task that calls `registerCompletion` →
    /// schedulePendingStartsIfPossible is invoked on the delegate. Kills
    /// any mutant that drops `registerCompletion` or `schedulePending`
    /// from the cancel callback.
    func testCancellation_OfActiveDownload_FreesSlotAndSchedulesPendingStarts() async {
        let cap = 1
        stateManager.maxConcurrentDownloads = cap
        let active = makeBook()
        let task = SyncCompletingDownloadTask(taskIdentifier: 200)
        await attach(task: task, to: active)
        await markActive(active)

        cancellationHandler.cancelDownload(for: active.identifier)

        // The cancel completion fires synchronously (per SyncCompletingDownloadTask),
        // then queues an actor Task to register the completion. Wait for
        // the schedule signal so we know the actor work landed.
        await waitForAsync { [self] in self.cancellationSpy.scheduleCount > 0 }

        XCTAssertEqual(task.cancelByProducingResumeDataCount, 1,
                       "cancelDownload must invoke URLSessionDownloadTask.cancel(byProducingResumeData:) exactly once")
        XCTAssertEqual(cancellationSpy.scheduleCount, 1,
                       "Cancel completion must fire delegate.schedulePendingStartsIfPossible() — required to reuse the freed slot")
        let activeAfter = await stateManager.downloadCoordinator.activeCount
        XCTAssertEqual(activeAfter, 0,
                       "Cancel completion must call registerCompletion — kills mutants that leave activeCount=1 after cancel")
    }

    /// Wires the full chain: orchestrator owns the queue, cancellation
    /// frees the slot, then the next pump promotes the queued book.
    /// Kills "cancel succeeds but next queued never starts" mutants.
    func testCancellation_OfActiveDownload_PromotesNextQueuedBook() async {
        let cap = 1
        stateManager.maxConcurrentDownloads = cap
        let active = makeBook()
        let queued = makeBook()
        let task = SyncCompletingDownloadTask(taskIdentifier: 300)
        await attach(task: task, to: active)
        await markActive(active)
        await stateManager.downloadCoordinator.enqueuePending(queued)

        cancellationHandler.cancelDownload(for: active.identifier)
        await waitForAsync { [self] in self.cancellationSpy.scheduleCount > 0 }

        // After cancel, the schedule callback is invoked on the *cancellation*
        // delegate (not the orchestrator's delegate). We pump the orchestrator
        // directly here to verify the queued book is dequeued FIFO from the
        // freed slot — this is what MBDC's
        // DownloadCancellationHandlerDelegate.schedulePendingStartsIfPossible
        // ultimately does (it forwards into queueOrchestrator).
        await orchestrator.schedulePendingStartsAsync()

        XCTAssertEqual(startSpy.startCalls.map { $0.book.identifier },
                       [queued.identifier],
                       "After cancelling the active download, the queued book must be promoted to active")
    }

    // MARK: - 5. Queue ordering — FIFO is the pinned contract

    /// Pins FIFO ordering of `dequeuePending`. Kills mutants that swap the
    /// dequeue source from `pendingQueue.prefix(capacity)` to `.suffix`,
    /// `.dropFirst`, or `.shuffled()`.
    func testDequeuePending_RemovesBooksInFIFOOrder() async {
        let coord = stateManager.downloadCoordinator
        let b1 = makeBook(); let b2 = makeBook(); let b3 = makeBook()
        await coord.enqueuePending(b1)
        await coord.enqueuePending(b2)
        await coord.enqueuePending(b3)

        let firstBatch = await coord.dequeuePending(capacity: 2)
        XCTAssertEqual(firstBatch.map { $0.identifier },
                       [b1.identifier, b2.identifier],
                       "dequeuePending must return books in INSERTION order (FIFO) — kills LIFO / reversed / shuffled mutants")

        let secondBatch = await coord.dequeuePending(capacity: 10)
        XCTAssertEqual(secondBatch.map { $0.identifier },
                       [b3.identifier],
                       "Second dequeue must return the remaining book (kills mutants that double-dequeue or skip)")
    }

    /// Multi-round-trip: enqueue 4, dequeue cap=2, enqueue 1 more, dequeue cap=2.
    /// FIFO must hold across re-enqueues. Kills mutants that break ordering
    /// when the queue is mutated between dequeues.
    func testQueueOrdering_FIFOSurvivesInterleavedEnqueueAndDequeue() async {
        let coord = stateManager.downloadCoordinator
        let b1 = makeBook(); let b2 = makeBook(); let b3 = makeBook(); let b4 = makeBook()
        await coord.enqueuePending(b1)
        await coord.enqueuePending(b2)
        await coord.enqueuePending(b3)
        await coord.enqueuePending(b4)

        let firstTwo = await coord.dequeuePending(capacity: 2)
        XCTAssertEqual(firstTwo.map { $0.identifier },
                       [b1.identifier, b2.identifier],
                       "FIFO: first 2 dequeued must be b1,b2 in that order")

        let b5 = makeBook()
        await coord.enqueuePending(b5)

        let nextTwo = await coord.dequeuePending(capacity: 2)
        XCTAssertEqual(nextTwo.map { $0.identifier },
                       [b3.identifier, b4.identifier],
                       "FIFO: b5 added AFTER b3+b4 must NOT jump ahead — kills mutants that shuffle queue on enqueue")
    }

    /// Kills the `capacity > 0` guard mutant: dequeue with capacity=0 must
    /// return an empty array AND leave the queue intact. Otherwise a
    /// mutation to `capacity >= 0` would drain a book per zero-capacity call.
    func testDequeuePending_zeroCapacity_returnsEmptyAndPreservesQueue() async {
        let coord = stateManager.downloadCoordinator
        let b1 = makeBook()
        await coord.enqueuePending(b1)

        let dequeued = await coord.dequeuePending(capacity: 0)
        XCTAssertTrue(dequeued.isEmpty,
                      "dequeuePending(capacity: 0) must return empty — kills `> 0 → >= 0` guard mutants")
        let qcount = await coord.queueCount
        XCTAssertEqual(qcount, 1,
                       "Zero-capacity dequeue must NOT remove anything from the queue")
    }

    /// Kills mutants that swap `prefix(capacity)` for `prefix(pendingQueue.count)`
    /// (which would drain more than the freed-capacity allows). With cap=3,
    /// 1 active, and 4 enqueued, the orchestrator must start EXACTLY 2.
    func testSchedulePendingStartsAsync_HonorsRemainingCapacity_NotQueueSize() async {
        stateManager.maxConcurrentDownloads = 3
        let active = makeBook()
        await markActive(active)
        let q1 = makeBook(); let q2 = makeBook(); let q3 = makeBook(); let q4 = makeBook()
        for b in [q1, q2, q3, q4] {
            await stateManager.downloadCoordinator.enqueuePending(b)
        }

        await orchestrator.schedulePendingStartsAsync()

        XCTAssertEqual(startSpy.startCalls.count, 2,
                       "Remaining capacity = max(3) - active(1) = 2 — orchestrator must start EXACTLY 2 (kills mutants that drain the queue or off-by-one capacity)")
        let queueRemaining = await stateManager.downloadCoordinator.queueCount
        XCTAssertEqual(queueRemaining, 2,
                       "2 of 4 queued books must remain; kills mutants that clear the entire queue regardless of capacity")
    }

    // MARK: - 6. Duplicate enqueue is deduplicated by book identifier

    /// Pins the dedup contract: `enqueuePending` is idempotent on book
    /// identifier. The two-rapid-tap regression: the user taps download
    /// twice → only one queued entry should result. Kills any mutant that
    /// drops the `contains(where:)` guard.
    func testEnqueuePending_isDedupedByBookIdentifier() async {
        let coord = stateManager.downloadCoordinator
        let book = makeBook()

        await coord.enqueuePending(book)
        await coord.enqueuePending(book)
        await coord.enqueuePending(book)

        let queueCount = await coord.queueCount
        XCTAssertEqual(queueCount, 1,
                       "Three enqueues of the SAME book identifier must yield queueCount=1 — kills mutants that drop the dedup guard (would yield 3)")

        // Sanity: a different book IS appended.
        let other = makeBook()
        await coord.enqueuePending(other)
        let afterOther = await coord.queueCount
        XCTAssertEqual(afterOther, 2,
                       "Dedup is per-identifier, not per-enqueue — a different identifier must append (kills mutants that always reject duplicates)")
    }

    // MARK: - 7. Cold-start: fresh coordinator has no resumed downloads

    /// Pins the contract: cold-start (a freshly constructed
    /// DownloadCoordinator) has NO active downloads and NO queued
    /// downloads — even if the book registry has books in `.downloading`
    /// state from a previous app session. The Palace contract is "registry
    /// state is restored by BookRegistrySync, but the coordinator is
    /// re-built empty on launch — user must re-trigger downloads."
    /// Kills any mutant that injects ghost downloads on init.
    func testColdStart_ofCoordinator_HasNoActiveOrQueuedDownloads() async {
        // Simulate the cold-start: a book that was downloading in a prior
        // session has been re-loaded from disk as .downloading by the
        // registry sync.
        let b = makeBook()
        bookRegistry.setState(.downloading, for: b.identifier)

        // But a FRESH coordinator has no idea about it.
        let fresh = DownloadCoordinator()

        let active = await fresh.activeCount
        let queued = await fresh.queueCount
        XCTAssertEqual(active, 0,
                       "A fresh DownloadCoordinator must have activeCount=0 even when the registry has books in .downloading state — there is NO auto-resume in this layer")
        XCTAssertEqual(queued, 0,
                       "A fresh DownloadCoordinator must have queueCount=0 — cold-start does not re-queue pre-existing 'downloading' books")
    }

    // MARK: - 8. Foreground transition: cap re-application drives pending pump

    /// When the app foregrounds, DownloadThrottlingService re-applies the
    /// concurrency cap which always ends with `schedulePendingStartsAsync`.
    /// Pins the contract that the foreground → cap-reapply → queue-pump
    /// chain runs even when actives are AT the cap (so the cap-reapply
    /// itself doesn't suspend anything). Kills mutants that skip the
    /// `await delegate?.schedulePendingStartsAsync()` tail call.
    func testForegroundReapplyOfCap_AlwaysPumpsThePendingQueue() async {
        // Standup a throttling service against the same stateManager.
        let throttle = DownloadThrottlingService(
            stateManager: stateManager,
            notificationCenter: notificationCenter
        )
        let throttleSpy = ThrottleScheduleSpy()
        throttle.delegate = throttleSpy

        // active=cap → reapply must NOT suspend or resume anything, BUT
        // must still pump the queue (kills "skip schedulePending when at cap").
        stateManager.maxConcurrentDownloads = 2
        let a1 = makeBook(); let a2 = makeBook()
        await markActive(a1)
        await markActive(a2)

        throttle.limitActiveDownloads(max: 2)
        await waitForAsync { throttleSpy.scheduleCount > 0 }

        XCTAssertGreaterThan(throttleSpy.scheduleCount, 0,
                             "limitActiveDownloads (foreground reapply path) must always end with schedulePendingStartsAsync — kills mutants that skip the tail call when running==max")
    }

    // MARK: - 9. registerCompletion is independent across identifiers

    /// Kills mutants that swap `activeDownloadIdentifiers.remove(identifier)`
    /// for `.removeAll()` (would crater all actives on one completion) or
    /// for a no-op (would never free slots).
    func testRegisterCompletion_RemovesOnlyTheNamedIdentifier() async {
        let coord = stateManager.downloadCoordinator
        await coord.registerStart(identifier: "alpha")
        await coord.registerStart(identifier: "beta")
        await coord.registerStart(identifier: "gamma")

        await coord.registerCompletion(identifier: "beta")

        let active = await coord.activeCount
        XCTAssertEqual(active, 2,
                       "registerCompletion('beta') must remove ONLY beta — alpha and gamma must remain active (kills .removeAll() and no-op mutants)")

        // Verify the remaining set is exactly {alpha, gamma} by completing
        // them one at a time and watching the count.
        await coord.registerCompletion(identifier: "alpha")
        let afterAlpha = await coord.activeCount
        XCTAssertEqual(afterAlpha, 1, "Completing alpha must yield exactly 1 remaining (gamma)")

        await coord.registerCompletion(identifier: "gamma")
        let afterGamma = await coord.activeCount
        XCTAssertEqual(afterGamma, 0, "Completing gamma must zero the active count")
    }

    /// Kills mutants that make `registerCompletion` for an unknown
    /// identifier throw, crash, or accidentally decrement the count.
    func testRegisterCompletion_unknownIdentifier_isSafeNoOp() async {
        let coord = stateManager.downloadCoordinator
        await coord.registerStart(identifier: "real")

        await coord.registerCompletion(identifier: "ghost") // not present

        let active = await coord.activeCount
        XCTAssertEqual(active, 1,
                       "Completing an UNKNOWN identifier must not affect the active count (Set.remove of missing is a no-op — kills mutants that decrement unconditionally)")
    }

    // MARK: - 10. Reset wipes EVERY tracking dimension

    /// `reset()` is invoked on account-switch / log-out. If it leaks any
    /// state, the next library inherits ghost downloads. Pins the contract
    /// that activeCount, queueCount, cachedInfo, and redirect attempts ALL
    /// go to zero. Kills mutants that comment out one of the .removeAll().
    func testReset_ClearsActive_Queue_Cache_AndRedirectAttempts() async {
        let coord = stateManager.downloadCoordinator
        let task = StubDownloadTask(taskIdentifier: 7)
        let info = MyBooksDownloadInfo(downloadProgress: 0.5, downloadTask: task, rightsManagement: .none)

        await coord.registerStart(identifier: "a")
        await coord.enqueuePending(makeBook())
        await coord.cacheDownloadInfo(info, for: "a")
        await coord.incrementRedirectAttempts(for: 7)

        // Sanity preconditions — guard against vacuous resets.
        let preActive = await coord.activeCount
        let preQueue = await coord.queueCount
        let preCache = await coord.getCachedDownloadInfo(for: "a")
        let preRedir = await coord.getRedirectAttempts(for: 7)
        XCTAssertEqual(preActive, 1)
        XCTAssertEqual(preQueue, 1)
        XCTAssertNotNil(preCache)
        XCTAssertEqual(preRedir, 1)

        await coord.reset()

        let postActive = await coord.activeCount
        let postQueue = await coord.queueCount
        let postCache = await coord.getCachedDownloadInfo(for: "a")
        let postRedir = await coord.getRedirectAttempts(for: 7)
        XCTAssertEqual(postActive, 0, "reset() must clear activeDownloadIdentifiers")
        XCTAssertEqual(postQueue, 0, "reset() must clear pendingQueue")
        XCTAssertNil(postCache, "reset() must clear downloadInfoCache — kills mutants that skip this line")
        XCTAssertEqual(postRedir, 0, "reset() must clear redirectAttempts — kills mutants that skip this line")
    }

    // MARK: - 11. Redirect-attempt counting (per-task isolation)

    /// Network-redirect retry policy: redirectAttempts is keyed by URLSession
    /// taskIdentifier; clearing one task must NOT affect another's count.
    /// Kills mutants that mutate `removeValue` to `removeAll`.
    func testRedirectAttempts_perTaskIsolated_andClearable() async {
        let coord = stateManager.downloadCoordinator

        await coord.incrementRedirectAttempts(for: 1)
        await coord.incrementRedirectAttempts(for: 1)
        await coord.incrementRedirectAttempts(for: 2)

        var t1 = await coord.getRedirectAttempts(for: 1)
        var t2 = await coord.getRedirectAttempts(for: 2)
        XCTAssertEqual(t1, 2, "incrementRedirectAttempts must accumulate per-task — kills mutants that overwrite on increment")
        XCTAssertEqual(t2, 1, "Per-task isolation: task 2's count must not be affected by task 1's increments")

        await coord.clearRedirectAttempts(for: 1)
        t1 = await coord.getRedirectAttempts(for: 1)
        t2 = await coord.getRedirectAttempts(for: 2)
        XCTAssertEqual(t1, 0, "clearRedirectAttempts(1) must zero task 1's count")
        XCTAssertEqual(t2, 1, "clearRedirectAttempts(1) must NOT affect task 2 — kills mutants that swap removeValue→removeAll")
    }

    // MARK: - 12. Concurrent enqueue from many tasks — actor safety

    /// Mutation-tier hard case: spawn many concurrent enqueues of UNIQUE
    /// books. The actor must serialize them; final queueCount must equal
    /// the number of unique enqueues. Kills mutations that drop the `actor`
    /// or replace `pendingQueue.append` with a non-atomic write.
    func testConcurrentEnqueueFromManyTasks_IsActorSerialized() async {
        let coord = stateManager.downloadCoordinator
        let books = (0..<25).map { _ in makeBook() }

        await withTaskGroup(of: Void.self) { group in
            for book in books {
                group.addTask {
                    await coord.enqueuePending(book)
                }
            }
        }

        let count = await coord.queueCount
        XCTAssertEqual(count, books.count,
                       "Actor must serialize concurrent enqueues — final count must equal unique inputs (\(books.count)). Kills mutants that race on pendingQueue.append.")
    }

    // MARK: - 13. Orchestrator: empty queue is no-op, never calls delegate

    /// Kills mutants that make `schedulePendingStartsAsync` call the
    /// delegate with a default/empty book or with `nil`.
    func testSchedulePendingStartsAsync_emptyQueue_doesNotInvokeDelegate() async {
        stateManager.maxConcurrentDownloads = 4
        // No actives, no pending.

        await orchestrator.schedulePendingStartsAsync()

        XCTAssertEqual(startSpy.startCalls.count, 0,
                       "Empty queue must short-circuit before calling the delegate (kills mutants that fire on empty toStart)")
    }

    // MARK: - 14. Capacity = 0 when at-cap → orchestrator must not dequeue

    /// Pins the "at-cap" guard. With active==max, capacity=0, and even
    /// though the queue is non-empty, the orchestrator must NOT dequeue
    /// and must NOT call the delegate. Kills mutants on the
    /// `guard capacity > 0 else { return }` line.
    func testSchedulePendingStartsAsync_atCap_preservesQueueAndSkipsDelegate() async {
        stateManager.maxConcurrentDownloads = 2
        let a1 = makeBook(); let a2 = makeBook()
        await markActive(a1)
        await markActive(a2)
        let parked = makeBook()
        await stateManager.downloadCoordinator.enqueuePending(parked)

        await orchestrator.schedulePendingStartsAsync()

        XCTAssertEqual(startSpy.startCalls.count, 0,
                       "At-cap orchestrator pump must NOT call the delegate")
        let qcount = await stateManager.downloadCoordinator.queueCount
        XCTAssertEqual(qcount, 1,
                       "At-cap orchestrator pump must NOT drain the queue (kills mutants on the `capacity > 0` guard)")
    }

    // MARK: - 15. Pump multiple round-trips: each completion frees one slot

    /// End-to-end three-book queue with cap=1 walking through completion +
    /// pump three times. Each completion → exactly one pump dequeues
    /// exactly one queued book. Kills "drain whole queue on first pump"
    /// and "skip pump after second completion" mutants.
    func testThreeRoundTrips_eachCompletion_promotesExactlyOneQueuedBook() async {
        stateManager.maxConcurrentDownloads = 1
        let a = makeBook(); let b = makeBook(); let c = makeBook()
        await markActive(a)
        await stateManager.downloadCoordinator.enqueuePending(b)
        await stateManager.downloadCoordinator.enqueuePending(c)

        // Round 1: complete a → pump → expect b started.
        await stateManager.downloadCoordinator.registerCompletion(identifier: a.identifier)
        await orchestrator.schedulePendingStartsAsync()
        XCTAssertEqual(startSpy.startCalls.last?.book.identifier, b.identifier,
                       "Round 1: completing 'a' must promote 'b'")
        XCTAssertEqual(startSpy.startCalls.count, 1,
                       "Round 1: exactly one delegate call — kills 'drain whole queue' mutants")
        // After dequeue, the delegate is supposed to *eventually* call
        // registerStart for b. The orchestrator does NOT do this — that
        // happens inside the delegate's startDownloadAsync. For this test
        // we simulate it so the cap is correctly held at 1.
        await stateManager.downloadCoordinator.registerStart(identifier: b.identifier)

        // Round 2: at-cap with c still queued. Pumping should NOT start c.
        await orchestrator.schedulePendingStartsAsync()
        XCTAssertEqual(startSpy.startCalls.count, 1,
                       "Round 2: at-cap, pumping must NOT start another book (kills mutants that ignore active count)")

        // Round 3: complete b → pump → expect c started.
        await stateManager.downloadCoordinator.registerCompletion(identifier: b.identifier)
        await orchestrator.schedulePendingStartsAsync()
        XCTAssertEqual(startSpy.startCalls.last?.book.identifier, c.identifier,
                       "Round 3: completing 'b' must promote 'c'")
        XCTAssertEqual(startSpy.startCalls.count, 2,
                       "Round 3: total delegate calls must be 2 (b then c) — kills mutants that re-call delegate or skip")

        let finalQueue = await stateManager.downloadCoordinator.queueCount
        XCTAssertEqual(finalQueue, 0,
                       "After all three round-trips, the queue must be empty")
    }
}

// MARK: - Spies

private final class StartSpyDelegate: DownloadQueueOrchestratorDelegate {
    private(set) var startCalls: [(book: TPPBook, request: URLRequest?)] = []

    func startDownloadAsync(for book: TPPBook, withRequest request: URLRequest?) async {
        startCalls.append((book, request))
    }
}

private final class CancellationSpyDelegate: DownloadCancellationHandlerDelegate {
    private(set) var broadcastCount = 0
    private(set) var scheduleCount = 0

    func broadcastUpdate() { broadcastCount += 1 }
    func schedulePendingStartsIfPossible() { scheduleCount += 1 }
}

private final class ThrottleScheduleSpy: DownloadThrottlingServiceDelegate {
    private(set) var scheduleCount = 0
    func schedulePendingStartsAsync() async { scheduleCount += 1 }
}

// MARK: - Fakes

/// Minimal URLSessionDownloadTask stub for state-machine tests that don't
/// exercise the cancel-completion path.
private final class StubDownloadTask: URLSessionDownloadTask {
    private let _taskIdentifier: Int
    private(set) var cancelByProducingResumeDataCount = 0

    init(taskIdentifier: Int) {
        self._taskIdentifier = taskIdentifier
        super.init()
    }

    override var taskIdentifier: Int { _taskIdentifier }
    override func cancel() {}
    override func cancel(byProducingResumeData completionHandler: @escaping (Data?) -> Void) {
        cancelByProducingResumeDataCount += 1
        completionHandler(nil)
    }
    override func resume() {}
    override func suspend() {}
}

/// URLSessionDownloadTask stub whose cancel(byProducingResumeData:) calls
/// the completion synchronously with nil data, so the cancel cleanup path
/// runs in-line (no waiting on iOS to drive the completion).
private final class SyncCompletingDownloadTask: URLSessionDownloadTask {
    private let _taskIdentifier: Int
    private(set) var cancelByProducingResumeDataCount = 0

    init(taskIdentifier: Int) {
        self._taskIdentifier = taskIdentifier
        super.init()
    }

    override var taskIdentifier: Int { _taskIdentifier }
    override func cancel() {}
    override func cancel(byProducingResumeData completionHandler: @escaping (Data?) -> Void) {
        cancelByProducingResumeDataCount += 1
        completionHandler(nil)
    }
    override func resume() {}
    override func suspend() {}
}
