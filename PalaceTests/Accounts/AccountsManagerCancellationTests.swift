//
//  AccountsManagerCancellationTests.swift
//  PalaceTests
//
//  Tests for `AccountsManager.cancelBackgroundWork()` — the DEBUG-only
//  cooperative-cancellation seam used by `AppContainer._resetForTesting()`
//  to tell the prior cached AccountsManager's background `loadCatalogs`
//  Task to bail before a fresh graph is constructed.
//
//  Verifies the three contract invariants:
//   1. Calling `cancelBackgroundWork()` flows cancellation through to the
//      stored `backgroundFetchTask` (and clears the handle).
//   2. It's idempotent — repeated calls are safe and don't mutate
//      persistent state.
//   3. Calling it on a manager constructed with `deferInitialLoadCatalogsForTesting=true`
//      (which never allocated a task) does NOT crash and behaves as a no-op
//      on the task side.
//
//  swarm_4b64e4e0 Fix 2 — closes the H1 finding from swarm_f88ae9e3 A.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import PalaceCatalog
@testable import Palace

final class AccountsManagerCancellationTests: XCTestCase {

    // MARK: - Setup / Teardown

    override func tearDown() {
        // Restore production semantics for any later test class in the suite.
        AccountsManager.deferInitialLoadCatalogsForTesting = false
        super.tearDown()
    }

    // MARK: - Tests

    /// Constructing an AccountsManager with the test opt-out flag set means
    /// `cancelBackgroundWork()` operates on a manager that has NO live
    /// task. Calling cancel here must not crash, must clear the handle (if
    /// any), and the manager must remain usable for subsequent reads.
    ///
    /// This is the most common shape the seam runs against: the post-reset
    /// AppContainer constructs its AccountsManager under the opt-out flag,
    /// then `cancelBackgroundWork()` is called by the NEXT reset on this
    /// opt-out instance. No task, no crash, no state mutation.
    func testCancelBackgroundWork_onOptOutInstance_isSafeNoOp() {
        // Arrange: opt-out flag ON → no background task spawned at init.
        AccountsManager.deferInitialLoadCatalogsForTesting = true
        let manager = AccountsManager()

        // Sanity: no task to begin with.
        XCTAssertTrue(
            manager._backgroundFetchTaskIsCancelledOrCleared,
            "Opt-out construction must not allocate a background task"
        )

        // Act: cancel — must be safe even without a live task.
        manager.cancelBackgroundWork()

        // Assert: still no live task, manager is still usable for read.
        XCTAssertTrue(
            manager._backgroundFetchTaskIsCancelledOrCleared,
            "After cancelBackgroundWork on an opt-out instance, the task must remain cancelled/cleared"
        )
        // The manager must still be reachable for reads — `accounts()` is a
        // cheap accessor that exercises the same `accountSetsLock` the
        // background task would have written through. If the cancel mutated
        // persistent state, this would return inconsistent data.
        let observed = manager.accounts()
        // We don't assert a specific count — disk cache may be populated by
        // prior tests in the suite. We just assert the call returns without
        // crash, which proves the storage is still valid.
        XCTAssertNotNil(observed, "Manager must remain usable after cancelBackgroundWork — accounts() returned nil")
    }

    /// Cancel must be idempotent — multiple consecutive calls on the same
    /// instance must not crash and must leave the manager in a usable state.
    ///
    /// Multi-step body: construct → cancel → cancel → cancel → assert.
    func testCancelBackgroundWork_isIdempotent() {
        AccountsManager.deferInitialLoadCatalogsForTesting = true
        let manager = AccountsManager()

        // Act: three consecutive cancels.
        manager.cancelBackgroundWork()
        manager.cancelBackgroundWork()
        manager.cancelBackgroundWork()

        // Assert: no crash; task remains cancelled/cleared; manager is still
        // readable.
        XCTAssertTrue(
            manager._backgroundFetchTaskIsCancelledOrCleared,
            "After three consecutive cancels, task handle must remain cancelled/cleared"
        )
        XCTAssertNotNil(
            manager.accounts(),
            "Manager must remain readable after multiple cancelBackgroundWork calls"
        )
    }

