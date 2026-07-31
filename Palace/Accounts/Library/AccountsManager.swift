import Foundation
import PalacePreferences
import PalaceLogging
import PalaceCatalog
import PalaceBookRegistry

let currentAccountIdentifierKey = "TPPCurrentAccountIdentifier"

// `CatalogCacheMetadata` and the on-disk catalog cache moved to
// `AccountRegistryCache.swift` (Wave 3 / 3a-1) — injected via `registryCache`.

@objc protocol TPPCurrentLibraryAccountProvider: NSObjectProtocol {
    var currentAccount: Account? { get }
}

/// Resolves per-library `TPPUserAccount` instances. Prefer this over
/// `TPPUserAccount.sharedAccount(libraryUUID:)` — instances returned by
/// this protocol have immutable keychain keys and are not subject to the
/// TOCTOU race in the singleton's mutable `libraryUUID` pattern.
@objc protocol TPPUserAccountResolving: NSObjectProtocol {
    func userAccount(for libraryUUID: String) -> TPPUserAccount
    var currentUserAccount: TPPUserAccount { get }
}

@objc protocol TPPLibraryAccountsProvider: TPPCurrentLibraryAccountProvider, TPPUserAccountResolving {
    var tppAccountUUID: String { get }
    var currentAccountId: String? { get }
    func account(_ uuid: String) -> Account?
}

/// Lock-backed holder for `AccountsManager`'s test-only `Bool` flags so they
/// can be concurrency-safe global state without `nonisolated(unsafe)`.
/// `@unchecked Sendable` invariant: the only mutable state is `storage`, read
/// and written exclusively under `lock` (an immutable `NSLock`); the wrapped
/// value is a `Sendable` `Bool`.
private final class AccountsManagerBoolFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Bool
    init(_ value: Bool) { storage = value }
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); defer { lock.unlock() }; storage = newValue }
    }
}

/// The load-completion + crawler-handoff `@unchecked Sendable` carrier boxes moved to
/// `AccountRegistryLoader.swift` (Wave 3 / 3a-4) with the load pipeline.

/// Manages library accounts asynchronously with authentication & image loading
///
/// `@unchecked Sendable` rationale (Swift 6 Phase B, Wave-2):
/// `AccountsManager` is a process-wide singleton owned by `AppContainer` and
/// shared, by design, across every actor (the background `loadCatalogs` crawl
/// Tasks, `@MainActor` UI, token-refresh / audiobook / bookmark consumers).
/// Its four background `Task { [weak self] in … }` crawl/refresh/preload
/// closures require a `@Sendable` capture of `self` — and they cannot be
/// rewritten to "snapshot Sendable fields at the site" because each one drives
/// `self`'s instance I/O pipeline (`registryCache.writeCatalogData`,
/// `loadAccountSetsAndAuthDoc`, `fallbackFetchFromNetwork`, `triggerCatalogPreload`,
/// `catalogPreloader`, `currentAccount`), which is the whole purpose of the Task.
/// So the type itself must be `Sendable`. It is safe to share because EVERY
/// mutable stored property is synchronized. Full audit (matches #1155's
/// `TPPUserAccount` and `AccountStateStore`'s own `@unchecked` justification):
///
///   Instance mutable state:
///   - the account-registry state (current hash, `accountSets`, the `accountByUUID`
///     index, and the slim fallback)  → moved to the injected `AccountRegistryStore`
///     (Wave 3 / 3a-2), which owns their concurrent `accountSetsLock` sync-read /
///     barrier-write model; the hub holds the store as an immutable `Sendable` `let`.
///   - the catalog LOAD state (loading-handler map, owned-crawl registry, first-run
///     subset, `backgroundFetchTask`)  → moved to the injected `AccountRegistryLoader`
///     (Wave 3 / 3a-4), which owns its own queues/locks; the hub holds it as a `lazy var`.
///   - the auth-document fetch state (single-flight map + lock)  → moved to the
///     injected `AuthDocumentLoader` (Wave 3 / 3a-3), which owns its own `NSLock`; the
///     hub holds the loader as a `lazy var` and no longer names that state.
///   - the per-account credential state (`userAccounts` cache + its lock,
///     `lastKnownCurrentUserAccount`, `noAccountPlaceholder`)  → moved to the injected
///     `AccountCredentialResolver` (Wave 3 / 3a-5), which owns their `NSLock`/lazy
///     synchronization; the hub holds it as a `lazy var`.
///   - `crawlScheduler`  → immutable `Sendable` `let` bound once from `init`, passed
///     into the load collaborator.
///   - `isAccountSwitching`  → storage moved into the lock-backed
///     `AccountsManagerBoolFlag` holder (`_isAccountSwitching`), so its `Bool`
///     set/get is serialized by the holder's own `NSLock`; the public
///     `private(set) var` computed accessor preserves every call site and the
///     value/timing verbatim (see property below).
///   - `networkExecutor`  → `lazy var`, resolved exactly once from an
///     already-constructed dependency (inside the background load path after
///     `AppContainer` finishes constructing) and immutable thereafter — write-once.
///   - `_explicitCancelCalled`  → `#if DEBUG` test-only; compiled out of release. Set by
///     the hub cancel/drain facades BEFORE delegating to the load collaborator (so the
///     3a-3 `AuthDocumentLoader.isTornDown` binding stays byte-identical).
///
///   Immutable (`let`) state — inherently safe: `tppAccountUUID`, `ageCheck`,
///   `settings`, `defaults`, `registryStore` (internally synchronized),
///   `registryCache`, `crawlScheduler`.
///
///   `currentAccountId` is a computed property backed by the injected
///   `UserDefaults` (`defaults`), which is itself internally thread-safe — no
///   instance storage is mutated.
///
/// NO property uses `nonisolated(unsafe)` and there is no bare `@unchecked`:
/// every mutable field above has a named synchronization mechanism. Making the
/// singleton `@MainActor` was rejected — it would move `loadCatalogs` /
/// `init`'s background dispatch onto the main actor and change load timing,
/// which is out of scope for this pass.
@objcMembers final class AccountsManager: NSObject, TPPLibraryAccountsProvider, TPPUserAccountResolving, @unchecked Sendable {

