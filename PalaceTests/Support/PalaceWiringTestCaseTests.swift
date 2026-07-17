//
//  PalaceWiringTestCaseTests.swift
//  PalaceTests
//
//  Verifies the `PalaceWiringTestCase` base-class contract — the test
//  fixture itself must (1) invoke `SingletonResetRegistry` on every
//  `setUp`, (2) drain its own `cancellables` set on every `tearDown`,
//  (3) cancel background work on any `AccountsManager` minted via the
//  base helper, and (4) honor the `deferInitialLoadCatalogsForTesting`
//  opt-out when constructing those managers.
//
//  These tests use a `Probe` subclass that exposes a hook into setUp /
//  tearDown timing so we can drive a single fixture lifecycle and assert
//  against the observed effects rather than relying on subsequent
//  test-method timing (which is at the mercy of XCTest's bundle
//  ordering).
//
//  Test-target-only. swarm_4b64e4e0 Wave 1c.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import Combine
@testable import Palace

@MainActor
final class PalaceWiringTestCaseTests: XCTestCase {

    // MARK: - Probe — a minimal subclass we can drive synchronously

    /// Subclass exposing the base lifecycle so we can call `setUpWithError`
    /// and `tearDownWithError` from this outer test and observe the effects.
    /// `XCTestCase`'s default no-arg `init()` is suitable for that — we never
    /// register `Probe` with the runner, we just instantiate it.
    @MainActor
    final class Probe: PalaceWiringTestCase {
        var cancellableDrainCount: Int { return drainObservedCancellableCount }
        private(set) var drainObservedCancellableCount: Int = 0

        // Override tearDown to record the cancellables count BEFORE the
        // base drains it. The base call below performs the drain; we
        // sample first so the assertion in the test can observe "the base
        // drained the set we populated."
        override func tearDownWithError() throws {
            drainObservedCancellableCount = cancellables.count
            try super.tearDownWithError()
        }
    }

    // MARK: - 1. setUp invokes every registered resetter

    /// Base contract: `setUpWithError` must explicitly invoke
    /// `SingletonResetRegistry.shared.invokeAll()`. The observer also
    /// fires it post-test, but a fresh test METHOD inside an existing
    /// test-class run needs its own pre-test reset because the prior
    /// method on the SAME class can have written state during its tearDown
    /// (or via Combine sinks completing late) — a window the observer's
    /// `testCaseDidFinish` did NOT cover for that specific class-internal
    /// transition.
    func testSetUp_runsAllResetters() throws {
        // Pin the registry to a known shape: clear, install a tracker,
        // run the probe's setUp, assert the tracker fired.
        SingletonResetRegistry.shared._removeAllForTests()
        defer { SingletonResetRegistry.shared._removeAllForTests() }

        var invocationCount = 0
        SingletonResetRegistry.shared.register("PalaceWiringTestCaseTests.tracker") {
            invocationCount += 1
        }

        let probe = Probe()
        try probe.setUpWithError()
        defer { try? probe.tearDownWithError() }

        XCTAssertGreaterThanOrEqual(invocationCount, 1,
                                    "PalaceWiringTestCase.setUpWithError must invoke SingletonResetRegistry — observed \(invocationCount) calls")
    }

    // MARK: - 2. tearDown drains cancellables

    /// Base contract: `tearDownWithError` must call `cancellables.removeAll()`
    /// on the base's protected `cancellables` set. A test method that adds
    /// Combine subscriptions to `cancellables` during its body must not
    /// see those subscriptions retained into the NEXT test method on the
    /// same class — that's the leak class this base closes.
    func testTearDown_drainsCancellables() throws {
        let probe = Probe()
        try probe.setUpWithError()

        // Seed the base's cancellables set. Use `PassthroughSubject` so we
        // have a concrete publisher to subscribe to; the subscription
        // count is what matters, not the publisher's value.
        let subject = PassthroughSubject<Int, Never>()
        subject.sink { _ in /* no-op — we only care about retention */ }
            .store(in: &probe.cancellables)
        subject.sink { _ in /* no-op */ }
            .store(in: &probe.cancellables)
        subject.sink { _ in /* no-op */ }
            .store(in: &probe.cancellables)

        XCTAssertEqual(probe.cancellables.count, 3,
                       "Pre-state: 3 sinks must be retained in the base cancellables set")

        // Act: drive tearDown. The Probe samples the pre-drain count first
        // (returning 3), then invokes `super.tearDownWithError()` which
        // performs the drain.
        try probe.tearDownWithError()

        XCTAssertEqual(probe.cancellableDrainCount, 3,
                       "Probe must observe 3 sinks pre-drain — this pins that we actually retained them")
        XCTAssertEqual(probe.cancellables.count, 0,
                       "Post-tearDown: cancellables set must be empty — base must drain it")
    }

