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

        // Wipe the on-disk OPDS2 catalog cache. The bundled-registry
        // snapshot path inside `AccountsManager.loadCatalogs()` writes
        // `accounts_catalog_<hash>.json` and the matching metadata file
        // into the app's Application Support directory (see
        // `AccountsManager.swift:841`/`:851`). When the pre-push gate
        // runs the wiring class AFTER `AccountsManagerHelpersTests` or
        // `AccountsManagerCancellationTests` — both of which explicitly
        // call `loadCatalogs()` — those bundled writes survive into the
        // wiring test methods. Wiring tests then call
        // `preloadAccountsFromDiskCacheSync()` and observe ~1142 bundled
        // accounts instead of the 171-entry fixture seed they injected,
        // which flips `currentAccount` away from the expected fixture
        // entry and fails `testLoadCatalogs_warmPath_drivesCurrentAccountPastBasicInfoLoaded`.
        // This is the same prefix list `AccountsManager.clearCache()`
        // uses at runtime.
        purgeAccountsDiskCacheForWiringTests()
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

        // Symmetry with setUp: wipe the on-disk OPDS2 catalog cache so
        // any bundled-registry snapshot a wiring test write through
        // `loadCatalogs()` cannot leak into the next XCTestCase class
        // that runs in this process. See setUpWithError for the failure
        // mode.
        purgeAccountsDiskCacheForWiringTests()

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

    // MARK: - Disk-cache cleanup

    /// Remove every on-disk catalog/auth/crawl cache file in the test
    /// process's Application Support sandbox so the next wiring test
    /// starts from a cold-cache baseline. Mirrors the prefix list
    /// `AccountsManager.clearCache()` uses at runtime:
    ///
    ///  - `accounts_catalog_<hash>.json`           (bundled or network catalog blob)
    ///  - `accounts_catalog_metadata_<hash>.json`  (timestamp + isBundled flag)
    ///  - `library_list_*`                         (raw library-registry list cache)
    ///  - `authentication_document_*`              (per-library auth-doc cache)
    ///  - `crawl_state_*`                          (per-hash crawl-state JSON)
    ///
    /// Missing files (cold-start) and missing directory are silently
    /// ignored — both are valid pre-test states.
    private func purgeAccountsDiskCacheForWiringTests() {
        let prefixes = [
            "library_list_",
            "accounts_catalog_",
            "accounts_catalog_metadata_",
            "authentication_document_",
            "crawl_state_",
        ]
        let fm = FileManager.default
        guard let appSupport = try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) else { return }
        guard let files = try? fm.contentsOfDirectory(
            at: appSupport,
            includingPropertiesForKeys: nil
        ) else { return }

        for file in files {
            let name = file.lastPathComponent
            if prefixes.contains(where: { name.hasPrefix($0) }) {
                try? fm.removeItem(at: file)
            }
        }
    }
}