    // MARK: – Config / state

    static let TPPAccountUUIDs = [
        "urn:uuid:065c0c11-0d0f-42a3-82e4-277b18786949", // NYPL proper
        "urn:uuid:edef2358-9f6a-4ce6-b64f-9b351ec68ac4", // Brooklyn
        "urn:uuid:56906f26-2c9a-4ae9-bd02-552557720b99"  // Simplified Instant Classics
    ]

    static let TPPNationalAccountUUIDs = [
        "urn:uuid:6b849570-070f-43b4-9dcc-7ebb4bca292e" // Palace Bookshelf
    ]

    let tppAccountUUID = AccountsManager.TPPAccountUUIDs[0]

    /// Lock-backed storage for `isAccountSwitching` so the flag is
    /// concurrency-safe without `nonisolated(unsafe)`. Written from the
    /// `currentAccount` setter (account-switch path) and the `@MainActor`
    /// cleanup Task; read from the sign-in-modal presenter. In practice all
    /// accesses are main-thread, but the holder's `NSLock` makes that safe
    /// regardless — closing the one un-synchronized-instance-var gap in the
    /// `@unchecked Sendable` audit above. Value/timing are identical to the
    /// prior plain `Bool` — only access is serialized.
    private let _isAccountSwitching = AccountsManagerBoolFlag(false)

    /// True during an account switch — suppresses sign-in modal presentation
    /// to prevent the intermittent login prompt (F-032). `private(set)`
    /// contract preserved: external readers see get-only, internal code sets
    /// via the private setter (both routed through the lock-backed holder).
    private(set) var isAccountSwitching: Bool {
        get { _isAccountSwitching.value }
        set { _isAccountSwitching.value = newValue }
    }

    let ageCheck: TPPAgeCheckVerifying
    private let settings: TPPSettings

    /// `UserDefaults` backing store for the persisted
    /// `currentAccountIdentifierKey` read/written by `currentAccountId`.
    /// Production callers use the no-arg `init()` which binds `.standard`;
    /// tests inject a per-suite `UserDefaults(suiteName:)` via the
    /// explicit initializer so two tests touching the current-account
    /// key cannot pollute each other. There is NO fallback once injected.
    private let defaults: UserDefaults
    /// Injected account-switch borrow-reauth circuit-breaker reset (Wave 3 S1).
    /// Replaces the static `MyBooksDownloadCenter.clearAllBorrowReauthState()`
    /// call so the money-path clear is spy-testable. See `BorrowReauthResetting`.
    private let borrowReauthResetter: any BorrowReauthResetting
    /// Wave 3 S3 — account-switch cleanup collaborators injected as a frozen bundle (spy-observable);
    /// the concrete executor TYPE edge is now inverted behind `AccountNetworking` too (3a precondition).
    private let switchDeps: AccountSwitchDependencies
    /// Lazy-resolved through the injected provider to break the singleton init cycle:
    /// AccountsManager is constructed inline by AppContainer._cached's initializer, so
    /// we cannot resolve the executor during init. First accessed *after* AppContainer
    /// finishes constructing; resolved exactly once, then cached here.
    private lazy var networkExecutor: any AccountNetworking = switchDeps.networkExecutorProvider()
    /// Per-account auth-document fetch + state-machine collaborator (Wave 3 / 3a-3).
    /// A `lazy var` (not a `let` default arg like `registryStore`) because its provider
    /// closures capture `self`, so it can't be resolved before `super.init()`; first
    /// access is post-init (the earliest drive is the preload / background `loadCatalogs`),
    /// exactly like `networkExecutor`. The `isTornDown` binding is `#if DEBUG` (reads the
    /// DEBUG-only `_explicitCancelCalled`); release binds `{ false }` so the DRM build compiles.
    private lazy var authDocLoader: AuthDocumentLoader = {
        #if DEBUG
        let torn: @Sendable () -> Bool = { [weak self] in self?._explicitCancelCalled ?? true }
        #else
        let torn: @Sendable () -> Bool = { false }
        #endif
        return AuthDocumentLoader(
            accountStateStore: switchDeps.accountStateStore,
            currentAccountProvider: { [weak self] in self?.currentAccount },
            signedInStateProvider: { [weak self] in self?.currentUserAccount },
            isTornDown: torn
        )
    }()
    /// Injectable background-crawl spawn seam (see `CatalogCrawlScheduler`).
    /// Immutable `Sendable` `let`; `.production` by default, recording under test.
    private let crawlScheduler: CrawlTaskScheduler
    /// Catalog LOAD orchestration + owned background-crawl + drain collaborator
    /// (Wave 3 / 3a-4). A `lazy var` (not a `let` default arg) because its provider
    /// closures capture `self`; first access is post-init (the preload / background
    /// `loadCatalogs`), exactly like `authDocLoader`. Orchestrates registryCache /
    /// registryStore / authDocLoader (via the injected drive/fetch closures).
    private lazy var registryLoader: AccountRegistryLoader = AccountRegistryLoader(
        registryCache: registryCache,
        registryStore: registryStore,
        crawlScheduler: crawlScheduler,
        settings: settings,
        imageCache: switchDeps.imageCache,
        accountStateStore: switchDeps.accountStateStore,
        ageCheck: ageCheck,
        networkExecutorProvider: switchDeps.networkExecutorProvider,
        currentAccountProvider: { [weak self] in self?.currentAccount },
        currentAccountIdProvider: { [weak self] in self?.currentAccountId },
        accountsForKeyProvider: { [weak self] in self?.accounts($0) ?? [] },
        accountProvider: { [weak self] in self?.account($0) },
        currentUserAccountProvider: { [weak self] in self?.currentUserAccount },
        driveCurrentAccountAuthDoc: { [weak self] in self?.driveCurrentAccountAuthDocIfNeeded() },
        fetchAuthDocumentWithStateMachine: { [weak self] account, completion in
            guard let self else { completion(false); return }
            self.fetchAuthDocumentWithStateMachine(for: account, completion: completion)
        },
        currentLibraryAccountProvider: { [weak self] in self }
    )
    /// On-disk catalog cache collaborator (Wave 3 / 3a-1). Immutable `Sendable`
    /// `let`; the stateless `DiskAccountRegistryCache` by default, a recording
    /// double under test. All catalog read/write/staleness/clear disk I/O routes
    /// here, so the hub carries none of it and a packaged manager names no
    /// FileManager cache body.
    private let registryCache: any AccountRegistryCaching
    /// Account-registry state + all thread-safe access (Wave 3 / 3a-2): the current
    /// catalog hash, the `[hash → [Account]]` sets, the O(1) `uuid → Account` index
    /// rebuilt in-barrier-lockstep with them, and the separate slim launch-hydration
    /// fallback. Injected `let` — the concrete `AccountRegistryStore` by default, a
    /// recording double under test. All registry-state concurrency (the concurrent
    /// `accountSetsLock` sync-read / barrier-write model) lives in the store now, so
    /// the hub carries none of it. See `AccountRegistryStore.swift` for the
    /// `@unchecked Sendable` invariant and the class-not-actor rationale.
    private let registryStore: AccountRegistryStore

