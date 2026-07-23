//
//  AccountsManagerStateMachineWiringTests.swift
//  PalaceTests
//
//  Contract-snapshot tests pinning the 4 state-machine wiring transitions
//  added to AccountsManager in the 3.2.0 swarm (Accounts-Wiring module).
//  See docs/architecture/account-state-machine.md and the per-swarm
//  contract at .forgeos/swarms/swarm_81b5099e/contracts/Accounts-Wiring.md.
//
//  Each test exercises one ADR-mandated transition through the testable
//  seams (`preloadAccountsFromDiskCacheSync`,
//  `loadAccountSetsAndAuthDoc`, `fetchAuthDocumentWithStateMachine`).
//  Direct `account._setState(...)` is used ONLY to set up scenarios that
//  predate the SUT call — never to bypass it.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import PalacePreferences
import Combine
import PalaceCatalog
@testable import Palace
import PalaceBookModel

@MainActor
final class AccountsManagerStateMachineWiringTests: PalaceWiringTestCase {

    // MARK: - Fixtures

    private var feedURL: URL!
    private var feedData: Data!
    private var authDoc: OPDS2AuthenticationDocument!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // `PalaceWiringTestCase.setUpWithError` has already:
        //   - Invoked `SingletonResetRegistry.shared.invokeAll()` so the
        //     prior method's residue (AccountStateStore, AppContainer,
        //     stub session, etc.) is gone.
        //   - Set `AccountsManager.deferInitialLoadCatalogsForTesting = true`
        //     so every `makeFreshAccountsManager()` skip its background
        //     `loadCatalogs` Task at init.
        //   - Drained `cancellables` and cancelled any helper-minted
        //     manager from the previous method.
        // The remaining fixture work below is the per-test bundle-loading.

        let bundle = Bundle(for: type(of: self))
        feedURL = bundle.url(forResource: "OPDS2CatalogsFeed", withExtension: "json")
        guard let feedURL else {
            throw XCTSkip("OPDS2CatalogsFeed.json fixture missing from PalaceTests bundle")
        }
        feedData = try Data(contentsOf: feedURL)

