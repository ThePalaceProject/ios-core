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

/// Documented carrier for a non-Sendable `() -> Void` handed to a
/// `DispatchQueue` barrier block in `AccountsManager.performWrite`.
/// `@unchecked Sendable` invariant: the wrapped closure is invoked exactly
/// once, on the serial barrier of the concurrent `accountSetsLock`, never
/// concurrently.
private struct VoidWorkBox: @unchecked Sendable {
    let work: () -> Void
}

/// Documented carrier for the non-Sendable `(inout [String: [Account]]) -> Void`
/// mutation closure handed to the `accountSetsLock` barrier in
/// `AccountsManager.mutateAccountSets`. Same `@unchecked Sendable` invariant as
/// `VoidWorkBox`: the wrapped closure is invoked exactly once, on the serial
/// `.barrier` of the concurrent `accountSetsLock`, never concurrently. Timing
/// and the mutate-then-rebuild-index contract are unchanged.
private struct AccountSetsMutationBox: @unchecked Sendable {
    let mutate: (inout [String: [Account]]) -> Void
}

/// Documented carrier for a non-Sendable `(Bool) -> Void` load-completion
/// handler stored into the `loadingHandlersQueue` barrier in
/// `AccountsManager.addLoadingHandler`. `@unchecked Sendable` invariant: the
/// wrapped closure is only ever appended to / read from
/// `loadingCompletionHandlers[hash]` under the serial `.barrier` of the
/// concurrent `loadingHandlersQueue`, and invoked later on whatever queue the
/// caller of `callAndClearLoadingHandlers` runs on — never concurrently with
/// its own storage mutation. The handler's own thread-affinity is the caller's
/// contract (unchanged); this box only satisfies the `@Sendable` boundary of
/// the dispatch barrier.
private struct LoadCompletionBox: @unchecked Sendable {
    let handler: (Bool) -> Void
}