    // The catalog load orchestration + owned-crawl + drain (the loading-completion
    // handler map, the owned-task registry, the catalog preloader, the load bodies)
    // moved to `AccountRegistryLoader.swift` (Wave 3 / 3a-4) — injected via `registryLoader`.

    // The per-account auth-document fetch + state-machine wiring (the single-flight
    // map + lock, the timeout, and the fetch/drive/terminal logic) moved to
    // `AuthDocumentLoader.swift` (Wave 3 / 3a-3) — injected via `authDocLoader` below.

    /// Alias retained so `AccountsManager.authDocInflightTimeout` keeps resolving for
    /// the wiring-suite tests; the value + the fetch machinery live on `AuthDocumentLoader`.
    static let authDocInflightTimeout: TimeInterval = AuthDocumentLoader.authDocInflightTimeout

    #if DEBUG
    /// Test-only opt-out from the post-init background `loadCatalogs` spawn.
    /// When `true`, `AccountsManager.init()` skips the owned background
    /// `loadCatalogs` Task spawn — eliminating the cross-test race where lingering background
    /// work from a previously-constructed AccountsManager instance writes
    /// through to `accountSets` / `AccountStateStore.shared` mid-test.
    ///
    /// Production callers never set this. The suite-level `setUp` of any
    /// XCTestCase that constructs multiple `AccountsManager()` instances
    /// should set it to `true` in `setUp` and reset to `false` in `tearDown`
    /// to keep the flag flip scoped. NOT compiled into release builds.
    ///
    /// See `feedback_wiring_suite_test_isolation.md` for the underlying race.
    ///
    /// swarm_4b64e4e0 Wave 1d — default value now derives from
    /// `XCTestConfigurationFilePath` env var. When this process is hosting
    /// XCTest, the flag defaults to `true` so the very first cached
    /// `AppContainer.production()` call (which may happen before any test's
    /// setUp — e.g. via a static `let` or default arg in a class touched by
    /// the test runner's discovery phase) doesn't fire a background
    /// `loadCatalogs` Task that races with later test-fixture seeds. Tests
    /// that need the background `loadCatalogs` to fire (e.g.
    /// `AppContainerResetTests`) explicitly flip the flag back to `false`
    /// in their own setUp. Production runs (no `XCTestConfigurationFilePath`
    /// in the env) keep the original `false` default so the background load
    /// fires as designed.
    private static let _deferInitialLoadCatalogsForTesting = AccountsManagerBoolFlag(
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    )
    /// Lock-backed so this test-only flag is concurrency-safe global state
    /// without `nonisolated(unsafe)`. Storage lives in the `Sendable`
    /// `AccountsManagerBoolFlag` holder; this computed accessor keeps every
    /// existing read/write call site unchanged. Read value and timing are
    /// identical to the prior `static var` — only access is serialized.
    internal static var deferInitialLoadCatalogsForTesting: Bool {
        get { _deferInitialLoadCatalogsForTesting.value }
        set { _deferInitialLoadCatalogsForTesting.value = newValue }
    }

    /// Test-only opt-out from the synchronous `preloadAccountsFromDiskCacheSync()`
    /// in `init()`. Defaults to `false`, so production AND every test that relies
    /// on preloaded accounts are unaffected — only tests that opt in are changed.
    ///
    /// A test that constructs an `AccountsManager` purely to satisfy a dependency
    /// and never reads `accountSets` (e.g. `TPPBookRegistryMigrationTests`, which
    /// drives `BookRegistrySync.load(account:)` with a random test UUID) sets this
    /// to `true` in `setUp` to skip the on-disk cached-account load, which can
    /// consume >5s on memory-pressured CI when the cache holds ~1138 accounts —
    /// the root of the FLAKE-003 `loadAndWait()` 30s timeout. Scope the flip to
    /// `setUp`/`tearDown`. NOT compiled into release builds.
    private static let _deferDiskCachePreloadForTesting = AccountsManagerBoolFlag(false)
    /// Lock-backed test-only flag (see `deferInitialLoadCatalogsForTesting`
    /// above for the holder rationale). Value/timing unchanged.
    internal static var deferDiskCachePreloadForTesting: Bool {
        get { _deferDiskCachePreloadForTesting.value }
        set { _deferDiskCachePreloadForTesting.value = newValue }
    }

    /// (The `backgroundFetchTask` handle moved to `AccountRegistryLoader` with the
    /// crawl/drain machinery — Wave 3 / 3a-4; the hub sets `_explicitCancelCalled` in the
    /// cancel/drain facades before delegating.)

    /// Test-only flag flipped to `true` inside `cancelBackgroundWork()` BEFORE
    /// the `.cancel()` is issued on `backgroundFetchTask`. Used by
    /// `AccountsManagerCancellationTests` to disambiguate "explicit cancel was
    /// called" from "task handle was nilled out by some other path." swarm_4b64e4e0
    /// qa-fixup — addresses qa_test concern about the prior single observation
    /// surface conflating those two semantics.
    private var _explicitCancelCalled: Bool = false