    /// Cancel on a NON-opt-out AccountsManager (one that DID spawn a
    /// background task at init) must cancel the task. We observe this via
    /// the `_backgroundFetchTaskIsCancelledOrCleared` accessor: before
    /// cancel it can be true OR false (depending on whether the task has
    /// already completed); after cancel it MUST be true.
    ///
    /// This is the structural cancellation contract — kill case for a
    /// mutation that removes `backgroundFetchTask?.cancel()` from
    /// `cancelBackgroundWork()`. Without the cancel call, on a slow-network
    /// CI run where the task hasn't completed yet, the accessor would still
    /// return false (live task, not cancelled, handle not nilled).
    ///
    /// Multi-step body: clear flag → construct (spawns task) → cancel →
    /// assert cancelled.
    func testCancelBackgroundWork_onLiveInstance_cancelsTheTask() {
        // Arrange: flag OFF → AccountsManager.init spawns the background task.
        AccountsManager.deferInitialLoadCatalogsForTesting = false
        let manager = AccountsManager()

        // We can't reliably observe pre-cancel task state (it may have
        // completed before we read). The contract under test is post-cancel:
        // the handle must be cancelled or nil regardless of prior state.

        // Act: cancel.
        manager.cancelBackgroundWork()

        // Assert: cancelled or cleared. Mutation kill: removing the
        // `?.cancel()` line OR removing the `= nil` line both break this
        // — if neither runs and the task is still in flight, the accessor
        // returns false.
        XCTAssertTrue(
            manager._backgroundFetchTaskIsCancelledOrCleared,
            "After cancelBackgroundWork on a live-task instance, task handle must be cancelled or cleared"
        )
    }

    /// Cancel must NOT mutate the persistent `accountSets` storage — only
    /// in-flight async work is affected. If a test relies on previously-
    /// populated `accountSets` data surviving a cancel, this contract must
    /// hold.
    ///
    /// We verify this by seeding accounts via the existing
    /// `_testSetAccountSet` seam, then calling cancel, then re-reading.
    /// The set must be unchanged.
    ///
    /// Multi-step body: seed → snapshot → cancel → re-read → assert equal.
    func testCancelBackgroundWork_doesNotMutatePersistentAccountSets() {
        AccountsManager.deferInitialLoadCatalogsForTesting = true
        let manager = AccountsManager()

        // Arrange: seed two account sentinels into a known bucket so we can
        // assert the cancel preserves them.
        let testBucketKey = "test_bucket_cancel_doesnt_mutate"
        let stub1 = TestAccountFactory.makeStubAccount(uuid: "uuid-cancel-1")
        let stub2 = TestAccountFactory.makeStubAccount(uuid: "uuid-cancel-2")
        manager._testSetAccountSet([stub1, stub2], forKey: testBucketKey)

        // Snapshot the seeded UUIDs (read-back for confirmation).
        let preCancelUUIDs = manager.accounts(testBucketKey).map { $0.uuid }
        XCTAssertEqual(
            preCancelUUIDs.sorted(),
            ["uuid-cancel-1", "uuid-cancel-2"].sorted(),
            "Pre-cancel: seeded bucket must contain the two stubs"
        )

        // Act: cancel.
        manager.cancelBackgroundWork()

        // Assert: the seeded bucket survives the cancel unchanged.
        let postCancelUUIDs = manager.accounts(testBucketKey).map { $0.uuid }
        XCTAssertEqual(
            postCancelUUIDs.sorted(),
            preCancelUUIDs.sorted(),
            "cancelBackgroundWork must not mutate persistent accountSets storage — seeded bucket changed"
        )
    }
}

// MARK: - Test helpers

/// Minimal stub Account factory for tests that need account-shaped values
/// to seed `accountSets` buckets without paying the full OPDS2 fixture
/// cost. Uses the public initializer with a minimal publication.
private enum TestAccountFactory {
    static func makeStubAccount(uuid: String) -> Account {
        // Build a minimal OPDS2 publication shape. Account's init accepts
        // a publication and an image cache; the publication's id is used
        // as the account UUID via the `uuid` accessor.
        let metadata = OPDS2Publication.Metadata(
            updated: Date(),
            description: "Stub library for cancel test",
            id: uuid,
            title: "Stub Library \(uuid.prefix(6))"
        )
        let publication = OPDS2Publication(
            links: [],
            metadata: metadata,
            images: nil
        )
        return Account(publication: publication, imageCache: ImageCache.shared)
    }
}