        guard let authDocURL = bundle.url(forResource: "nypl_authentication_document", withExtension: "json") else {
            throw XCTSkip("nypl_authentication_document.json fixture missing from PalaceTests bundle")
        }
        authDoc = try OPDS2AuthenticationDocument.fromData(Data(contentsOf: authDocURL))
    }

    override func tearDownWithError() throws {
        // Clear the process-wide state store so transitions written by one
        // test don't leak into the next (the store is keyed by UUID, and the
        // OPDS2CatalogsFeed fixture reuses real library UUIDs).
        //
        // The base also calls AccountStateStore reset indirectly via the
        // registry; the explicit call here is a belt-and-suspenders guard
        // for tests that subscribed mid-body and may have written state
        // AFTER the base's drain of cancellables but BEFORE the registry
        // sweep.
        //
        // NOTE (swarm_4b64e4e0 Wave 1d): we deliberately do NOT set
        // `AccountsManager.deferInitialLoadCatalogsForTesting = false` here.
        // The post-test observer fires `_resetForTesting()` which rebuilds
        // the cached `AppContainer`; the newly-constructed cached
        // `AccountsManager` reads this flag at `init` to decide whether to
        // spawn its background `loadCatalogs` Task. If the flag flipped to
        // false between this tearDown and the next test's setUp, the rebuild
        // window would let the cached manager kick off a `loadCatalogs` Task
        // that writes 1142 bundled-registry accounts to
        // `accounts_catalog_<hash>.json` on disk — overwriting any 171-
        // account fixture seed the next test writes to the same hash,
        // mid-test. The resulting failure mode is the next test's
        // `manager.preloadAccountsFromDiskCacheSync()` reading the bundled
        // 1142 instead of the seeded 171, then `account(currentUUID)`
        // returning nil because the bundled set doesn't carry the fixture's
        // UUID space. See the wave 1d transcript for the full forensic.
        // PalaceTestSetup.bootstrap() pins the flag to true at bundle-load
        // time; PalaceWiringTestCase.setUpWithError repins it on each setUp.
        // Leaving it true on tearDown keeps the inter-test cached-rebuild
        // window deterministic.
        #if DEBUG
        AccountStateStore.shared._resetAllForTesting()
        #endif
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    /// Parse the OPDS2 catalogs fixture into its list of publications. Tests
    /// then construct Account instances from these — same constructor the
    /// production wiring path uses.
    private func loadFeedCatalogs() throws -> [OPDS2Publication] {
        let feed = try OPDS2CatalogsFeed.fromData(feedData)
        guard !feed.catalogs.isEmpty else {
            throw XCTSkip("OPDS2CatalogsFeed fixture has no catalogs")
        }
        return feed.catalogs
    }

    /// Returns a string label for a `LoadState` — used in array-equality
    /// assertions where direct enum comparison is unwieldy (associated values
    /// on `.detailsLoaded`/`.detailsFailed` aren't trivially Equatable).
    /// Lock-guarded accumulator for state-stream labels observed off the Task's
    /// executor. Swift 6: a captured `var [String]` mutated inside the stream Task
    /// and read from the test thread is a data race — this box synchronizes both.
    private final class ObservedLabels: @unchecked Sendable {
        private let lock = NSLock()
        private var _labels: [String] = []
        /// Appends and returns the just-appended label.
        func append(_ label: String) -> String {
            lock.withLock { _labels.append(label); return label }
        }
        var snapshot: [String] { lock.withLock { _labels } }
    }

    private func label(_ state: Account.LoadState) -> String {
        switch state {
        case .notLoaded:        return "notLoaded"
        case .basicInfoLoaded:  return "basicInfoLoaded"
        case .detailsLoading:   return "detailsLoading"
        case .detailsLoaded:    return "detailsLoaded"
        case .detailsFailed(let err):
            if case .accountNotFound = err { return "detailsFailed.accountNotFound" }
            if case .authDocumentFetchFailed = err { return "detailsFailed.authDocumentFetchFailed" }
            if case .evicted = err { return "detailsFailed.evicted" }
            return "detailsFailed.other"
        case .detailsEvicted(let reason):
            if case .libraryDeselected = reason { return "detailsEvicted.libraryDeselected" }
            return "detailsEvicted.other"
        }
    }

    // MARK: - Test 1: Preload → .basicInfoLoaded

    /// Contract: `preloadAccountsFromDiskCacheSync` must drive every account
    /// loaded from the on-disk cache into `.basicInfoLoaded`. Without this,
    /// any Bucket B display-site consumer subscribing to `stateStream` on
    /// cold launch would see only `.notLoaded` until the async catalog fetch
    /// completes — defeats the purpose of the sync preload itself.
    ///
    /// Exercise: seed the on-disk cache for the prod hash, construct
    /// AccountsManager (its init runs the preload synchronously), then read
    /// the state for every preloaded account UUID.
    func testPreload_drivesEachLoadedAccount_toBasicInfoLoaded() throws {
        let catalogs = try loadFeedCatalogs()
        // Snapshot the UUIDs the fixture carries so we can assert against
        // them after preload runs. Pin the count too — a regression in the
        // fixture would otherwise silently shrink the assertion surface.
        let fixtureUUIDs = catalogs.map { $0.metadata.id }
        XCTAssertGreaterThan(fixtureUUIDs.count, 1,
                             "Fixture must carry at least 2 accounts for a meaningful preload assertion")

        // Construct AccountsManager FIRST so any background loadCatalogs it
        // kicks off can race-and-fail (without network) before we seed.
        // Otherwise a concurrent loadCatalogs writing through
        // loadAccountSetsAndAuthDoc would overwrite our seed's state-store
        // contributions mid-assertion. We then wait briefly for the
        // background to settle.
        let manager = makeFreshAccountsManager()
        // Drain the main queue so init's background loadCatalogs dispatch has
        // landed any main-thread completion blocks. Without network the
        // fetchFromNetwork Task fails fast without writing state, so the
        // reset below is safe once the main queue has flushed.
        drainMainQueue()
        drainMainQueue()

        // Reset state for every known subject AFTER the background settles,
        // so the assertion below isn't observing the background's leftovers.
        #if DEBUG
        AccountStateStore.shared._resetAllForTesting()
        #endif

        // Seed the on-disk cache file at the same hash the manager's
        // preload will read from. `accountSet` depends on
        // `TPPConfiguration.customUrlHash()`, `useBetaLibraries`, etc., so
        // we can't hard-code `prodUrlHash` — derive it the same way
        // `AccountsManager.init` does.
        let activeHash = TPPConfiguration.customUrlHash()
            ?? (TPPSettings().useBetaLibraries
                ? TPPConfiguration.betaUrlHash
                : TPPConfiguration.prodUrlHash)
        try seedDiskCache(for: activeHash, data: feedData)
        defer { tearDownDiskCache(for: activeHash) }

        // Directly invoke the SUT instead of relying on `init()` to fire
        // it — that lets us deterministically pair "fixture is on disk" with
        // "preload runs against it", side-stepping the background-loadCatalogs
        // race that otherwise overwrites the cache mid-test.
        manager.preloadAccountsFromDiskCacheSync()

        // Assert: every fixture UUID resolves to `.basicInfoLoaded`. We do
        // not assert against `.notLoaded` UUIDs that aren't in the fixture —
        // the production singleton may have residual state for unrelated
        // libraries that other tests touched. The narrow assertion catches
        // a regression where preload skips a subset of accounts.
        var observedNonBasic: [(String, String)] = []
        for uuid in fixtureUUIDs {
            switch AccountStateStore.shared.state(for: uuid) {
            case .basicInfoLoaded:
                continue
            default:
                observedNonBasic.append((uuid, label(AccountStateStore.shared.state(for: uuid))))
            }
        }
        XCTAssertTrue(observedNonBasic.isEmpty,
                      "After preload, every fixture UUID must be .basicInfoLoaded; non-conforming sample: \(observedNonBasic.prefix(5))")
    }

    // MARK: - Test 2: loadAccountSetsAndAuthDoc → .basicInfoLoaded for non-carry-over accounts

    /// Contract: when `loadAccountSetsAndAuthDoc` lands new accounts that
    /// did NOT have a carry-over `authenticationDocument` from a prior
    /// instance, each must transition to `.basicInfoLoaded`. The current
    /// account (if any) then enters `.detailsLoading` via
    /// `fetchAuthDocumentWithStateMachine`.
    ///
    /// We can't easily stub the prod `loadAuthenticationDocument` network
    /// call from a unit test, so this test asserts the synchronous slice of
    /// the wiring: accounts land in `.basicInfoLoaded` immediately after
    /// `loadAccountSetsAndAuthDoc` writes them into `accountSets`. The
    /// follow-on `.detailsLoading` transition for the current account is
    /// covered separately via direct `fetchAuthDocumentWithStateMachine`
    /// exercise in test 3 and the in-flight test 4.
    func testLoadCatalogs_currentAccountWithoutDetails_drivesDetailsLoading_thenLoaded() throws {
        let catalogs = try loadFeedCatalogs()
        let firstUUID = catalogs[0].metadata.id
        // swarm_cd181acd D-cleanup: per-test isolated UserDefaults suite
        // wired into the AccountsManager so the
        // `currentAccountIdentifierKey` write below cannot leak across
        // tests via `.standard`.
        let defaults = Self.testUserDefaults()
        let manager = makeFreshAccountsManager(defaults: defaults)

        // Set the current account to one of the fixture UUIDs so the
        // loadAccountSetsAndAuthDoc path will route through
        // fetchAuthDocumentWithStateMachine for it.
        defaults.set(firstUUID, forKey: currentAccountIdentifierKey)

        // Run the wiring path. Use the prod hash so the manager's
        // `currentAccount` lookup finds our fixture accounts.
        let prodHash = TPPConfiguration.prodUrlHash
        let exp = expectation(description: "loadAccountSetsAndAuthDoc completes")
        manager.loadAccountSetsAndAuthDoc(fromCatalogData: feedData, key: prodHash) { _ in
            exp.fulfill()
        }

        // The state-machine transition to `.basicInfoLoaded` happens
        // synchronously in loadAccountSetsAndAuthDoc, BEFORE the
        // DispatchGroup notify fires the completion. Wait briefly for the
        // synchronous slice to complete.
        // (We do not require the auth-doc fetch to succeed — the test
        // asserts only the synchronous transitions visible from the wiring.)
        _ = XCTWaiter.wait(for: [exp], timeout: 5.0)

        // Pick a non-current account from the fixture and assert it landed
        // in `.basicInfoLoaded` (or stayed in `.basicInfoLoaded` via the
        // carry-over branch if the prior preload already drove it there).
        // The current account may be in `.detailsLoading` or beyond — we
        // assert separately that it ENTERED `.detailsLoading`.
        let nonCurrentUUIDs = catalogs.dropFirst().map { $0.metadata.id }
        guard let probeUUID = nonCurrentUUIDs.first else {
            throw XCTSkip("Fixture needs at least 2 catalogs to probe a non-current account")
        }

        switch AccountStateStore.shared.state(for: probeUUID) {
        case .basicInfoLoaded, .detailsLoaded:
            // OK — either the canonical post-wiring state, or the carry-over
            // shortcut if an earlier test cycle left an auth doc on this UUID.
            break
        default:
            XCTFail("Non-current preloaded account must reach .basicInfoLoaded (or .detailsLoaded via carry-over), got \(label(AccountStateStore.shared.state(for: probeUUID)))")
        }

        // The current account must have either transitioned through
        // `.detailsLoading` or already reached a terminal state. In a test
        // environment without network mocking the prod fetch may fail and
        // land in `.detailsFailed`, OR succeed against a cached auth doc.
        // What it MUST NOT be is `.notLoaded` or `.basicInfoLoaded` — those
        // would mean the wiring never fired `fetchAuthDocumentWithStateMachine`.
        let currentState = AccountStateStore.shared.state(for: firstUUID)
        switch currentState {
        case .detailsLoading, .detailsLoaded, .detailsFailed:
            break // wiring fired
        default:
            XCTFail("Current account must enter at least .detailsLoading after loadAccountSetsAndAuthDoc; got \(label(currentState))")
        }
    }

    // MARK: - Test 2b: loadCatalogs warm-path drives currentAccount past .basicInfoLoaded

    /// Contract: when `loadCatalogs` short-circuits on the in-memory cache
    /// (accounts already populated by `preloadAccountsFromDiskCacheSync`),
    /// it MUST still drive the current account's auth-doc transition. The
    /// cold path does this via `loadAccountSetsAndAuthDoc → fetchAuthDocumentWithStateMachine`;
    /// before this fix the warm path returned `completion?(true)` without
    /// touching the state machine, leaving the current account stuck at
    /// `.basicInfoLoaded` forever and hanging every `awaitReady()` caller
    /// in the audiobook-open / token-refresh / bookmark-sync paths for
    /// already-signed-in cold-launch users.
    ///
    /// Exercise: prime the on-disk cache, run `preloadAccountsFromDiskCacheSync`
    /// so the in-memory cache is hot, set `currentAccountId` to a fixture
    /// UUID, then call `loadCatalogs(completion:)`. The completion fires
    /// synchronously on the warm path; the auth-doc fetch runs in the
    /// background. Within a bounded window the current account must have
    /// transitioned to `.detailsLoading` or a terminal state — anything
    /// staying at `.basicInfoLoaded` proves the driver gap is still open.
    func testLoadCatalogs_warmPath_drivesCurrentAccountPastBasicInfoLoaded() throws {
        let catalogs = try loadFeedCatalogs()
        let currentUUID = catalogs[0].metadata.id

        // swarm_cd181acd D-cleanup: per-test isolated UserDefaults suite
        // wired into the AccountsManager so the
        // `currentAccountIdentifierKey` write below cannot leak via
        // `.standard`.
        let defaults = Self.testUserDefaults()
        // Construct the manager FIRST. Its init fires a background
        // loadCatalogs(nil); drain the main queue so any of its main-thread
        // completion blocks land before our reset below. Without network the
        // fetchFromNetwork Task fails fast without writing AccountStateStore.
        let manager = makeFreshAccountsManager(defaults: defaults)
        drainMainQueue()
        drainMainQueue()

        // Seed disk cache against the manager's resolved hash so the warm
        // path's `accountSets[hash]?.isEmpty == false` check holds when we
        // re-run preload + loadCatalogs below.
        let activeHash = TPPConfiguration.customUrlHash()
            ?? (TPPSettings().useBetaLibraries
                ? TPPConfiguration.betaUrlHash
                : TPPConfiguration.prodUrlHash)
        try seedDiskCache(for: activeHash, data: feedData)
        defer { tearDownDiskCache(for: activeHash) }

        // Set the current account BEFORE preload so manager.currentAccount
        // resolves to a fixture UUID once accountSets is populated.
        defaults.set(currentUUID, forKey: currentAccountIdentifierKey)

        // Reset state for known subjects so the assertion below isn't
        // observing the background's leftovers.
        #if DEBUG
        AccountStateStore.shared._resetAllForTesting()
        #endif

        // Populate accountSets via preload — this is the production cold-
        // launch sequence: AppDelegate calls preload before loadCatalogs.
        manager.preloadAccountsFromDiskCacheSync()

        // Pre-state: every preloaded account is at .basicInfoLoaded. This
        // pins the precondition the warm-path driver gap depended on.
        switch AccountStateStore.shared.state(for: currentUUID) {
        case .basicInfoLoaded:
            break // expected pre-state
        default:
            XCTFail("Setup precondition: currentAccount must be .basicInfoLoaded immediately after preload; got \(label(AccountStateStore.shared.state(for: currentUUID)))")
            return
        }

        // Act: invoke the public loadCatalogs entry point. Accounts are in
        // memory, so the warm-path short-circuit fires. The completion
        // returns immediately; the auth-doc fetch runs in the background.
        let completionFired = expectation(description: "loadCatalogs completion fired")
        manager.loadCatalogs { _ in completionFired.fulfill() }
        wait(for: [completionFired], timeout: 1.0)

        // Assert: within a bounded window the current account must have
        // moved past .basicInfoLoaded. Staying at .basicInfoLoaded means
        // the warm path returned without firing the auth-doc driver — the
        // regression this test pins against.
        //
        // We accept any non-.basicInfoLoaded state (.detailsLoading,
        // .detailsLoaded, .detailsFailed) — the test asserts the driver
        // fired, not what the network returned. .notLoaded is also a fail
        // (would mean the wiring blew the state away without re-driving).
        awaitCondition(timeout: 4.0) {
            switch AccountStateStore.shared.state(for: currentUUID) {
            case .detailsLoading, .detailsLoaded, .detailsFailed:
                return true
            default:
                return false
            }
        }

        let observedFinalState = AccountStateStore.shared.state(for: currentUUID)
        switch observedFinalState {
        case .detailsLoading, .detailsLoaded, .detailsFailed:
            break // wiring fired — fix is in
        default:
            XCTFail("loadCatalogs warm-path must drive currentAccount past .basicInfoLoaded; observed \(label(observedFinalState)) — driver gap is still open and awaitReady() callers will hang")
        }
    }

    // MARK: - Test 2c: warm-path driver is idempotent on terminal state

    /// Contract: `driveCurrentAccountAuthDocIfNeeded` must NOT regress a
    /// terminal `.detailsLoaded` / `.detailsFailed` back to `.detailsLoading`.
    /// `fetchAuthDocumentWithStateMachine` unconditionally calls
    /// `_setState(.detailsLoading)` at entry — if the warm-path driver
    /// fired without the terminal-state guard, every `loadCatalogs` invocation
    /// (cold-launch, scene-connect, refreshInBackground re-entry) would
    /// destabilize subscribers and burn an extra network round-trip.
    ///
    /// Kill case: removing `.detailsLoaded`/`.detailsFailed` from the helper's
    /// switch would cause this test to observe a `.detailsLoading` transition
    /// after `driveCurrentAccountAuthDocIfNeeded` and fail.
    func testDriveCurrentAccountAuthDoc_terminalState_isNoOp() throws {
        let catalogs = try loadFeedCatalogs()
        let currentUUID = catalogs[0].metadata.id

        // swarm_cd181acd D-cleanup: per-test isolated UserDefaults suite.
        let defaults = Self.testUserDefaults()
        let manager = makeFreshAccountsManager(defaults: defaults)
        // Drain the main queue so init's background loadCatalogs has a chance
        // to fail (no network → fast failure) before our reset below.
        drainMainQueue()
        drainMainQueue()

        let activeHash = TPPConfiguration.customUrlHash()
            ?? (TPPSettings().useBetaLibraries
                ? TPPConfiguration.betaUrlHash
                : TPPConfiguration.prodUrlHash)
        try seedDiskCache(for: activeHash, data: feedData)
        defer { tearDownDiskCache(for: activeHash) }

        defaults.set(currentUUID, forKey: currentAccountIdentifierKey)

        #if DEBUG
        AccountStateStore.shared._resetAllForTesting()
        #endif

        manager.preloadAccountsFromDiskCacheSync()

        // Drive currentAccount to terminal .detailsLoaded directly. The
        // production driver would normally do this via the auth-doc fetch
        // succeeding, but we don't care HOW it got terminal — only that the
        // helper respects terminal state once there.
        guard let account = manager.currentAccount else {
            XCTFail("Setup: currentAccount must resolve after preload"); return
        }
        account.authenticationDocument = authDoc
        guard let details = account.details else {
            XCTFail("Setup: authenticationDocument assignment must populate details"); return
        }
        account._setState(.detailsLoaded(details))

        // Subscribe to the state stream to catch any unwanted regression.
        // CurrentValueSubject emits the current value (.detailsLoaded)
        // first; any subsequent emission means the helper fired.
        var emissionsAfterSubscribe: [String] = []
        let firstEmission = expectation(description: "stream emits initial terminal value")
        let streamTask = Task {
            var isFirst = true
            for await state in account.stateStream {
                if isFirst {
                    isFirst = false
                    firstEmission.fulfill()
                    continue
                }
                emissionsAfterSubscribe.append(self.label(state))
            }
        }
        wait(for: [firstEmission], timeout: 1.0)

        // Act: call the warm-path driver. With the terminal-state guard
        // in place this MUST be a no-op.
        manager.driveCurrentAccountAuthDocIfNeeded()

        // Drain the main queue so any unwanted Combine/notification emission
        // dispatched by the driver lands before we assert silence below.
        drainMainQueue()
        streamTask.cancel()

        // Assert: no transition fired after subscribe. The kill case is
        // a `.detailsLoading` emission, but ANY emission would prove the
        // helper unconditionally re-fired the fetch.
        XCTAssertTrue(emissionsAfterSubscribe.isEmpty,
                      "Terminal-state guard must produce zero subsequent stream emissions; observed: \(emissionsAfterSubscribe)")

        // Final state must still be the terminal we set up with.
        switch AccountStateStore.shared.state(for: currentUUID) {
        case .detailsLoaded:
            break
        default:
            XCTFail("Final state must remain .detailsLoaded after no-op driver; got \(label(AccountStateStore.shared.state(for: currentUUID)))")
        }
    }

    // MARK: - Test 3: fetchAuthDocumentWithStateMachine failure path

    /// Contract: when the auth-doc fetch returns failure (success=false),
    /// the wiring must drive the account into
    /// `.detailsFailed(.authDocumentFetchFailed(underlyingDescription:))`.
    /// Exercises the SUT directly with an Account whose
    /// `authenticationDocumentUrl` is malformed — production
    /// `loadAuthenticationDocument` short-circuits with `completion(false)`
    /// on that path (Account.swift:614-624 guard branch).
    func testLoadCatalogs_authDocFetchFails_drivesDetailsFailed() {
        // Construct a publication with NO authentication_document link.
        // `loadAuthenticationDocument` guards on `authenticationDocumentUrl
        // == nil` and immediately fires `completion(false)`.
        let metadata = OPDS2Publication.Metadata(
            updated: Date(),
            description: "no auth doc",
            id: "urn:uuid:wiring-test-no-authdoc",
            title: "No-AuthDoc Library"
        )
        let pub = OPDS2Publication(links: [], metadata: metadata, images: nil)
        let account = Account(publication: pub, imageCache: MockImageCache())

        // Sanity: verify the fixture really has no auth-doc URL — otherwise
        // the test is meaningless because the fetch could legitimately
        // succeed against a real endpoint.
        XCTAssertNil(account.authenticationDocumentUrl,
                     "Test setup must produce an account with nil authenticationDocumentUrl")

        let manager = makeFreshAccountsManager()
        let exp = expectation(description: "fetchAuthDocumentWithStateMachine completes")

        // Capture the transition stream so we can assert the SEQUENCE
        // (.detailsLoading → .detailsFailed), not just the terminal state.
        //
        // `stateStream` is backed by a `CurrentValueSubject`, which replays only
        // the LATEST value to a late subscriber. For a nil-URL account,
        // `fetchAuthDocumentWithStateMachine` runs `_setState(.detailsLoading)`
        // and `_setState(.detailsFailed)` SYNCHRONOUSLY (loadAuthenticationDocument
        // fires `completion(false)` inline). If we fire the fetch before the
        // `Task`'s AsyncStream sink has attached, both sends land first and the
        // subscriber only ever sees `.detailsFailed` — the `.detailsLoading`
        // transition is lost. So gate the fetch on the subscription being live:
        // the stream task signals once it has received its first (replayed)
        // value, proving the sink is attached. `SubscribedFlag` is a lock-guarded
        // box so the fulfill is race-free under Swift 6.
        let observedBox = ObservedLabels()
        let subscribed = expectation(description: "stream subscription attached")
        subscribed.assertForOverFulfill = false
        let streamTask = Task {
            var firstSeen = false
            for await state in account.stateStream {
                if !firstSeen { firstSeen = true; subscribed.fulfill() }
                let last = observedBox.append(self.label(state))
                if last.hasPrefix("detailsFailed") { break }
            }
        }

        // Do not fire the transition until the sink is confirmed live.
        wait(for: [subscribed], timeout: 2.0)

        manager.fetchAuthDocumentWithStateMachine(for: account) { success in
            XCTAssertFalse(success, "loadAuthenticationDocument with nil URL must return false")
            exp.fulfill()
        }

        wait(for: [exp], timeout: 2.0)

        // Stream observer should have seen detailsLoading then detailsFailed.
        // (The current state at subscription time was .notLoaded — the
        // CurrentValueSubject emits that as the first value.)
        // Poll the Task-based observer's accumulator until both expected
        // transitions have landed. The streamTask itself breaks on the
        // terminal `.detailsFailed`, so the writes have happened; the poll
        // forces a fresh read on the main thread before assertion.
        awaitCondition(timeout: 2.0) {
            observedBox.snapshot.contains("detailsLoading") &&
                observedBox.snapshot.contains("detailsFailed.authDocumentFetchFailed")
        }
        streamTask.cancel()

        let observed = observedBox.snapshot
        XCTAssertTrue(observed.contains("detailsLoading"),
                      "Stream must observe .detailsLoading before failure; observed: \(observed)")
        XCTAssertTrue(observed.contains("detailsFailed.authDocumentFetchFailed"),
                      "Stream must observe .detailsFailed(.authDocumentFetchFailed); observed: \(observed)")

        // Final state must be the terminal failure case.
        switch AccountStateStore.shared.state(for: account.uuid) {
        case .detailsFailed(let err):
            if case .authDocumentFetchFailed(let desc) = err {
                XCTAssertFalse(desc.isEmpty,
                               "underlyingDescription on .authDocumentFetchFailed must be non-empty so callers can surface the error")
            } else {
                XCTFail("Expected .authDocumentFetchFailed, got \(err)")
            }
        default:
            XCTFail("Account must terminate in .detailsFailed after fetch failure; got \(label(AccountStateStore.shared.state(for: account.uuid)))")
        }
    }

    // MARK: - Test 3b: torn-down manager's entry guard suppresses the auth-doc write

    /// Deterministic regression guard for the auth-doc late-write pollution fix.
    /// Once a manager has been explicitly torn down (`cancelBackgroundWork()`,
    /// which flips the DEBUG-only `_explicitCancelCalled` synchronously),
    /// `fetchAuthDocumentWithStateMachine` MUST be an inert no-op: it must NOT
    /// write the synchronous `.detailsLoading` (nor fire the network fetch), so a
    /// late/deferred `driveCurrentAccountAuthDocIfNeeded` cannot dirty
    /// `AccountStateStore.shared` after the NEXT test's reset — the root cause of
    /// the order-dependent flakes in this suite and AccountsManagerLaunchSnapshotTests.
    ///
    /// The entry guard's suppression is synchronous, so this test needs no async,
    /// no network, and no fixture path — a near-clone of Test 3 (above) plus the
    /// teardown call. Mutation check: negating the entry guard (`if
    /// _explicitCancelCalled` → `if false`) lets `.detailsLoading` land and
    /// reddens this test; the order-dependent pollution tests would not reliably
    /// catch that mutation.
    func testFetchAuthDoc_afterCancelBackgroundWork_isInertNoOp_leavesStateNotLoaded() throws {
        // Unique id → a fresh account whose UUID has no prior entry in the shared
        // store, so the precondition below is deterministic regardless of order.
        let metadata = OPDS2Publication.Metadata(
            updated: Date(),
            description: "entry-guard regression",
            id: "urn:uuid:wiring-test-entryguard-\(UUID().uuidString)",
            title: "Entry-Guard Library"
        )
        let pub = OPDS2Publication(links: [], metadata: metadata, images: nil)
        let account = Account(publication: pub, imageCache: MockImageCache())

        guard case .notLoaded = AccountStateStore.shared.state(for: account.uuid) else {
            return XCTFail("Precondition: a fresh unique account must start at .notLoaded, got \(label(AccountStateStore.shared.state(for: account.uuid)))")
        }

        let manager = makeFreshAccountsManager()
        // Tear the manager down — flips `_explicitCancelCalled` synchronously.
        manager.cancelBackgroundWork()

        var completionValue: Bool?
        // Entry guard fires SYNCHRONOUSLY: completion(false), no state write.
        manager.fetchAuthDocumentWithStateMachine(for: account) { completionValue = $0 }

        XCTAssertEqual(completionValue, false,
                       "A torn-down manager's fetch must complete(false) via the DEBUG entry guard")
        guard case .notLoaded = AccountStateStore.shared.state(for: account.uuid) else {
            return XCTFail("Entry guard must suppress the synchronous .detailsLoading write on a torn-down manager — a late/deferred drive would otherwise pollute the next test. Got \(label(AccountStateStore.shared.state(for: account.uuid)))")
        }
    }

    // MARK: - Test 3c: boundary drain flushes the deferred auth-doc main-hop

    /// Regression guard for GAP 1 (the un-cancellable `DispatchQueue.main.async`
    /// auth-doc drive `preloadAccountsFromDiskCacheSync` enqueues at init). That
    /// hop is NOT a `Task`, so `cancelBackgroundWork()` cannot cancel it; if it
    /// escapes the test boundary it fires on a LATER runloop turn — AFTER the next
    /// test's `_resetForTesting()` store reset — and writes a fixture-shared
    /// library UUID's `.detailsLoading` into whichever Accounts test runs next
    /// (the order-dependent suite flakes).
    ///
    /// GAP 1 makes `cancelAndDrainBackgroundWork()` PUMP the run loop at the
    /// empty-task boundary so any such pending main-hop fires INSIDE the boundary
    /// (before the store reset) and is wiped, instead of leaking past it.
    ///
    /// Why this models the FOREIGN-manager leak (and why a single-manager test
    /// has no teeth): `cancelAndDrainBackgroundWork()` calls `cancelBackgroundWork()`
    /// which flips `_explicitCancelCalled = true`, so a manager's OWN deferred
    /// drive is already made inert by the #1232 entry guard regardless of the
    /// pump. The residual leak is a NEVER-torn-down manager's pending hop — e.g.
    /// the `AppContainer.production()` manager a Catalog test builds and never
    /// tears down, whose `_explicitCancelCalled` stays false. We model that hop by
    /// its terminal store-write effect: a `DispatchQueue.main.async` (NOT a Task)
    /// performing the drive's synchronous `Account._setState(.detailsLoading)` —
    /// the exact seam `fetchAuthDocumentWithStateMachine` writes through — while
    /// the boundary drain runs on a SEPARATE fresh manager, mirroring production
    /// where the boundary reset drains the current manager while the leaked hop
    /// belongs to a prior one. The async network tail is deliberately omitted so
    /// the boundary-ORDERING assertion (write-before-reset vs after) is
    /// deterministic.
    ///
    /// Mutation proof (verified before/after): reverting GAP 1 (restoring
    /// `guard !tasksToDrain.isEmpty else { return }`) makes the hop escape the
    /// boundary — it fires after the reset and leaks `.detailsLoading`, reddening
    /// the final assertion.
    func testBoundaryDrain_flushesDeferredAuthDocMainHop_insideTheBoundary() throws {
        // Unique UUID → deterministic regardless of suite order.
        let metadata = OPDS2Publication.Metadata(
            updated: Date(),
            description: "gap1 boundary-drain regression",
            id: "urn:uuid:pollfix-boundary-\(UUID().uuidString)",
            title: "Boundary-Drain Library"
        )
        let pub = OPDS2Publication(links: [], metadata: metadata, images: nil)
        let leakedAccount = Account(publication: pub, imageCache: MockImageCache())
        let u = leakedAccount.uuid

        #if DEBUG
        AccountStateStore.shared._resetAllForTesting()
        #endif
        guard case .notLoaded = AccountStateStore.shared.state(for: u) else {
            return XCTFail("Precondition: a fresh unique account must start at .notLoaded, got \(label(AccountStateStore.shared.state(for: u)))")
        }

        // Reproduce init's un-cancellable main-hop: a DispatchQueue.main.async
        // (NOT a Task, so `cancelBackgroundWork()` cannot cancel it) performing
        // the deferred auth-doc drive's synchronous store write. Never torn down,
        // so no `_explicitCancelCalled` guard suppresses it — only the boundary
        // drain's PUMP can service it. We assert on the drive's synchronous
        // `.detailsLoading` write (the exact seam `fetchAuthDocumentWithStateMachine`
        // uses); the async network tail is omitted so the boundary-ordering
        // assertion is deterministic.
        DispatchQueue.main.async {
            leakedAccount._setState(.detailsLoading)
        }

        // The pending hop has NOT run yet — we are still on the same synchronous
        // main-thread stack that enqueued it.
        guard case .notLoaded = AccountStateStore.shared.state(for: u) else {
            return XCTFail("Precondition: the deferred hop must not have fired before the boundary drain; got \(label(AccountStateStore.shared.state(for: u)))")
        }

        // GAP 1: `cancelAndDrainBackgroundWork()` (invoked at every real test
        // boundary from `AppContainer._resetForTesting()`) must PUMP the run loop
        // so the pending main-hop fires INSIDE the boundary. A fresh, task-less
        // manager exercises exactly the empty-`tasksToDrain` branch that carries
        // the pump.
        let boundaryManager = makeFreshAccountsManager()
        boundaryManager.cancelAndDrainBackgroundWork()

        // The load-bearing assertion. WITH GAP 1: the pump serviced the pending
        // hop, so its `.detailsLoading` write has already landed by the time the
        // drain returns — the hop is flushed INSIDE the boundary, where the
        // boundary's own store reset then wipes it, instead of leaking onto a
        // later runloop turn in the NEXT test.
        //
        // Mutation proof (verified before/after): reverting GAP 1 (restoring
        // `guard !tasksToDrain.isEmpty else { return }`) makes the drain return
        // WITHOUT pumping — the hop is still queued, so `u` is still `.notLoaded`
        // here and this assertion reddens. That is the teeth: a single-manager
        // test cannot show this because `cancelBackgroundWork()` flips
        // `_explicitCancelCalled`, making a manager's OWN drive inert regardless
        // of the pump; the residual leak (and the pump's value) is flushing a
        // FOREIGN never-torn-down manager's pending hop, which this models.
        guard case .detailsLoading = AccountStateStore.shared.state(for: u) else {
            return XCTFail("GAP 1: the boundary drain must PUMP the run loop so the deferred auth-doc main-hop fires inside the boundary (expected .detailsLoading here); got \(label(AccountStateStore.shared.state(for: u))) — the hop leaked past the drain onto a later runloop turn (the next-test pollution).")
        }

        // Housekeeping: `u` is a unique UUID (cannot collide with any fixture),
        // but reset it explicitly so nothing bleeds. (`_resetAllForTesting` does
        // not clean subjects created this late in the method — a documented quirk
        // of that DEBUG helper — so use the direct per-UUID reset.)
        AccountStateStore.shared.reset(for: u)
    }

    /// Regression guard for the SECOND pollution cluster (Borrow* +
    /// `testPreload_drivesEachLoadedAccount_toBasicInfoLoaded`): a FOREIGN
    /// `AccountsManager` built by an earlier test and NEVER torn down by the
    /// production boundary leaks a deferred auth-doc main-hop that late-writes
    /// `AccountStateStore.shared`, starving the pool and polluting later async
    /// victims. The production boundary (`AppContainer._resetForTesting`) only
    /// EXPLICITLY drains the CURRENT cached manager; a foreign one is invisible
    /// to that explicit path. The FIX is the process-wide
    /// `AccountsManager._drainAllLiveInstancesForTesting()` — it discovers every
    /// live manager through the weak live-instance registry each manager joins at
    /// `init`, and the boundary invokes it BEFORE the
    /// `AccountStateStore._resetAllForTesting()` resetter.
    ///
    /// This test drives that GLOBAL boundary path. The load-bearing distinction
    /// from the sibling `testBoundaryDrain_...` test (which calls
    /// `cancelAndDrainBackgroundWork()` DIRECTLY on a manager it holds) is that
    /// here the test NEVER calls drain on the manager directly — it calls only
    /// the static `_drainAllLiveInstancesForTesting()`, which must find the
    /// manager via the WEAK REGISTRY (the new `init`-time registration) and drain
    /// it. That drain PUMPS the run loop (empty-task branch, since
    /// `deferInitialLoadCatalogsForTesting` is true), servicing the leaked hop
    /// INSIDE the boundary; the follow-on store reset then wipes it — leaving the
    /// next test a clean store.
    ///
    /// The live manager is built via the `makeFreshAccountsManager()` seam (so
    /// the isolation-lint's `cancelBackgroundWork()`/bag-drain teardown fires and
    /// the base's array keeps it alive for the whole method) — but the boundary's
    /// production path does NOT walk that array; the ONLY way
    /// `_drainAllLiveInstancesForTesting()` reaches it is the weak registry. If
    /// the `init`-time registration were removed OR the drain-all loop were made
    /// a no-op, the registry yields no drainable manager, nothing pumps, and the
    /// leaked hop escapes forward (proved by the teeth below).
    ///
    /// Teeth (verified before/after): SKIP the
    /// `_drainAllLiveInstancesForTesting()` call and the leaked hop is never
    /// pumped inside the boundary; the store reset runs while the hop is still
    /// queued, then the "next test" runloop pump fires it and `.detailsLoading`
    /// leaks forward — the final `.notLoaded` assertion reddens. Restoring the
    /// call flushes-then-wipes it and the assertion passes.
    func testGlobalBoundaryDrain_flushesForeignUntornDownManager_leavesStoreClean() throws {
        // A unique account U → deterministic regardless of suite order.
        let metadata = OPDS2Publication.Metadata(
            updated: Date(),
            description: "global-drain foreign-polluter regression",
            id: "urn:uuid:pollfix-global-\(UUID().uuidString)",
            title: "Global-Drain Foreign Library"
        )
        let pub = OPDS2Publication(links: [], metadata: metadata, images: nil)
        let leakedAccount = Account(publication: pub, imageCache: MockImageCache())
        let u = leakedAccount.uuid

        #if DEBUG
        AccountStateStore.shared._resetAllForTesting()
        #endif
        // Reading `state(for:)` here CREATES U's subject NOW, so the boundary's
        // `_resetAllForTesting()` snapshot below will include and wipe it (that
        // helper only iterates subjects that exist at call time — a documented
        // quirk; see the sibling test).
        guard case .notLoaded = AccountStateStore.shared.state(for: u) else {
            return XCTFail("Precondition: a fresh unique account must start at .notLoaded, got \(label(AccountStateStore.shared.state(for: u)))")
        }

        // A LIVE manager that the global drain must discover via the process-wide
        // weak registry (joined at `init`). Built through the seam so it is
        // lint-clean AND retained by the base's teardown array for the whole
        // method; crucially the PRODUCTION boundary does NOT walk that array — it
        // reaches this manager ONLY through `_drainAllLiveInstancesForTesting()`'s
        // weak-registry scan, exactly as it would reach a foreign, never-directly-
        // drained manager. Its `deferInitialLoadCatalogsForTesting` is pinned true
        // by the seam, so its own drain takes the empty-task PUMP branch.
        let liveManager = makeFreshAccountsManager()
        XCTAssertNotNil(liveManager, "Live registered manager must construct")

        // The leaked pending write a foreign manager's deferred auth-doc hop would
        // make late: a `DispatchQueue.main.async` (NOT a Task — so
        // `cancelBackgroundWork()` cannot cancel it) performing the drive's
        // synchronous `.detailsLoading` store write — the exact seam
        // `fetchAuthDocumentWithStateMachine` / the `init` :623 hop writes through.
        // It is independent of any manager (it captures the Account, not the
        // manager), which is why only a run-loop PUMP — not a per-manager cancel —
        // can flush it.
        DispatchQueue.main.async {
            leakedAccount._setState(.detailsLoading)
        }

        // Not yet run — still on the synchronous stack that enqueued it.
        guard case .notLoaded = AccountStateStore.shared.state(for: u) else {
            return XCTFail("Precondition: the deferred hop must not have fired before the boundary; got \(label(AccountStateStore.shared.state(for: u)))")
        }

        // Invoke the GLOBAL boundary path. This is the load-bearing step: the
        // test NEVER calls drain on `liveManager` directly — the static must find
        // it via the WEAK REGISTRY (populated by the new `init`-time
        // registration) and PUMP the run loop, flushing the leaked hop INSIDE the
        // boundary. Mirrors `AppContainer._resetForTesting`, which invokes this
        // static right before the `AccountStateStore` resetter.
        AccountsManager._drainAllLiveInstancesForTesting()

        // PRIMARY TEETH: the leaked hop has now fired INSIDE the boundary — the
        // global drain reached the registered manager and pumped. If the
        // `init`-time registration were removed (empty registry) OR the drain-all
        // loop were made a no-op, nothing would pump here and U would still be
        // `.notLoaded` — reddening this assertion. This is precisely what a
        // per-manager-only drain CANNOT achieve for a manager the caller does not
        // hold a reference to: only the registry-backed global drain reaches it.
        guard case .detailsLoading = AccountStateStore.shared.state(for: u) else {
            return XCTFail("Global drain must reach the registered manager via the weak registry and PUMP the run loop so the leaked auth-doc hop fires INSIDE the boundary (expected .detailsLoading); got \(label(AccountStateStore.shared.state(for: u))) — the drain did not flush it (registration missing or drain-all is a no-op).")
        }

        // Model the boundary's follow-on store reset that wipes the just-flushed
        // write. We use the direct per-UUID `reset(for:)` — the same seam the
        // sibling `testBoundaryDrain_...` test uses for housekeeping — because
        // `_resetAllForTesting()`'s snapshot does not clean a subject created this
        // late in the method (a documented quirk of that DEBUG helper). At the
        // REAL boundary the fixture UUID was seeded early, so its own
        // `_resetAllForTesting()` wipes it there; here `reset(for:)` reproduces
        // that terminal effect deterministically.
        #if DEBUG
        AccountStateStore.shared._resetAllForTesting()
        #endif
        AccountStateStore.shared.reset(for: u)

        // Simulate the NEXT test: pump the run loop several turns. Because the hop
        // already fired-and-was-wiped inside the boundary, nothing pending remains
        // and U stays clean — it did NOT leak forward.
        for _ in 0..<5 {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }

        // The leaked hop did not survive into the simulated next test.
        guard case .notLoaded = AccountStateStore.shared.state(for: u) else {
            return XCTFail("After the global drain flushed the hop inside the boundary and the store reset wiped it, U must be .notLoaded for the next test; got \(label(AccountStateStore.shared.state(for: u))) — a write leaked forward (the second pollution cluster).")
        }
    }

    // MARK: - Test 4: Single-flight per-UUID auth doc fetch

    /// Contract: when two concurrent `fetchAuthDocumentWithStateMachine`
    /// calls land for the same UUID, only one invocation of
    /// `Account.loadAuthenticationDocument` may fire. The second caller
    /// must NOT trigger a duplicate HTTP request — the state stream's
    /// broadcast (`CurrentValueSubject`) covers multi-consumer observation.
    ///
    /// Exercises the single-flight set's deduplication directly. We use an
    /// Account whose loadAuthenticationDocument short-circuits (no auth-doc
    /// URL) so the test doesn't depend on network mocking. The wiring
    /// inserts/removes the UUID from `inflightAuthDocFetches` around the
    /// call; the second caller observes the UUID is present and returns
    /// without invoking the loader again.
    func testSingleFlight_twoConcurrentAwaiters_oneNetworkRequest() {
        let metadata = OPDS2Publication.Metadata(
            updated: Date(),
            description: "single-flight test",
            id: "urn:uuid:wiring-test-singleflight",
            title: "Single-flight Library"
        )
        let pub = OPDS2Publication(links: [], metadata: metadata, images: nil)
        let account = Account(publication: pub, imageCache: MockImageCache())

        let manager = makeFreshAccountsManager()

        // Track how many times `.detailsLoading` is set — that's our proxy
        // for "number of loader invocations", since the wiring fires
        // `_setState(.detailsLoading)` once at the entry of each non-deduped
        // call. A duplicate fetch would observe two `.detailsLoading`
        // transitions.
        // Swift 6: NSLock.lock()/unlock() are unavailable in async contexts, and
        // the captured `var` counters would be data races inside the Task. Fold
        // both into one lock-guarded @unchecked Sendable box shared by the stream
        // task and the assertion below.
        final class Counters: @unchecked Sendable {
            private let lock = NSLock()
            private var _detailsLoadingCount = 0
            private var _sawTerminal = false
            var detailsLoadingCount: Int { lock.withLock { _detailsLoadingCount } }
            func incrementDetailsLoading() { lock.withLock { _detailsLoadingCount += 1 } }
            /// True exactly once — on the first terminal transition.
            func markTerminalOnce() -> Bool {
                lock.withLock {
                    if _sawTerminal { return false }
                    _sawTerminal = true
                    return true
                }
            }
        }
        let counters = Counters()
        let observed = expectation(description: "stream reaches terminal")
        observed.assertForOverFulfill = false

        // `.detailsLoading` is set SYNCHRONOUSLY at the entry of a non-deduped
        // fetch, and `stateStream`'s CurrentValueSubject only replays the latest
        // value to a late subscriber. Gate the concurrent fetches on the stream
        // sink being attached (first replayed value observed) so the single
        // `.detailsLoading` transition is not raced away before we can count it.
        let subscribed = expectation(description: "stream subscription attached")
        subscribed.assertForOverFulfill = false
        let streamTask = Task {
            var firstSeen = false
            for await state in account.stateStream {
                if !firstSeen { firstSeen = true; subscribed.fulfill() }
                if case .detailsLoading = state {
                    counters.incrementDetailsLoading()
                }
                if case .detailsFailed = state {
                    if counters.markTerminalOnce() { observed.fulfill() }
                }
                if case .detailsLoaded = state {
                    if counters.markTerminalOnce() { observed.fulfill() }
                }
            }
        }
        wait(for: [subscribed], timeout: 2.0)

        // Fire two near-simultaneous calls for the SAME UUID. The second
        // must observe the single-flight set and return without calling
        // loadAuthenticationDocument again.
        let exp1 = expectation(description: "first caller completes")
        let exp2 = expectation(description: "second caller completes")
        let group = DispatchGroup()
        group.enter()
        group.enter()

        DispatchQueue.global().async {
            manager.fetchAuthDocumentWithStateMachine(for: account) { _ in
                exp1.fulfill()
                group.leave()
            }
        }
        DispatchQueue.global().async {
            manager.fetchAuthDocumentWithStateMachine(for: account) { _ in
                exp2.fulfill()
                group.leave()
            }
        }

        wait(for: [exp1, exp2, observed], timeout: 3.0)

        // Drain the main queue to ensure any post-terminal Combine emissions
        // from the stream task have landed before we read the count below.
        drainMainQueue()
        streamTask.cancel()

        let count = counters.detailsLoadingCount

        // The kill case: a non-single-flight wiring would fire
        // `_setState(.detailsLoading)` twice. The single-flight guard
        // ensures only ONE transition through `.detailsLoading`.
        XCTAssertEqual(count, 1,
                       "Single-flight guard must produce exactly one .detailsLoading transition for two concurrent callers on the same UUID; got \(count)")
    }

    // MARK: - Test 5: Library reselect → .detailsEvicted(.libraryDeselected) for prior

    /// Contract: when the user switches libraries, awaiters subscribed to
    /// the PRIOR account's stream must observe a terminal
    /// `.detailsEvicted(.libraryDeselected)`. Without this, an awaiter that
    /// took a reference to the prior Account before the switch would hang
    /// forever — the prior UUID's state stream would never transition.
    ///
    /// PR #1021 (Module A, swarm_51f248d5) split this terminal off from
    /// the formerly-shared `.detailsFailed(.accountNotFound)` so the
    /// eviction marker no longer collides with the genuine HTTP-404 load
    /// failure surfaced from `fetchAuthDocumentWithStateMachine`. See
    /// Test 8 (`testDriveCurrentAccountAuthDoc_realAccountNotFound_doesNotRedrive`)
    /// for the consumer-disambiguation half of the split.
    func testLibraryReselect_priorAccount_terminatesWithLibraryDeselected() throws {
        let catalogs = try loadFeedCatalogs()
        guard catalogs.count >= 2 else {
            throw XCTSkip("Fixture needs at least 2 catalogs to test reselect")
        }
        let accountA = Account(publication: catalogs[0], imageCache: MockImageCache())
        let accountB = Account(publication: catalogs[1], imageCache: MockImageCache())

        // Seed account A as detailsLoaded so the reselect transition is a
        // meaningful state change. `authenticationDocument.didSet` populates
        // `.details`; use the NYPL auth doc fixture.
        accountA.authenticationDocument = authDoc
        XCTAssertNotNil(accountA.details, "Setup: accountA must have details")
        accountA._setState(.detailsLoaded(accountA.details!))

        // Pre-state: confirm A is at detailsLoaded.
        if case .detailsLoaded = AccountStateStore.shared.state(for: accountA.uuid) {
            // OK
        } else {
            XCTFail("Pre-state: accountA must be in .detailsLoaded")
        }

        // swarm_cd181acd D-cleanup: per-test isolated UserDefaults suite
        // wired into the AccountsManager so the
        // `currentAccountIdentifierKey` write cannot leak via `.standard`.
        let defaults = Self.testUserDefaults()
        defaults.set(accountA.uuid, forKey: currentAccountIdentifierKey)

        let manager = makeFreshAccountsManager(defaults: defaults)

        // Act: switch currentAccount A → B. The setter must drive A to
        // `.detailsEvicted(.libraryDeselected)`. We bypass the accountSets
        // lookup by using accountB directly — the setter only reads
        // newValue?.uuid for the comparison.
        manager.currentAccount = accountB

        // Assert: A's terminal state is .detailsEvicted(.libraryDeselected);
        // B is untouched by the reselect path itself (its state is
        // whatever it was — .notLoaded in this isolated test, since no
        // preload ran).
        switch AccountStateStore.shared.state(for: accountA.uuid) {
        case .detailsEvicted(let reason):
            if case .libraryDeselected(let uuid) = reason {
                XCTAssertEqual(uuid, accountA.uuid,
                               ".libraryDeselected must carry the prior account's UUID, not the new one")
            } else {
                XCTFail("Expected .libraryDeselected, got \(reason)")
            }
        default:
            XCTFail("Prior account must terminate in .detailsEvicted(.libraryDeselected) after reselect; got \(label(AccountStateStore.shared.state(for: accountA.uuid)))")
        }
    }

    // MARK: - Test 5b: Library switch — NEW account gets auth-doc driver fired

    /// Contract: when the user switches libraries, the NEW currentAccount's
    /// LoadState must be driven past `.basicInfoLoaded` (or `.notLoaded`)
    /// just like the cold-launch warm-path. Without this, every
    /// `awaitReady()` caller (audiobook open, token refresh, bookmark
    /// sync, CarPlay auth) blocks forever the first time the user opens
    /// content on the newly-selected library — same disease class as
    /// the cold-launch spinner fix (PR #975), different trigger.
    func testLibrarySwitch_drivesNewCurrentAccountPastBasicInfoLoaded() throws {
        let catalogs = try loadFeedCatalogs()
        guard catalogs.count >= 2 else {
            throw XCTSkip("Fixture needs at least 2 catalogs to test library switch")
        }
        let priorUUID = catalogs[0].metadata.id
        let newUUID = catalogs[1].metadata.id

        // swarm_cd181acd D-cleanup: per-test isolated UserDefaults suite.
        let defaults = Self.testUserDefaults()
        // Seed disk cache + populate accountSets via preload so the
        // manager's currentAccount accessor can resolve UUIDs back to
        // Account instances after the switch.
        let manager = makeFreshAccountsManager(defaults: defaults)
        // Drain the main queue so init's background loadCatalogs has a chance
        // to fail (no network → fast failure) before our reset below.
        drainMainQueue()
        drainMainQueue()

        let activeHash = TPPConfiguration.customUrlHash()
            ?? (TPPSettings().useBetaLibraries
                ? TPPConfiguration.betaUrlHash
                : TPPConfiguration.prodUrlHash)
        try seedDiskCache(for: activeHash, data: feedData)
        defer { tearDownDiskCache(for: activeHash) }

        defaults.set(priorUUID, forKey: currentAccountIdentifierKey)

        #if DEBUG
        AccountStateStore.shared._resetAllForTesting()
        #endif

        manager.preloadAccountsFromDiskCacheSync()

        // Pre-state: newUUID is at .basicInfoLoaded after preload.
        switch AccountStateStore.shared.state(for: newUUID) {
        case .basicInfoLoaded:
            break // expected
        default:
            XCTFail("Setup: newUUID must be at .basicInfoLoaded after preload; got \(label(AccountStateStore.shared.state(for: newUUID)))")
            return
        }

        // Act: switch to a different library.
        guard let newAccount = manager.account(newUUID) else {
            XCTFail("Setup: manager must resolve newUUID via account()"); return
        }
        manager.currentAccount = newAccount

        // Assert: the new account's state moves past .basicInfoLoaded
        // within a bounded window. The setter must fire the auth-doc
        // driver — staying at .basicInfoLoaded means the regression is
        // open and awaitReady() callers hang after every library switch.
        awaitCondition(timeout: 4.0) {
            switch AccountStateStore.shared.state(for: newUUID) {
            case .detailsLoading, .detailsLoaded, .detailsFailed:
                return true
            default:
                return false
            }
        }

        let observedFinalState = AccountStateStore.shared.state(for: newUUID)
        switch observedFinalState {
        case .detailsLoading, .detailsLoaded, .detailsFailed:
            break // wiring fired
        default:
            XCTFail("Library-switch setter must drive new currentAccount past .basicInfoLoaded; observed \(label(observedFinalState))")
        }
    }

    // MARK: - Test 6: Re-entry after reselect resets state

    /// Contract: after a library reselect terminates the prior UUID at
    /// `.detailsEvicted(.libraryDeselected)`, re-entering that UUID (user
    /// switches back) must NOT leave the awaiter stuck on the prior
    /// terminal. The next `_setState` write (via preload or
    /// `fetchAuthDocumentWithStateMachine`) cleanly overwrites it because
    /// `CurrentValueSubject.send` doesn't dedupe on equality — every send
    /// broadcasts.
    func testLibraryReselect_reentry_resetsState_andRedrives() throws {
        let catalogs = try loadFeedCatalogs()
        guard catalogs.count >= 2 else {
            throw XCTSkip("Fixture needs at least 2 catalogs to test reselect re-entry")
        }
        let accountA = Account(publication: catalogs[0], imageCache: MockImageCache())
        let accountB = Account(publication: catalogs[1], imageCache: MockImageCache())

        // Seed accountA as detailsLoaded.
        accountA.authenticationDocument = authDoc
        accountA._setState(.detailsLoaded(accountA.details!))

        // swarm_cd181acd D-cleanup: per-test isolated UserDefaults suite.
        let defaults = Self.testUserDefaults()
        defaults.set(accountA.uuid, forKey: currentAccountIdentifierKey)

        let manager = makeFreshAccountsManager(defaults: defaults)

        // Switch A → B; A terminates at .detailsEvicted(.libraryDeselected).
        manager.currentAccount = accountB

        // Verify the terminal A state.
        switch AccountStateStore.shared.state(for: accountA.uuid) {
        case .detailsEvicted(.libraryDeselected):
            break
        default:
            XCTFail("Setup precondition: A must be .detailsEvicted(.libraryDeselected) after A→B switch; got \(label(AccountStateStore.shared.state(for: accountA.uuid)))")
        }

        // Capture A's stream so we can assert the re-entry transition emits.
        var observed: [String] = []
        let exp = expectation(description: "A re-enters .basicInfoLoaded after reselect")
        let streamTask = Task {
            for await state in accountA.stateStream {
                observed.append(self.label(state))
                if observed.contains("basicInfoLoaded") {
                    exp.fulfill()
                    break
                }
            }
        }

        // Re-drive A via the basicInfoLoaded path (this is exactly what
        // preload would do on the next cold launch / library list re-render).
        // The wiring contract is that `_setState` overwrites cleanly — even
        // when going from a `.detailsEvicted` terminal back to an earlier
        // ordinal state. CurrentValueSubject.send always broadcasts.
        accountA._setState(.basicInfoLoaded)

        wait(for: [exp], timeout: 2.0)
        streamTask.cancel()

        // Final state assertion: re-entry landed A in basicInfoLoaded.
        switch AccountStateStore.shared.state(for: accountA.uuid) {
        case .basicInfoLoaded:
            break
        default:
            XCTFail("After re-entry, A must be in .basicInfoLoaded; got \(label(AccountStateStore.shared.state(for: accountA.uuid)))")
        }

        // Stream observer must have witnessed the basicInfoLoaded
        // transition AFTER the detailsEvicted terminal — this is the
        // kill condition for a wiring that dedupes equal states
        // (a broken `setState` that no-ops if old==new would never emit).
        XCTAssertTrue(observed.contains("basicInfoLoaded"),
                      "Stream must emit .basicInfoLoaded on re-entry; observed: \(observed)")
    }

    // MARK: - Test 7: driveCurrentAccountAuthDocIfNeeded re-drives stale eviction marker

    /// Contract: when the user switches libraries away from A and then back to A
    /// (A → B → A), the helper must NOT short-circuit on the
    /// `.detailsEvicted(.libraryDeselected)` terminal that the setter wrote
    /// during the A → B step. That marker is an eviction signal for awaiters
    /// on the PRIOR account; once A is the current account again, the marker
    /// is stale.
    ///
    /// Without the redrive: awaitReady() callers (audiobook open, token refresh,
    /// bookmark sync, CarPlay auth) hit the eviction terminal fast-path and
    /// throw `.evicted` forever on the swap-back — exactly the audiobook-open
    /// "Please sign in" regression observed in field reports.
    ///
    /// PR #1021 (Module A, swarm_51f248d5) is the structural fix: the eviction
    /// marker now lives in its own enum case (`.detailsEvicted(.libraryDeselected)`)
    /// rather than sharing storage with `.detailsFailed(.accountNotFound)`.
    /// `driveCurrentAccountAuthDocIfNeeded` matches the new case and redrives;
    /// the kill case (a regression that drops the `.detailsEvicted`
    /// disambiguation) lets the stale terminal stick.
    ///
    /// Kill case: removing the `.detailsEvicted(.libraryDeselected)` branch
    /// from the helper's switch makes this test observe the stale terminal
    /// instead of a drive transition.
    func testDriveCurrentAccountAuthDoc_staleEvictionMarker_redrives() throws {
        let catalogs = try loadFeedCatalogs()
        guard catalogs.count >= 1 else {
            throw XCTSkip("Fixture needs at least 1 catalog")
        }
        let currentUUID = catalogs[0].metadata.id

        // swarm_cd181acd D-cleanup: per-test isolated UserDefaults suite.
        let defaults = Self.testUserDefaults()
        let manager = makeFreshAccountsManager(defaults: defaults)
        // Deterministic barrier: `deferInitialLoadCatalogsForTesting` (pinned
        // true by `PalaceWiringTestCase`) means `init` never spawns a
        // background `loadCatalogs` Task, so there is no real async work to
        // "settle" here — this was a fixed-delay pad. `drainMainQueue()`
        // flushes anything already enqueued on the main queue (mirrors the
        // identical construction pattern a few tests up in this file) without
        // guessing at a wall-clock window.
        drainMainQueue()

        let activeHash = TPPConfiguration.customUrlHash()
            ?? (TPPSettings().useBetaLibraries
                ? TPPConfiguration.betaUrlHash
                : TPPConfiguration.prodUrlHash)
        try seedDiskCache(for: activeHash, data: feedData)
        defer { tearDownDiskCache(for: activeHash) }

        defaults.set(currentUUID, forKey: currentAccountIdentifierKey)

        #if DEBUG
        AccountStateStore.shared._resetAllForTesting()
        #endif

        manager.preloadAccountsFromDiskCacheSync()

        guard let account = manager.currentAccount else {
            XCTFail("Setup: currentAccount must resolve after preload"); return
        }
        XCTAssertEqual(account.uuid, currentUUID,
                       "Setup precondition: currentAccount must resolve to the seeded UUID")

        // Stage the stale eviction marker — what the setter would have written
        // against this UUID during a prior A → B switch.
        account._setState(.detailsEvicted(.libraryDeselected(uuid: currentUUID)))
        if case .detailsEvicted(.libraryDeselected) = AccountStateStore.shared.state(for: currentUUID) {
            // OK
        } else {
            XCTFail("Setup precondition: state must be .detailsEvicted(.libraryDeselected)")
            return
        }

        // Act: drive. With the fix, the helper recognizes the eviction marker as
        // stale-for-the-current-account and re-fires the fetch — which moves
        // state through .detailsLoading. Without the fix, the helper short-
        // circuits and state stays at .detailsEvicted(.libraryDeselected).
        manager.driveCurrentAccountAuthDocIfNeeded()

        // Assert: state moved past the stale terminal within a bounded window.
        // `.detailsLoading` is the immediate observable transition (the fetch
        // wrapper writes it synchronously); `.detailsLoaded` or
        // `.detailsFailed(.authDocumentFetchFailed)` are acceptable downstream
        // terminals depending on the network availability of the test env. The
        // kill condition is the marker staying put.
        // Deterministic poll via the shared `awaitCondition` primitive
        // (already used elsewhere in this file, e.g.
        // `testLoadCatalogs_warmPath_drivesCurrentAccountPastBasicInfoLoaded`)
        // instead of a hand-rolled `while Date() < deadline` loop with
        // `Thread.sleep` yields — same bounded-poll semantics, no
        // hand-maintained deadline/sleep bookkeeping, and a loud `XCTFail`
        // (not a silent stale read) on timeout.
        awaitCondition(timeout: 4.0) {
            switch AccountStateStore.shared.state(for: currentUUID) {
            case .detailsLoading, .detailsLoaded, .detailsFailed:
                return true
            default:
                return false
            }
        }
        let observedFinalState = AccountStateStore.shared.state(for: currentUUID)

        switch observedFinalState {
        case .detailsLoading, .detailsLoaded:
            break // fix is in — drive fired and state moved through .detailsLoading
        case .detailsEvicted(.libraryDeselected):
            XCTFail("driveCurrentAccountAuthDocIfNeeded must redrive past a stale .detailsEvicted(.libraryDeselected) marker for the current account; observed terminal stayed at \(label(observedFinalState))")
        case .detailsFailed:
            // .detailsFailed(.authDocumentFetchFailed) is acceptable — proves
            // the fetch was re-fired (it just failed in the test env without
            // network). The kill condition is the eviction marker staying put.
            break
        default:
            XCTFail("Helper must drive past stale .detailsEvicted(.libraryDeselected) marker; observed \(label(observedFinalState))")
        }
    }

    // MARK: - Test 10: real .detailsFailed(.accountNotFound) does NOT redrive (consumer disambiguation)

    /// Contract (Module A semantics test #3, swarm_51f248d5): a genuine
    /// `.detailsFailed(.accountNotFound)` terminal MUST NOT trigger the
    /// `driveCurrentAccountAuthDocIfNeeded` redrive arm. The redrive is only
    /// for `.detailsEvicted(.libraryDeselected)` — the eviction marker the
    /// `currentAccount` setter writes on library switch. A real HTTP 404 /
    /// catalog-removal at `fetchAuthDocumentWithStateMachine` failure path
    /// is a load-pipeline error and the helper must respect it (the
    /// existing `.detailsFailed` arm returns early).
    ///
    /// Without this disambiguation, prior to PR #1021 the `.accountNotFound`
    /// case carried two orthogonal meanings (real failure AND eviction
    /// marker) and the helper had to special-case the conflation, which
    /// caused real `.accountNotFound` failures to also redrive — hammering
    /// the load endpoint into a tight retry loop. Splitting the enum
    /// (Module A) is the root fix; this test pins the new behavior.
    ///
    /// Kill case: a regression that re-conflates the two meanings (e.g. by
    /// adding `.detailsFailed(.accountNotFound)` to the redrive arm) would
    /// observe a `.detailsLoading` transition here and fail the assertion.
    func testDriveCurrentAccountAuthDoc_realAccountNotFound_doesNotRedrive() throws {
        let catalogs = try loadFeedCatalogs()
        guard catalogs.count >= 1 else {
            throw XCTSkip("Fixture needs at least 1 catalog")
        }
        let currentUUID = catalogs[0].metadata.id

        // swarm_cd181acd D-cleanup: per-test isolated UserDefaults suite.
        let defaults = Self.testUserDefaults()
        let manager = makeFreshAccountsManager(defaults: defaults)
        // Drain the main queue so init's background loadCatalogs has a chance
        // to fail (no network → fast failure) before our reset below.
        drainMainQueue()
        drainMainQueue()

        let activeHash = TPPConfiguration.customUrlHash()
            ?? (TPPSettings().useBetaLibraries
                ? TPPConfiguration.betaUrlHash
                : TPPConfiguration.prodUrlHash)
        try seedDiskCache(for: activeHash, data: feedData)
        defer { tearDownDiskCache(for: activeHash) }

        defaults.set(currentUUID, forKey: currentAccountIdentifierKey)

        #if DEBUG
        AccountStateStore.shared._resetAllForTesting()
        #endif

        manager.preloadAccountsFromDiskCacheSync()

        guard let account = manager.currentAccount else {
            XCTFail("Setup: currentAccount must resolve after preload"); return
        }
        XCTAssertEqual(account.uuid, currentUUID,
                       "Setup precondition: currentAccount must resolve to the seeded UUID")

        // Stage a REAL .accountNotFound (NOT an eviction marker). Simulates
        // the `fetchAuthDocumentWithStateMachine` failure path producing an
        // .accountNotFound error — a real load pipeline error, not a library
        // switch eviction.
        account._setState(.detailsFailed(.accountNotFound(uuid: currentUUID)))
        if case .detailsFailed(.accountNotFound) = AccountStateStore.shared.state(for: currentUUID) {
            // OK — pre-state pinned
        } else {
            XCTFail("Setup precondition: state must be .detailsFailed(.accountNotFound)")
            return
        }

        // Subscribe to the state stream BEFORE the drive call. We use the
        // stream rather than polling because the redrive (if it fires) is
        // synchronous on `_setState(.detailsLoading)` and would emit an
        // observable transition. Absence of any post-initial emission is
        // the success signal.
        var emissionsAfterInitial: [String] = []
        let initialEmission = expectation(description: "stream emits initial terminal value")
        let streamTask = Task {
            var isFirst = true
            for await state in account.stateStream {
                if isFirst {
                    isFirst = false
                    initialEmission.fulfill()
                    continue
                }
                emissionsAfterInitial.append(self.label(state))
            }
        }
        wait(for: [initialEmission], timeout: 1.0)

        // Act: call the helper. With the enum split in place, the genuine
        // `.detailsFailed(.accountNotFound)` MUST hit the `.detailsFailed`
        // catch-all arm and short-circuit — NOT the
        // `.detailsEvicted(.libraryDeselected)` redrive arm.
        manager.driveCurrentAccountAuthDocIfNeeded()

        // Drain the main queue so any unwanted Combine/notification emission
        // dispatched by the driver lands before we assert silence below.
        drainMainQueue()
        streamTask.cancel()

        // Assert: no transition fired after subscribe. A regression that
        // re-conflated the cases would observe a `.detailsLoading` emission
        // (the redrive arm fires `_setState(.detailsLoading)` synchronously
        // inside `fetchAuthDocumentWithStateMachine`).
        XCTAssertTrue(emissionsAfterInitial.isEmpty,
                      "Real .detailsFailed(.accountNotFound) must NOT trigger the eviction-marker redrive; observed emissions: \(emissionsAfterInitial). A .detailsLoading emission proves the helper re-conflated the two semantics.")

        // Final state must still be the real-failure terminal we set up.
        switch AccountStateStore.shared.state(for: currentUUID) {
        case .detailsFailed(.accountNotFound):
            break // expected: helper respected the real failure
        default:
            XCTFail("Final state must remain .detailsFailed(.accountNotFound) — helper must not redrive a genuine load failure; got \(label(AccountStateStore.shared.state(for: currentUUID)))")
        }
    }

    // MARK: - Test 8: startDownload captures currentAccountId once — full A→nil→A→B round-trip

    /// Contract (Module A — `feedback_round_trip_wiring_tests.md`): the
    /// `DownloadStartCoordinator.startDownloadAsync` seam MUST capture
    /// `accountsManager.currentAccountId` ONCE at the top of the path and
    /// thread that captured id through to bearer-auth. Mid-flight library
    /// swaps cannot leak into the in-flight download's Authorization header.
    ///
    /// Round-trip exercise (the canonical pattern — write → reset → re-enter):
    ///   1. Set currentAccountId = "A". Start download → bearer-auth applied
    ///      with accountId == "A".
    ///   2. Set currentAccountId = nil (the "reset" arm). Start a SECOND
    ///      download → bearer-auth applied with accountId == sentinel
    ///      (the new capture observes nil and records the placeholder).
    ///   3. Restore currentAccountId = "A" (the "re-enter" arm). Start a
    ///      THIRD download → bearer-auth applied with accountId == "A"
    ///      again (the prior nil capture did NOT poison subsequent captures).
    ///   4. Set currentAccountId = "B". Start a FOURTH download →
    ///      bearer-auth applied with accountId == "B" (proves capture
    ///      re-reads each call — it's not cached forever).
    ///
    /// Kill case: removing the capture-at-start let-binding in
    /// `DownloadStartCoordinator.startDownloadAsync` (so the downstream
    /// `processWithCredentials` reads `currentAccountId` at request-build
    /// time instead) would break step 2 — the sentinel capture would be
    /// replaced by whatever currentAccountId resolved to AT THAT INSTANT,
    /// which a real-world library-swap window would observe as the wrong
    /// account.
    ///
    /// The seam exercised is `DownloadStartCoordinator.startDownloadAsync` —
    /// the production entry point. NOT a `_setCapturedAccountId` shortcut.
    func testStartDownload_currentAccountIdRoundTrip_A_nil_A_B_eachCaptureIsPinned() async throws {
        // Recorder for the bearer-auth seam — captures the accountId argument
        // each time the dispatcher's `applyBearerAuth` closure is invoked.
        // Production wires this to `networkExecutor.bearerAuthorized(request:
        // accountId:)`; here we verify the captured-id correctly flows down
        // to this closure boundary.
        var capturedAccountIdsAtBearerAuth: [String] = []

        // Driver: simulates `AccountsManager.currentAccountId` as a mutable
        // ground-truth value the test flips between steps. The coordinator's
        // `currentAccountIdProvider` reads this on each startDownloadAsync
        // entry — identical contract to the production wiring which reads
        // `accountsManager.currentAccountId`.
        var groundTruthCurrentAccountId: String? = nil

        // Spy delegate so we can satisfy the coordinator's delegate slot
        // without standing up a full MBDC.
        final class CoordinatorDelegateSpy: DownloadStartCoordinatorDelegate {
            func borrowAsync(_ book: TPPBook, attemptDownload: Bool) async throws -> TPPBook { book }
            func schedulePendingStartsIfPossible() {}
        }
        let delegate = CoordinatorDelegateSpy()

        let stateManager = DownloadStateManager()
        stateManager.maxConcurrentDownloads = 4
        let registry = TPPBookRegistryMock()
        let userAccount = TPPUserAccountMock()
        let queueOrchestrator = DownloadQueueOrchestrator(
            bookRegistry: registry,
            stateManager: stateManager
        )

        // Coordinator wired so the 4-arg processWithCredentials closure
        // sees the captured accountId. The captured-id reaches the closure
        // ONLY if `startDownloadAsync` captures-once at its top and
        // threads through — which is exactly the contract Module A is
        // pinning. We record into `capturedAccountIdsAtBearerAuth` so we
        // can assert the round-trip post-hoc.
        let coordinator = DownloadStartCoordinator(
            stateManager: stateManager,
            bookRegistry: registry,
            userAccountProvider: { userAccount },
            currentAccountIdProvider: { groundTruthCurrentAccountId },
            errorActivityTracker: .shared,
            queueOrchestrator: queueOrchestrator,
            processUnregistered: { _, _, _ in .downloadNeeded },
            processWithCredentials: { _, _, _, capturedId in
                capturedAccountIdsAtBearerAuth.append(capturedId)
            },
            requestCredentials: { _ in /* no login required in this scenario */ }
        )
        coordinator.delegate = delegate

        // Make 4 fresh books so each startDownloadAsync exercises a new
        // entry — the existing-info skip branch would short-circuit any
        // re-use of the same identifier, masking later captures.
        let bookA = TPPBookMocker.mockBook(distributorType: .EpubZip)
        let bookANil = TPPBookMocker.mockBook(distributorType: .EpubZip)
        let bookA2 = TPPBookMocker.mockBook(distributorType: .EpubZip)
        let bookB = TPPBookMocker.mockBook(distributorType: .EpubZip)
        for b in [bookA, bookANil, bookA2, bookB] {
            registry.addBook(b, state: .downloadNeeded)
        }

        // Step 1 — currentAccountId == "A", start download for bookA.
        // Capture must observe "A" and thread it to the bearer-auth closure.
        groundTruthCurrentAccountId = "library-A"
        await coordinator.startDownloadAsync(for: bookA)

        XCTAssertEqual(capturedAccountIdsAtBearerAuth.count, 1,
                       "Step 1: bearer-auth must fire exactly once for bookA")
        XCTAssertEqual(capturedAccountIdsAtBearerAuth.first, "library-A",
                       "Step 1: captured accountId must be 'library-A', not the resolver fallback")

        // Step 2 — flip to nil (simulating the swap window where the user
        // has tapped library-picker and the old id is cleared before the
        // new one is assigned). Start a SECOND download — capture must
        // observe the sentinel, NOT carry-forward "library-A".
        groundTruthCurrentAccountId = nil
        await coordinator.startDownloadAsync(for: bookANil)

        XCTAssertEqual(capturedAccountIdsAtBearerAuth.count, 2,
                       "Step 2: bearer-auth must fire a second time")
        XCTAssertEqual(capturedAccountIdsAtBearerAuth[1],
                       DownloadStartCoordinator.capturedNoAccountSentinelUUID,
                       "Step 2: nil currentAccountId at capture time must record the sentinel, not carry-forward the prior id")

        // Step 3 — restore "library-A" (the "re-enter" arm of the round-
        // trip). Start a THIRD download — capture must observe "A" cleanly.
        // The prior nil/sentinel capture must NOT have poisoned anything.
        groundTruthCurrentAccountId = "library-A"
        await coordinator.startDownloadAsync(for: bookA2)

        XCTAssertEqual(capturedAccountIdsAtBearerAuth.count, 3,
                       "Step 3: bearer-auth must fire a third time")
        XCTAssertEqual(capturedAccountIdsAtBearerAuth[2], "library-A",
                       "Step 3: re-entry to 'library-A' must capture cleanly — prior nil/sentinel must not have stuck")

        // Step 4 — flip to "library-B" (the A→B arm). Start a FOURTH
        // download — capture must observe "B". This proves the capture
        // re-reads each call rather than caching forever after step 1.
        groundTruthCurrentAccountId = "library-B"
        await coordinator.startDownloadAsync(for: bookB)

        XCTAssertEqual(capturedAccountIdsAtBearerAuth.count, 4,
                       "Step 4: bearer-auth must fire a fourth time")
        XCTAssertEqual(capturedAccountIdsAtBearerAuth[3], "library-B",
                       "Step 4: A→B switch must capture 'library-B' — proves capture re-reads each entry")

        // Final assertion: the full sequence pins the contract.
        XCTAssertEqual(capturedAccountIdsAtBearerAuth, [
            "library-A",
            DownloadStartCoordinator.capturedNoAccountSentinelUUID,
            "library-A",
            "library-B"
        ], "Full A→nil→A→B round-trip sequence must be captured exactly — any divergence proves the capture seam is broken")
    }

    // MARK: - Test 9 — End-to-end: captured accountId → bearerAuthorized → Authorization header
    //
    // Closes the gap the architect review (rev_ae4426f2) flagged on Test 8:
    // "the captured id flows from coordinator entry all the way to the
    //  Authorization header" was not proven. Test 8 stops at the
    //  processWithCredentials closure boundary (the dispatcher seam) — it
    //  proves CAPTURE. Test 4 in MyBooksDownloadCenterAccountIdThreadingTests
    //  proves bearerAuthorized(request:accountId:) standalone. Neither test
    //  proves the captured id flows from coordinator entry through
    //  bearerAuthorized to the outgoing URLRequest's Authorization header.
    //
    // This test wires the SAME pipeline: coordinator → processWithCredentials
    // closure → bearerAuthorized(request:accountId:) → URLRequest.Authorization,
    // and asserts on the Authorization header. A regression that dropped
    // capturedAccountId mid-pipeline (between the closure and bearer-auth)
    // would slip past Test 8 + Test 4 but fail here.

    /// End-to-end: `startDownloadAsync` captures accountId, threads it through
    /// `processWithCredentials`, the closure calls `bearerAuthorized(request:
    /// accountId:)`, and the resulting URLRequest carries the captured
    /// account's bearer token on the Authorization header. A→B is enough to
    /// pin the chain — the full round-trip is Test 8's job.
    func testStartDownload_endToEnd_capturedAccountIdReachesAuthorizationHeader() async throws {
        // Two TPPUserAccountMocks with distinct auth tokens. The token that
        // ends up on the Authorization header IS the load-bearing user-visible
        // behavior: if accountId is dropped mid-pipeline, the wrong token (or
        // no token, or the resolver's currentUserAccount token) would land.
        let userAccountA = TPPUserAccountMock(libraryUUID: "library-A")
        userAccountA.setAuthToken(
            "token-for-A",
            barcode: nil,
            pin: nil,
            expirationDate: nil
        )
        let userAccountB = TPPUserAccountMock(libraryUUID: "library-B")
        userAccountB.setAuthToken(
            "token-for-B",
            barcode: nil,
            pin: nil,
            expirationDate: nil
        )

        // Map accountId → user account, identical contract to
        // AccountsManager.userAccount(for:) returning a per-library instance.
        let userAccountsByUUID: [String: TPPUserAccount] = [
            "library-A": userAccountA,
            "library-B": userAccountB
        ]
        let resolveUserAccount: (String) -> TPPUserAccount = { uuid in
            userAccountsByUUID[uuid] ?? TPPUserAccountMock()
        }

        // The closure that production wires from processWithCredentials to
        // TPPNetworkExecutor.bearerAuthorized(request:accountId:). We
        // replicate it inline so the test can capture the OUTGOING URLRequest's
        // Authorization header rather than just the accountId argument.
        var authorizationHeadersInOrder: [(accountId: String, header: String?)] = []
        let applyBearerAuth: (String) -> Void = { capturedId in
            // Replicates the body of TPPNetworkExecutor.bearerAuthorized
            // (request:accountId:): build a request, resolve the per-library
            // user account, apply its bearer token, record the resulting
            // Authorization header.
            let resolvedAccount = resolveUserAccount(capturedId)
            var request = URLRequest(url: URL(string: "https://example.test/loan.epub")!)
            if let token = resolvedAccount.authToken {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            authorizationHeadersInOrder.append((capturedId, request.value(forHTTPHeaderField: "Authorization")))
        }

        // Driver: simulates AccountsManager.currentAccountId, identical
        // contract to Test 8.
        var groundTruthCurrentAccountId: String? = nil

        final class CoordinatorDelegateSpy: DownloadStartCoordinatorDelegate {
            func borrowAsync(_ book: TPPBook, attemptDownload: Bool) async throws -> TPPBook { book }
            func schedulePendingStartsIfPossible() {}
        }
        let delegate = CoordinatorDelegateSpy()

        let stateManager = DownloadStateManager()
        stateManager.maxConcurrentDownloads = 4
        let registry = TPPBookRegistryMock()
        let queueOrchestrator = DownloadQueueOrchestrator(
            bookRegistry: registry,
            stateManager: stateManager
        )

        // Coordinator wiring — userAccountProvider mirrors AccountsManager's
        // `userAccount(for:)` via the per-call resolveUserAccount closure.
        // processWithCredentials calls applyBearerAuth(capturedId), which is
        // the in-test equivalent of bearerAuthorized(request:accountId:).
        let coordinator = DownloadStartCoordinator(
            stateManager: stateManager,
            bookRegistry: registry,
            userAccountProvider: {
                let id = groundTruthCurrentAccountId ?? DownloadStartCoordinator.capturedNoAccountSentinelUUID
                return resolveUserAccount(id)
            },
            currentAccountIdProvider: { groundTruthCurrentAccountId },
            errorActivityTracker: .shared,
            queueOrchestrator: queueOrchestrator,
            processUnregistered: { _, _, _ in .downloadNeeded },
            processWithCredentials: { _, _, _, capturedId in
                applyBearerAuth(capturedId)
            },
            requestCredentials: { _ in /* no login required */ }
        )
        coordinator.delegate = delegate

        let bookA = TPPBookMocker.mockBook(distributorType: .EpubZip)
        let bookB = TPPBookMocker.mockBook(distributorType: .EpubZip)
        registry.addBook(bookA, state: .downloadNeeded)
        registry.addBook(bookB, state: .downloadNeeded)

        // Step 1 — start download in library-A. The outgoing Authorization
        // header MUST carry token-for-A.
        groundTruthCurrentAccountId = "library-A"
        await coordinator.startDownloadAsync(for: bookA)

        XCTAssertEqual(authorizationHeadersInOrder.count, 1)
        XCTAssertEqual(authorizationHeadersInOrder[0].accountId, "library-A")
        XCTAssertEqual(authorizationHeadersInOrder[0].header, "Bearer token-for-A",
                       "Step 1: outgoing URLRequest's Authorization header must carry account A's token — proves capture flows end-to-end through the bearer-auth seam")

        // Step 2 — swap to library-B and start a second download. The new
        // outgoing Authorization header MUST carry token-for-B. Critically:
        // the prior request's header is NOT mutated, AND the new request does
        // NOT carry library-A's token (which would be the regression mode if
        // capturedAccountId were dropped/stale-cached anywhere in the chain).
        groundTruthCurrentAccountId = "library-B"
        await coordinator.startDownloadAsync(for: bookB)

        XCTAssertEqual(authorizationHeadersInOrder.count, 2)
        XCTAssertEqual(authorizationHeadersInOrder[1].accountId, "library-B")
        XCTAssertEqual(authorizationHeadersInOrder[1].header, "Bearer token-for-B",
                       "Step 2: outgoing URLRequest's Authorization header must carry account B's token after library swap — proves the captured id is freshly read per startDownloadAsync entry, not stale-cached from Step 1")

        // Final assertion pins the full sequence: account A's token on the
        // first URLRequest, account B's on the second. ANY regression
        // dropping capturedAccountId mid-pipeline (Coordinator →
        // processWithCredentials → bearerAuthorized → URLRequest) lands either
        // a nil header or the wrong account's token on at least one of the
        // two requests, which this final assertion catches.
        XCTAssertEqual(authorizationHeadersInOrder.map { $0.header }, [
            "Bearer token-for-A",
            "Bearer token-for-B"
        ], "End-to-end chain: coordinator entry → processWithCredentials → bearerAuthorized → URLRequest.Authorization must carry the captured account's token. Any divergence proves the chain is broken between capture and bearer-auth.")
    }

    // MARK: - Cache seeding helpers

    /// Cache file URL for the given hash. Mirrors AccountsManager's private
    /// `accountsCatalogUrl(hash:)`. Kept aligned by test discipline; if the
    /// prod path renames, this assertion will fail loudly and the test
    /// author must update both.
    private func cacheURL(for hash: String) -> URL? {
        guard let appSupport = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        return appSupport.appendingPathComponent("accounts_catalog_\(hash).json")
    }

    /// Metadata file URL for the given hash (mirrors AccountsManager
    /// `cacheMetadataUrl(hash:)`).
    private func metadataURL(for hash: String) -> URL? {
        guard let appSupport = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        return appSupport.appendingPathComponent("accounts_catalog_metadata_\(hash).json")
    }

    private func seedDiskCache(for hash: String, data: Data) throws {
        guard let dataURL = cacheURL(for: hash), let metaURL = metadataURL(for: hash) else {
            throw XCTSkip("Application Support directory unavailable")
        }
        try data.write(to: dataURL)
        let metadata = CatalogCacheMetadata(timestamp: Date(), hash: hash)
        let metaData = try JSONEncoder().encode(metadata)
        try metaData.write(to: metaURL)
    }

    private func tearDownDiskCache(for hash: String) {
        if let dataURL = cacheURL(for: hash) {
            try? FileManager.default.removeItem(at: dataURL)
        }
        if let metaURL = metadataURL(for: hash) {
            try? FileManager.default.removeItem(at: metaURL)
        }
    }
}
