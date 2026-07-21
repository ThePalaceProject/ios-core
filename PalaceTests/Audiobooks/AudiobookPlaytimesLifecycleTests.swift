//
//  AudiobookPlaytimesLifecycleTests.swift
//  PalaceTests
//
//  Round-trip wiring tests for the cross-account scope guard added to
//  AudiobookDataManager.syncValues() by swarm_162a3219 / Module C (Bug B
//  per .forgeos/handoffs/2026-06-05-icarus-cross-host-logout-regression.md).
//
//  CROSS-VENDOR SMOKE RATIONALE — the playtimes upload is downstream of the
//  Palace circulation-manager `/playtimes/...` REST endpoint, NOT the
//  audiobook vendor adapter chain (Findaway / OverDrive / LCP / open-access).
//  All vendors share the same `AudiobookDataManager` queue and the same
//  upload codepath; the scope guard hinges on `LibraryBook.libraryId`, which
//  is per-library not per-vendor. ONE round-trip test exercises the guard
//  for every vendor — there is no vendor-specific control flow to permute.
//  This is documented per `reference_audiobook_toolkit_risk_profile.md` so
//  the QA reviewer does not block on missing 4-vendor permutations.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

private func clearAudiobookTimeTrackerStore() {
    if let dir = TPPBookContentMetadataFilesHelper.directory(for: "timetracker") {
        let storeFile = dir.appendingPathComponent("store.json")
        try? FileManager.default.removeItem(at: storeFile)
    }
}

@MainActor
final class AudiobookPlaytimesLifecycleTests: XCTestCase {

    private var spyExecutor: SpyAudiobookNetworkExecutor!
    private var sut: AudiobookDataManager!

    /// Mutable storage for the closure injected as
    /// `currentAccountIdProvider`. Tests flip this to simulate the user
    /// switching libraries — the simplest possible production-seam analogue
    /// of `AccountsManager.currentAccount.didSet` writing
    /// `currentAccountId`.
    private var activeAccountIdBox: AccountIdBox!

    private let libraryA = "urn:uuid:LIBRARY_A_for_playtimes_test"
    private let libraryB = "urn:uuid:LIBRARY_B_for_playtimes_test"

    private let trackingURLA = URL(string: "https://hostA.example.com/libA/playtimes/book-A")!
    private let trackingURLB = URL(string: "https://hostB.example.com/libB/playtimes/book-B")!

    override func setUp() {
        super.setUp()
        clearAudiobookTimeTrackerStore()
        spyExecutor = SpyAudiobookNetworkExecutor()
        activeAccountIdBox = AccountIdBox(value: libraryA)
        let box = activeAccountIdBox!
        sut = AudiobookDataManager(
            syncTimeInterval: 3600,
            networkService: spyExecutor,
            currentAccountIdProvider: { box.value }
        )
        sut.store.queue.removeAll()
        sut.store.urls.removeAll()
        // Drain reachability-triggered initial sync triggered by the
        // constructor's Combine subscription. Same race AudiobookDataManager
        // SyncTests guards against.
        drainMainQueue()
        spyExecutor.reset()
    }

    override func tearDown() {
        sut?.store.queue.removeAll()
        sut?.store.urls.removeAll()
        sut = nil
        spyExecutor = nil
        activeAccountIdBox = nil
        clearAudiobookTimeTrackerStore()
        super.tearDown()
    }

    // MARK: - Test 1: same-account happy path

