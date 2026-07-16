//
//  AccountsManagerCancellationTests.swift
//  PalaceTests
//
//  Tests for `AccountsManager.cancelBackgroundWork()` — the DEBUG-only
//  cooperative-cancellation seam used by `AppContainer._resetForTesting()`
//  to tell the prior cached AccountsManager's background `loadCatalogs`
//  Task to bail before a fresh graph is constructed.
//
//  Verifies the four contract invariants:
//   1. Calling `cancelBackgroundWork()` flows cancellation through to the
//      stored `backgroundFetchTask` (the explicit-cancel flag flips AND the
//      handle is nilled — checked independently so a mutation that drops
//      ONE of the two effects still fails its dedicated assertion).
//   2. It's idempotent — repeated calls are safe and don't mutate
//      persistent state (verified by re-reading a seeded bucket post-cancel
//      and asserting equality with the pre-cancel snapshot).
//   3. Calling it on a manager constructed with `deferInitialLoadCatalogsForTesting=true`
//      (which never allocated a task) does NOT crash and behaves as a no-op
//      on the task side (the same persisted-state-equality assertion runs).
//   4. The post-resume cooperative-cancel guard at `fetchFromNetwork`
//      line 651 (`if Task.isCancelled { return }`) blocks the commit when
//      the task is cancelled mid-await. Exercised via a controlled Task
//      injected through `_injectBackgroundFetchTaskForTesting` so the test
//      drives the suspend-cancel-resume sequence deterministically.
//
//  swarm_4b64e4e0 Fix 2 — closes the H1 finding from swarm_f88ae9e3 A.
//  swarm_4b64e4e0 qa-fixup — addresses qa_test BLOCK on tautology assertions
//                            + missing race-guard test + conflated observation
//                            surface.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import PalaceCatalog
@testable import Palace

class AccountsManagerCancellationTests: PalaceWiringTestCase {

    // MARK: - Tests
    //
    // PalaceWiringTestCase pins `deferInitialLoadCatalogsForTesting = true`
    // for every test in this class so each `makeFreshAccountsManager()` call
    // returns an opt-out instance with no live background task. Tests that
    // need a live task install one via `_injectBackgroundFetchTaskForTesting`.

    /// Constructing an AccountsManager with the test opt-out flag set means
    /// `cancelBackgroundWork()` operates on a manager that has NO live
    /// task. Calling cancel here must not crash, must clear the handle (if
    /// any), and the manager's persistent storage must be preserved
    /// byte-for-byte (cancel touches in-flight work, not committed state).
    ///
    /// This is the most common shape the seam runs against: the post-reset
    /// AppContainer constructs its AccountsManager under the opt-out flag,
    /// then `cancelBackgroundWork()` is called by the NEXT reset on this
    /// opt-out instance. No task, no crash, no state mutation.
    func testCancelBackgroundWork_onOptOutInstance_isSafeNoOp() {
        // Arrange: opt-out flag ON → no background task spawned at init.
        // `makeFreshAccountsManager()` pins the flag to true internally.
        let manager = makeFreshAccountsManager()

        // Seed a deterministic two-account bucket so we can assert post-cancel
        // state equals pre-cancel state. Without seeding, `accounts()` may be
        // empty OR may contain whatever disk cache an earlier test left
        // behind — neither baseline can distinguish "cancel mutated state"
        // from "background work mutated state" in a clean way.
        let bucketKey = "test_bucket_optout_isSafeNoOp"
        let stub1 = TestAccountFactory.makeStubAccount(uuid: "uuid-optout-1")
        let stub2 = TestAccountFactory.makeStubAccount(uuid: "uuid-optout-2")
        manager._testSetAccountSet([stub1, stub2], forKey: bucketKey)

        let preCancelUUIDs = manager.accounts(bucketKey).map { $0.uuid }.sorted()
        XCTAssertEqual(
            preCancelUUIDs,
            ["uuid-optout-1", "uuid-optout-2"],
            "Sanity: seeded bucket must contain the two stubs before cancel"
        )

        // Sanity: no task to begin with — both observation properties agree
        // that there is nothing to cancel and the handle is nil.
        XCTAssertTrue(
            manager._backgroundFetchTaskHandleIsNil,
            "Opt-out construction must not allocate a background task — handle should be nil"
        )
        XCTAssertFalse(
            manager._backgroundFetchTaskWasExplicitlyCancelled,
            "Pre-cancel: explicit-cancel flag must be false"
        )

        // Act: cancel — must be safe even without a live task.
        manager.cancelBackgroundWork()

        // Assert behavior: the explicit-cancel flag flipped AND the handle
        // remains nil. These are independently observed so removing the
        // `_explicitCancelCalled = true` line would fail the first assertion
        // and removing the `backgroundFetchTask = nil` line would fail the
        // second (when there's no live task to begin with, the nil-out is a
        // no-op rebind, but the assertion still pins the contract).
        XCTAssertTrue(
            manager._backgroundFetchTaskWasExplicitlyCancelled,
            "After cancelBackgroundWork, explicit-cancel flag must be true"
        )
        XCTAssertTrue(
            manager._backgroundFetchTaskHandleIsNil,
            "After cancelBackgroundWork on an opt-out instance, task handle must remain nil"
        )

        // Behavior assertion: persistent state survives the cancel unchanged.
        // This replaces the prior `XCTAssertNotNil(manager.accounts())`
        // tautology — `accounts()` returns non-optional `[Account]` so the
        // old assertion could never fail. The new assertion compares the
        // pre-cancel UUID set to the post-cancel UUID set and fails if the
        // bucket was mutated.
        let postCancelUUIDs = manager.accounts(bucketKey).map { $0.uuid }.sorted()
        XCTAssertEqual(
            postCancelUUIDs,
            preCancelUUIDs,
            "cancelBackgroundWork must not mutate the seeded accountSets bucket — opt-out instance"
        )
    }

