//
//  PalaceWiringTestCase.swift
//  PalaceTests
//
//  Base class for any XCTestCase that exercises `AccountsManager` and
//  related per-library state-machine wiring. Closes the intra-class
//  state-pollution gap that Wave 1's `PalaceTestSetup`
//  XCTestObservation does NOT cover: that observer fires after every
//  test CASE; it does not pre-clear state for the NEXT test method,
//  and it does not have a hook into the per-test method's own
//  `AccountsManager` instance constructor.
//
//  Symptom this base addresses: `AccountsManagerStateMachineWiringTests`
//  has 13 tests; running them in suite order, the terminal test
//  `testDriveCurrentAccountAuthDoc_terminalState_isNoOp` passes in
//  isolation but fails when it runs AFTER
//  `testStartDownload_endToEnd_capturedAccountIdReachesAuthorizationHeader`
//  in the same class because:
//
//    1. Each test method constructs its OWN `AccountsManager()` whose
//       init kicks off a background `loadCatalogs` that outlives the
//       test (unless the opt-out flag is set BEFORE init).
//    2. Combine sinks in the test body retain background work.
//    3. The instance-level `userAccounts` dictionary on AccountsManager
//       is per-instance, but the bookkeeping the wiring tests do on
//       `AccountStateStore.shared` and `UserDefaults` IS process-global.
//
//  This base:
//    - Invokes `SingletonResetRegistry.shared.invokeAll()` on every
//      setUp so the next test method starts with the same fully-clean
//      state the post-test observer leaves.
//    - Defensively flips `AccountsManager.deferInitialLoadCatalogsForTesting`
//      to `true` BEFORE any helper-minted manager is constructed.
//    - Owns a protected `cancellables` set that subclasses use for
//      Combine subscriptions; the base drains it on tearDown so leaks
//      cannot survive into the next test.
//    - Tracks every `AccountsManager` minted via `makeFreshAccountsManager`
//      and calls `cancelBackgroundWork()` on each in tearDown.
//
//  Subclasses keep their own setUp/tearDown logic — they MUST call
//  `super` to inherit these guarantees.
//
//  Test-target-only. swarm_4b64e4e0 Wave 1c.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import Combine
@testable import Palace

/// Base class for wiring tests. Subclasses inherit a deterministic
/// pre-test reset, a shared `cancellables` set, and automatic
/// cancellation of helper-minted `AccountsManager` instances on
/// tearDown. See header for the failure mode it closes.
///
/// **Contract — subclasses MUST:**
///  - Call `super.setUpWithError()` and `super.tearDownWithError()` if
///    they override either lifecycle hook.
///  - Store Combine subscriptions in `self.cancellables` rather than a
///    private set so the base can drain on tearDown.
///  - Mint `AccountsManager` via `makeFreshAccountsManager()` rather
///    than `AccountsManager()` so the cancellation hook fires.
class PalaceWiringTestCase: XCTestCase {

    /// Combine subscription bag for the subclass. The base drains this
    /// on `tearDownWithError`. Stored as `internal` so test methods can
    /// `.store(in: &cancellables)`; the property is mutated only on the
    /// main thread (test methods inherit `@MainActor` via XCTest's
    /// default isolation for sync test methods).
    var cancellables: Set<AnyCancellable> = []

    /// Internal list of `AccountsManager` instances minted via
    /// `makeFreshAccountsManager` during a single test method. tearDown
    /// walks this list and calls `cancelBackgroundWork()` on each, then
    /// empties the list so the next method starts clean. Stored as
    /// `private` — only `makeFreshAccountsManager` mutates it.
    private var managersToCancelOnTearDown: [AccountsManager] = []

    // MARK: - Lifecycle

    override func setUpWithError() throws {
        try super.setUpWithError()

        // Explicit reset invocation. The PalaceSingletonResetObserver
        // also fires `invokeAll()` post-test, but a method that constructs
        // a new `AccountsManager()` BEFORE its first observable transition
        // races with the prior method's lingering Combine sinks landing
        // on `AccountStateStore.shared`. Pre-clearing on setUp closes
        // that window for THIS class — the next method starts from a
        // pinned-clean state regardless of what the prior method left
        // behind.
        SingletonResetRegistry.shared.invokeAll()

        // Defensively set the opt-out flag. The post-test observer's
        // resetter list does NOT toggle this flag (it's owned by the
        // wiring suite, not the registry), so a prior test that flipped
        // it to false would leak forward without this line.
        #if DEBUG
        AccountsManager.deferInitialLoadCatalogsForTesting = true
        #endif
    }

    override func tearDownWithError() throws {
        // Drain Combine subscriptions FIRST so any cancellation-side
        // notifications they would observe land before we cancel the
        // managers.
        cancellables.removeAll()

        // Cancel background work on every helper-minted manager. We
        // capture the list locally and clear the stored property first
        // so a re-entrant tearDown (shouldn't happen, but) sees an empty
        // list. `cancelBackgroundWork()` is idempotent — already-cancelled
        // managers ignore the second call.
        let managers = managersToCancelOnTearDown
        managersToCancelOnTearDown.removeAll()
        for manager in managers {
            manager.cancelBackgroundWork()
        }

        try super.tearDownWithError()
    }

    // MARK: - Helpers

    /// Construct a fresh `AccountsManager` with the test-only background
    /// `loadCatalogs` deferral applied, then register the instance for
    /// `cancelBackgroundWork()` on tearDown.
    ///
    /// Use this instead of bare `AccountsManager()` in wiring tests so
    /// the suite-level isolation guarantees hold. The optional `configure`
    /// closure runs AFTER construction so callers can wire spy delegates
    /// or seed state before assertions.
    ///
    /// - Parameter configure: Closure to run on the constructed manager
    ///   before returning. Default no-op.
    /// - Returns: A constructed `AccountsManager` whose background
    ///   `loadCatalogs` Task was skipped at init (per the opt-out flag)
    ///   AND whose `cancelBackgroundWork()` will fire in tearDown
    ///   regardless of whether the test body called it.
    @discardableResult
    func makeFreshAccountsManager(_ configure: (AccountsManager) -> Void = { _ in }) -> AccountsManager {
        // Pin the opt-out flag immediately before construction. setUp
        // already set it, but a test method that intentionally toggled
        // it off mid-body must not poison helper construction after
        // that toggle.
        #if DEBUG
        AccountsManager.deferInitialLoadCatalogsForTesting = true
        #endif
        let manager = AccountsManager()
        configure(manager)
        managersToCancelOnTearDown.append(manager)
        return manager
    }
}
