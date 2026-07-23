//
//  AccountsManagerLaunchSnapshotTests.swift
//  PalaceTests
//
//  CP-D1 (LaunchHydration) tests for the slim launch-snapshot split in
//  `AccountsManager`. Profiling established that the pre-CP-D1
//  `preloadAccountsFromDiskCacheSync` cost ~207ms on a fast sim (95ms decode
//  + 112ms mapping 1142 accounts) on the launch main thread. CP-D1 hydrates
//  only a SLIM snapshot (current + settings accounts) synchronously and moves
//  the full 1142-account decode+map OFF-MAIN behind the existing
//  `Account.awaitReady()` gate.
//
//  These tests pin the four contract behaviours:
//    1. Slim-snapshot correctness — only current + settings accounts hydrate
//       synchronously; the slim set does NOT leak into `accountSets`.
//    2. Picker-full-count — `accounts()` reaches the FULL fixture count, not
//       the slim count, once the full list materializes via the production
//       seam (so `accountsHaveLoaded` still reflects the full list — the
//       library-picker truncation guard from Phase 1a correction #2).
//    3. Round-trip through the production seam (slim preload → library
//       reselect away → back → re-drive), NOT `_setState` shortcuts.
//    4. Consumer smoke — the readiness gate is DRIVEN (not left hanging) for
//       the current account after cold launch AND after a library swap.
//  Plus unit coverage of the pure `carveSlimFeed` carve.
//
//  Isolation is inherited from `PalaceWiringTestCase` (see its header):
//  per-test `SingletonResetRegistry.invokeAll()`,
//  `deferInitialLoadCatalogsForTesting = true`, `cancelBackgroundWork()` on
//  every helper-minted manager in tearDown, and an Application-Support
//  `accounts_catalog_*` purge in setUp + tearDown (which also sweeps the
//  `accounts_catalog_slim_*` files these tests write).
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import PalacePreferences
import PalaceCatalog
@testable import Palace

@MainActor
final class AccountsManagerLaunchSnapshotTests: PalaceWiringTestCase {

    // MARK: - Fixtures