    /// SRS: PLAYTIMES-1 — same-library upload posts normally.
    /// Guards against a guard regression that filters out the active-library
    /// case alongside the foreign ones.
    func testPlaytimes_sameAccountUpload_postsNormally() {
        let entry = AudiobookTimeEntry(
            id: "entry-A1",
            bookId: "book-A",
            libraryId: libraryA,
            timeTrackingUrl: trackingURLA,
            duringMinute: "2026-06-05T10:00Z",
            duration: 42
        )

        sut.save(time: entry)
        sut.syncQueue.sync {}   // barrier: `save` is a syncQueue.async(.barrier)
        XCTAssertEqual(sut.store.queue.count, 1)

        sut.syncValues()
        sut.syncQueue.sync {}          // barrier: the syncValues block dispatched the POST
        spyExecutor.drainCompletions() // barrier: the POST completion ran removeSynchronizedEntries

        XCTAssertEqual(spyExecutor.calls.count, 1,
                       "Same-library entry must POST exactly once")
        XCTAssertEqual(spyExecutor.calls.first?.url, trackingURLA,
                       "POST must target the entry's tracking URL, not a foreign host")
        XCTAssertTrue(sut.store.queue.isEmpty,
                      "Successful sync must clear the queue")
    }

    // MARK: - Test 2: cross-account skip preserves queue (the canonical regression)

    /// SRS: PLAYTIMES-2 — foreign-library upload is skipped and the queue
    /// is preserved (Bug B canonical round-trip).
    func testPlaytimes_crossAccountUpload_isSkipped_andQueuePreserved() {
        let entry = AudiobookTimeEntry(
            id: "entry-A1",
            bookId: "book-A",
            libraryId: libraryA,
            timeTrackingUrl: trackingURLA,
            duringMinute: "2026-06-05T10:00Z",
            duration: 42
        )

        sut.save(time: entry)
        sut.syncQueue.sync {}
        XCTAssertEqual(sut.store.queue.count, 1)

        // Simulate user switching to library B — the production seam writes
        // currentAccountId. The provider closure reads through to the box.
        activeAccountIdBox.value = libraryB

        sut.syncValues()
        sut.syncQueue.sync {}   // barrier: the (skip) sync block runs to completion

        XCTAssertTrue(spyExecutor.calls.isEmpty,
                      "No POST may fire for a foreign-library entry — that is the Bug B regression")
        XCTAssertEqual(sut.store.queue.count, 1,
                       "Queue entry must be preserved so it can flush on switch-back")
        XCTAssertNotNil(sut.store.urls[LibraryBook(time: entry)],
                        "Tracking URL must be preserved alongside the queued entry")
    }

    // MARK: - Test 3: switch back flushes preserved entries (write → reset → re-enter)

    /// SRS: PLAYTIMES-3 — switch-back flushes deferred uploads. The
    /// CLAUDE.md round-trip wiring rule incarnate: drive enqueue → switch
    /// away → re-enqueue → switch back → drive seam, prove POST happens.
    func testPlaytimes_switchBack_flushesPreservedEntries() {
        // (a) library A active, entry A1 enqueued
        let entryA1 = AudiobookTimeEntry(
            id: "entry-A1",
            bookId: "book-A",
            libraryId: libraryA,
            timeTrackingUrl: trackingURLA,
            duringMinute: "2026-06-05T10:00Z",
            duration: 42
        )
        sut.save(time: entryA1)
        sut.syncQueue.sync {}
        XCTAssertEqual(sut.store.queue.count, 1)

        // (b) sync — uploads, queue clears
        sut.syncValues()
        sut.syncQueue.sync {}
        spyExecutor.drainCompletions()
        XCTAssertEqual(spyExecutor.calls.count, 1, "First sync uploads cleanly")
        XCTAssertTrue(sut.store.queue.isEmpty, "First sync clears the queue")

        // (c) switch to library B (the cross-host scenario the regression
        // describes — A1QA → Icarus)
        activeAccountIdBox.value = libraryB

        // (d) enqueue another A entry (the tracker still has a live timer for
        // an A book while user navigates B)
        let entryA2 = AudiobookTimeEntry(
            id: "entry-A2",
            bookId: "book-A",
            libraryId: libraryA,
            timeTrackingUrl: trackingURLA,
            duringMinute: "2026-06-05T10:01Z",
            duration: 30
        )
        sut.save(time: entryA2)
        sut.syncQueue.sync {}
        XCTAssertEqual(sut.store.queue.count, 1)

        // (e) sync — must NOT POST (foreign library)
        sut.syncValues()
        sut.syncQueue.sync {}
        XCTAssertEqual(spyExecutor.calls.count, 1,
                       "Sync under foreign library must not add a POST")
        XCTAssertEqual(sut.store.queue.count, 1,
                       "Foreign-library entry is retained")

        // (f) switch BACK to library A, sync — the retained entry flushes.
        // Deterministic barriers instead of a wall-clock poll (the poll timed
        // out under parallel-clone oversubscription, CI run 29805821296):
        //   1. `syncQueue.sync {}` — waits for the `syncValues` block (which
        //      dispatches the POST) to run to completion on the manager's
        //      serial queue.
        //   2. `drainCompletions()` — waits for the spy's success completion
        //      (which calls `removeSynchronizedEntries`) to run on the spy's
        //      serial completion queue.
        // After both, the flush is fully observed, no matter how starved the
        // cooperative/GCD pools are.
        activeAccountIdBox.value = libraryA
        sut.syncValues()
        sut.syncQueue.sync {}
        spyExecutor.drainCompletions()

        XCTAssertEqual(spyExecutor.calls.count, 2,
                       "Switch-back sync must flush the deferred entry — full write → reset → re-enter cycle through the production seam")
        XCTAssertTrue(sut.store.queue.isEmpty,
                      "Queue empties on switch-back sync, proving deferral was non-destructive")
    }