    /// Test-only: forwards to the loader's single-flight seed (Wave 3 / 3a-3).
    func _seedInflightAuthDocForTesting(uuid: String, age: TimeInterval) {
        authDocLoader._seedInflightAuthDocForTesting(uuid: uuid, age: age)
    }

    /// Test-only read of whether a UUID currently occupies the loader's single-flight map.
    func _inflightAuthDocContainsForTesting(uuid: String) -> Bool {
        authDocLoader._inflightAuthDocContainsForTesting(uuid: uuid)
    }
    #endif

    // The owned-crawl-task registry, its spawn/first-run-tracking, the XCTest join
    // seams, and the `_fetchFromNetworkCount` observability moved to
    // `AccountRegistryLoader.swift` (Wave 3 / 3a-4). The hub keeps the forwarders below
    // so AppContainer + every test call site stays byte-identical.

    /// Resolves the build-time bundled registry snapshot resource (forwards to the loader,
    /// where the first-run decode reads it). Settable so tests inject a stub.
    var snapshotResourceResolver: BundleResourceResolving {
        get { registryLoader.snapshotResourceResolver }
        set { registryLoader.snapshotResourceResolver = newValue }
    }

    /// Test-observability forwarder: count of `fetchFromNetwork` entries.
    var fetchFromNetworkCountForTesting: Int { registryLoader.fetchFromNetworkCountForTesting }

    /// Test-only whole-quiescence JOIN seam forwarder (PP-4754).
    func _awaitCatalogLoadForTesting(maxRounds: Int = 8) async {
        await registryLoader._awaitCatalogLoadForTesting(maxRounds: maxRounds)
    }

    /// Test-only quiescence assertion helper forwarder.
    var _ownedCrawlTaskCountForTesting: Int { registryLoader._ownedCrawlTaskCountForTesting }

    /// Test-only NARROW deterministic JOIN seam forwarder.
    func _awaitAllCrawlTasksForTesting() async {
        await registryLoader._awaitAllCrawlTasksForTesting()
    }

    /// Initializer is `internal` rather than `private` so `AppContainer` can
    /// construct the single live instance directly. Outside of `AppContainer`
    /// (and tests that need an isolated instance), do not call this directly
    /// — read `appContainer.accountsManager` instead.
    ///
    /// - Parameter defaults: UserDefaults backing store for
    ///   `currentAccountIdentifierKey` reads/writes. Defaults to `.standard`
    ///   so production callers stay green; tests pass a per-suite instance.
    /// - Parameter borrowReauthResetter: account-switch borrow-reauth reset seam
    ///   (Wave 3 S1). REAL default keeps every existing call site behavior-identical;
    ///   tests inject a spy, `AppContainer` passes it explicitly.
    /// - Parameter crawlScheduler: injectable background-crawl spawn seam
    ///   (PP-4754). `.production` keeps every call site behavior-identical.
    /// - Parameter switchDependencies: account-switch cleanup seams (Wave 3 S3);
    ///   `.production` binds the live collaborators (behavior-identical), tests spy.
    init(
        defaults: UserDefaults = .standard,
        borrowReauthResetter: any BorrowReauthResetting = DownloadCenterBorrowReauthResetter(),
        crawlScheduler: CrawlTaskScheduler = .production,
        switchDependencies: AccountSwitchDependencies = .production,
        registryCache: any AccountRegistryCaching = DiskAccountRegistryCache(),
        registryStore: AccountRegistryStore = AccountRegistryStore()
    ) {
        self.defaults = defaults
        self.borrowReauthResetter = borrowReauthResetter
        self.crawlScheduler = crawlScheduler
        self.switchDeps = switchDependencies
        self.registryCache = registryCache
        self.registryStore = registryStore
        self.settings = TPPSettings()
        self.ageCheck = TPPAgeCheck(ageCheckChoiceStorage: settings)
        super.init()
        // Seed the registry store's current hash (was the hub's `accountSet` stored
        // property, now owned by the store — Wave 3 / 3a-2). Written on the store's
        // barrier; the synchronous `preloadAccountsFromDiskCacheSync` read below
        // observes it via GCD barrier FIFO ordering (the one deliberate init delta).
        registryStore.setCurrentHash(
            TPPConfiguration.customUrlHash()
                ?? (settings.useBetaLibraries
                        ? TPPConfiguration.betaUrlHash
                        : TPPConfiguration.prodUrlHash)
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateAccountSetFromNotification(_:)),
            name: .TPPUseBetaDidChange,
            object: nil
        )

        #if DEBUG
        // Register in the process-wide weak live-instance registry so the global
        // test-boundary drain (`_drainAllLiveInstancesForTesting`) can cancel +
        // drain background work on THIS instance even when the constructing test
        // never tears it down (the foreign-polluter case). Placed after
        // `super.init()` — before any early `return` below — so EVERY constructed
        // instance is caught regardless of the `deferInitialLoadCatalogsForTesting`
        // branch. The registry is weak, so this never extends lifetime.
        Self._registerLiveInstanceForTesting(self)
        #endif

        // Synchronously pre-populate accountSets from the on-disk cache before
        // returning. Without this, AppContainer.production() returns while
        // loadCatalogs() is still running on a background queue, so any UI
        // mounted in that window — including Settings -> Libraries and the
        // sign-in modal — calls account(uuid) against an empty dict and renders
        // an empty list. The async refresh below still runs to pick up any
        // server-side registry changes.
        #if DEBUG
        // Test-only skip (see `deferDiskCachePreloadForTesting`): a test that
        // never reads `accountSets` can opt out of the >5s cached-account load.
        if !Self.deferDiskCachePreloadForTesting {
            registryLoader.preloadAccountsFromDiskCacheSync()
        }
        #else
        registryLoader.preloadAccountsFromDiskCacheSync()
        #endif