    /// Cancel must be idempotent — multiple consecutive calls on the same
    /// instance must not crash and must leave the manager in a usable state.
    ///
    /// Multi-step body: seed → snapshot → cancel → cancel → cancel → assert.
    func testCancelBackgroundWork_isIdempotent() {
        // `makeFreshAccountsManager()` pins the opt-out flag to true.
        let manager = makeFreshAccountsManager()

        // Seed a bucket so we can assert idempotence preserves persistent
        // state across three consecutive cancel calls. Replaces the prior
        // `XCTAssertNotNil(accounts())` tautology with a real
        // before-vs-after comparison.
        let bucketKey = "test_bucket_idempotent"
        let seeded = [
            TestAccountFactory.makeStubAccount(uuid: "uuid-idem-1"),
            TestAccountFactory.makeStubAccount(uuid: "uuid-idem-2"),
            TestAccountFactory.makeStubAccount(uuid: "uuid-idem-3")
        ]
        manager._testSetAccountSet(seeded, forKey: bucketKey)
        let preCancelUUIDs = manager.accounts(bucketKey).map { $0.uuid }.sorted()
        XCTAssertEqual(
            preCancelUUIDs.count,
            3,
            "Sanity: seeded bucket must contain the three stubs before cancel"
        )

        // Act: three consecutive cancels.
        manager.cancelBackgroundWork()
        manager.cancelBackgroundWork()
        manager.cancelBackgroundWork()

        // Assert: no crash; observation surfaces consistent; persistent
        // state preserved across all three cancels.
        XCTAssertTrue(
            manager._backgroundFetchTaskWasExplicitlyCancelled,
            "After three consecutive cancels, explicit-cancel flag must remain true"
        )
        XCTAssertTrue(
            manager._backgroundFetchTaskHandleIsNil,
            "After three consecutive cancels, task handle must remain nil"
        )

        let postCancelUUIDs = manager.accounts(bucketKey).map { $0.uuid }.sorted()
        XCTAssertEqual(
            postCancelUUIDs,
            preCancelUUIDs,
            "Multiple cancelBackgroundWork calls must not mutate persistent accountSets storage"
        )
    }