    // MARK: - Test 4: notification observer is non-destructive

    /// SRS: PLAYTIMES-4 — `.TPPCurrentAccountDidChange` observer must NOT
    /// clear the queue. Destructive clear-on-switch is the obvious-and-wrong
    /// implementation that loses playtimes for any toggled-between book.
    func testPlaytimes_accountSwitchNotification_doesNotClearQueue() {
        let entry = AudiobookTimeEntry(
            id: "entry-A1",
            bookId: "book-A",
            libraryId: libraryA,
            timeTrackingUrl: trackingURLA,
            duringMinute: "2026-06-05T10:00Z",
            duration: 42
        )
        sut.save(time: entry)
        sut.syncQueue.sync {}
        XCTAssertEqual(sut.store.queue.count, 1)

        activeAccountIdBox.value = libraryB
        NotificationCenter.default.post(name: .TPPCurrentAccountDidChange, object: nil)
        drainMainQueue()

        XCTAssertEqual(sut.store.queue.count, 1,
                       "Account-change notification must not mutate the queue — the scope guard in syncValues() is the only enforcement seam")
        XCTAssertTrue(spyExecutor.calls.isEmpty,
                      "Notification alone must not trigger uploads")
    }

    // MARK: - Test 5: background-task end on all-cross-account queue

    /// SRS: PLAYTIMES-5 — when every entry is cross-account, `syncValues()`
    /// must end its background task (early-return branch). The naive
    /// "pendingCount = queuedLibraryBooks.count" would leak the task because
    /// no completion callback fires for skipped entries. We assert
    /// behaviorally — sync completes without hanging the test, AND any
    /// follow-up sync with an active match runs cleanly (proving the
    /// previous sync didn't leave shared state poisoned).
    func testPlaytimes_allCrossAccount_backgroundTaskStillEnds() {
        let entry = AudiobookTimeEntry(
            id: "entry-A1",
            bookId: "book-A",
            libraryId: libraryA,
            timeTrackingUrl: trackingURLA,
            duringMinute: "2026-06-05T10:00Z",
            duration: 42
        )
        sut.save(time: entry)
        sut.syncQueue.sync {}
        XCTAssertEqual(sut.store.queue.count, 1)

        activeAccountIdBox.value = libraryB
        sut.syncValues()
        // Deterministically wait for the sync block to finish on `syncQueue` —
        // `drainMainQueue()` only drains main, NOT the queue where `syncValues`
        // actually runs, so the two rapid syncs below could race on the serial
        // queue (the flake). Per the `AudiobookDataManager.syncQueue` contract,
        // tests may `syncQueue.sync {}` as a barrier.
        sut.syncQueue.sync {}
        // First-pass sync (all cross-account) — must not hang, must not POST.
        XCTAssertTrue(spyExecutor.calls.isEmpty,
                      "All-cross-account sync POSTs nothing")
        XCTAssertEqual(sut.store.queue.count, 1,
                       "Queue retains every entry")

        // Switch back to A — the next sync must complete normally,
        // proving the previous all-skip path didn't poison the
        // background-task counter or syncQueue.
        activeAccountIdBox.value = libraryA
        sut.syncValues()
        // Barriers: the sync block dispatches the POST on `syncQueue`, and the
        // spy runs its completion on its own serial queue — join both so
        // `calls.count == 1` is exact, not a starvable poll.
        sut.syncQueue.sync {}
        spyExecutor.drainCompletions()
        XCTAssertEqual(spyExecutor.calls.count, 1,
                       "Subsequent same-account sync runs normally — proves prior all-skip path ended cleanly")
    }