/// Documented carrier for the non-Sendable `LibraryRegistryCrawler` handed
/// from the first-page crawl Task into its nested background pagination Task
/// in `AccountsManager.fetchFromNetwork`. `@unchecked Sendable` invariant: the
/// crawler is used strictly sequentially — the outer Task finishes its
/// `crawlFirstPage` await BEFORE the pagination Task is spawned, and only the
/// pagination Task touches the crawler thereafter (`crawlRemainingPages`), so
/// the two never touch it concurrently. Mirrors `LibraryRegistryCrawler`'s own
/// `CrawlerFetcherBox`.
private struct CrawlerHandoffBox: @unchecked Sendable {
    let crawler: LibraryRegistryCrawler
}

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
///   - `accountSet`, `accountSets`, `accountByUUID`  → read via `performRead`
///     (`accountSetsLock.sync`), written via `performWrite` / `mutateAccountSets`
///     (`accountSetsLock.async(flags:.barrier)`). `accountByUUID` is only ever
///     rebuilt inside the same barrier as `accountSets`, so the two never desync.
///   - `loadingCompletionHandlers`  → read via `loadingHandlersQueue.sync`,
///     written via `loadingHandlersQueue.async(flags:.barrier)`.
///   - `inflightAuthDocFetches`  → read/written only under `inflightAuthDocLock`.
///   - `userAccounts`, `lastKnownCurrentUserAccount`  → read/written only under
///     `userAccountsLock`.
///   - `_trackedFirstRunTasks`  → read/written only under `_trackedCrawlTasksLock`.
///   - `ownedCrawlTasks`  → an `OwnedCrawlTaskRegistry`, internally synchronized;
///     `crawlScheduler`  → immutable `Sendable` `let` bound once from `init`.
///   - `isAccountSwitching`  → storage moved into the lock-backed
///     `AccountsManagerBoolFlag` holder (`_isAccountSwitching`), so its `Bool`
///     set/get is serialized by the holder's own `NSLock`; the public
///     `private(set) var` computed accessor preserves every call site and the
///     value/timing verbatim (see property below).
///   - `networkExecutor`, `noAccountPlaceholder`  → `lazy var`, each resolved
///     exactly once from an already-constructed dependency and immutable
///     thereafter; the lazy init runs on the first touch, which for
///     `networkExecutor` is inside the background load path after `AppContainer`
///     finishes constructing, and for `noAccountPlaceholder` only on the fresh-
///     install `currentUserAccount` path. Effectively write-once.
///   - `backgroundFetchTask`, `_explicitCancelCalled`  → `#if DEBUG` test-only;
///     compiled out of release. Driven only from the test-boundary
///     `cancelBackgroundWork()` / `_injectBackgroundFetchTaskForTesting` seams.
///
///   Immutable (`let`) state — inherently safe: `tppAccountUUID`, `ageCheck`,
///   `settings`, `defaults`, `accountSetsLock`, `catalogPreloader`,
///   `loadingHandlersQueue`, `inflightAuthDocLock`, `userAccountsLock`,
///   `_trackedCrawlTasksLock`.
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
    /// Injectable background-crawl spawn seam (see `CatalogCrawlScheduler`).
    /// Immutable `Sendable` `let`; `.production` by default, recording under test.
    private let crawlScheduler: CrawlTaskScheduler
    /// On-disk catalog cache collaborator (Wave 3 / 3a-1). Immutable `Sendable`
    /// `let`; the stateless `DiskAccountRegistryCache` by default, a recording
    /// double under test. All catalog read/write/staleness/clear disk I/O routes
    /// here, so the hub carries none of it and a packaged manager names no
    /// FileManager cache body.
    private let registryCache: any AccountRegistryCaching
    /// Owns every background catalog-crawl Task — production included (PP-4754):
    /// the previously fire-and-forget crawl now has an owner the reset
    /// choreography cancels + awaits, so no un-drainable write channel survives a
    /// test boundary. Self-pruning + internally synchronized.
    private let ownedCrawlTasks = OwnedCrawlTaskRegistry()
    private var accountSet: String
    private var accountSets = [String: [Account]]()
    /// O(1) `uuid → Account` index derived from `accountSets`, kept in lockstep
    /// with it under `accountSetsLock`. Lets `account(_:)` resolve a UUID without
    /// a linear scan over every bucket — the registry snapshot holds ~1142
    /// accounts, and `account(_:)` is on the main-thread display path for every
    /// account-change-driven view refresh, so the old `accountSets.values.first {
    /// $0.contains(where:) }` scan saturated the main thread (the test-suite hang
    /// class, and a live-app cost on every library switch). MUST only be mutated
    /// via `mutateAccountSets` so it can never desync from `accountSets`.
    private var accountByUUID = [String: Account]()
    private let accountSetsLock = DispatchQueue(label: "com.tpp.accountSetsLock", attributes: .concurrent)

    /// Launch-hydration (CP-D1) slim lookup: the current + `settingsAccountIdsList`
    /// accounts (~2 accounts, a few KB) decoded SYNCHRONOUSLY at launch from the
    /// small `accounts_catalog_slim_<hash>.json` snapshot, so `currentAccount`
    /// resolves — and its `awaitReady()` gate is driven — within a few ms of
    /// launch instead of paying the full ~207ms (fast sim) / ~0.3-0.6s (device)
    /// 1142-account decode+map on the launch main thread.
    ///
    /// Deliberately kept SEPARATE from `accountSets`: `accountsHaveLoaded` and
    /// `accounts()` MUST keep reflecting the FULL 1142-account list (the library
    /// picker — `TPPAccountList` / `TPPAppDelegate.presentFirstRunFlowIfNeeded`
    /// — reads them), so the ~2-account slim set must NOT flip `accountsHaveLoaded`
    /// true (a truncated-picker bug). This structure only backs `account(_:)`'s
    /// FALLBACK; full instances (in `accountByUUID`) always win once the full
    /// list materializes off-main via the background `loadCatalogs`. Guarded by
    /// its own `NSLock` so `account(_:)`'s `accountSetsLock` read and this
    /// fallback never contend on the same lock.
    private var slimAccountsByUUID = [String: Account]()
    private let slimAccountsLock = NSLock()

    private let catalogPreloader = CatalogPreloader()

    // Per‐catalog in‐flight tracking:
    private var loadingCompletionHandlers = [String: [(Bool) -> Void]]()
    private let loadingHandlersQueue = DispatchQueue(label: "com.tpp.loadingHandlers", attributes: .concurrent)

    /// Per-UUID single-flight guard for `authentication_document` fetches,
    /// keyed by UUID → the `Date` the fetch was started. Without single-flight,
    /// two concurrent consumers calling `awaitReady()` on the same Account would
    /// each cause `current.loadAuthenticationDocument` to fire a duplicate HTTP
    /// request. The state machine's broadcast (`CurrentValueSubject`) handles
    /// multi-consumer observation; this map just prevents the duplicate network
    /// request. See ADR docs/architecture/account-state-machine.md Open Q #1.
    ///
    /// The start-time value (rather than a bare `Set`) exists so a wedged fetch
    /// can be reclaimed: if a fetch's network completion is DROPPED, the UUID
    /// would otherwise stay in-flight forever and every later
    /// `driveCurrentAccountAuthDocIfNeeded` would early-return on the dead entry,
    /// leaving the account stuck at `.detailsLoading` (HelpSpot #18414). When an
    /// entry is older than `authDocInflightTimeout`, the next fetch reclaims the
    /// slot and re-fires instead of deduping against the corpse.
    private var inflightAuthDocFetches = [String: Date]()
    private let inflightAuthDocLock = NSLock()

    /// How long a single-flight `authentication_document` fetch may remain
    /// in-flight before a subsequent fetch treats it as wedged (dropped
    /// completion) and reclaims the slot. Sized above a healthy auth-doc
    /// round-trip so a genuinely concurrent fetch is still deduped, while a
    /// dropped-completion wedge self-heals on the next drive.
    static let authDocInflightTimeout: TimeInterval = 30

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

    /// Test-only handle to the post-init background `loadCatalogs` task so
    /// `cancelBackgroundWork()` can issue cooperative cancellation. Only ever
    /// non-nil under DEBUG builds AND when `deferInitialLoadCatalogsForTesting`
    /// was `false` at init time. Production reads this field implicitly via
    /// `cancelBackgroundWork()` (called by `AppContainer._resetForTesting()`);
    /// production does NOT pay the storage cost in release builds because the
    /// whole field is `#if DEBUG`-gated.
    ///
    /// swarm_4b64e4e0 Fix 2 — closes the H1 finding from swarm_f88ae9e3 A.
    private var backgroundFetchTask: Task<Void, Never>?

    /// Test-only flag flipped to `true` inside `cancelBackgroundWork()` BEFORE
    /// the `.cancel()` is issued on `backgroundFetchTask`. Used by
    /// `AccountsManagerCancellationTests` to disambiguate "explicit cancel was
    /// called" from "task handle was nilled out by some other path." swarm_4b64e4e0
    /// qa-fixup — addresses qa_test concern about the prior single observation
    /// surface conflating those two semantics.
    private var _explicitCancelCalled: Bool = false

    /// Test-only: seed the single-flight `inflightAuthDocFetches` map with an
    /// entry whose start time is `age` seconds in the past. Lets the stale-wedge
    /// reclaim path in `fetchAuthDocumentWithStateMachine` be exercised
    /// deterministically without burning `authDocInflightTimeout` wall-clock
    /// seconds. NOT compiled into release builds.
    func _seedInflightAuthDocForTesting(uuid: String, age: TimeInterval) {
        inflightAuthDocLock.lock()
        inflightAuthDocFetches[uuid] = Date().addingTimeInterval(-age)
        inflightAuthDocLock.unlock()
    }

    /// Test-only read of whether a UUID currently occupies the single-flight map.
    func _inflightAuthDocContainsForTesting(uuid: String) -> Bool {
        inflightAuthDocLock.lock(); defer { inflightAuthDocLock.unlock() }
        return inflightAuthDocFetches[uuid] != nil
    }
    #endif

    /// PP-4754: every background catalog-crawl `Task` (init load, first-run,
    /// crawl, pagination, refresh, the wrapped fallback GETs, preload) is spawned
    /// through `spawnOwnedCrawlTask` into `ownedCrawlTasks` — production included,
    /// no XCTest/`#if DEBUG` bookkeeping on the spawn path — so the reset
    /// choreography cancels + awaits every one, closing the last un-drainable
    /// write channel that leaked a live crawl into the next test.
    private static let _isRunningUnderXCTest =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    /// Guards `_trackedFirstRunTasks`.
    private let _trackedCrawlTasksLock = NSLock()
    /// Subset of owned tasks that are `loadCatalogs` FIRST-RUN tasks. Populated
    /// only under XCTest (byte-identical to the prior `_trackFirstRunTask` gate).
    /// The narrow `_awaitAllCrawlTasksForTesting()` seam joins ONLY these (see it
    /// for why); the broad `_awaitCatalogLoadForTesting()` joins the whole set.
    private var _trackedFirstRunTasks: [Task<Void, Never>] = []

    /// Resolves the build-time bundled registry snapshot resource. Production
    /// binds `Bundle.main`; tests inject a stub (`BundleResourceResolving`) to
    /// observe the first-launch bundled decode's thread + invocation count
    /// WITHOUT a `#if DEBUG` seam (mirrors `BundledRegistrySnapshot.load(resolver:)`,
    /// which was designed for exactly this injection). Read on the first-run
    /// decode task; never mutated in production.
    var snapshotResourceResolver: BundleResourceResolving = Bundle.main

    /// Test-observability: count of `fetchFromNetwork` entries. Incremented
    /// only under XCTest (same env-var gate as `_trackCrawlTask` — no
    /// `#if DEBUG`, so blast-radius BR-2 stays clean). Lets the first-run-decode
    /// tests assert the network fetch STILL fires after the bundled snapshot
    /// decode (the Phase 1a regression the naive dedupe would swallow) without
    /// waiting on a live network round-trip.
    private let _fetchFromNetworkCountLock = NSLock()
    private var _fetchFromNetworkCount = 0
    var fetchFromNetworkCountForTesting: Int {
        _fetchFromNetworkCountLock.lock()
        defer { _fetchFromNetworkCountLock.unlock() }
        return _fetchFromNetworkCount
    }

    /// Spawn a background crawl `Task` through `crawlScheduler` and register it in
    /// `ownedCrawlTasks` so the reset choreography can cancel + await it.
    /// `detached`/`priority` preserve each call site's exact semantics + QoS;
    /// `firstRun` also records it in the narrow-join subset (XCTest only). A
    /// `defer` self-prunes the token as the task unwinds, bounding the live set.
    @discardableResult
    private func spawnOwnedCrawlTask(
        priority: TaskPriority,
        detached: Bool,
        firstRun: Bool = false,
        _ operation: @escaping @Sendable () async -> Void
    ) -> Task<Void, Never> {
        let token = UUID()
        let registry = ownedCrawlTasks
        let owned: @Sendable () async -> Void = {
            defer { registry.complete(token) }
            await operation()
        }
        let task = detached
            ? crawlScheduler.spawnDetached(priority, owned)
            : crawlScheduler.spawn(priority, owned)
        ownedCrawlTasks.register(token, task)
        if firstRun { _trackFirstRunTask(task) }
        return task
    }

    /// Record a `loadCatalogs` FIRST-RUN task in the narrow-join subset. No-op
    /// outside XCTest (the whole-set drain uses `ownedCrawlTasks`, not this).
    private func _trackFirstRunTask(_ task: Task<Void, Never>) {
        guard Self._isRunningUnderXCTest else { return }
        _trackedCrawlTasksLock.lock()
        _trackedFirstRunTasks.append(task)
        _trackedCrawlTasksLock.unlock()
    }

    /// Test-only whole-quiescence JOIN seam (PP-4754). Grows-until-stable: awaits
    /// every owned crawl `Task`, re-snapshotting to catch tasks the wave spawned
    /// (crawl → pagination/fallback → preload is a finite chain) until none is
    /// new or `maxRounds` is hit. NO wall-clock — pure Task-join, so it never
    /// starves under parallel CI clones (STARVE-001-clean) and never blocks main
    /// (it suspends). No-op outside XCTest.
    nonisolated func _awaitCatalogLoadForTesting(maxRounds: Int = 8) async {
        guard Self._isRunningUnderXCTest else { return }
        var awaited = Set<UUID>()
        for _ in 0..<maxRounds {
            let fresh = ownedCrawlTasks.snapshot().filter { !awaited.contains($0.0) }
            if fresh.isEmpty { return }
            for (token, task) in fresh {
                _ = await task.value
                awaited.insert(token)
            }
        }
    }

    /// Test-only quiescence assertion helper: number of live owned crawl tasks.
    var _ownedCrawlTaskCountForTesting: Int { ownedCrawlTasks.count }

    /// Test-only NARROW deterministic JOIN seam. Awaits every tracked FIRST-RUN
    /// task (bundled decode → synchronous `fetchFromNetwork` kickoff) instead of
    /// polling a wall-clock deadline that starves under parallel CI clones. It
    /// deliberately does NOT await the downstream live crawl `fetchFromNetwork`
    /// spawns — the first-run task's synchronous `fetchFromNetwork` call has
    /// already returned (bumping `_fetchFromNetworkCount`) by the time its
    /// `.value` resolves, so joining the first-run task alone suffices for the
    /// decode + fetch-fired observations. (For whole-quiescence use
    /// `_awaitCatalogLoadForTesting`.) No-op in RELEASE — the array only
    /// populates under XCTest. Snapshot-then-await-without-a-lock (Swift 6 bans
    /// `NSLock.lock()` across an await).
    nonisolated private func _snapshotFirstRunTasksForTesting() -> [Task<Void, Never>] {
        _trackedCrawlTasksLock.lock()
        defer { _trackedCrawlTasksLock.unlock() }
        return _trackedFirstRunTasks
    }

    nonisolated func _awaitAllCrawlTasksForTesting() async {
        for task in _snapshotFirstRunTasksForTesting() {
            _ = await task.value
        }
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
        registryCache: any AccountRegistryCaching = DiskAccountRegistryCache()
    ) {
        self.defaults = defaults
        self.borrowReauthResetter = borrowReauthResetter
        self.crawlScheduler = crawlScheduler
        self.switchDeps = switchDependencies
        self.registryCache = registryCache
        self.settings = TPPSettings()
        self.accountSet = TPPConfiguration.customUrlHash()
            ?? (settings.useBetaLibraries
                    ? TPPConfiguration.betaUrlHash
                    : TPPConfiguration.prodUrlHash)
        self.ageCheck = TPPAgeCheck(ageCheckChoiceStorage: settings)
        super.init()
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
            preloadAccountsFromDiskCacheSync()
        }
        #else
        preloadAccountsFromDiskCacheSync()
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
        // Unified background-load arm (both configs) — PP-4754. Routed through
        // `spawnOwnedCrawlTask` so the crawl is OWNED (cancellable + drainable at
        // a test boundary). RELEASE previously used a bare
        // `DispatchQueue.global(qos: .utility).async` (untracked); it now spawns
        // the SAME detached `.utility` work DEBUG has exercised for months. This
        // ownership unification is the single deliberate production-visible
        // delta; the crawl work (`loadCatalogs`) is unchanged. DEBUG keeps a
        // separate `backgroundFetchTask` handle for the injection + cancellation
        // observation seams; RELEASE lets the registry own it.
        let initialLoadTask = spawnOwnedCrawlTask(priority: .utility, detached: true) { [weak self] in
            self?.loadCatalogs(completion: nil)
        }
        #if DEBUG
        backgroundFetchTask = initialLoadTask
        #else
        _ = initialLoadTask
        #endif
    }

    /// Hydrate `accountSets[accountSet]` from the on-disk OPDS2 catalog cache
    /// without dispatching to a background queue. Safe to call from `init()`
    /// because the cache read is local I/O measured in single-digit ms.
    ///
    /// Exposed `internal` so contract-snapshot tests can drive the preload
    /// path directly after seeding the on-disk cache.
    internal func preloadAccountsFromDiskCacheSync() {
        let hash = self.accountSet
        // Fast path (CP-D1 LaunchHydration): when a slim snapshot exists, decode
        // ONLY the current + settings accounts (a few KB) synchronously so
        // `currentAccount` resolves and its auth-doc drive fires within a few ms
        // of launch. The full 1142-account decode+map moves OFF the launch main
        // thread — it materializes into `accountSets` via the background
        // `loadCatalogs` that `init()` dispatches immediately after this call
        // (its disk-cache branch decodes the full blob off-main and posts
        // `.TPPCatalogDidLoad`). Consumers block on the EXISTING
        // `Account.awaitReady()` gate, which reads `AccountStateStore` keyed by
        // uuid and so survives the slim→full Account-instance swap.
        //
        // Gated on `registryCache.hasFreshCatalogData` (full-cache freshness): the slim
        // snapshot carries no separate metadata, so a truly-expired cache still
        // falls through to the no-op below rather than hydrating stale data.
        if registryCache.hasFreshCatalogData(hash: hash), hydrateSlimLaunchSnapshot(hash: hash) {
            refreshSlimLaunchSnapshotOffMain(hash: hash)
            return
        }
        // Slow path: no slim snapshot yet (first launch after this ships, or a
        // fresh install whose catalog cache was just written). Hydrate the full
        // set synchronously exactly as before so behaviour is unchanged on that
        // one launch, then seed a slim snapshot off-main so the NEXT launch takes
        // the fast path above.
        guard registryCache.hasFreshCatalogData(hash: hash),
              let cachedData = registryCache.readCatalogData(hash: hash) else {
            return
        }
        hydrateFullAccountSets(fromCatalogData: cachedData, hash: hash)
        refreshSlimLaunchSnapshotOffMain(hash: hash)
    }

    /// Decode the small `accounts_catalog_slim_<hash>.json` snapshot and hydrate
    /// the current + settings accounts into `slimAccountsByUUID` (NOT
    /// `accountSets` — see that property's doc for why). Drives each slim account
    /// to `.basicInfoLoaded` (only if still `.notLoaded`, so a state already
    /// advanced by a concurrent path is never knocked back) and fires the current
    /// account's auth-doc drive. Returns `false` when there is no slim snapshot,
    /// it is empty, or it fails to decode — the caller then takes the full sync
    /// path. CP-D1.
    private func hydrateSlimLaunchSnapshot(hash: String) -> Bool {
        guard let url = registryCache.slimSnapshotURL(hash: hash),
              FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else {
            return false
        }
        do {
            let feed = try OPDS2CatalogsFeed.fromData(data)
            let accounts = feed.catalogs.map {
                Account(publication: $0, imageCache: switchDeps.imageCache)
            }
            guard !accounts.isEmpty else { return false }
            // CP-D1 (Finding 5): the slim snapshot is written from the
            // then-current account at launch; a mid-session library switch does
            // NOT rewrite it, so a stale slim file can LACK the now-current
            // account (currentAccountId persisted in UserDefaults ≠ slim set).
            // If the current account is absent from the decoded slim set, fall
            // through to the full sync hydrate (return false) rather than taking
            // the fast path with a slim set that can't resolve `currentAccount`
            // — otherwise there'd be a transient nil-currentAccount window at
            // launch (spurious sign-in modals / empty library UI) that did not
            // exist pre-D1. Belt-and-suspenders alongside the setter refresh.
            if let currentId = currentAccountId,
               !accounts.contains(where: { $0.uuid == currentId }) {
                return false
            }
            storeSlimAccounts(accounts)
            for account in accounts {
                if case .notLoaded = switchDeps.accountStateStore.state(for: account.uuid) {
                    account._setState(.basicInfoLoaded)
                }
            }
            // Drive the current account's auth-doc so `awaitReady()` consumers
            // (audiobook open, token refresh, bookmark sync, CarPlay auth)
            // resolve without waiting on the full off-main materialization.
            // `currentAccount` resolves via `account(_:)`'s slim fallback.
            //
            // DEFERRED off this synchronous stack (was a direct call). This path
            // is reached from `AccountsManager.init` → `preloadAccountsFromDiskCacheSync`,
            // and on cold launch `AccountsManager()` is constructed INSIDE
            // `AppContainer._buildCachedAppContainer()`, which runs under
            // `AppContainer._cachedLock.withLock`. The drive transitively calls
            // `AppContainer.production()` again (`Account.fetchAuthenticationDocument`
            // → `.networkExecutor`), and re-entering the non-recursive
            // `OSAllocatedUnfairLock` on the same thread traps (`EXC_BREAKPOINT`)
            // — it crashed launch for every signed-in user (a logged-out sim has
            // no current account to drive, which is why it didn't reproduce there).
            // Hopping to the next main-runloop turn lets the container finish
            // building and release the lock first, so the re-entrant
            // `production()` returns the now-cached graph. The drive is an async
            // fire-and-forget network fetch, so a one-turn defer is behaviorally
            // inert for `awaitReady()` consumers (all of which run well after launch).
            DispatchQueue.main.async { [weak self] in
                self?.driveCurrentAccountAuthDocIfNeeded()
            }
            Log.info(#file, "CP-D1: slim launch snapshot hydrated \(accounts.count) accounts (hash=\(hash))")
            return true
        } catch {
            Log.warn(#file, "CP-D1: slim launch snapshot decode failed: \(error). Falling back to full sync hydrate.")
            return false
        }
    }

    /// The original synchronous full-hydrate path, factored out of
    /// `preloadAccountsFromDiskCacheSync` so the slow (no-slim-snapshot) launch
    /// keeps behaving exactly as before. Only advances still-`.notLoaded` uuids
    /// so a concurrently-advanced current account is never downgraded. CP-D1.
    private func hydrateFullAccountSets(fromCatalogData cachedData: Data, hash: String) {
        do {
            let feed = try OPDS2CatalogsFeed.fromData(cachedData)
            let accounts = feed.catalogs.map {
                Account(publication: $0, imageCache: switchDeps.imageCache)
            }
            mutateAccountSets { $0[hash] = accounts }
            // Account state-machine wiring (3.2.0): Phase 1 — drive every
            // preloaded account into `.basicInfoLoaded`. Display-only
            // consumers (Settings/Libraries) can render the row immediately;
            // critical-path readers `awaitReady()` continue blocking until
            // the auth-doc transition completes.
            for account in accounts {
                if case .notLoaded = switchDeps.accountStateStore.state(for: account.uuid) {
                    account._setState(.basicInfoLoaded)
                }
            }
            Log.info(#file, "Pre-loaded \(accounts.count) accounts from disk cache (sync, hash=\(hash))")
        } catch {
            // Best-effort. If the cached blob is corrupt or schema-shifted,
            // we silently fall through to the async network refresh.
            Log.warn(#file, "Sync disk-cache pre-load failed: \(error). Will refresh from network async.")
        }
    }

    /// Thread-safe write of the slim launch-hydration accounts. CP-D1.
    private func storeSlimAccounts(_ accounts: [Account]) {
        slimAccountsLock.lock()
        defer { slimAccountsLock.unlock() }
        for account in accounts {
            slimAccountsByUUID[account.uuid] = account
        }
    }

    /// Thread-safe read of a slim launch-hydration account. CP-D1.
    private func slimAccount(_ uuid: String) -> Account? {
        slimAccountsLock.lock()
        defer { slimAccountsLock.unlock() }
        return slimAccountsByUUID[uuid]
    }

    /// Rebuild the slim launch snapshot from the authoritative full on-disk
    /// catalog cache, OFF the main thread. Best-effort: keeps the slim file in
    /// sync with the latest current + settings selection so the NEXT cold
    /// launch's synchronous hydrate reflects it. Reads the full blob and
    /// serializes off-main so no launch main-thread time is spent here. CP-D1.
    private func refreshSlimLaunchSnapshotOffMain(hash: String) {
        // Skip the background slim-snapshot write under XCTest. A detached
        // best-effort file write outlives the test (cooperative cancel can't
        // stop an in-progress `Data.write`), leaking an
        // `accounts_catalog_slim_<hash>.json` — whose slim uuids are the writer
        // test's, not the reader's — into a sibling test's launch, flipping it
        // onto the slim fast path with a non-matching current account. Same
        // cross-test-pollution rationale + mechanism as `_trackCrawlTask`'s
        // XCTest gate (BR-2: runtime env gate, not `#if DEBUG`, so no
        // conditional compilation on the production path). Production always
        // refreshes; tests seed slim snapshots explicitly.
        guard !Self._isRunningUnderXCTest else { return }
        spawnOwnedCrawlTask(priority: .utility, detached: true) { [weak self] in
            guard let self, !Task.isCancelled else { return }
            guard let data = self.registryCache.readCatalogData(hash: hash) else { return }
            guard !Task.isCancelled else { return }
            self.writeSlimSnapshot(fromFullCatalogData: data, hash: hash)
        }
    }

    /// Carve the current + settings accounts out of the full catalog blob and
    /// persist them as a small OPDS2 feed at `accounts_catalog_slim_<hash>.json`.
    /// Runs on a background queue (never the launch main thread). CP-D1.
    private func writeSlimSnapshot(fromFullCatalogData data: Data, hash: String) {
        let keepUUIDs = slimSnapshotUUIDs()
        guard !keepUUIDs.isEmpty, let url = registryCache.slimSnapshotURL(hash: hash) else { return }
        guard let carved = Self.carveSlimFeed(fromFullCatalogData: data, keepUUIDs: keepUUIDs) else {
            Log.warn(#file, "CP-D1: slim snapshot carve produced no data (hash=\(hash))")
            return
        }
        do {
            try carved.write(to: url)
            Log.info(#file, "CP-D1: slim launch snapshot written (\(keepUUIDs.count) uuids, \(carved.count) bytes, hash=\(hash))")
        } catch {
            Log.warn(#file, "CP-D1: slim snapshot write failed: \(error)")
        }
    }

    /// The uuids the slim launch snapshot must carry: the current account plus
    /// `settingsAccountIdsList` (which itself always includes the current
    /// account + the SimplyE instant-classics default per `TPPSettings+SE`). CP-D1.
    private func slimSnapshotUUIDs() -> Set<String> {
        var uuids = Set<String>()
        if let current = currentAccountId {
            uuids.insert(current)
        }
        for uuid in settings.settingsAccountIdsList {
            uuids.insert(uuid)
        }
        return uuids
    }

    /// Pure raw-JSON carve: parse the full OPDS2 catalog blob with
    /// `JSONSerialization`, keep only the `catalogs` entries whose
    /// `metadata.id` is in `keepUUIDs`, and re-serialize the (otherwise
    /// unchanged) root. Carving the raw JSON rather than re-encoding decoded
    /// models preserves the exact date-string format `OPDS2CatalogsFeed.fromData`'s
    /// custom date decoder expects, so the slim snapshot round-trips through the
    /// same reader with no encoder date-strategy hazard. Returns nil if the blob
    /// isn't the expected shape or no entries match. Static + pure so it is
    /// unit-testable without a manager or disk. CP-D1.
    static func carveSlimFeed(fromFullCatalogData data: Data, keepUUIDs: Set<String>) -> Data? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let catalogs = root["catalogs"] as? [[String: Any]] else {
            return nil
        }
        let kept = catalogs.filter { entry in
            guard let metadata = entry["metadata"] as? [String: Any],
                  let id = metadata["id"] as? String else { return false }
            return keepUUIDs.contains(id)
        }
        guard !kept.isEmpty else { return nil }
        var slimRoot = root
        slimRoot["catalogs"] = kept
        return try? JSONSerialization.data(withJSONObject: slimRoot)
    }

    // MARK: – Thread‐safe accountSets access

    private func performRead<T>(_ block: () -> T) -> T {
        return accountSetsLock.sync {
            block()
        }
    }

    private func performWrite(_ block: @escaping () -> Void) {
        // Carry the non-Sendable `block` into the barrier block via a
        // documented box. `@unchecked Sendable` invariant: `block` is
        // invoked exactly once, on the serial `.barrier` of the concurrent
        // `accountSetsLock`, never concurrently — the same execution
        // contract this method already guaranteed. Timing is unchanged.
        let box = VoidWorkBox(work: block)
        accountSetsLock.async(flags: .barrier) {
            box.work()
        }
    }

    /// The ONLY sanctioned way to mutate `accountSets`. Applies `mutate` to the
    /// dictionary inside the `accountSetsLock` barrier, then rebuilds the
    /// `accountByUUID` index in the same critical section so the two can never
    /// desync. Every write site (preload hydrate, network load, the test seams)
    /// goes through here — adding a new write that bypasses it would silently
    /// break `account(_:)` lookups, which the index-coherence test guards against.
    private func mutateAccountSets(_ mutate: @escaping (inout [String: [Account]]) -> Void) {
        // Carry the non-Sendable `mutate` into the `@Sendable` barrier block via
        // a documented box (mirrors `performWrite`'s `VoidWorkBox`). Same serial-
        // barrier execution contract; timing unchanged.
        let box = AccountSetsMutationBox(mutate: mutate)
        accountSetsLock.async(flags: .barrier) {
            box.mutate(&self.accountSets)
            self.accountByUUID = AccountsManager.buildAccountIndex(self.accountSets)
        }
    }

    /// Pure: flatten `accountSets` into a `uuid → Account` index. When a UUID
    /// appears in more than one bucket (e.g. an account present in both the
    /// prod and beta registries), the last-enumerated wins — equivalent to the
    /// nondeterministic "first across `values`" the prior linear scan returned.
    static func buildAccountIndex(_ sets: [String: [Account]]) -> [String: Account] {
        var index = [String: Account]()
        for accounts in sets.values {
            for account in accounts {
                index[account.uuid] = account
            }
        }
        return index
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
            refreshSlimLaunchSnapshotOffMain(hash: self.accountSet)
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
        if let full = performRead({ accountByUUID[uuid] }) {
            return full
        }
        // CP-D1 launch-hydration fallback: before the full 1142-account list has
        // materialized off-main, the slim snapshot backs current-account
        // resolution so `currentAccount` (and its auth-doc drive) work in the
        // pre-materialization window. Full instances take precedence (checked
        // first, above) once present.
        return slimAccount(uuid)
    }

    func accounts(_ key: String? = nil) -> [Account] {
        return performRead {
            let k = key ?? self.accountSet
            return self.accountSets[k] ?? []
        }
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
        let seedKey = self.accountSet
        mutateAccountSets {
            var seeded = $0[seedKey] ?? []
            seeded.removeAll { $0.uuid == account.uuid }
            seeded.append(account)
            $0[seedKey] = seeded
        }
        let previousId = defaults.string(forKey: currentAccountIdentifierKey)
        defaults.set(account.uuid, forKey: currentAccountIdentifierKey)
        return {
            self.mutateAccountSets {
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
        return performRead {
            !(self.accountSets[self.accountSet]?.isEmpty ?? true)
        }
    }

    // MARK: - Per-Account User Credentials

    /// Cache of per-library `TPPUserAccount` instances. Each instance has
    /// immutable keychain keys, eliminating the TOCTOU race that the
    /// singleton's mutable `libraryUUID` pattern was subject to.
    private var userAccounts = [String: TPPUserAccount]()
    private let userAccountsLock = NSLock()

    /// Last account returned from `currentUserAccount`. Used to ride out the
    /// brief windows where `currentAccountId` is nil during an account switch
    /// — without this, consumers observe a transiently-unauthenticated state
    /// on an account that IS signed in, and fire spurious sign-in modals.
    private var lastKnownCurrentUserAccount: TPPUserAccount?

    /// Sentinel UUID for the "no account selected" placeholder. Not a real
    /// library UUID — keychain reads for this instance return nil, so
    /// hasCredentials() deterministically returns false.
    private static let noAccountSentinelUUID = "__no_account_selected__"

    /// Placeholder returned by `currentUserAccount` only on a truly fresh
    /// install before any account has ever been selected. Lazily created so
    /// app launch doesn't pay for a keychain-probed instance.
    private lazy var noAccountPlaceholder: TPPUserAccount = TPPUserAccount(
        libraryUUID: AccountsManager.noAccountSentinelUUID
    )

    /// Returns a library-scoped `TPPUserAccount` instance. Creates and
    /// caches a new one on first access for a given UUID.
    func userAccount(for libraryUUID: String) -> TPPUserAccount {
        userAccountsLock.lock()
        defer { userAccountsLock.unlock() }
        if let existing = userAccounts[libraryUUID] {
            return existing
        }
        let account = TPPUserAccount(libraryUUID: libraryUUID)
        userAccounts[libraryUUID] = account
        return account
    }

    /// Convenience for the current library's user account.
    ///
    /// Thread-safety note: `currentAccountId` can transiently be nil during an
    /// account switch (the old id is cleared before the new id is assigned).
    /// If we blindly fell back to a fresh/empty instance in that window,
    /// consumers like MyBooksDownloadCenter would observe `hasCredentials ==
    /// false` on an account that IS signed in and fire a spurious login modal.
    /// We cache the last-resolved account and return it during the nil window
    /// instead. The placeholder path only fires on a true fresh-install state
    /// where no account has ever been selected.
    var currentUserAccount: TPPUserAccount {
        if let id = currentAccountId {
            let account = userAccount(for: id)
            userAccountsLock.lock()
            lastKnownCurrentUserAccount = account
            userAccountsLock.unlock()
            return account
        }
        userAccountsLock.lock()
        let last = lastKnownCurrentUserAccount
        userAccountsLock.unlock()
        return last ?? noAccountPlaceholder
    }

    // MARK: – Load logic

    /// Adds a completion handler for the given catalog hash,
    /// returns true if a load is already underway.
    private func addLoadingHandler(for hash: String, _ handler: ((Bool) -> Void)?) -> Bool {
        var alreadyLoading = false
        loadingHandlersQueue.sync {
            alreadyLoading = loadingCompletionHandlers[hash] != nil
        }

        guard !alreadyLoading else {
            if let h = handler {
                // Box the non-Sendable handler across the `@Sendable` barrier.
                let box = LoadCompletionBox(handler: h)
                loadingHandlersQueue.async(flags: .barrier) { [weak self] in
                    self?.loadingCompletionHandlers[hash]?.append(box.handler)
                }
            }
            return true
        }

        // first request for this hash
        let box = handler.map { LoadCompletionBox(handler: $0) }
        loadingHandlersQueue.async(flags: .barrier) {
            self.loadingCompletionHandlers[hash] = box.map { [$0.handler] } ?? []
        }
        return false
    }

    /// Calls & clears all handlers for the given hash
    private func callAndClearLoadingHandlers(for hash: String, _ success: Bool) {
        var handlers: [(Bool) -> Void] = []
        loadingHandlersQueue.sync {
            handlers = loadingCompletionHandlers[hash] ?? []
        }
        loadingHandlersQueue.async(flags: .barrier) {
            self.loadingCompletionHandlers[hash] = nil
        }
        handlers.forEach { $0(success) }
    }

    /// Public entrypoint - implements stale-while-revalidate pattern
    /// 1. If data is in memory, return immediately (refresh in background if stale)
    /// 2. If data is on disk and not expired, load it immediately and refresh in background
    /// 3. If no cache or expired, fetch from network
    func loadCatalogs(completion: ((Bool) -> Void)?) {
        let targetUrl = TPPConfiguration.customUrl()
            ?? (settings.useBetaLibraries
                    ? TPPConfiguration.betaUrl
                    : TPPConfiguration.prodUrl)
        let hash = targetUrl.absoluteString
            .md5()
            .base64EncodedStringUrlSafe()
            .trimmingCharacters(in: ["="])

        // 1. If already loaded in memory, return immediately
        if performRead({ self.accountSets[hash]?.isEmpty == false }) {
            // State-machine wiring (3.2.0): the cold path drives the
            // current account's LoadState past `.basicInfoLoaded` via
            // `loadAccountSetsAndAuthDoc → fetchAuthDocumentWithStateMachine`.
            // The warm path historically returned here without firing the
            // auth-doc transition, leaving every `awaitReady()` caller
            // (audiobook open, token refresh, bookmark sync, CarPlay auth)
            // blocked forever on cold-launch for already-signed-in users
            // whose accounts were populated by `preloadAccountsFromDiskCacheSync`.
            // Restore the invariant: any account in `accountSets[hash]`
            // must reach a terminal LoadState. The single-flight guard
            // inside `fetchAuthDocumentWithStateMachine` dedupes against
            // any concurrent invocation from refreshInBackground or a
            // library switch.
            driveCurrentAccountAuthDocIfNeeded()
            completion?(true)
            // Still refresh in background if stale
            if registryCache.isCatalogStale(hash: hash) {
                refreshInBackground(targetUrl: targetUrl, hash: hash)
            }
            return
        }

        // 2. Try disk cache first (stale-while-revalidate)
        if registryCache.hasFreshCatalogData(hash: hash),
           let cachedData = registryCache.readCatalogData(hash: hash) {
            Log.info(#file, "Loading catalogs from cache (stale-while-revalidate), hash=\(hash), dataSize=\(cachedData.count)")

            // dedupe concurrent loads for initial cache load
            if addLoadingHandler(for: hash, completion) { return }

            loadAccountSetsAndAuthDoc(fromCatalogData: cachedData, key: hash) { [weak self] success in
                NotificationCenter.default.post(name: .TPPCatalogDidLoad, object: nil)
                self?.callAndClearLoadingHandlers(for: hash, success)
            }

            // Always refresh in background when loading from cache
            refreshInBackground(targetUrl: targetUrl, hash: hash)
            return
        }

        // 2.5 + 3. No disk cache: the build-time bundled snapshot fast-path
        // (PP-4258) for immediate library-picker display, THEN the network
        // fetch that supersedes it.
        //
        // SINGLE dedupe guard covering BOTH the bundled decode and the network
        // fetch. It is placed ABOVE the bundled branch (so a concurrent second
        // caller short-circuits HERE, before paying the ~2.4 MB bundled decode
        // — the double-decode bug) and is deliberately NOT re-checked before
        // `fetchFromNetwork` below. Re-checking there is the Phase 1a
        // regression: the first caller would observe its OWN registration and
        // `return` before the network ever fires, stranding the picker on
        // stale bundled data until the next launch. The previous redundant
        // guard immediately before `fetchFromNetwork` has been removed.
        if addLoadingHandler(for: hash, completion) { return }

        // Hop the bundled decode + network kickoff OFF the calling thread. On
        // cold first launch `loadCatalogs` is reachable from
        // `TPPAppDelegate.presentFirstRunFlowIfNeeded` (@MainActor); decoding
        // the ~2.4 MB snapshot there would block the main thread. Runs at
        // `.utility` (matching the init crawl arms) and is tracked via
        // `_trackCrawlTask` so `cancelBackgroundWork()` cancels it — which
        // keeps the `Task.isCancelled` guard below meaningful (mirrors the
        // crawl tasks spawned inside `fetchFromNetwork`).
        spawnOwnedCrawlTask(priority: .utility, detached: true, firstRun: true) { [weak self] in
            guard let self = self else { return }

            // 2.5. Bundled snapshot fast-path. The `Task.isCancelled` guard
            // mirrors `fetchFromNetwork`'s post-await branch: a cancelled
            // first-run task must not write the bundled bytes over a
            // fixture-seeded test's on-disk cache.
            if let bundledData = BundledRegistrySnapshot.load(resolver: self.snapshotResourceResolver),
               !Task.isCancelled {
                Log.info(#file, "First launch — loading bundled registry snapshot for hash \(hash), dataSize=\(bundledData.count)")
                // isBundled=true keeps the cache flagged as non-authoritative so
                // every subsequent loadCatalogs call still triggers refresh until
                // a real network response overwrites the metadata.
                self.registryCache.writeCatalogData(bundledData, hash: hash, isBundled: true)
                self.loadAccountSetsAndAuthDoc(fromCatalogData: bundledData, key: hash) { _ in
                    NotificationCenter.default.post(name: .TPPCatalogDidLoad, object: nil)
                }
            }

            // 3. Network fetch — ALWAYS fires (the bundled snapshot is a
            // fast-path, not a replacement). The caller's completion is cleared
            // on network completion via `callAndClearLoadingHandlers` inside
            // `fetchFromNetwork`, NOT on the bundled load (whose completion
            // above is `_ in`).
            if Task.isCancelled { return }
            Log.debug(#file, "Loading catalogs from network for hash \(hash)…")
            self.fetchFromNetwork(targetUrl: targetUrl, hash: hash)
        }
    }

    /// Fetches catalog data using the first-page fast path:
    /// 1. Fetch first page (~35KB, ~260ms) → display immediately
    /// 2. Paginate remaining pages in background → update cache when done
    /// Falls back to a direct GET if even the first page fails.
    private func fetchFromNetwork(targetUrl: URL, hash: String) {
        // Test-observability (env-gated, no-op outside XCTest — see
        // `_fetchFromNetworkCount`): record that the network fetch fired so the
        // first-run-decode tests can prove the bundled-snapshot dedupe did not
        // swallow it (Phase 1a regression guard).
        if Self._isRunningUnderXCTest {
            _fetchFromNetworkCountLock.lock()
            _fetchFromNetworkCount += 1
            _fetchFromNetworkCountLock.unlock()
        }

        // A developer-configured explicit registry URL is fetched verbatim via a
        // direct GET — no crawlable rewrite — so the exact endpoint (e.g. a bare
        // /libraries feed) is exercised. Gated behind a custom registry being set;
        // production registry loading still uses the crawler below.
        if TPPConfiguration.customRegistryIsExplicitURL() {
            fallbackFetchFromNetwork(targetUrl: targetUrl, hash: hash)
            return
        }
        spawnOwnedCrawlTask(priority: .userInitiated, detached: false) { [weak self] in
            guard let self = self else { return }
            Log.debug(#file, "Fetching catalogs via first-page fast path for hash \(hash)")

            let crawler = LibraryRegistryCrawler(fetcher: URLSessionCrawlerFetcher(), hash: hash)

            // Step 1: Fetch first page for immediate display
            let firstPageResult = await crawler.crawlFirstPage(baseURL: targetUrl)
            // Cooperative cancellation observation (swarm_4b64e4e0 Fix 2):
            // if `cancelBackgroundWork()` was called while we were awaiting
            // `crawlFirstPage`, drop the result on the floor instead of
            // writing through to `accountSets` / `registryCache.writeCatalogData`.
            // Without this, a test that `_resetForTesting()`s the AppContainer
            // mid-fetch still sees the prior `AccountsManager`'s response
            // land in its caches a few ms later.
            if Task.isCancelled { return }

            switch firstPageResult {
            case .success(let firstPageData, let firstPage):
                // Display first page immediately
                self.registryCache.writeCatalogData(firstPageData, hash: hash)
                self.loadAccountSetsAndAuthDoc(fromCatalogData: firstPageData, key: hash) { success in
                    NotificationCenter.default.post(name: .TPPCatalogDidLoad, object: nil)
                    self.callAndClearLoadingHandlers(for: hash, success)
                }

                // Step 2: Paginate remaining pages in background
                // Use the parsed firstPage (not re-parsed data) to check nextPageURL,
                // because serializeAsCatalogsFeed drops pagination links.
                guard firstPage.nextPageURL != nil else {
                    Log.info(#file, "Single-page registry response (\(firstPage.catalogs.count) libraries) — no pagination needed")
                    self.triggerCatalogPreload()
                    break
                }

                Log.info(#file, "Registry has more pages (first page: \(firstPage.catalogs.count) of \(firstPage.metadata.numberOfItems ?? -1)) — paginating in background")
                // Carry the non-Sendable crawler into the nested pagination Task
                // via a documented box (used strictly sequentially — see
                // `CrawlerHandoffBox`). `firstPage`/`targetUrl` are Sendable.
                let crawlerBox = CrawlerHandoffBox(crawler: crawler)
                self.spawnOwnedCrawlTask(priority: .utility, detached: false) { [weak self] in
                    guard let self = self else { return }

                    let remainingResult = await crawlerBox.crawler.crawlRemainingPages(
                        firstPage: firstPage,
                        baseURL: targetUrl,
                        existingPublications: firstPage.catalogs,
                        feedMetadata: firstPage.metadata
                    )

                    if case .success(let fullData) = remainingResult {
                        let fullCount = (try? OPDS2CatalogsFeed.fromData(fullData))?.catalogs.count ?? -1
                        Log.info(#file, "Background pagination complete: \(fullCount) total libraries cached")
                        self.registryCache.writeCatalogData(fullData, hash: hash)
                        self.loadAccountSetsAndAuthDoc(fromCatalogData: fullData, key: hash) { _ in
                            NotificationCenter.default.post(name: .TPPCatalogDidLoad, object: nil)
                        }
                    }
                    self.triggerCatalogPreload()
                }

            case .noChanges:
                self.callAndClearLoadingHandlers(for: hash, true)

            case .failure(let error):
                Log.info(#file, "First page crawl failed: \(error), falling back to direct GET to \(targetUrl)")
                self.fallbackFetchFromNetwork(targetUrl: targetUrl, hash: hash)
            }
        }
    }

    /// Fallback direct GET when crawler fails on first launch.
    ///
    /// PP-4754: the GET completion used to be a fire-and-forget closure the
    /// test-boundary drain could not await (the last un-drainable write channel).
    /// It now runs inside an OWNED `spawnOwnedCrawlTask` bridging the callback GET
    /// via the existing `ContinuationGuard`-protected `async throws` `GET` (so
    /// the continuation resumes exactly once even on a -999 cancel). The
    /// post-await `Task.isCancelled` guard drops a late response instead of
    /// late-writing `AccountStateStore.shared` into the next test — now that the
    /// task is owned+cancelled, this fully supersedes the prior DEBUG
    /// `_explicitCancelCalled` completion guard.
    private func fallbackFetchFromNetwork(targetUrl: URL, hash: String) {
        spawnOwnedCrawlTask(priority: .utility, detached: true) { [weak self] in
            guard let self = self else { return }
            do {
                let (data, _) = try await self.networkExecutor.GET(targetUrl, useTokenIfAvailable: false)
                if Task.isCancelled { return }
                self.registryCache.writeCatalogData(data, hash: hash)
                self.loadAccountSetsAndAuthDoc(fromCatalogData: data, key: hash) { success in
                    NotificationCenter.default.post(name: .TPPCatalogDidLoad, object: nil)
                    self.callAndClearLoadingHandlers(for: hash, success)
                }
            } catch {
                if Task.isCancelled { return }
                Log.error(#file, "Failed to load catalogs from network: \(error.localizedDescription)")
                if let data = self.registryCache.readCatalogData(hash: hash) {
                    Log.info(#file, "Using cached catalog data as fallback after network failure")
                    self.loadAccountSetsAndAuthDoc(fromCatalogData: data, key: hash) { success in
                        NotificationCenter.default.post(name: .TPPCatalogDidLoad, object: nil)
                        self.callAndClearLoadingHandlers(for: hash, success)
                    }
                } else {
                    Log.error(#file, "No cached catalog data available, catalog load failed completely")
                    self.callAndClearLoadingHandlers(for: hash, false)
                }
            }
        }
    }

    /// Refreshes catalog data in background using the incremental crawler.
    /// Falls back to a direct GET if the crawlable endpoint fails.
    private func refreshInBackground(targetUrl: URL, hash: String) {
        // Explicit dev registry URLs bypass the incremental crawler and refresh
        // via a verbatim direct GET, mirroring fetchFromNetwork.
        if TPPConfiguration.customRegistryIsExplicitURL() {
            fallbackFetchFromNetwork(targetUrl: targetUrl, hash: hash)
            return
        }
        spawnOwnedCrawlTask(priority: .utility, detached: false) { [weak self] in
            guard let self = self else { return }
            Log.debug(#file, "Starting background refresh (crawl) for catalog hash \(hash)")

            // Parse existing cached publications for merge
            let existingPubs: [OPDS2Publication]
            let existingMetadata: OPDS2CatalogsFeed.Metadata?
            if let cachedData = self.registryCache.readCatalogData(hash: hash),
               let feed = try? OPDS2CatalogsFeed.fromData(cachedData) {
                existingPubs = feed.catalogs
                existingMetadata = feed.metadata
            } else {
                existingPubs = []
                existingMetadata = nil
            }

            let crawler = LibraryRegistryCrawler(fetcher: URLSessionCrawlerFetcher(), hash: hash)
            let result = await crawler.crawl(
                baseURL: targetUrl,
                existingPublications: existingPubs,
                feedMetadata: existingMetadata
            )

            switch result {
            case .success(let data):
                let pubCount = (try? OPDS2CatalogsFeed.fromData(data))?.catalogs.count ?? -1
                Log.info(#file, "Background crawl successful for hash \(hash), \(pubCount) libraries in result, dataSize=\(data.count)")
                self.registryCache.writeCatalogData(data, hash: hash)
                self.loadAccountSetsAndAuthDoc(fromCatalogData: data, key: hash) { [weak self] _ in
                    NotificationCenter.default.post(name: .TPPCatalogDidLoad, object: nil)
                    // Preload catalogs for active accounts
                    self?.triggerCatalogPreload()
                }

            case .noChanges:
                Log.debug(#file, "Background crawl found no changes for hash \(hash)")
                // Still preload catalogs — they may not be cached yet
                self.triggerCatalogPreload()

            case .failure(let error):
                Log.debug(#file, "Background crawl failed for hash \(hash): \(error.localizedDescription)")
                // Fallback: try direct GET (old behavior)
                self.fallbackDirectRefresh(targetUrl: targetUrl, hash: hash)
            }
        }
    }

    /// Fallback to direct GET when crawlable endpoint fails. PP-4754: owned +
    /// drainable, bridging the callback GET via the `ContinuationGuard`-protected
    /// `async throws` `GET` — see `fallbackFetchFromNetwork` for the rationale.
    private func fallbackDirectRefresh(targetUrl: URL, hash: String) {
        spawnOwnedCrawlTask(priority: .utility, detached: true) { [weak self] in
            guard let self = self else { return }
            do {
                let (data, _) = try await self.networkExecutor.GET(targetUrl, useTokenIfAvailable: false)
                if Task.isCancelled { return }
                Log.info(#file, "Fallback direct refresh successful for hash \(hash)")
                self.registryCache.writeCatalogData(data, hash: hash)
                self.loadAccountSetsAndAuthDoc(fromCatalogData: data, key: hash) { _ in
                    NotificationCenter.default.post(name: .TPPCatalogDidLoad, object: nil)
                }
            } catch {
                Log.debug(#file, "Fallback direct refresh also failed for hash \(hash): \(error.localizedDescription)")
            }
        }
    }

    /// Triggers catalog feed preloading for active accounts.
    private func triggerCatalogPreload() {
        spawnOwnedCrawlTask(priority: .utility, detached: false) { [weak self] in
            guard let self = self else { return }
            await self.catalogPreloader.preloadCatalogs(
                currentAccount: self.currentAccount,
                recentAccountUUIDs: self.settings.settingsAccountIdsList,
                accountProvider: { self.account($0) }
            )
        }
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

    // MARK: – Auth Document fetch with state-machine wiring

    /// Wraps `Account.loadAuthenticationDocument` with:
    /// 1. Per-UUID single-flight guard — the second concurrent caller for
    ///    the same UUID does NOT fire a duplicate HTTP request; the state
    ///    stream's broadcast (`CurrentValueSubject`) ensures both callers
    ///    observe the same eventual transition.
    /// 2. State-machine transitions — `.detailsLoading` before the fetch;
    ///    `.detailsLoaded(details)` on success; `.detailsFailed(...)` on
    ///    failure. New code that reads `account.details` must go through
    ///    `Account.awaitReady()`, which observes these transitions.
    ///
    /// Exposed `internal` so contract-snapshot tests can drive the wiring
    /// path directly without going through the full `loadCatalogs` cycle.
    /// Whether an auth-doc fetch completion may write its own terminal
    /// (`.detailsLoaded`/`.detailsFailed`). Returns `false` when the account has
    /// since been evicted by a library switch — the deliberate, newer
    /// `.detailsEvicted` terminal supersedes the in-flight fetch this completion
    /// belonged to, and awaiters rely on it to fail-fast + redrive on return.
    /// Pure so the guard is unit-testable without a controllable async fetch.
    /// CP-D1 (swarm_27c181b5).
    static func fetchCompletionMayWriteTerminal(currentState: Account.LoadState) -> Bool {
        if case .detailsEvicted = currentState { return false }
        return true
    }

    internal func fetchAuthDocumentWithStateMachine(
        for account: Account,
        completion: @escaping (Bool) -> Void
    ) {
        #if DEBUG
        // Test-isolation (entry guard): once this manager was explicitly torn
        // down (`cancelBackgroundWork()` in `AppContainer._resetForTesting()`),
        // it must not drive any auth-doc state — neither the synchronous
        // `.detailsLoading` below nor the async terminal write. Otherwise a
        // late/deferred drive (`driveCurrentAccountAuthDocIfNeeded` dispatched
        // via `DispatchQueue.main.async`) fires on a later runloop turn, after
        // the next test's `AccountStateStore` reset, keyed by a fixture-shared
        // library UUID, and pollutes whichever Accounts test runs next (the
        // order-dependent flakes in AccountsManagerLaunchSnapshotTests /
        // AccountsManagerStateMachineWiringTests). Production is UNAFFECTED:
        // `_explicitCancelCalled` and `cancelBackgroundWork()` are `#if DEBUG`
        // test-only (the latter is reachable only from `_resetForTesting()`).
        if _explicitCancelCalled {
            completion(false)
            return
        }
        #endif

        let now = Date()
        inflightAuthDocLock.lock()
        let existingStart = inflightAuthDocFetches[account.uuid]
        let isStaleWedge: Bool
        if let existingStart {
            isStaleWedge = now.timeIntervalSince(existingStart) >= Self.authDocInflightTimeout
        } else {
            isStaleWedge = false
        }
        // Claim (or re-claim) the slot unless a genuinely-recent fetch owns it.
        let deduping = existingStart != nil && !isStaleWedge
        if !deduping {
            inflightAuthDocFetches[account.uuid] = now
        }
        inflightAuthDocLock.unlock()

        if deduping {
            // A fresh fetch for this UUID is already in flight. Don't fire a
            // duplicate HTTP request — the state stream's broadcast covers
            // multi-consumer observation. Caller's completion gets `true`
            // so the calling DispatchGroup (if any) balances.
            completion(true)
            return
        }

        if isStaleWedge {
            // The prior in-flight fetch never reported back (its network
            // completion was dropped) — the account is wedged at
            // `.detailsLoading`. We reclaimed the slot above; re-fire the fetch
            // so `awaitReady()` callers aren't stuck forever (HelpSpot #18414).
            // Re-entering `.detailsLoading` below is the retryable reset: the
            // stream re-broadcasts and the fresh fetch drives a real terminal.
            Log.warn(#file, "Auth-doc fetch for \(account.uuid) was wedged in-flight beyond \(Self.authDocInflightTimeout)s — reclaiming and re-firing")
        }

        account._setState(.detailsLoading)
        account.loadAuthenticationDocument(using: self.currentUserAccount) { [weak self] success in
            guard let self = self else {
                completion(success)
                return
            }
            self.inflightAuthDocLock.lock()
            self.inflightAuthDocFetches.removeValue(forKey: account.uuid)
            self.inflightAuthDocLock.unlock()

            #if DEBUG
            // Test-isolation (completion guard): companion to the entry guard —
            // an auth-doc fetch that was already IN FLIGHT when this manager was
            // torn down must not land its terminal `_setState` after the test
            // boundary. Suppress the write; still balance the caller's completion.
            // (DEBUG-only — see entry guard; production is unaffected.)
            if self._explicitCancelCalled {
                completion(success)
                return
            }
            #endif

            // A fetch that was SUPERSEDED by a library switch must not overwrite
            // the eviction marker the `currentAccount` setter wrote. Sequence
            // (CP-D1, swarm_27c181b5): the setter cancels this account's in-flight
            // fetch (`cancelNonEssentialTasks`) THEN writes
            // `.detailsEvicted(.libraryDeselected)`; this cancellation completion
            // then fires ASYNC with `success == false` (NSURLError -999). Without
            // this guard it clobbers `.detailsEvicted` with
            // `.detailsFailed(.authDocumentFetchFailed)`, and on switch-back
            // `driveCurrentAccountAuthDocIfNeeded` reads `.detailsFailed` → the
            // "genuine failure, don't redrive" arm → `awaitReady()` consumers
            // (audiobook open, token refresh, bookmark sync, CarPlay auth) stay
            // stuck (the regression class PR #1021 split the enum to prevent). A
            // switch-cancellation is NOT a genuine auth failure — the deliberate,
            // newer `.detailsEvicted` terminal must win. Applies to success too:
            // a fetch that landed just before cancellation must not resurrect the
            // now-non-current account.
            if AccountsManager.fetchCompletionMayWriteTerminal(
                currentState: switchDeps.accountStateStore.state(for: account.uuid)
            ) {
                if success, let details = account.details {
                    account._setState(.detailsLoaded(details))
                } else {
                    account._setState(.detailsFailed(
                        .authDocumentFetchFailed(underlyingDescription: "loadAuthenticationDocument returned false")
                    ))
                }
            }
            completion(success)
        }
    }

    /// Fires `fetchAuthDocumentWithStateMachine` for the current account
    /// when its `LoadState` is non-terminal. Used by the `loadCatalogs`
    /// warm-path to close the driver gap on cold-launch with a hot
    /// in-memory accountSets cache — without this, `awaitReady()` callers
    /// (audiobook open, token refresh, bookmark sync, CarPlay auth) hang
    /// indefinitely waiting for `.detailsLoaded`/`.detailsFailed` because
    /// nothing drives the transition. No-op when there is no current
    /// account, or when state has already settled at a terminal value
    /// (existing `awaitReady()` awaiters resolve via that terminal).
    /// Single-flight guard inside `fetchAuthDocumentWithStateMachine`
    /// dedupes against concurrent callers from `refreshInBackground` or
    /// the library-switch path.
    internal func driveCurrentAccountAuthDocIfNeeded() {
        guard let account = currentAccount else { return }
        switch switchDeps.accountStateStore.state(for: account.uuid) {
        case .detailsLoaded:
            return // terminal — `awaitReady()` awaiters resolve via the loaded details
        case .detailsEvicted(.libraryDeselected):
            // `.detailsEvicted(.libraryDeselected)` is the eviction marker
            // the `currentAccount` setter writes against the PRIOR uuid
            // when the user switches libraries. If this account is back to
            // being the current account, that marker is stale — re-drive
            // the auth-doc fetch so awaitReady() callers (audiobook open,
            // token refresh, bookmark sync, CarPlay auth) don't throw
            // `.evicted` forever after a swap-away/swap-back.
            //
            // PR #1021 (Module A, swarm_51f248d5) split this case off from
            // `.detailsFailed(.accountNotFound)` so the eviction marker
            // stops sharing storage with the genuine HTTP-404 load failure
            // below. Now a real `.accountNotFound` correctly hits the
            // `.detailsFailed` arm and does NOT redrive.
            //
            // FORWARD-COMPAT (added by swarm_18b0d071 wave 3 Module B):
            // This arm matches ONLY `.libraryDeselected` today because
            // that is the only known `AccountEvictionReason`. When a NEW
            // `AccountEvictionReason` case is added in the future, the
            // implementer must decide between two semantics:
            //   (a) "Re-drive on re-entry" — same semantics as
            //       `.libraryDeselected`: the eviction was triggered by a
            //       reversible UX action (library swap, sign-out-on-
            //       current, etc.). Add `case .detailsEvicted(.<newReason>):`
            //       to THIS arm (alongside `.libraryDeselected`) so
            //       awaitReady() callers can resume after re-entry.
            //   (b) "Do NOT re-drive" — the eviction was triggered by an
            //       irreversible state (account deleted server-side,
            //       policy expiry, etc.). Add a NEW
            //       `case .detailsEvicted(.<newReason>):` arm that
            //       `return`s (mirroring the `.detailsFailed` arm below at
            //       line ~983) so awaitReady() correctly surfaces the
            //       failure to consumers instead of looping fetches.
            // The `default` case is deliberately NOT added to this switch
            // — Swift's switch-exhaustiveness check will fail at compile
            // time when a new `AccountEvictionReason` case is added,
            // forcing the future implementer to make the (a)/(b) decision
            // explicit here rather than silently inheriting the wrong
            // behaviour from a default fall-through.
            break
        case .detailsFailed:
            return // genuine load failure — caller must retry explicitly
        case .notLoaded, .basicInfoLoaded, .detailsLoading:
            break
        }
        fetchAuthDocumentWithStateMachine(for: account) { _ in }
    }

    // MARK: – Parsing & notifying

    internal func loadAccountSetsAndAuthDoc(
        fromCatalogData data: Data,
        key hash: String,
        completion: @escaping (Bool) -> Void
    ) {
        // Box the non-Sendable `completion` so it can be invoked from the
        // `@Sendable` `group.notify(queue: .main)` block below. The handler is
        // still only called once, on `.main`; its thread-affinity contract is
        // unchanged — the box only satisfies the `@Sendable` boundary.
        let completionBox = LoadCompletionBox(handler: completion)
        do {
            let feed = try OPDS2CatalogsFeed.fromData(data)
            let hadAccount = self.currentAccount != nil
            let oldAccounts = self.accounts(hash)
            // Index old accounts by uuid ONCE so the carry-over loop below is a
            // dict lookup per new account instead of an O(n²) linear scan over
            // the ~1142-account registry snapshot (precedent: `accountByUUID`).
            // First-write-wins mirrors the prior `oldAccounts.first(where:)`
            // semantics exactly for the (rare) duplicate-uuid case.
            let oldAccountsByUUID = Dictionary(
                oldAccounts.map { ($0.uuid, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            let newAccounts = feed.catalogs.map { publication -> Account in
                // CP-D1 (Finding 4): on the slim→full LAUNCH materialization
                // (accountSets/`oldAccounts` empty for this uuid), REUSE the
                // existing slim instance instead of constructing a fresh one.
                // `details`/`authenticationDocument` are per-INSTANCE stored
                // properties, and the slim current-account drive fetches the
                // auth-doc onto the SLIM instance. If we swapped in a fresh
                // instance here, an in-flight slim fetch would land on the
                // discarded instance — leaving `currentAccount.details == nil`
                // while state reads `.detailsLoaded` (split-brain: legacy direct
                // readers `.details`/`.needsAuth`/`.loansUrl`/`.authSurfaceHosts`
                // see nil). Reusing keeps ONE Account per uuid so the fetch
                // completion lands on the current instance. BOUNDED to launch:
                // once `accountSets` is populated (warm / network-refresh path),
                // `oldAccountsByUUID` carries the auth-doc forward via the loop
                // below and fresh network data must win, so we do NOT reuse then.
                if oldAccountsByUUID[publication.metadata.id] == nil,
                   let slim = slimAccount(publication.metadata.id) {
                    return slim
                }
                return Account(publication: publication, imageCache: switchDeps.imageCache)
            }

            // Carry over authenticationDocument (and thus details) from old
            // accounts so a background refresh doesn't nil-out details while
            // the user is actively using the app. Also invalidate logo cache
            // entries when the thumbnail URL has changed.
            for newAccount in newAccounts {
                if let old = oldAccountsByUUID[newAccount.uuid] {
                    if let authDoc = old.authenticationDocument {
                        newAccount.authenticationDocument = authDoc
                    }
                    // Evict cached logo if the thumbnail URL changed
                    if old.logoUrl != newAccount.logoUrl {
                        switchDeps.imageCache.remove(for: newAccount.uuid)
                    }
                }
            }

            self.mutateAccountSets { $0[hash] = newAccounts }

            // Account state-machine wiring (3.2.0): Phase 1 — drive every
            // freshly-constructed account into its post-load terminal state.
            // The `authentication_document` carry-over path above means an
            // account that previously held `.detailsLoaded` continues to
            // observe loaded details (under the new instance). Accounts
            // without a carry-over auth doc fall back to `.basicInfoLoaded`
            // until the current-account fetch below drives them through
            // `.detailsLoading` → `.detailsLoaded` / `.detailsFailed`.
            for newAccount in newAccounts {
                if newAccount.authenticationDocument != nil,
                   let details = newAccount.details {
                    // Belt-and-suspenders `guard let`: `authenticationDocument`
                    // didSet populates `details` synchronously, but a
                    // mock-data publication could in principle land here
                    // with an authDoc that fails to construct details.
                    newAccount._setState(.detailsLoaded(details))
                } else if case .notLoaded = switchDeps.accountStateStore.state(for: newAccount.uuid) {
                    // CP-D1: preserve any state the slim launch snapshot already
                    // advanced this uuid to. The slim current-account drive can
                    // reach `.detailsLoading`/`.detailsLoaded` BEFORE this async
                    // full-list materialization runs; only stamp `.basicInfoLoaded`
                    // on a still-fresh uuid so the off-main full load can't knock a
                    // mid-flight current account back down and force a redundant
                    // re-drive. (No-op change for the cold-launch case where the
                    // store is fresh `.notLoaded` — this else-branch only fires for
                    // accounts without a carry-over auth doc, which were previously
                    // `.notLoaded`/`.basicInfoLoaded` anyway.)
                    newAccount._setState(.basicInfoLoaded)
                }
            }

            let group = DispatchGroup()

            let accountExistenceChanged = hadAccount != (self.currentAccount != nil)
            let currentAccountMissingDetails = self.currentAccount != nil && self.currentAccount?.details == nil

            if accountExistenceChanged || currentAccountMissingDetails, let current = self.currentAccount {
                group.enter()
                current.loadLogo()
                fetchAuthDocumentWithStateMachine(for: current) { _ in
                    if current.details?.needsAgeCheck ?? false {
                        group.enter()
                        self.ageCheck.verifyCurrentAccountAgeRequirement(
                            userAccountProvider: self.currentUserAccount,
                            currentLibraryAccountProvider: self
                        ) { _ in group.leave() }
                    }
                    group.leave()
                }
            }

            group.notify(queue: .main) {
                var mainFeed = URL(string: self.currentAccount?.catalogUrl ?? "")
                if let cur = self.currentAccount, cur.details?.needsAgeCheck ?? false {
                    mainFeed = cur.details?.defaultAuth?.coppaURL(isOfAge: true)
                }
                // Don't overwrite a valid accountMainFeedURL with nil.
                // On cache loads the current account may not have its catalogUrl
                // populated yet (auth doc hasn't loaded), but the URL from the
                // previous session is still valid in UserDefaults.
                if let mainFeed {
                    self.settings.accountMainFeedURL = mainFeed
                } else if self.settings.accountMainFeedURL == nil {
                    Log.warn(#file, "accountMainFeedURL is nil and no cached value — catalog will not load until auth doc completes")
                }
                // This `group.notify(queue: .main)` block runs on the main
                // queue but is a nonisolated closure; hop the main-actor
                // `UIApplication` access through `assumeIsolated` (safe — we
                // are provably on `.main`). Behavior unchanged.
                MainActor.assumeIsolated {
                    UIApplication.shared.delegate?.window??.tintColor = TPPConfiguration.mainColor()
                }
                NotificationCenter.default.post(name: .TPPCurrentAccountDidChange, object: nil)
                completionBox.handler(true)
            }

        } catch {
            TPPErrorLogger.logError(error, summary: "Error parsing catalog feed")
            completion(false)
        }
    }

    @objc private func updateAccountSetFromNotification(_ notif: Notification) {
        // Run off the poster's thread. `.TPPUseBetaDidChange` is delivered
        // synchronously by `NotificationCenter` on whatever thread posted it —
        // typically MAIN, from a Settings toggle. `updateAccountSet` does an
        // `accountSetsLock.sync` read (`performRead`) that blocks until any
        // in-flight background catalog-refresh barrier on that lock drains; under
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

        performWrite { self.accountSet = newHash }
        if performRead({ self.accountSets[newHash]?.isEmpty ?? true }) || TPPConfiguration.customUrlHash() != nil {
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
    /// OPDS2 parsing. Routes through `performWrite` so concurrent-access
    /// invariants are preserved. Used by mutation-killing tests for
    /// `account(_ uuid:)` — multi-bucket scenarios are not otherwise
    /// reachable from outside the class.
    func _testSetAccountSet(_ accounts: [Account], forKey key: String) {
        mutateAccountSets { $0[key] = accounts }
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
        // Order matters: flip the explicit-cancel flag BEFORE issuing the
        // .cancel() so the observation surface
        // `_backgroundFetchTaskWasExplicitlyCancelled` distinguishes "we
        // called cancel" from "the handle was nilled by some other path."
        // swarm_4b64e4e0 qa-fixup Fix 3.
        _explicitCancelCalled = true
        backgroundFetchTask?.cancel()
        backgroundFetchTask = nil
        // Cancel every OWNED crawl / pagination / refresh / fallback-GET /
        // preload task spawned by loadCatalogs — without this they leak a live
        // crawl past the test boundary and pollute the next test. Each task
        // self-prunes its token as it unwinds, so cancelAll() does not clear the
        // map — the drain then awaits whatever is still live.
        ownedCrawlTasks.cancelAll()
        // Drop the first-run subset so the narrow join seam does not re-await an
        // already-cancelled task.
        _trackedCrawlTasksLock.lock()
        _trackedFirstRunTasks.removeAll()
        _trackedCrawlTasksLock.unlock()
        networkExecutor.cancelNonEssentialTasks()
    }

    /// Test-only: cancel the in-flight background `loadCatalogs` crawl AND
    /// synchronously DRAIN it before returning, so no orphan crawl outlives the
    /// test boundary holding the `accountSetsLock` barrier.
    ///
    /// Why this exists (WS-0 follow-up — closes the residual race documented on
    /// `cancelBackgroundWork()` above): the cooperative `cancelBackgroundWork()`
    /// returns immediately, so a just-cancelled crawl can still be mid-flight —
    /// holding the `performWrite` `.barrier` on `accountSetsLock` — when the
    /// NEXT test's `@MainActor` reauth path does a synchronous
    /// `currentUserAccount` / `performRead` `.sync` read. That read blocks
    /// behind the barrier; because the crawl hops to the main actor to complete,
    /// and main is now blocked on the read, the two deadlock → the victim test's
    /// 5s `waitForExpectations` timer never fires → 120s main-thread jam. This
    /// is the "auth-state-bleed" board-red whose ROOT is a leaked
    /// `deferInitialLoadCatalogsForTesting = false` crawl (flag-value-restored ≠
    /// crawl-drained — the gap the flag-value defer gate could not see).
    ///
    /// The drain MUST pump the run loop while waiting: the crawl needs the main
    /// actor to finish, so blocking main outright would re-create the deadlock.
    /// Pumping lets the cancelled crawl's main-hops + barrier writes complete,
    /// then it observes cancellation and exits — bounded by `timeout`.
    ///
    /// Production-safe — `#if DEBUG`, called only from
    /// `AppContainer._resetForTesting()` (every test boundary) so the fix is
    /// global across ALL flag-false crawl spawners, not a per-test patch.
    func cancelAndDrainBackgroundWork(timeout: TimeInterval = 3.0) {
        // Capture the FULL owned set BEFORE cancelBackgroundWork() cancels it —
        // including the newly-wrapped fallback GET tasks, so the last
        // un-drainable write channel is now awaited, not missed.
        // `backgroundFetchTask` is also awaited to cover a test-INJECTED task
        // not in the registry (an owned task awaited twice returns immediately).
        let ownedTasks = ownedCrawlTasks.snapshot().map { $0.1 }
        let fetchTask = backgroundFetchTask
        let tasksToDrain = ownedTasks + [fetchTask].compactMap { $0 }

        cancelBackgroundWork() // requests cancellation, nils the handle

        if tasksToDrain.isEmpty {
            // No tracked Tasks, but init may have enqueued a DispatchQueue.main.async
            // auth-doc drive (see `preloadAccountsFromDiskCacheSync`'s deferred
            // `driveCurrentAccountAuthDocIfNeeded()` hop) that is NOT a Task and
            // therefore CANNOT be cancelled by `cancelBackgroundWork()`. If it
            // escapes this boundary it fires on a LATER runloop turn — after the
            // next test's `_resetForTesting()` store reset — and writes a
            // fixture-shared library UUID's `.detailsLoading`/`.detailsFailed`
            // into the next test (the order-dependent Accounts-suite flakes).
            // Pump the main run loop briefly so any such pending main-hop fires
            // NOW, inside the boundary: for THIS torn-down manager the
            // `_explicitCancelCalled` entry guard in
            // `fetchAuthDocumentWithStateMachine` makes its own drive inert; for a
            // foreign, never-torn-down manager's pending hop (e.g. an
            // `AppContainer.production()` manager built by a Catalog test) the
            // write lands here and is then wiped by the boundary's own store
            // reset — either way nothing leaks past `_resetForTesting()`.
            //
            // CRITICAL invariant (see the drain-must-pump note above): PUMP the
            // run loop, never BLOCK main — the crawl-drain deadlock reason applies
            // equally here. A single `RunLoop.run(mode:before:)` can return BEFORE
            // libdispatch services a lone pending main-queue block (it exits early
            // when no traditional run-loop source is ready), so — exactly like the
            // Task-drain loop below — we pump in a BOUNDED loop. We enqueue a
            // sentinel AFTER any pending hop (the main queue is FIFO) and spin
            // until it drains: once the sentinel runs, every earlier main-hop has
            // already fired. Bounded by a 50ms ceiling so a wedged main queue can
            // never hang the boundary; the common case exits in well under 1ms.
            let sentinel = DispatchGroup()
            sentinel.enter()
            DispatchQueue.main.async { sentinel.leave() }
            let pumpDeadline = Date().addingTimeInterval(0.05)
            while sentinel.wait(timeout: .now()) == .timedOut && Date() < pumpDeadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
            }
            return
        }

        // Await all (now-cancelled) tasks while pumping the run loop, so any
        // barrier the crawl holds is released and its main-actor hops complete
        // before we return. Bounded by `timeout` so a stuck task can't hang the
        // boundary.
        let started = Date()
        let group = DispatchGroup()
        for task in tasksToDrain {
            group.enter()
            Task { _ = await task.value; group.leave() }
        }
        let deadline = started.addingTimeInterval(timeout)
        while group.wait(timeout: .now()) == .timedOut && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        // Telemetry: a fast drain (cancelled crawl + pumped main unwinds in
        // single-digit ms) is the expected case. Hitting the `timeout` ceiling
        // means the cancel did NOT actually stop the crawl — surface it loudly
        // (a stuck crawl is a real bug) but never hang the boundary.
        let elapsedMs = Int(Date().timeIntervalSince(started) * 1000)
        if group.wait(timeout: .now()) == .timedOut {
            NSLog("[WS0-DRAIN] cancelAndDrainBackgroundWork TIMED OUT after %dms draining %d task(s) — crawl did not observe cancellation; investigate.", elapsedMs, tasksToDrain.count)
        } else if elapsedMs >= 50 {
            NSLog("[WS0-DRAIN] cancelAndDrainBackgroundWork drained %d task(s) in %dms.", tasksToDrain.count, elapsedMs)
        }
    }

    /// Test-only setter that swaps a caller-provided Task into
    /// `backgroundFetchTask`. Used by the race-guard test in
    /// `AccountsManagerCancellationTests` to install a Task it controls (via
    /// a CheckedContinuation) so it can drive cancel-mid-await semantics
    /// without going through a live network round-trip. Returns the prior
    /// task so the caller can restore it or cancel it as needed.
    ///
    /// swarm_4b64e4e0 qa-fixup Fix 2 — addresses qa_test concern that the
    /// cooperative-cancel guard at line 651 of `fetchFromNetwork` has no
    /// behavioral test covering the post-resume branch.
    @discardableResult
    func _injectBackgroundFetchTaskForTesting(_ task: Task<Void, Never>?) -> Task<Void, Never>? {
        let prior = backgroundFetchTask
        backgroundFetchTask = task
        return prior
    }

    /// Test-only observation surface. Returns `true` iff `cancelBackgroundWork()`
    /// was called on this instance (the flag is flipped BEFORE the underlying
    /// `.cancel()` call so a partial cancel-then-throw cannot leave this
    /// false). Pin this in tests when you want to prove the explicit
    /// production seam was invoked, distinct from the task handle being nil.
    ///
    /// swarm_4b64e4e0 qa-fixup Fix 3.
    var _backgroundFetchTaskWasExplicitlyCancelled: Bool {
        return _explicitCancelCalled
    }

    /// Test-only observation surface. Returns `true` iff `backgroundFetchTask`
    /// is currently `nil` (post-cancel cleanup OR pre-init OR opt-out
    /// construction). Pin this in tests when you want to prove the handle
    /// was nilled out.
    ///
    /// swarm_4b64e4e0 qa-fixup Fix 3.
    var _backgroundFetchTaskHandleIsNil: Bool {
        return backgroundFetchTask == nil
    }

    /// Test-only observation surface for `backgroundFetchTask`. Returns
    /// `true` if the task is currently in a cancelled state OR if the task
    /// handle has been nilled out by `cancelBackgroundWork()`. Used by
    /// `AccountsManagerCancellationTests` to verify the cooperative-cancel
    /// invariant without poking at the private storage directly.
    ///
    /// - DEPRECATED in qa-fixup: this property conflates "explicit cancel
    ///   was called" with "task handle was nilled." Prefer
    ///   `_backgroundFetchTaskWasExplicitlyCancelled` AND
    ///   `_backgroundFetchTaskHandleIsNil` together so a mutation that
    ///   removes only ONE of the two effects fails its dedicated test.
    @available(*, deprecated, message: "Use _backgroundFetchTaskWasExplicitlyCancelled + _backgroundFetchTaskHandleIsNil so cancel-vs-nil mutations are independently observable. See swarm_4b64e4e0 qa-fixup Fix 3.")
    var _backgroundFetchTaskIsCancelledOrCleared: Bool {
        guard let task = backgroundFetchTask else { return true }
        return task.isCancelled
    }
}
#endif