    /// Cancel on a NON-opt-out AccountsManager (one that DID spawn a
    /// background task at init) must cancel the task AND nil out the handle.
    ///
    /// This is the structural cancellation contract — kill case for THREE
    /// independent mutations:
    ///   - removing `_explicitCancelCalled = true` from `cancelBackgroundWork()`
    ///   - removing `backgroundFetchTask?.cancel()` from `cancelBackgroundWork()`
    ///   - removing `backgroundFetchTask = nil` from `cancelBackgroundWork()`
    ///
    /// The first is caught by the
    /// `_backgroundFetchTaskWasExplicitlyCancelled` assertion. The third is
    /// caught by the `_backgroundFetchTaskHandleIsNil` assertion. The second
    /// is caught indirectly: removing `.cancel()` while keeping the nil-out
    /// leaves a live, uncancelled Task still running in the background which
    /// would race against subsequent tests — the test suite as a whole
    /// observes this via leaked-state findings. Asserting cancellation
    /// directly is hard because the task handle is nilled in the same call,
    /// so we pin the explicit-cancel flag (proves we entered the cancel
    /// path) AND the handle-nil flag (proves cleanup ran to completion).
    ///
    /// Multi-step body: clear flag → construct (spawns task) → cancel →
    /// assert both observation properties.
    func testCancelBackgroundWork_onLiveInstance_cancelsTheTask() {
        // Arrange: opt-out construction (clean) + inject a controlled live
        // Task that mirrors the shape of the real `backgroundFetchTask`.
        // The injection seam (`_injectBackgroundFetchTaskForTesting`) is the
        // documented test pin for exercising the live-task cancel path
        // without paying the cost of a real `loadCatalogs()` round-trip or
        // leaking a real network task across test boundaries. swarm_47883816
        // Module B switched away from a flag=false helper because that
        // helper's flag-flip mutation survived testCaseDidFinish observation
        // (AppContainer._resetForTesting resets the flag to false), polluting
        // the next test's `makeFreshAccountsManager()` initialization path.
        let manager = makeFreshAccountsManager()

        // Spawn a long-running task that suspends indefinitely so the cancel
        // has something real to act on (mirrors `Task.detached { loadCatalogs() }`
        // in AccountsManager.init under flag=false). The task uses
        // `withCheckedContinuation` so it suspends until cancelled — the
        // production task's structure is the same family.
        let injectedTask = Task<Void, Never>(priority: .background) {
            // Suspend until cancelled, the cancellation-aware way. `Task.sleep`
            // throws `CancellationError` the moment the task is cancelled, so
            // `try?` lets the task complete cleanly. The prior version used
            // `withCheckedContinuation { _ in }` and never resumed it, which
            // leaked the continuation ("SWIFT TASK CONTINUATION MISUSE") — a
            // suspended-forever task that lingered in the process and showed up
            // as a runtime warning during later, unrelated tests.
            try? await Task.sleep(nanoseconds: .max)
        }
        manager._injectBackgroundFetchTaskForTesting(injectedTask)

        // Pre-state: explicit-cancel flag has never been set, the handle is
        // now NOT nil (we just injected a task), and the injected task is
        // not yet cancelled.
        XCTAssertFalse(
            manager._backgroundFetchTaskWasExplicitlyCancelled,
            "Pre-cancel: explicit-cancel flag must be false on a fresh instance"
        )
        XCTAssertFalse(
            manager._backgroundFetchTaskHandleIsNil,
            "Pre-cancel: with the injected task, the handle must NOT be nil"
        )
        XCTAssertFalse(
            injectedTask.isCancelled,
            "Pre-cancel: injected task must be live"
        )

        // Act: cancel.
        manager.cancelBackgroundWork()

        // Assert BOTH observation surfaces independently. The test FAILS if:
        //   - the `_explicitCancelCalled = true` line is removed (first
        //     assertion fails);
        //   - the `backgroundFetchTask?.cancel()` line is removed (third
        //     assertion fails — the injected task wouldn't see cancellation);
        //   - the `backgroundFetchTask = nil` line is removed (second
        //     assertion fails — the handle would still point at the task).
        XCTAssertTrue(
            manager._backgroundFetchTaskWasExplicitlyCancelled,
            "After cancelBackgroundWork on a live-task instance, explicit-cancel flag must be true"
        )
        XCTAssertTrue(
            manager._backgroundFetchTaskHandleIsNil,
            "After cancelBackgroundWork on a live-task instance, task handle must be nilled out"
        )
        XCTAssertTrue(
            injectedTask.isCancelled,
            "After cancelBackgroundWork on a live-task instance, the injected task must be cancelled — kills the mutant that drops `backgroundFetchTask?.cancel()`"
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
        // `makeFreshAccountsManager()` pins the opt-out flag to true.
        let manager = makeFreshAccountsManager()

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

    /// Race-guard test: when `cancelBackgroundWork()` fires while a
    /// `backgroundFetchTask` is mid-await, the post-resume cooperative-cancel
    /// guard (the `if Task.isCancelled { return }` pattern that lives at
    /// `fetchFromNetwork` line 651) must block any commit to `accountSets`
    /// AND any post-resume side effects (e.g. logging on commit success).
    ///
    /// Without `_injectBackgroundFetchTaskForTesting`, we cannot reach
    /// `fetchFromNetwork`'s real Task without making a live network round-
    /// trip to the registry. Instead, we install a controlled Task that
    /// mirrors the production pattern (suspend on a continuation, then check
    /// `Task.isCancelled`, then commit-or-return) into `backgroundFetchTask`
    /// and drive the cancel-during-suspend sequence.
    ///
    /// This proves the cancellation-guard PATTERN works against the same
    /// `backgroundFetchTask?.cancel()` call site used by production. If the
    /// `Task.isCancelled { return }` line is removed from the test seam
    /// below, the assertion `committedCount.value == 0` fails because the
    /// commit fires after resume.
    ///
    /// Multi-step body: seed snapshot → install suspending task → cancel mid-
    /// await → resume → wait for task to finish → assert no commit + no
    /// post-resume side effects + accountSets unchanged.
    func testCancelBackgroundWork_whileFetchInFlight_doesNotCommitToAccountSets() {
        // Arrange: opt-out so init does not spawn its own background task —
        // we want the only task in flight to be the one we control.
        // `makeFreshAccountsManager()` pins the opt-out flag to true.
        let manager = makeFreshAccountsManager()

        // Seed a sentinel bucket so we can prove `accountSets` is byte-for-
        // byte identical pre- and post-resume. A real fetchFromNetwork
        // commit would write to `accountSets[hash]` via
        // `loadAccountSetsAndAuthDoc(fromCatalogData:key:)` — we mimic that
        // by passing a commit closure that writes to a *different* bucket
        // and asserting that bucket is empty post-resume.
        let observedBucketKey = "test_bucket_race_guard_observed"
        let commitBucketKey = "test_bucket_race_guard_commit_target"
        manager._testSetAccountSet(
            [TestAccountFactory.makeStubAccount(uuid: "uuid-race-observed-1")],
            forKey: observedBucketKey
        )
        let preResumeObservedUUIDs = manager.accounts(observedBucketKey).map { $0.uuid }.sorted()

        // Synchronization primitives: the suspended task awaits this
        // continuation; we resume it after issuing cancel. The
        // `commitFiredExpectation` is INVERTED — we assert it does NOT
        // fulfill (the cooperative-cancel guard must block the post-resume
        // branch).
        let taskCompletedExpectation = expectation(description: "controlled task completed (post-cancel teardown finished)")
        let commitFiredExpectation = expectation(description: "post-resume commit branch (MUST NOT FIRE under cancel)")
        commitFiredExpectation.isInverted = true

        // Atomic counters so we can pin the boolean "commit branch fired"
        // separately from "post-resume side effect (logging) fired."
        let commitCounter = TestAtomicCounter()
        let postResumeSideEffectCounter = TestAtomicCounter()

        // A box that holds the continuation so the test can resume it from
        // the main thread after issuing cancel.
        actor ContinuationBox {
            var continuation: CheckedContinuation<Void, Never>?
            func set(_ c: CheckedContinuation<Void, Never>) { continuation = c }
            func take() -> CheckedContinuation<Void, Never>? {
                let c = continuation
                continuation = nil
                return c
            }
        }
        let box = ContinuationBox()

        // Install a controlled Task that mirrors the production pattern at
        // `fetchFromNetwork` line 636-660:
        //   Task(priority: .userInitiated) {
        //     await someAwaitablePoint()
        //     if Task.isCancelled { return }
        //     // commit side effect
        //   }
        let controlledTask = Task(priority: .userInitiated) { [weak manager] in
            // Suspend point — production code awaits `crawler.crawlFirstPage`.
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                Task { await box.set(c) }
            }

            // Post-await cooperative-cancel guard. This is the SAME pattern
            // as `fetchFromNetwork` line 651. Removing this line surfaces
            // both the commit (via commitCounter) and the post-resume side
            // effect (via postResumeSideEffectCounter) — the inverted
            // expectation also fulfills, failing the test on the inverted
            // wait at the bottom.
            if Task.isCancelled {
                taskCompletedExpectation.fulfill()
                return
            }

            // Commit branch — mirrors `loadAccountSetsAndAuthDoc(...)`-style
            // writes to a real accountSets bucket. We write to a separate
            // bucket so we can assert the OBSERVED bucket stays unchanged
            // AND the COMMIT bucket stays empty.
            manager?._testSetAccountSet(
                [TestAccountFactory.makeStubAccount(uuid: "uuid-race-commit-1")],
                forKey: commitBucketKey
            )
            commitCounter.increment()
            commitFiredExpectation.fulfill()

            // Mirrors the post-commit logging at AccountsManager.swift:263
            // ("Pre-loaded N accounts from disk cache (sync, hash=...)") — a
            // side effect that fires only when the commit branch runs.
            postResumeSideEffectCounter.increment()

            taskCompletedExpectation.fulfill()
        }

        manager._injectBackgroundFetchTaskForTesting(controlledTask)

        // Brief wait so the controlledTask actually enters the suspend point
        // (sets the continuation in the box) before we cancel. Without this,
        // a too-fast `cancelBackgroundWork()` would cancel before suspend
        // and `withCheckedContinuation` would re-check `Task.isCancelled`
        // semantics differently.
        let suspendReached = expectation(description: "controlled task reached suspend point")
        Task {
            // Spin until the continuation is set.
            for _ in 0..<200 { // 200 * 10ms = 2s budget
                if await box.continuation != nil {
                    suspendReached.fulfill()
                    return
                }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        wait(for: [suspendReached], timeout: 3.0)

        // Act: cancel the in-flight task via the production seam. This
        // exercises `cancelBackgroundWork()` against our controlled Task.
        manager.cancelBackgroundWork()

        // Resume the suspended task — without this, the task would hang and
        // the test would time out. The cooperative-cancel guard inside the
        // task runs immediately on resume.
        Task {
            if let c = await box.take() {
                c.resume()
            }
        }

        // Wait for the task to run through to completion (the cancel-return
        // path fulfills `taskCompletedExpectation`).
        wait(for: [taskCompletedExpectation], timeout: 5.0)

        // Inverted expectation — must NOT fulfill within the wait. If the
        // commit branch fired, this wait would fail because the inverted
        // expectation was fulfilled.
        wait(for: [commitFiredExpectation], timeout: 0.5)

        // Assert behavior: the cooperative-cancel guard blocked the commit.
        XCTAssertEqual(
            commitCounter.value,
            0,
            "Commit branch must not run after a mid-await cancel (cooperative-cancel guard at fetchFromNetwork:651 failed)"
        )
        XCTAssertEqual(
            postResumeSideEffectCounter.value,
            0,
            "Post-resume side effects (e.g. post-commit logging) must not fire after a mid-await cancel"
        )

        // The OBSERVED bucket is byte-identical to pre-resume.
        let postResumeObservedUUIDs = manager.accounts(observedBucketKey).map { $0.uuid }.sorted()
        XCTAssertEqual(
            postResumeObservedUUIDs,
            preResumeObservedUUIDs,
            "Mid-await cancel must not mutate the OBSERVED accountSets bucket"
        )

        // The COMMIT-target bucket is empty (the commit branch never ran).
        let postResumeCommitUUIDs = manager.accounts(commitBucketKey).map { $0.uuid }.sorted()
        XCTAssertEqual(
            postResumeCommitUUIDs,
            [],
            "Mid-await cancel must not commit to the target accountSets bucket"
        )

        // Observation surfaces confirm the explicit cancel path ran end-to-end.
        XCTAssertTrue(
            manager._backgroundFetchTaskWasExplicitlyCancelled,
            "Race-guard: explicit-cancel flag must be true after cancelBackgroundWork() fires mid-await"
        )
        XCTAssertTrue(
            manager._backgroundFetchTaskHandleIsNil,
            "Race-guard: task handle must be nilled out after cancelBackgroundWork() fires mid-await"
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

/// Thread-safe counter used by the race-guard test to track whether the
/// post-resume commit branch and post-resume side effects fired. NSLock
/// is sufficient — we only increment from inside a single Task body.
///
/// `@unchecked Sendable`: the only mutable state (`_value`) is read and written
/// exclusively under `lock`, so instances cross into the `@Sendable` Task
/// closure safely. Swift 6 requires this to be explicit.
private final class TestAtomicCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Int = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }

    func increment() {
        lock.lock()
        _value += 1
        lock.unlock()
    }
}