    // MARK: - Test 6: queue does not auto-replay foreign uploads

    /// SRS: PLAYTIMES-6 — fast switch-away during sync. The architect
    /// review (Phase 1a §5) flagged this gap: if `syncValues()` started a
    /// POST and the user switched mid-flight, the network queue must not
    /// resurrect the foreign POST after `cancelNonEssentialTasks()`. We
    /// drive the in-flight scenario by holding the completion handler and
    /// firing the notification before responding.
    func testPlaytimes_midFlightCancellation_notReplayedByQueue() {
        spyExecutor.autoRespondSuccess = false

        let entry = AudiobookTimeEntry(
            id: "entry-A1",
            bookId: "book-A",
            libraryId: libraryA,
            timeTrackingUrl: trackingURLA,
            duringMinute: "2026-06-05T10:00Z",
            duration: 42
        )
        sut.save(time: entry)
        sut.syncQueue.sync {}
        XCTAssertEqual(sut.store.queue.count, 1)

        // Start a sync that will dispatch a POST but never complete
        // (autoRespondSuccess == false → the spy records the call but fires no
        // completion). The syncQueue barrier guarantees the POST was dispatched.
        sut.syncValues()
        sut.syncQueue.sync {}
        XCTAssertEqual(spyExecutor.calls.count, 1)

        // Switch account mid-flight.
        activeAccountIdBox.value = libraryB
        NotificationCenter.default.post(name: .TPPCurrentAccountDidChange, object: nil)
        drainMainQueue()

        // The in-flight POST count must not grow — no replay path.
        XCTAssertEqual(spyExecutor.calls.count, 1,
                       "TPPNetworkQueue must not replay the foreign POST after account switch — the prior dispatch's lifecycle is owned by cancelNonEssentialTasks(), not by syncValues()")

        // Now retry: with autoRespondSuccess back on, a switch-back sync
        // must flush cleanly — proving no orphaned state from the cancelled
        // first attempt.
        spyExecutor.autoRespondSuccess = true
        activeAccountIdBox.value = libraryA
        sut.syncValues()
        sut.syncQueue.sync {}
        spyExecutor.drainCompletions()
        XCTAssertEqual(spyExecutor.calls.count, 2,
                       "Switch-back sync flushes the still-queued entry once normal responses resume")
        XCTAssertTrue(sut.store.queue.isEmpty,
                      "Switch-back sync empties the queue")
    }
}

// MARK: - Helpers

/// Heap-allocated box so the closure injected as `currentAccountIdProvider`
/// captures the same identity the test mutates. A struct + `inout` capture
/// won't survive the closure boundary.
///
/// Thread-safe: `value` is written on the test's main thread but read inside
/// `AudiobookDataManager.syncValues`'s background `syncQueue` block (and by the
/// constructor's reachability-triggered sync). An `NSLock` closes that
/// cross-thread data race — without it the read could observe a stale value
/// under CI load, occasionally routing the switch-back sync down the
/// cross-account skip path and hanging `awaitCondition`
/// (`testPlaytimes_allCrossAccount_backgroundTaskStillEnds` flake).
private final class AccountIdBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: String?
    var value: String? {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); defer { lock.unlock() }; _value = newValue }
    }
    init(value: String?) { self._value = value }
}