    private var feedData: Data!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let bundle = Bundle(for: type(of: self))
        guard let feedURL = bundle.url(forResource: "OPDS2CatalogsFeed", withExtension: "json") else {
            throw XCTSkip("OPDS2CatalogsFeed.json fixture missing from PalaceTests bundle")
        }
        feedData = try Data(contentsOf: feedURL)
    }

    // MARK: - Helpers

    private func loadFeedCatalogs() throws -> [OPDS2Publication] {
        let feed = try OPDS2CatalogsFeed.fromData(feedData)
        guard feed.catalogs.count >= 3 else {
            throw XCTSkip("OPDS2CatalogsFeed fixture needs at least 3 catalogs")
        }
        return feed.catalogs
    }

    /// Derive the active catalog hash the same way `AccountsManager.init` does,
    /// so seeds land where preload/loadCatalogs read.
    private func activeHash() -> String {
        return TPPConfiguration.customUrlHash()
            ?? (TPPSettings().useBetaLibraries
                ? TPPConfiguration.betaUrlHash
                : TPPConfiguration.prodUrlHash)
    }

    private func appSupportURL(_ name: String) -> URL? {
        guard let dir = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        return dir.appendingPathComponent(name)
    }

    private func fullCacheURL(_ hash: String) -> URL? { appSupportURL("accounts_catalog_\(hash).json") }
    private func metadataURL(_ hash: String) -> URL? { appSupportURL("accounts_catalog_metadata_\(hash).json") }
    private func slimURL(_ hash: String) -> URL? { appSupportURL("accounts_catalog_slim_\(hash).json") }

    /// Write the full catalog blob + a fresh (non-expired) metadata file so
    /// `hasCachedCatalogData` returns true — mirrors production's cache layout.
    private func seedFullCache(hash: String, data: Data) throws {
        guard let dataURL = fullCacheURL(hash), let metaURL = metadataURL(hash) else {
            throw XCTSkip("Application Support directory unavailable")
        }
        try data.write(to: dataURL)
        let metadata = CatalogCacheMetadata(timestamp: Date(), hash: hash)
        try JSONEncoder().encode(metadata).write(to: metaURL)
    }

    /// Write a slim snapshot carved (via the SUT's own carve) from the full
    /// fixture, keeping only `keepUUIDs`. This is exactly the on-disk shape
    /// `writeSlimSnapshot` produces on a prior launch.
    private func seedSlimSnapshot(hash: String, keepUUIDs: Set<String>) throws {
        guard let carved = AccountsManager.carveSlimFeed(fromFullCatalogData: feedData, keepUUIDs: keepUUIDs) else {
            throw XCTSkip("carveSlimFeed produced no data for the seed UUIDs")
        }
        guard let url = slimURL(hash) else { throw XCTSkip("Application Support directory unavailable") }
        try carved.write(to: url)
    }

    private func tearDownCaches(hash: String) {
        for url in [fullCacheURL(hash), metadataURL(hash), slimURL(hash)].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func label(_ state: Account.LoadState) -> String {
        switch state {
        case .notLoaded:        return "notLoaded"
        case .basicInfoLoaded:  return "basicInfoLoaded"
        case .detailsLoading:   return "detailsLoading"
        case .detailsLoaded:    return "detailsLoaded"
        case .detailsFailed:    return "detailsFailed"
        case .detailsEvicted:   return "detailsEvicted"
        }
    }

    // MARK: - 1. Slim-snapshot correctness

    /// Contract: with a slim snapshot present, `preloadAccountsFromDiskCacheSync`
    /// hydrates ONLY the current + settings accounts synchronously — enough to
    /// resolve `currentAccount` and drive its readiness gate — and does NOT
    /// populate `accountSets`. The ~2-account slim set must not masquerade as
    /// the full list, so `accountsHaveLoaded` stays false and `accounts()` stays
    /// empty until the full off-main materialization lands.
    func testPreload_slimSnapshotPresent_hydratesOnlyCurrentAndSettings_notFullList() throws {
        let catalogs = try loadFeedCatalogs()
        let currentUUID = catalogs[0].metadata.id
        let settingsUUID = catalogs[1].metadata.id

        let defaults = Self.testUserDefaults()
        defaults.set(currentUUID, forKey: currentAccountIdentifierKey)
        let manager = makeFreshAccountsManager(defaults: defaults)

        let hash = activeHash()
        try seedFullCache(hash: hash, data: feedData)
        try seedSlimSnapshot(hash: hash, keepUUIDs: [currentUUID, settingsUUID])
        defer { tearDownCaches(hash: hash) }

        #if DEBUG
        AccountStateStore.shared._resetAllForTesting()
        #endif

        manager.preloadAccountsFromDiskCacheSync()

        // Slim current account resolves via the fallback...
        XCTAssertEqual(manager.currentAccount?.uuid, currentUUID,
                       "Slim preload must make currentAccount resolve without the full list")
        // ...but the FULL list has NOT materialized: accountSets stays empty so
        // accountsHaveLoaded still reflects the (not-yet-loaded) full list.
        XCTAssertFalse(manager.accountsHaveLoaded,
                       "Slim hydrate must NOT flip accountsHaveLoaded — the ~2-account slim set must not masquerade as the full \(catalogs.count)-account list (picker-truncation guard)")
        XCTAssertTrue(manager.accounts(hash).isEmpty,
                      "Slim accounts must not leak into accountSets/accounts()")
        // The slim current account was advanced past .notLoaded (basicInfoLoaded
        // synchronously, and the auth-doc drive fired).
        if case .notLoaded = AccountStateStore.shared.state(for: currentUUID) {
            XCTFail("Slim preload must advance the current account past .notLoaded")
        }
        // A settings account NOT in the slim set is still unknown to account().
        let excludedUUID = catalogs[2].metadata.id
        XCTAssertNil(manager.account(excludedUUID),
                     "An account outside the slim set must not resolve until the full list materializes")
    }

    /// Contract: a slim snapshot whose current account is NOT current-cache-fresh
    /// (no full cache present) must not hydrate — CP-D1 gates the slim fast path
    /// on `hasCachedCatalogData` so a missing/expired full cache still no-ops.
    func testPreload_slimSnapshotButNoFullCache_doesNotHydrate() throws {
        let catalogs = try loadFeedCatalogs()
        let currentUUID = catalogs[0].metadata.id

        let defaults = Self.testUserDefaults()
        defaults.set(currentUUID, forKey: currentAccountIdentifierKey)
        let manager = makeFreshAccountsManager(defaults: defaults)

        let hash = activeHash()
        // Deliberately DO NOT seed the full cache; only the slim file.
        try seedSlimSnapshot(hash: hash, keepUUIDs: [currentUUID])
        defer { tearDownCaches(hash: hash) }

        #if DEBUG
        AccountStateStore.shared._resetAllForTesting()
        #endif

        manager.preloadAccountsFromDiskCacheSync()

        XCTAssertNil(manager.currentAccount,
                     "With no full cache present, the slim fast path must be gated off — no hydration")
        if case .notLoaded = AccountStateStore.shared.state(for: currentUUID) {
            // expected — nothing drove it
        } else {
            XCTFail("No cache ⇒ current account must remain .notLoaded; got \(label(AccountStateStore.shared.state(for: currentUUID)))")
        }
    }

    // MARK: - 2. Picker-full-count

    /// Contract (Phase 1a correction #2): after the full list materializes via
    /// the production seam, `accounts()` reaches the FULL fixture count and
    /// `accountsHaveLoaded` is true — the library picker sees every account, not
    /// the ~2-account slim set. The kill case is a design where the slim set
    /// leaked into `accountSets` (picker would see the slim count).
    func testPicker_fullListMaterializes_reachesFullCount_notSlimCount() throws {
        let catalogs = try loadFeedCatalogs()
        let fullCount = catalogs.count
        let currentUUID = catalogs[0].metadata.id
        let slimUUIDs: Set<String> = [currentUUID, catalogs[1].metadata.id]

        let defaults = Self.testUserDefaults()
        defaults.set(currentUUID, forKey: currentAccountIdentifierKey)
        let manager = makeFreshAccountsManager(defaults: defaults)

        let hash = activeHash()
        try seedFullCache(hash: hash, data: feedData)
        try seedSlimSnapshot(hash: hash, keepUUIDs: slimUUIDs)
        defer { tearDownCaches(hash: hash) }

        #if DEBUG
        AccountStateStore.shared._resetAllForTesting()
        #endif

        // Launch: slim hydrate only.
        manager.preloadAccountsFromDiskCacheSync()
        XCTAssertFalse(manager.accountsHaveLoaded,
                       "Precondition: full list not yet materialized after slim preload")
        XCTAssertEqual(manager.accounts(hash).count, 0,
                       "Precondition: slim set must not populate accounts()")

        // Materialize the full list through the production seam
        // (`loadAccountSetsAndAuthDoc` is what `loadCatalogs`' disk branch —
        // the background dispatch `init` fires — calls to fill `accountSets`).
        let exp = expectation(description: "full list materializes into accountSets")
        manager.loadAccountSetsAndAuthDoc(fromCatalogData: feedData, key: hash) { _ in exp.fulfill() }
        wait(for: [exp], timeout: 15.0) // FLAKE-003-OK: integration-scoped — awaits the full ~1142-account off-main decode+materialize through loadAccountSetsAndAuthDoc; 15s is CI-load headroom for the real decode, not a hidden sleep.
        drainMainQueue()

        XCTAssertTrue(manager.accountsHaveLoaded,
                      "After full materialization the picker gate (accountsHaveLoaded) must be true")
        XCTAssertEqual(manager.accounts(hash).count, fullCount,
                       "Picker must see the FULL \(fullCount)-account list, not the \(slimUUIDs.count)-account slim set")
    }

    // MARK: - 3. Round-trip through the production seam

    /// Contract (CLAUDE.md state-machine round-trip rule): a slim-hydrated
    /// current account survives a full library-reselect cycle driven entirely
    /// through production seams — slim preload (WRITE) → switch A→B (setter
    /// evicts A, RESET) → switch B→A (setter re-drives A, RE-ENTER). A must move
    /// OFF the stale `.detailsEvicted(.libraryDeselected)` marker on the way
    /// back, exactly as `testLibraryReselect_reentry_resetsState_andRedrives`
    /// proves for full accounts — here proven for SLIM-hydrated accounts.
    func testRoundTrip_slimHydratedCurrentAccount_reselectAwayAndBack_redrivesViaProductionSeam() throws {
        let catalogs = try loadFeedCatalogs()
        let aUUID = catalogs[0].metadata.id
        let bUUID = catalogs[1].metadata.id

        let defaults = Self.testUserDefaults()
        defaults.set(aUUID, forKey: currentAccountIdentifierKey)
        let manager = makeFreshAccountsManager(defaults: defaults)

        let hash = activeHash()
        try seedFullCache(hash: hash, data: feedData)
        try seedSlimSnapshot(hash: hash, keepUUIDs: [aUUID, bUUID])
        defer { tearDownCaches(hash: hash) }

        #if DEBUG
        AccountStateStore.shared._resetAllForTesting()
        #endif

        // WRITE: slim preload hydrates + drives A.
        manager.preloadAccountsFromDiskCacheSync()
        guard let slimA = manager.account(aUUID), let slimB = manager.account(bUUID) else {
            XCTFail("Slim preload must resolve both A and B via the slim fallback"); return
        }
        XCTAssertEqual(manager.currentAccount?.uuid, aUUID, "Precondition: A is current after slim preload")

        // RESET: switch A → B through the setter. The setter cancels A's
        // in-flight slim-drive auth-doc fetch and terminates A at
        // .detailsEvicted(.libraryDeselected).
        manager.currentAccount = slimB
        switch AccountStateStore.shared.state(for: aUUID) {
        case .detailsEvicted(.libraryDeselected):
            break
        default:
            XCTFail("A→B switch must evict A to .detailsEvicted(.libraryDeselected); got \(label(AccountStateStore.shared.state(for: aUUID)))")
            return
        }

        // CP-D1 production guard (prove-a-negative): A's cancelled auth-doc fetch
        // completion fires ASYNC with success==false and must NOT clobber the
        // eviction marker with .detailsFailed (which would make the switch-back
        // below hit the "don't redrive" arm and strand awaitReady() consumers).
        // Observe A's state stream across a bounded settle window via an INVERTED
        // expectation — any drift OFF .detailsEvicted(.libraryDeselected) fulfills
        // it (→ FAIL); if the guard holds the marker stays put and the inverted
        // expectation passes. This is the XCTest-sanctioned negative-wait primitive
        // (replaces a fixed asyncAfter sleep, FLAKE-002) and catches the clobber
        // deterministically regardless of subscribe-vs-completion ordering
        // (stateStream emits the current value on subscribe).
        let noClobber = expectation(description: "cancelled fetch must not clobber A's eviction marker")
        noClobber.isInverted = true
        let clobberObserver = Task {
            for await state in AccountStateStore.shared.stateStream(for: aUUID) {
                if case .detailsEvicted(.libraryDeselected) = state { continue }
                noClobber.fulfill()
                break
            }
        }
        wait(for: [noClobber], timeout: 1.0)
        clobberObserver.cancel()
        drainMainQueue()
        switch AccountStateStore.shared.state(for: aUUID) {
        case .detailsEvicted(.libraryDeselected):
            break // guard held — the cancelled fetch did not clobber the eviction
        default:
            XCTFail("A cancelled auth-doc fetch completion must not clobber the eviction marker (CP-D1 guard); A drifted to \(label(AccountStateStore.shared.state(for: aUUID)))")
            return
        }

        // RE-ENTER: switch B → A through the setter. The setter's
        // driveCurrentAccountAuthDocIfNeeded must recognize A's eviction marker
        // as stale and re-fire the auth-doc fetch — A moves past the marker.
        manager.currentAccount = slimA

        awaitCondition(timeout: 6.0) {
            switch AccountStateStore.shared.state(for: aUUID) {
            case .detailsLoading, .detailsLoaded, .detailsFailed:
                return true
            default:
                return false
            }
        }
        switch AccountStateStore.shared.state(for: aUUID) {
        case .detailsLoading, .detailsLoaded, .detailsFailed:
            break // re-entry re-drove A off the stale eviction marker
        default:
            XCTFail("Re-entry (B→A) must drive slim-hydrated A past the stale .detailsEvicted marker; observed \(label(AccountStateStore.shared.state(for: aUUID)))")
        }
    }

    // MARK: - 4. Consumer smoke — readiness gate is driven, not hanging

    /// Contract (CLAUDE.md consumer-smoke rule): the `Account.awaitReady()`
    /// readiness gate — consumed by audiobook open, token refresh, bookmark
    /// sync, CarPlay auth — must be DRIVEN (reach `.detailsLoading` and on to a
    /// terminal) for the current account after cold launch AND after a library
    /// swap, so those consumers resolve instead of hanging forever. The slim
    /// hydrate is only USEFUL if it drives the gate; a slim path that populated
    /// state but never drove the auth-doc would leave `awaitReady()` blocked.
    func testConsumerSmoke_readinessGateDriven_afterColdLaunch_andAfterLibrarySwap() throws {
        let catalogs = try loadFeedCatalogs()
        let aUUID = catalogs[0].metadata.id
        let bUUID = catalogs[1].metadata.id

        let defaults = Self.testUserDefaults()
        defaults.set(aUUID, forKey: currentAccountIdentifierKey)
        let manager = makeFreshAccountsManager(defaults: defaults)

        let hash = activeHash()
        try seedFullCache(hash: hash, data: feedData)
        try seedSlimSnapshot(hash: hash, keepUUIDs: [aUUID, bUUID])
        defer { tearDownCaches(hash: hash) }

        #if DEBUG
        AccountStateStore.shared._resetAllForTesting()
        #endif

        // Cold launch: slim preload must drive A's readiness gate.
        manager.preloadAccountsFromDiskCacheSync()
        awaitCondition(timeout: 6.0) {
            switch AccountStateStore.shared.state(for: aUUID) {
            case .detailsLoading, .detailsLoaded, .detailsFailed:
                return true
            default:
                return false
            }
        }
        switch AccountStateStore.shared.state(for: aUUID) {
        case .detailsLoading, .detailsLoaded, .detailsFailed:
            break
        default:
            XCTFail("Cold-launch slim preload must drive the current account's readiness gate; observed \(label(AccountStateStore.shared.state(for: aUUID)))")
        }

        // Library swap: the newly-current account's gate must also be driven so
        // its awaitReady() consumers don't hang after the switch.
        guard let slimB = manager.account(bUUID) else { XCTFail("B must resolve via slim fallback"); return }
        manager.currentAccount = slimB
        awaitCondition(timeout: 6.0) {
            switch AccountStateStore.shared.state(for: bUUID) {
            case .detailsLoading, .detailsLoaded, .detailsFailed:
                return true
            default:
                return false
            }
        }
        switch AccountStateStore.shared.state(for: bUUID) {
        case .detailsLoading, .detailsLoaded, .detailsFailed:
            break
        default:
            XCTFail("Library swap must drive the new current account's readiness gate; observed \(label(AccountStateStore.shared.state(for: bUUID)))")
        }
    }

    // MARK: - Regression (PR #1226): launch-time drive must be deferred off the sync stack

    /// Regression for the cold-launch re-entrancy crash (PR #1226). At cold launch
    /// `AccountsManager()` is built INSIDE `AppContainer._buildCachedAppContainer()`,
    /// which runs under `AppContainer._cachedLock` (a non-recursive
    /// `OSAllocatedUnfairLock`). `hydrateSlimLaunchSnapshot` used to drive the
    /// current account's auth-doc SYNCHRONOUSLY on that stack — and the drive calls
    /// `AppContainer.production()` again (`Account.fetchAuthenticationDocument`),
    /// re-entering the held lock → `_os_unfair_lock_recursive_abort` /
    /// `EXC_BREAKPOINT`. It crashed launch for every SIGNED-IN user (a logged-out
    /// sim has no current account to drive, so it never reproduced there — which is
    /// how it shipped).
    ///
    /// The fix defers the drive one main-runloop turn. This test pins that at the
    /// seam we can unit-test: immediately after the SYNCHRONOUS preload returns, the
    /// current account must NOT yet be driving (the deferred block hasn't run on this
    /// runloop turn); it must begin driving only AFTER the runloop turns. A revert to
    /// an inline drive flips the first assertion — the same change that reintroduces
    /// the re-entrant launch crash — and fails here.
    func testColdLaunch_authDocDrive_isDeferredOffSyncPreloadStack_notInline() throws {
        let catalogs = try loadFeedCatalogs()
        let aUUID = catalogs[0].metadata.id

        let defaults = Self.testUserDefaults()
        defaults.set(aUUID, forKey: currentAccountIdentifierKey)
        let manager = makeFreshAccountsManager(defaults: defaults)

        let hash = activeHash()
        try seedFullCache(hash: hash, data: feedData)
        try seedSlimSnapshot(hash: hash, keepUUIDs: [aUUID])
        defer { tearDownCaches(hash: hash) }

        #if DEBUG
        AccountStateStore.shared._resetAllForTesting()
        #endif

        // Synchronous preload — same runloop turn as the (deferred) drive schedule.
        manager.preloadAccountsFromDiskCacheSync()

        // The deferred drive has NOT run yet (we haven't yielded the runloop). If it
        // were inline — the re-entrancy regression — the account would already be
        // `.detailsLoading`.
        switch AccountStateStore.shared.state(for: aUUID) {
        case .detailsLoading, .detailsLoaded, .detailsFailed:
            XCTFail("Auth-doc drive ran SYNCHRONOUSLY inside preloadAccountsFromDiskCacheSync — at cold launch this re-enters AppContainer.production() under the held _cachedLock and aborts (PR #1226). It must be deferred off this stack. Observed \(label(AccountStateStore.shared.state(for: aUUID)))")
        default:
            break // .notLoaded / .basicInfoLoaded — deferred, correct.
        }

        // After the runloop turns, the deferred drive fires — the launch-readiness
        // contract (awaitReady() consumers resolve) is preserved.
        awaitCondition(timeout: 6.0) {
            switch AccountStateStore.shared.state(for: aUUID) {
            case .detailsLoading, .detailsLoaded, .detailsFailed:
                return true
            default:
                return false
            }
        }
        switch AccountStateStore.shared.state(for: aUUID) {
        case .detailsLoading, .detailsLoaded, .detailsFailed:
            break
        default:
            XCTFail("Deferred drive must still fire on the next runloop turn; observed \(label(AccountStateStore.shared.state(for: aUUID)))")
        }
    }

    // MARK: - Finding 4: slim→full instance reuse (no auth-doc split-brain)

    /// Contract (architect Finding 4): `details`/`authenticationDocument` are
    /// per-INSTANCE properties, and the slim current-account drive fetches the
    /// auth-doc onto the SLIM instance. When the full list materializes, the
    /// current account must remain the SAME instance the fetch targets — else an
    /// in-flight fetch is stranded on the discarded instance and
    /// `currentAccount.details` stays nil while state reads `.detailsLoaded`
    /// (legacy readers `.details`/`.needsAuth`/`.loansUrl`/`.authSurfaceHosts`
    /// see nil). Proven two ways: (1) instance identity across the transition;
    /// (2) an auth-doc set on the slim instance AFTER materialization (simulating
    /// an in-flight fetch completing) surfaces on `currentAccount.details`.
    func testSlimToFull_reusesSlimCurrentAccountInstance_soInFlightAuthDocNotStranded() throws {
        let catalogs = try loadFeedCatalogs()
        let currentUUID = catalogs[0].metadata.id

        let defaults = Self.testUserDefaults()
        defaults.set(currentUUID, forKey: currentAccountIdentifierKey)
        let manager = makeFreshAccountsManager(defaults: defaults)

        let hash = activeHash()
        try seedFullCache(hash: hash, data: feedData)
        try seedSlimSnapshot(hash: hash, keepUUIDs: [currentUUID, catalogs[1].metadata.id])
        defer { tearDownCaches(hash: hash) }

        #if DEBUG
        AccountStateStore.shared._resetAllForTesting()
        #endif

        // Launch: slim fast path creates the slim current-account instance.
        manager.preloadAccountsFromDiskCacheSync()
        guard let slimInstance = manager.account(currentUUID) else {
            XCTFail("Slim preload must resolve the current account instance"); return
        }

        // Materialize the full list through the production seam.
        let exp = expectation(description: "full list materializes")
        manager.loadAccountSetsAndAuthDoc(fromCatalogData: feedData, key: hash) { _ in exp.fulfill() }
        wait(for: [exp], timeout: 15.0) // FLAKE-003-OK: integration-scoped — awaits the full ~1142-account off-main decode+materialize through loadAccountSetsAndAuthDoc; 15s is CI-load headroom for the real decode, not a hidden sleep.
        drainMainQueue()

        // (1) The current account must be the SAME instance the slim drive
        //     fetched onto — not a fresh full-decode instance.
        guard let afterInstance = manager.account(currentUUID) else {
            XCTFail("Current account must resolve after materialization"); return
        }
        XCTAssertTrue(afterInstance === slimInstance,
                      "Slim→full materialization must reuse the slim current-account instance so an in-flight auth-doc fetch is not stranded on a discarded instance")
        // And the full list still materialized (reuse must not break the picker).
        XCTAssertEqual(manager.accounts(hash).count, catalogs.count,
                       "Reuse must not truncate the full materialized list")

        // (2) Simulate the in-flight slim fetch completing AFTER materialization:
        //     the auth-doc lands on the (reused) current instance → details show.
        guard let authDocURL = Bundle(for: type(of: self)).url(forResource: "nypl_authentication_document", withExtension: "json") else {
            throw XCTSkip("nypl_authentication_document.json fixture missing")
        }
        let authDoc = try OPDS2AuthenticationDocument.fromData(Data(contentsOf: authDocURL))
        afterInstance.authenticationDocument = authDoc
        XCTAssertNotNil(manager.currentAccount?.details,
                        "After the slim fetch completes onto the reused instance, currentAccount.details must be populated (no split-brain)")
    }

    // MARK: - Finding 5: stale slim snapshot lacking the current account

    /// Contract (architect Finding 5): the slim snapshot is written from the
    /// then-current account and is NOT rewritten on a mid-session switch, so a
    /// stale slim file can lack the now-current account. `preloadAccountsFromDiskCacheSync`
    /// must NOT take the slim fast path with a set that can't resolve
    /// `currentAccount` — it must fall through to the full sync hydrate so
    /// `currentAccount` still resolves at launch (no transient nil window that
    /// fires spurious sign-in modals / empty library UI). Kill case: without the
    /// current-account presence check, preload returns on the fast path and
    /// `currentAccount` is nil in the pre-materialization window.
    func testPreload_staleSlimSnapshotLacksCurrentAccount_fallsThroughToFullHydrate() throws {
        let catalogs = try loadFeedCatalogs()
        let currentUUID = catalogs[0].metadata.id     // now-current account (post-switch)
        let staleSlimUUID = catalogs[1].metadata.id   // slim written for the PRIOR current account
        XCTAssertNotEqual(currentUUID, staleSlimUUID)

        let defaults = Self.testUserDefaults()
        defaults.set(currentUUID, forKey: currentAccountIdentifierKey)
        let manager = makeFreshAccountsManager(defaults: defaults)

        let hash = activeHash()
        try seedFullCache(hash: hash, data: feedData)
        // Stale slim: contains the OLD account only, NOT the now-current one.
        try seedSlimSnapshot(hash: hash, keepUUIDs: [staleSlimUUID])
        defer { tearDownCaches(hash: hash) }

        #if DEBUG
        AccountStateStore.shared._resetAllForTesting()
        #endif

        manager.preloadAccountsFromDiskCacheSync()

        // Fell through to the full sync hydrate → currentAccount resolves in the
        // pre-materialization window, and the full list is populated.
        XCTAssertEqual(manager.currentAccount?.uuid, currentUUID,
                       "A stale slim snapshot lacking the current account must fall through to the full hydrate so currentAccount still resolves at launch")
        XCTAssertTrue(manager.accountsHaveLoaded,
                      "Fall-through to full sync hydrate must populate the full account list")
        XCTAssertEqual(manager.accounts(hash).count, catalogs.count,
                       "Fall-through must materialize the FULL list, not the stale slim set")
    }

    // MARK: - 5. carveSlimFeed (pure)

    /// The carve keeps ONLY the requested uuids and the result round-trips
    /// through the SAME reader production uses (`OPDS2CatalogsFeed.fromData`,
    /// custom date decoder) — proving the raw-JSON carve preserves the exact
    /// date-string format with no encoder date-strategy hazard.
    func testCarveSlimFeed_keepsOnlyRequestedUUIDs_andRoundTripsThroughReader() throws {
        let catalogs = try loadFeedCatalogs()
        let keep = Set([catalogs[0].metadata.id, catalogs[2].metadata.id])
        guard let carved = AccountsManager.carveSlimFeed(fromFullCatalogData: feedData, keepUUIDs: keep) else {
            XCTFail("carveSlimFeed returned nil for valid UUIDs"); return
        }
        let slimFeed = try OPDS2CatalogsFeed.fromData(carved)
        XCTAssertEqual(Set(slimFeed.catalogs.map { $0.metadata.id }), keep,
                       "Carve must keep exactly the requested uuids")
        XCTAssertEqual(slimFeed.catalogs.count, 2)
        XCTAssertLessThan(carved.count, feedData.count / 5,
                          "Slim carve must be dramatically smaller than the full blob")
    }

    func testCarveSlimFeed_noMatchingUUIDs_returnsNil() throws {
        XCTAssertNil(AccountsManager.carveSlimFeed(
            fromFullCatalogData: feedData,
            keepUUIDs: ["urn:uuid:00000000-0000-0000-0000-000000000000"]),
            "Carve with no matching uuids must return nil, not an empty feed")
    }

    func testCarveSlimFeed_emptyKeepSet_returnsNil() throws {
        XCTAssertNil(AccountsManager.carveSlimFeed(fromFullCatalogData: feedData, keepUUIDs: []),
                     "Carve with an empty keep set must return nil")
    }

    func testCarveSlimFeed_malformedData_returnsNil() {
        XCTAssertNil(AccountsManager.carveSlimFeed(
            fromFullCatalogData: Data("not valid json".utf8),
            keepUUIDs: ["urn:uuid:whatever"]),
            "Carve of non-JSON data must return nil, not crash")
    }

    // MARK: - 6. Eviction-wins guard (CP-D1 production fix)

    /// Contract: a superseded auth-doc fetch completion (its account was evicted
    /// by a library switch after the fetch started) must NOT overwrite the
    /// `.detailsEvicted` terminal — so a switch-cancellation's async completion
    /// can't strand `awaitReady()` consumers on `.detailsFailed`. Only the
    /// `.detailsEvicted` state suppresses the completion's terminal write; every
    /// non-evicted state lets the fetch record its real outcome.
    func testFetchCompletionMayWriteTerminal_evictedSuppressesWrite_othersAllow() {
        // Evicted → completion must NOT write (eviction wins).
        XCTAssertFalse(
            AccountsManager.fetchCompletionMayWriteTerminal(
                currentState: .detailsEvicted(.libraryDeselected(uuid: "urn:uuid:x"))),
            "A fetch completion must not overwrite the .detailsEvicted eviction marker")

        // Every other state → completion MUST be allowed to write its terminal.
        for state in nonEvictedStates() {
            XCTAssertTrue(
                AccountsManager.fetchCompletionMayWriteTerminal(currentState: state),
                "Non-evicted state \(label(state)) must let the fetch completion write its terminal")
        }
    }

    private func nonEvictedStates() -> [Account.LoadState] {
        var states: [Account.LoadState] = [.notLoaded, .basicInfoLoaded, .detailsLoading]
        states.append(.detailsFailed(.authDocumentFetchFailed(underlyingDescription: "x")))
        // A .detailsLoaded needs real AccountDetails; build one from the fixture
        // if available, otherwise skip that case (the three above + failed
        // already prove the "non-evicted allows write" branch).
        if let catalogs = try? loadFeedCatalogs() {
            let a = Account(publication: catalogs[0], imageCache: MockImageCache())
            if let details = a.details {
                states.append(.detailsLoaded(details))
            }
        }
        return states
    }
}