    // MARK: - 3. tearDown cancels background work on registered managers

    /// Base contract: any `AccountsManager` minted via `makeFreshAccountsManager`
    /// must be cancelled in `tearDownWithError`. The base registers a
    /// teardown hook keyed to the manager instance; tearDown walks the
    /// hook list and calls `cancelBackgroundWork()` on each.
    ///
    /// We use the `_backgroundFetchTaskWasExplicitlyCancelled` observation
    /// surface (introduced by swarm_4b64e4e0 Fix 2) to distinguish "we
    /// called cancel" from "the task handle was nilled by some other path."
    func testTearDown_cancelsBackgroundWorkOnRegisteredManagers() throws {
        let probe = Probe()
        try probe.setUpWithError()

        // Mint two managers via the helper. Each must be registered for
        // tearDown-time cancellation.
        let m1 = probe.makeFreshAccountsManager()
        let m2 = probe.makeFreshAccountsManager()

        // Pre-state: neither has been explicitly cancelled yet.
        #if DEBUG
        XCTAssertFalse(m1._backgroundFetchTaskWasExplicitlyCancelled,
                       "Pre-state: m1 must not have been cancelled before tearDown")
        XCTAssertFalse(m2._backgroundFetchTaskWasExplicitlyCancelled,
                       "Pre-state: m2 must not have been cancelled before tearDown")
        #endif

        // Act: drive tearDown.
        try probe.tearDownWithError()

        // Assert: both managers received the explicit cancel.
        #if DEBUG
        XCTAssertTrue(m1._backgroundFetchTaskWasExplicitlyCancelled,
                      "tearDown must call cancelBackgroundWork() on m1 — observed flag was false")
        XCTAssertTrue(m2._backgroundFetchTaskWasExplicitlyCancelled,
                      "tearDown must call cancelBackgroundWork() on m2 — observed flag was false")
        #endif
    }

    // MARK: - 4. makeFreshAccountsManager applies the opt-out flag

    /// Base contract: `makeFreshAccountsManager` must construct the
    /// `AccountsManager` with `deferInitialLoadCatalogsForTesting = true`.
    /// Without this, the manager's init dispatches a background
    /// `loadCatalogs` Task whose completion writes into
    /// `AccountStateStore.shared` mid-test — exactly the cross-test race
    /// the base class exists to close. We assert the
    /// `_backgroundFetchTaskHandleIsNil` observation: the opt-out path
    /// returns BEFORE assigning the task handle, leaving it nil.
    func testMakeFreshAccountsManager_appliesTestOptOut() throws {
        let probe = Probe()
        try probe.setUpWithError()
        defer { try? probe.tearDownWithError() }

        let manager = probe.makeFreshAccountsManager()

        // The opt-out branch in AccountsManager.init returns BEFORE assigning
        // backgroundFetchTask, so the handle stays nil even though the
        // init ran to completion. The non-opt-out branch would assign a
        // `Task.detached` here.
        #if DEBUG
        XCTAssertTrue(manager._backgroundFetchTaskHandleIsNil,
                      "Opt-out path must leave backgroundFetchTask nil — handle was non-nil, opt-out flag was NOT honored at init")
        XCTAssertFalse(manager._backgroundFetchTaskWasExplicitlyCancelled,
                       "Opt-out path must not have invoked cancelBackgroundWork() yet — explicit-cancel flag was unexpectedly true")
        #endif
    }
}
