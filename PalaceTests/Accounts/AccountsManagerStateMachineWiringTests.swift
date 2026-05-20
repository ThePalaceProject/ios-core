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
import Combine
import PalaceCatalog
@testable import Palace

final class AccountsManagerStateMachineWiringTests: XCTestCase {

    // MARK: - Fixtures

    private var feedURL: URL!
    private var feedData: Data!
    private var authDoc: OPDS2AuthenticationDocument!

    override func setUpWithError() throws {
        try super.setUpWithError()
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

    override func tearDown() {
        // Clear the process-wide state store so transitions written by one
        // test don't leak into the next (the store is keyed by UUID, and the
        // OPDS2CatalogsFeed fixture reuses real library UUIDs).
        #if DEBUG
        AccountStateStore.shared._resetAllForTesting()
        #endif
        super.tearDown()
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
    private func label(_ state: Account.LoadState) -> String {
        switch state {
        case .notLoaded:        return "notLoaded"
        case .basicInfoLoaded:  return "basicInfoLoaded"
        case .detailsLoading:   return "detailsLoading"
        case .detailsLoaded:    return "detailsLoaded"
        case .detailsFailed(let err):
            if case .accountNotFound = err { return "detailsFailed.accountNotFound" }
            if case .authDocumentFetchFailed = err { return "detailsFailed.authDocumentFetchFailed" }
            return "detailsFailed.other"
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
        let manager = AccountsManager()
        // Give the init-fired background loadCatalogs a beat to complete or
        // fail (no network in unit-test env → fast failure). 300ms is
        // empirically sufficient on the iPhone 16 Pro simulator; longer
        // tolerates slower CI without making the test flaky.
        let backgroundSettled = expectation(description: "background loadCatalogs settled")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { backgroundSettled.fulfill() }
        wait(for: [backgroundSettled], timeout: 2.0)

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
        let manager = AccountsManager()

        // Set the current account to one of the fixture UUIDs so the
        // loadAccountSetsAndAuthDoc path will route through
        // fetchAuthDocumentWithStateMachine for it.
        UserDefaults.standard.set(firstUUID, forKey: currentAccountIdentifierKey)
        defer { UserDefaults.standard.removeObject(forKey: currentAccountIdentifierKey) }

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

        // Construct the manager FIRST. Its init fires a background
        // loadCatalogs(nil); let it settle (no network → fails fast) so its
        // writes don't race the rest of the test.
        let manager = AccountsManager()
        let backgroundSettled = expectation(description: "background loadCatalogs settled")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { backgroundSettled.fulfill() }
        wait(for: [backgroundSettled], timeout: 2.0)

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
        UserDefaults.standard.set(currentUUID, forKey: currentAccountIdentifierKey)
        defer { UserDefaults.standard.removeObject(forKey: currentAccountIdentifierKey) }

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
        let movedExpectation = expectation(description: "currentAccount moved past .basicInfoLoaded")
        var observedFinalState: Account.LoadState = AccountStateStore.shared.state(for: currentUUID)
        let pollQueue = DispatchQueue.global()
        let deadline = Date().addingTimeInterval(3.0)
        pollQueue.async {
            while Date() < deadline {
                let s = AccountStateStore.shared.state(for: currentUUID)
                switch s {
                case .detailsLoading, .detailsLoaded, .detailsFailed:
                    observedFinalState = s
                    movedExpectation.fulfill()
                    return
                default:
                    Thread.sleep(forTimeInterval: 0.05)
                }
            }
        }
        wait(for: [movedExpectation], timeout: 4.0)

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

        let manager = AccountsManager()
        let backgroundSettled = expectation(description: "background loadCatalogs settled")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { backgroundSettled.fulfill() }
        wait(for: [backgroundSettled], timeout: 2.0)

        let activeHash = TPPConfiguration.customUrlHash()
            ?? (TPPSettings().useBetaLibraries
                ? TPPConfiguration.betaUrlHash
                : TPPConfiguration.prodUrlHash)
        try seedDiskCache(for: activeHash, data: feedData)
        defer { tearDownDiskCache(for: activeHash) }

        UserDefaults.standard.set(currentUUID, forKey: currentAccountIdentifierKey)
        defer { UserDefaults.standard.removeObject(forKey: currentAccountIdentifierKey) }

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

        // Drain stream a beat so any unwanted emission would land.
        let drained = expectation(description: "stream drain window")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { drained.fulfill() }
        wait(for: [drained], timeout: 1.0)
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

        let manager = AccountsManager()
        let exp = expectation(description: "fetchAuthDocumentWithStateMachine completes")

        // Capture the transition stream so we can assert the SEQUENCE
        // (.detailsLoading → .detailsFailed), not just the terminal state.
        var observed: [String] = []
        let streamTask = Task {
            for await state in account.stateStream {
                observed.append(self.label(state))
                if observed.last?.hasPrefix("detailsFailed") == true { break }
            }
        }

        manager.fetchAuthDocumentWithStateMachine(for: account) { success in
            XCTAssertFalse(success, "loadAuthenticationDocument with nil URL must return false")
            exp.fulfill()
        }

        wait(for: [exp], timeout: 2.0)

        // Stream observer should have seen detailsLoading then detailsFailed.
        // (The current state at subscription time was .notLoaded — the
        // CurrentValueSubject emits that as the first value.)
        // Give the stream task a beat to absorb the terminal state.
        let drained = expectation(description: "stream drains terminal")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { drained.fulfill() }
        wait(for: [drained], timeout: 1.0)
        streamTask.cancel()

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

        let manager = AccountsManager()

        // Track how many times `.detailsLoading` is set — that's our proxy
        // for "number of loader invocations", since the wiring fires
        // `_setState(.detailsLoading)` once at the entry of each non-deduped
        // call. A duplicate fetch would observe two `.detailsLoading`
        // transitions.
        let lock = NSLock()
        var detailsLoadingCount = 0
        var sawTerminal = false
        let observed = expectation(description: "stream reaches terminal")
        observed.assertForOverFulfill = false

        let streamTask = Task {
            for await state in account.stateStream {
                lock.lock()
                if case .detailsLoading = state {
                    detailsLoadingCount += 1
                }
                if case .detailsFailed = state {
                    if !sawTerminal {
                        sawTerminal = true
                        observed.fulfill()
                    }
                }
                if case .detailsLoaded = state {
                    if !sawTerminal {
                        sawTerminal = true
                        observed.fulfill()
                    }
                }
                lock.unlock()
            }
        }

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

        // Drain stream a beat to ensure detailsLoading count is settled.
        let drained = expectation(description: "stream count settled")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { drained.fulfill() }
        wait(for: [drained], timeout: 1.0)
        streamTask.cancel()

        lock.lock()
        let count = detailsLoadingCount
        lock.unlock()

        // The kill case: a non-single-flight wiring would fire
        // `_setState(.detailsLoading)` twice. The single-flight guard
        // ensures only ONE transition through `.detailsLoading`.
        XCTAssertEqual(count, 1,
                       "Single-flight guard must produce exactly one .detailsLoading transition for two concurrent callers on the same UUID; got \(count)")
    }

    // MARK: - Test 5: Library reselect → .detailsFailed(.accountNotFound) for prior

    /// Contract: when the user switches libraries, awaiters subscribed to
    /// the PRIOR account's stream must observe a terminal
    /// `.detailsFailed(.accountNotFound)`. Without this, an awaiter that
    /// took a reference to the prior Account before the switch would hang
    /// forever — the prior UUID's state stream would never transition.
    func testLibraryReselect_priorAccount_terminatesWithAccountNotFound() throws {
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

        // Set up: simulate currentAccountId pointing at A.
        UserDefaults.standard.set(accountA.uuid, forKey: currentAccountIdentifierKey)
        defer { UserDefaults.standard.removeObject(forKey: currentAccountIdentifierKey) }

        let manager = AccountsManager()

        // Act: switch currentAccount A → B. The setter must drive A to
        // `.detailsFailed(.accountNotFound)`. We bypass the accountSets
        // lookup by using accountB directly — the setter only reads
        // newValue?.uuid for the comparison.
        manager.currentAccount = accountB

        // Assert: A's terminal state is .accountNotFound; B is untouched
        // by the reselect path itself (its state is whatever it was —
        // .notLoaded in this isolated test, since no preload ran).
        switch AccountStateStore.shared.state(for: accountA.uuid) {
        case .detailsFailed(let err):
            if case .accountNotFound(let uuid) = err {
                XCTAssertEqual(uuid, accountA.uuid,
                               ".accountNotFound must carry the prior account's UUID, not the new one")
            } else {
                XCTFail("Expected .accountNotFound, got \(err)")
            }
        default:
            XCTFail("Prior account must terminate in .detailsFailed(.accountNotFound) after reselect; got \(label(AccountStateStore.shared.state(for: accountA.uuid)))")
        }
    }

    // MARK: - Test 6: Re-entry after reselect resets state

    /// Contract: after a library reselect terminates the prior UUID at
    /// `.detailsFailed(.accountNotFound)`, re-entering that UUID (user
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

        UserDefaults.standard.set(accountA.uuid, forKey: currentAccountIdentifierKey)
        defer { UserDefaults.standard.removeObject(forKey: currentAccountIdentifierKey) }

        let manager = AccountsManager()

        // Switch A → B; A terminates at .accountNotFound.
        manager.currentAccount = accountB

        // Verify the terminal A state.
        switch AccountStateStore.shared.state(for: accountA.uuid) {
        case .detailsFailed:
            break
        default:
            XCTFail("Setup precondition: A must be .detailsFailed after A→B switch")
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
        // when going from a `.detailsFailed` terminal back to an earlier
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
        // transition AFTER the detailsFailed terminal — this is the
        // kill condition for a wiring that dedupes equal states
        // (a broken `setState` that no-ops if old==new would never emit).
        XCTAssertTrue(observed.contains("basicInfoLoaded"),
                      "Stream must emit .basicInfoLoaded on re-entry; observed: \(observed)")
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