        #if DEBUG
        if Self.deferInitialLoadCatalogsForTesting {
            // Test-only path: skip the background dispatch. The wiring suite
            // (and any future XCTestCase constructing multiple instances)
            // sets this flag to eliminate the cross-test race where lingering
            // background work writes through state mid-test. Tests that need
            // `loadCatalogs` semantics call `manager.loadCatalogs(...)`
            // explicitly. Production never takes this branch.
            return
        }
        #endif
        // Unified background-load arm — PP-4754, owned + drainable. The spawn + the
        // DEBUG `backgroundFetchTask` handle live on the loader now (Wave 3 / 3a-4).
        registryLoader.spawnInitialBackgroundLoad()
    }

    /// Forwards the CP-D1 launch preload to `registryLoader` (Wave 3 / 3a-4). Exposed
    /// `internal` so contract-snapshot tests can drive the preload path after seeding the
    /// on-disk cache. The slim-hydration + full-hydrate + slim-snapshot carve/write bodies
    /// live on the loader.
    internal func preloadAccountsFromDiskCacheSync() {
        registryLoader.preloadAccountsFromDiskCacheSync()
    }

    // MARK: – Account index (static shim)

    /// Pure `uuid → Account` index builder. The implementation and ALL thread-safe
    /// `accountSets` access moved to `AccountRegistryStore` (Wave 3 / 3a-2); this thin
    /// static forwards so `AccountsManager.buildAccountIndex(...)` stays a stable name
    /// for `AccountsManagerAccountIndexTests`.
    static func buildAccountIndex(_ sets: [String: [Account]]) -> [String: Account] {
        AccountRegistryStore.buildAccountIndex(sets)
    }

    /// Static shim retained for `AccountsManagerLaunchSnapshotTests` — the pure raw-JSON
    /// slim carve moved to `AccountRegistryLoader` (Wave 3 / 3a-4).
    static func carveSlimFeed(fromFullCatalogData data: Data, keepUUIDs: Set<String>) -> Data? {
        AccountRegistryLoader.carveSlimFeed(fromFullCatalogData: data, keepUUIDs: keepUUIDs)
    }

    // MARK: - Account Retrieval
    var currentAccount: Account? {
        get {
            guard let uuid = currentAccountId else { return nil }
            return account(uuid)
        }
        set {
            let previousAccountId = currentAccountId
            let newAccountId = newValue?.uuid

            Log.debug(#file, "Setting currentAccount to <\(newValue?.name ?? "[N/A]")>")
            Log.debug(#file, "Previous account: \(previousAccountId ?? "nil") → New account: \(newAccountId ?? "nil")")

            if previousAccountId != newAccountId, previousAccountId != nil {
                Log.info(#file, "🔄 Account switch detected - cleaning up active content")
                isAccountSwitching = true
                cleanupActiveContentBeforeAccountSwitch(from: previousAccountId, to: newAccountId)
                // Evict decoded cover images — the new library has different covers.
                // Keeps compressed JPEG cache on disk for fast re-decode if user switches back.
                switchDeps.imageCache.evictDecodedImages()
                // Reset the cover-fetch circuit breaker: a host that tripped while
                // the prior library was active must not keep cover fetches
                // suppressed for the newly selected library.
                switchDeps.resetCoverCircuitBreaker()
            }

            self.currentAccount?.hasUpdatedToken = false
            currentAccountId = newValue?.uuid

            // CP-D2: event-driven credential-cache invalidation on account
            // switch. `credentialSnapshot()` no longer invalidates the keychain
            // cache on every read (it relies on the write-through cache + the
            // one-instance-per-UUID invariant). When the current library
            // changes, drop the newly-current account's cache so its first
            // snapshot after the switch reads fresh keychain state rather than a
            // value cached before it became "current". Only fires on a real
            // change (nil→B, A→B), not on a redundant B→B reassignment.
            if previousAccountId != newAccountId, let newId = newAccountId {
                userAccount(for: newId).invalidateCredentialCaches()
            }

            // Account state-machine wiring (3.2.0): Phase 1 — when the user
            // switches libraries, terminate any lingering `awaitReady()`
            // callers on the *prior* account with a definitive answer.
            // `.detailsEvicted(.libraryDeselected)` is the chosen terminal:
            //   - `.notLoaded` would leave awaiters hanging until reselect.
            //   - `.detailsFailed(.accountNotFound)` was the original
            //     terminal (PR #961) and confused this eviction marker with
            //     a real HTTP-404 load failure — `driveCurrentAccountAuthDoc
            //     IfNeeded` had to special-case the conflation. PR #1021
            //     (Module A, swarm_51f248d5) split the case so the two
            //     meanings stop sharing storage; the driver READ matches on
            //     `.detailsEvicted(.libraryDeselected)` directly.
            // Awaiters on this terminal throw `AccountLoadError.evicted`
            // (distinct from `.accountNotFound`) so consumers can decide
            // whether to retry, re-resolve, or simply discard the request.
            // Re-entering the same UUID later overwrites the marker through
            // the `.basicInfoLoaded` path on the next preload/loadCatalogs.
            if let prev = previousAccountId, prev != newAccountId {
                switchDeps.accountStateStore.setState(
                    .detailsEvicted(.libraryDeselected(uuid: prev)),
                    for: prev
                )
            }

            // Account state-machine wiring (3.2.0): drive the NEW
            // currentAccount past `.basicInfoLoaded` after the switch.
            // Sibling of the `loadCatalogs` warm-path driver (PR #975) —
            // same disease class, different trigger. Without this, every
            // `awaitReady()` caller (audiobook open, token refresh,
            // bookmark sync, CarPlay auth) hangs forever the first time
            // the user opens content on the newly-selected library.
            // Single-flight guard inside `fetchAuthDocumentWithStateMachine`
            // dedupes against any concurrent fetch from refresh-in-background.
            driveCurrentAccountAuthDocIfNeeded()

            TPPErrorLogger.setUserID(self.currentUserAccount.barcode)
            // isAccountSwitching is reset asynchronously by cleanupActiveContentBeforeAccountSwitch
            // after navigation cleanup completes — NOT here, to avoid premature reset (F-032).
            if Self.shouldFinishSwitchingImmediately(previousAccountId: previousAccountId, newAccountId: newAccountId) {
                isAccountSwitching = false
            }
            // CP-D1 (Finding 5): rewrite the slim launch snapshot off-main so it
            // reflects the newly-selected current account. `slimSnapshotUUIDs()`
            // is evaluated at write time, so without this a mid-session switch
            // would leave the slim file listing the PRIOR account — and the next
            // cold launch would resolve `currentAccount` nil in the
            // pre-materialization window (self-healed only one launch later).
            // Off-main + best-effort + XCTest-gated (see the method); no launch
            // main-thread cost. The `hydrateSlimLaunchSnapshot` current-account
            // presence check is the belt-and-suspenders if this ever lags.
            registryLoader.refreshSlimLaunchSnapshotOffMain(hash: registryStore.currentHash)
            NotificationCenter.default.post(name: .TPPCurrentAccountDidChange, object: nil)
        }
    }

    /// Cleans up active audiobook playback, in-flight network requests, and other
    /// content before switching accounts to prevent cross-account credential leaks.
    private func cleanupActiveContentBeforeAccountSwitch(from previousId: String?, to newId: String?) {
        networkExecutor.cancelNonEssentialTasks()
        borrowReauthResetter.clearAllBorrowReauthState()

        // Capture the injected nav-pop seam BY VALUE so the hop fires regardless of
        // the manager's lifetime (matching the prior composition-root-based pop). The
        // seam encapsulates the coordinator lookup + `shouldPopToRoot` + settle.
        let popToRoot = switchDeps.popToRootForAccountSwitch
        Task { @MainActor [weak self] in
            await popToRoot()
            // Reset flag AFTER async cleanup completes — not in the setter (F-032)
            self?.isAccountSwitching = false
        }
    }

    private(set) var currentAccountId: String? {
        get { defaults.string(forKey: currentAccountIdentifierKey) }
        set {
            Log.debug(#file, "Setting currentAccountId to \(newValue ?? "N/A")")
            defaults.set(newValue, forKey: currentAccountIdentifierKey)
        }
    }

    func account(_ uuid: String) -> Account? {
        return registryStore.account(uuid)
    }

    func accounts(_ key: String? = nil) -> [Account] {
        // Atomic on the nil path: the store reads currentHash + its bucket in ONE
        // critical section, so a concurrent library switch can't key the bucket to a
        // stale hash. Do NOT collapse this to `accounts(forKey: currentHash)`.
        if let key {
            return registryStore.accounts(forKey: key)
        }
        return registryStore.accountsForCurrentHash()
    }

    #if DEBUG
    /// Test-only: seed an Account into `accountSets[currentHash]` and set
    /// `currentAccountId` to its UUID, so `AppContainer.production()
    /// .accountsManager.currentAccount` returns it. Used by Bucket A
    /// integration tests that need to exercise production-stack code
    /// paths reading `currentAccount` (e.g.
    /// `AppContainer.production().audiobookSession.openAudiobook`,
    /// `CarPlayAuthHelper.isAuthenticated`,
    /// `TPPBookRegistry.syncAsync`, `BookRegistrySync.sync`) without
    /// requiring a real OPDS2 catalog fixture load. Closes the 4 XCTSkip
    /// blocks the swarm Phase 1 implementers flagged.
    ///
    /// Returns a teardown closure that removes the seeded account and
    /// restores the prior `currentAccountIdentifierKey`. Callers should
    /// defer-call it to keep the production singleton uncontaminated.
    ///
    /// NOT exposed in production builds.
    @discardableResult
    func _seedAccountForTesting(_ account: Account) -> () -> Void {
        let seedKey = registryStore.currentHash
        registryStore.mutate {
            var seeded = $0[seedKey] ?? []
            seeded.removeAll { $0.uuid == account.uuid }
            seeded.append(account)
            $0[seedKey] = seeded
        }
        let previousId = defaults.string(forKey: currentAccountIdentifierKey)
        defaults.set(account.uuid, forKey: currentAccountIdentifierKey)
        return {
            self.registryStore.mutate {
                $0[seedKey]?.removeAll { $0.uuid == account.uuid }
            }
            if let prev = previousId {
                self.defaults.set(prev, forKey: currentAccountIdentifierKey)
            } else {
                self.defaults.removeObject(forKey: currentAccountIdentifierKey)
            }
        }
    }
    #endif

    var accountsHaveLoaded: Bool {
        // Atomic: the store samples currentHash + its bucket in ONE critical section.
        return registryStore.currentBucketIsLoaded()
    }

    // MARK: - Per-Account User Credentials

    /// Per-account credential resolution (Wave 3 / 3a-5): the per-library
    /// `TPPUserAccount` cache (immutable keys), the `currentUserAccount` ride-out over
    /// the account-switch nil window, and the fresh-install placeholder moved to the
    /// injected `AccountCredentialResolver`, which owns the F-034/F-016 invariants. The
    /// hub keeps the `@objc TPPUserAccountResolving` witnesses below as thin facades.
    /// `lazy var` because the provider closure captures `self` (the authDocLoader
    /// precedent); `currentAccountIdProvider` is a LIVE read (not a snapshot) so the
    /// ride-out observes the transient nil window in real time.
    private lazy var credentialResolver = AccountCredentialResolver(
        currentAccountIdProvider: { [weak self] in self?.currentAccountId }
    )

    /// Returns a library-scoped `TPPUserAccount` instance (facade → `credentialResolver`).
    func userAccount(for libraryUUID: String) -> TPPUserAccount {
        credentialResolver.userAccount(for: libraryUUID)
    }

    /// Convenience for the current library's user account (facade → `credentialResolver`).
    var currentUserAccount: TPPUserAccount {
        credentialResolver.currentUserAccount
    }

    // MARK: – Load logic (facade → AccountRegistryLoader)

    /// Public catalog-load entrypoint. The stale-while-revalidate pipeline (memory/disk/
    /// network fast paths, the owned background crawl, the loading-handler dedupe) lives on
    /// `registryLoader` (Wave 3 / 3a-4); this thin facade keeps every call site + test
    /// (AppContainer, updateAccountSet, the wiring/first-run/cache suites) byte-identical.
    func loadCatalogs(completion: ((Bool) -> Void)?) {
        registryLoader.loadCatalogs(completion: completion)
    }

    // MARK: – Account-switch pure helpers
    //
    // The disk-cache helpers that lived here moved to `AccountRegistryCache.swift`
    // (Wave 3 / 3a-1). These two remain: they are pure switch-pipeline predicates,
    // not cache I/O, and travel with the current-account extraction later.

    /// Pure helper for `cleanupActiveContentBeforeAccountSwitch`'s
    /// `pathCount > 0` guard — extracted so the bound check is testable.
    static func shouldPopToRoot(navigationPathCount: Int) -> Bool {
        return navigationPathCount > 0
    }

    /// Pure helper for the `currentAccount.didSet` decision of whether to
    /// finish the account-switch synchronously. The previous implementation
    /// had `previousAccountId == newAccountId || previousAccountId == nil`
    /// inline in the setter; extracting it keeps the equality and identity
    /// branches testable and kills the surviving == ↔ != mutants.
    static func shouldFinishSwitchingImmediately(
        previousAccountId: String?,
        newAccountId: String?
    ) -> Bool {
        return previousAccountId == newAccountId || previousAccountId == nil
    }

    // MARK: – Auth Document fetch with state-machine wiring (facades → AuthDocumentLoader)
    //
    // The single-flight guard, the `.detailsLoading → .detailsLoaded/.detailsFailed`
    // transitions, and the `.detailsEvicted` disambiguation moved to
    // `AuthDocumentLoader.swift` (Wave 3 / 3a-3). The hub keeps thin forwarders so every
    // call site (the `currentAccount` setter, the warm path) and every test stays byte-
    // identical.

    /// Static forwarder — `AuthDocumentLoader.fetchCompletionMayWriteTerminal` holds the
    /// pure guard; retained here because the wiring/snapshot tests call
    /// `AccountsManager.fetchCompletionMayWriteTerminal`.
    static func fetchCompletionMayWriteTerminal(currentState: Account.LoadState) -> Bool {
        AuthDocumentLoader.fetchCompletionMayWriteTerminal(currentState: currentState)
    }

    /// Forwards to `authDocLoader` (Wave 3 / 3a-3). Exposed `internal` so contract-snapshot
    /// tests can drive the wiring path directly without the full `loadCatalogs` cycle.
    internal func fetchAuthDocumentWithStateMachine(
        for account: Account,
        completion: @escaping (Bool) -> Void
    ) {
        authDocLoader.fetchAuthDocumentWithStateMachine(for: account, completion: completion)
    }

    /// Forwards to `authDocLoader` (Wave 3 / 3a-3). Called synchronously from the
    /// `currentAccount` setter, the slim-hydrate drive, and the `loadCatalogs` warm path
    /// to close the readiness driver gap; no-op at a terminal state, redrive on a stale
    /// `.detailsEvicted` marker. The `.detailsEvicted`-vs-`.detailsFailed` disambiguation
    /// + the forward-compat exhaustiveness guard live in `AuthDocumentLoader`.
    internal func driveCurrentAccountAuthDocIfNeeded() {
        authDocLoader.driveCurrentAccountAuthDocIfNeeded()
    }

    // MARK: – Parsing & notifying

    /// Facade → `registryLoader.loadAccountSetsAndAuthDoc` (Wave 3 / 3a-4). Exposed
    /// `internal` so the cache-read + launch-snapshot contract tests can drive registry
    /// materialization directly; the parse + carry-over + auth-doc-drive body lives on the loader.
    internal func loadAccountSetsAndAuthDoc(
        fromCatalogData data: Data,
        key hash: String,
        completion: @escaping (Bool) -> Void
    ) {
        registryLoader.loadAccountSetsAndAuthDoc(fromCatalogData: data, key: hash, completion: completion)
    }

    @objc private func updateAccountSetFromNotification(_ notif: Notification) {
        // Run off the poster's thread. `.TPPUseBetaDidChange` is delivered
        // synchronously by `NotificationCenter` on whatever thread posted it —
        // typically MAIN, from a Settings toggle. `updateAccountSet` does a
        // synchronous read on the registry store's concurrent `accountSetsLock`
        // (via `registryStore.bucketIsNonEmpty`) that blocks until any in-flight
        // background catalog-refresh barrier on that lock drains; under
        // load that barrier can take a long time, so reacting synchronously stalls
        // the poster (the Settings UI — and any test that posts this notification,
        // which is how it surfaced as a 120s hang). The account-set update is
        // inherently async anyway (it may reload catalogs), so dispatch it.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.updateAccountSet(completion: nil)
        }
    }

    func updateAccountSet(completion: ((Bool) -> Void)?) {
        let newHash = TPPConfiguration.customUrlHash()
            ?? (settings.useBetaLibraries
                    ? TPPConfiguration.betaUrlHash
                    : TPPConfiguration.prodUrlHash)

        registryStore.setCurrentHash(newHash)
        // Original was `accountSets[newHash]?.isEmpty ?? true` (true when empty/missing);
        // bucketIsNonEmpty is its inverse, so this MUST be negated to preserve the
        // load-trigger polarity.
        if !registryStore.bucketIsNonEmpty(hash: newHash) || TPPConfiguration.customUrlHash() != nil {
            loadCatalogs(completion: completion)
        } else {
            completion?(true)
        }
    }

    /// Clears all local catalog, crawl state, and authentication caches
    func clearCache() {
        // network cache
        networkExecutor.clearCache()
        // file caches — the on-disk catalog/metadata/list/crawl sweep now lives on
        // the injected registry cache (Wave 3 / 3a-1).
        registryCache.clearFileCaches()
    }
}

#if DEBUG
/// Lock-backed weak-registry holder so `AccountsManager`'s process-wide live
/// instance set is concurrency-safe global state WITHOUT `nonisolated(unsafe)`
/// — mirrors the `AccountsManagerBoolFlag` house pattern above.
/// `@unchecked Sendable` invariant: the only mutable state is `table`, mutated
/// (`add`) and snapshotted (`snapshot`) exclusively under `lock` (an immutable
/// `NSLock`); `NSHashTable.weakObjects()` holds WEAK refs to `AccountsManager`
/// (itself `Sendable`), so registration never extends any instance's lifetime.
/// DEBUG-only: the whole registry compiles out of release.
private final class AccountsManagerLiveRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private let table = NSHashTable<AccountsManager>.weakObjects()
    func add(_ m: AccountsManager) {
        lock.lock(); defer { lock.unlock() }
        table.add(m)
    }
    /// Snapshot under the lock; callers drain OUTSIDE the lock (the drain pumps
    /// the run loop and must not hold a lock).
    func snapshot() -> [AccountsManager] {
        lock.lock(); defer { lock.unlock() }
        return table.allObjects
    }
}

extension AccountsManager {
    /// Process-wide weak registry of every live AccountsManager, so a global
    /// test-boundary drain can cancel background work on instances a test never
    /// tore down (the foreign-polluter case). Weak so it never extends lifetime.
    private static let _liveInstancesForTesting = AccountsManagerLiveRegistry()

    static func _registerLiveInstanceForTesting(_ m: AccountsManager) {
        _liveInstancesForTesting.add(m)
    }

    /// Drain + cancel background work on ALL live instances. Called at each test
    /// boundary BEFORE AccountStateStore._resetAllForTesting so any flushed late
    /// write is then wiped. Snapshot under lock (inside the holder); drain
    /// outside the lock (the drain pumps the run loop and must not hold a lock).
    static func _drainAllLiveInstancesForTesting() {
        let snapshot = _liveInstancesForTesting.snapshot()
        for m in snapshot { m.cancelAndDrainBackgroundWork() }
    }

    /// Test-only seam: populate an accountSets bucket without going through
    /// OPDS2 parsing. Routes through `registryStore.mutate` (the store's barrier)
    /// so concurrent-access invariants — including the in-barrier `accountByUUID`
    /// rebuild — are preserved. Used by mutation-killing tests for
    /// `account(_ uuid:)` — multi-bucket scenarios are not otherwise
    /// reachable from outside the class.
    func _testSetAccountSet(_ accounts: [Account], forKey key: String) {
        registryStore.mutate { $0[key] = accounts }
    }

    /// Test-only: cancel the in-flight background `loadCatalogs` Task (if any)
    /// and the network executor's non-essential URL session tasks. Cooperative
    /// — returns immediately after issuing the cancel; observation is delegated
    /// to the Task's own `Task.isCancelled` check inside `fetchFromNetwork`.
    /// Idempotent: safe to call repeatedly. Does NOT mutate persistent state;
    /// only cancels in-flight async work.
    ///
    /// Production-safe — guarded by `#if DEBUG` and called only from
    /// `AppContainer._resetForTesting()`. swarm_4b64e4e0 Fix 2 — closes the
    /// H1 finding from swarm_f88ae9e3 A.
    ///
    /// This is the COOPERATIVE cancel — it returns immediately. The SYNCHRONOUS
    /// `cancelAndDrainBackgroundWork()` (which `_resetForTesting()` actually
    /// calls at every boundary) awaits the full owned set, which drains the
    /// previously un-awaitable fallback-GET channel. Kept for the
    /// idempotent/observation-surface tests.
    ///
    /// Residual race window (NARROWED to one boundary): if `loadCatalogs` is
    /// already past the post-await `Task.isCancelled` check inside
    /// `fetchFromNetwork`, the network response still lands in `accountSets`
    /// on the OLD AccountsManager instance — but the OLD instance is no
    /// longer reachable from `AppContainer.production()` post-reset, so the
    /// write is observable only by code paths holding a strong reference to
    /// the prior `accountsManager` (vanishingly few in tests; none in
    /// production). Acceptable per swarm_4b64e4e0 outcome.md.
    func cancelBackgroundWork() {
        // Flip the hub-owned explicit-cancel flag BEFORE delegating so the observation
        // surface `_backgroundFetchTaskWasExplicitlyCancelled` (which reads this flag)
        // distinguishes "we called cancel" from "handle nilled by another path." The task/
        // registry cancel + network cancel live on the loader now (Wave 3 / 3a-4); the loader
        // body must NOT touch this flag (it can't reach it).
        _explicitCancelCalled = true
        registryLoader.cancelBackgroundWork()
    }

    /// Test-only: cancel + synchronously DRAIN the in-flight background crawl (pumping the
    /// run loop) before returning, so no orphan crawl outlives the test boundary. The drain
    /// body lives on the loader; the hub sets `_explicitCancelCalled` FIRST so the torn-down
    /// semantics engage for the pending auth-doc main-hop (Wave 3 / 3a-4 — the critical seam).
    func cancelAndDrainBackgroundWork(timeout: TimeInterval = 3.0) {
        _explicitCancelCalled = true
        registryLoader.cancelAndDrainBackgroundWork(timeout: timeout)
    }

    /// Test-only setter forwarder for the loader's `backgroundFetchTask`.
    @discardableResult
    func _injectBackgroundFetchTaskForTesting(_ task: Task<Void, Never>?) -> Task<Void, Never>? {
        return registryLoader._injectBackgroundFetchTaskForTesting(task)
    }

    /// Test-only observation surface: `true` iff `cancelBackgroundWork()` was called on this
    /// instance. Reads the hub-owned `_explicitCancelCalled` flag (stays here so the 3a-3
    /// `AuthDocumentLoader.isTornDown` binding is byte-identical). swarm_4b64e4e0 qa-fixup Fix 3.
    var _backgroundFetchTaskWasExplicitlyCancelled: Bool {
        return _explicitCancelCalled
    }

    /// Test-only observation-surface forwarder: `true` iff the loader's `backgroundFetchTask` is nil.
    var _backgroundFetchTaskHandleIsNil: Bool {
        return registryLoader._backgroundFetchTaskHandleIsNil
    }

    /// Test-only observation-surface forwarder.
    @available(*, deprecated, message: "Use _backgroundFetchTaskWasExplicitlyCancelled + _backgroundFetchTaskHandleIsNil so cancel-vs-nil mutations are independently observable. See swarm_4b64e4e0 qa-fixup Fix 3.")
    var _backgroundFetchTaskIsCancelledOrCleared: Bool {
        return registryLoader._backgroundFetchTaskIsCancelledOrCleared
    }
}
#endif
