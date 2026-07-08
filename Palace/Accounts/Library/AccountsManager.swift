import Foundation
import PalaceLogging
import PalaceCatalog

let currentAccountIdentifierKey = "TPPCurrentAccountIdentifier"

// MARK: - Cache Metadata

/// Metadata for tracking cache freshness in stale-while-revalidate pattern
struct CatalogCacheMetadata: Codable {
    let timestamp: Date
    let hash: String
    /// `true` when this cache entry was populated from the build-time
    /// bundled snapshot (`Palace/Accounts/Library/bundled_registry.json`),
    /// `false` for entries written from a network response. Bundled-origin
    /// caches return `true` from `isStale(serverMaxAge:now:)` regardless
    /// of timestamp so the refresh trigger keeps firing on every
    /// `loadCatalogs` call until a real network response overwrites the
    /// metadata with `isBundled = false`. Decodes as `false` for legacy
    /// metadata files written before this field existed.
    let isBundled: Bool

    init(timestamp: Date, hash: String, isBundled: Bool = false) {
        self.timestamp = timestamp
        self.hash = hash
        self.isBundled = isBundled
    }

    private enum CodingKeys: String, CodingKey {
        case timestamp, hash, isBundled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.timestamp = try container.decode(Date.self, forKey: .timestamp)
        self.hash = try container.decode(String.self, forKey: .hash)
        self.isBundled = try container.decodeIfPresent(Bool.self, forKey: .isBundled) ?? false
    }

    /// Default stale TTL: 6 hours (half the server's typical Cache-Control
    /// max-age of 12hr). Overridden dynamically by `staleTTL(serverMaxAge:)`.
    private static let defaultStaleTTL: TimeInterval = 21600

    /// Cache expires after 24 hours (must not be used)
    private static let maxAge: TimeInterval = 86400

    /// Returns the stale TTL, dynamically adjusted from the server's
    /// Cache-Control max-age if available. Uses half the server's value
    /// with a floor of 5 minutes and a ceiling of 12 hours.
    static func staleTTL(serverMaxAge: TimeInterval?) -> TimeInterval {
        guard let serverMax = serverMaxAge, serverMax > 0 else {
            return defaultStaleTTL
        }
        let half = serverMax / 2
        return min(max(half, 300), 43200) // clamp to [5min, 12hr]
    }

    /// Returns true if cache is stale given the server's max-age hint.
    func isStale(serverMaxAge: TimeInterval?) -> Bool {
        isStale(serverMaxAge: serverMaxAge, now: Date())
    }

    func isStale(serverMaxAge: TimeInterval?, now: Date) -> Bool {
        // Bundled-origin caches are always stale for refresh purposes
        // regardless of timestamp. The bundled bytes are usable for
        // immediate display but not authoritative, so refresh has to
        // keep firing until a real network response overwrites with
        // `isBundled = false`.
        if isBundled { return true }
        return now.timeIntervalSince(timestamp) > Self.staleTTL(serverMaxAge: serverMaxAge)
    }

    /// Returns true if cache is stale using the default TTL (no server hint).
    var isStale: Bool {
        isStale(serverMaxAge: nil)
    }

    /// Returns true if cache is expired (older than 24 hours)
    var isExpired: Bool {
        isExpired(now: Date())
    }

    func isExpired(now: Date) -> Bool {
        now.timeIntervalSince(timestamp) > Self.maxAge
    }
}

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
/// `self`'s instance I/O pipeline (`cacheAccountsCatalogData`,
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
///   - `_trackedCrawlTasks`  → read/written only under `_trackedCrawlTasksLock`.
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
    /// Lazy-resolved from AppContainer to break the singleton init cycle:
    /// AccountsManager is constructed inline by AppContainer._cached's
    /// initializer, so we cannot read AppContainer.production() during this
    /// class's init. The lazy var is first accessed *after* AppContainer
    /// finishes constructing, so the cached instance is ready.
    private lazy var networkExecutor: TPPNetworkExecutor = AppContainer.production().networkExecutor
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

    /// Per-UUID single-flight guard for `authentication_document` fetches.
    /// Without this, two concurrent consumers calling `awaitReady()` on the
    /// same Account would each cause `current.loadAuthenticationDocument` to
    /// fire a duplicate HTTP request. The state machine's broadcast
    /// (`CurrentValueSubject`) handles multi-consumer observation; this set
    /// just prevents the duplicate network request. See ADR
    /// docs/architecture/account-state-machine.md Open Q #1.
    private var inflightAuthDocFetches = Set<String>()
    private let inflightAuthDocLock = NSLock()

    #if DEBUG
    /// Test-only opt-out from the post-init background `loadCatalogs` spawn.
    /// When `true`, `AccountsManager.init()` skips the
    /// `DispatchQueue.global(qos: .background).async { loadCatalogs(...) }`
    /// dispatch — eliminating the cross-test race where lingering background
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
    #endif

    /// Registry of the unstructured background `Task`s spawned by
    /// `loadCatalogs` → `fetchFromNetwork` / `refreshInBackground` (the
    /// registry crawl, pagination, and catalog-preload). These are independent
    /// tasks — NOT children of `backgroundFetchTask` — so `cancelBackgroundWork()`
    /// did not previously cancel them. When a test constructed an
    /// `AccountsManager` under `deferInitialLoadCatalogsForTesting = false`
    /// (e.g. `AppContainerResetTests`), these tasks outlived the test and the
    /// cooperative-cancel of `backgroundFetchTask`, leaking a live multi-page
    /// network crawl into whatever test ran next — the root of the intermittent
    /// cross-test CI crashes (a different victim each run).
    ///
    /// `_trackCrawlTask` no-ops outside an XCTest process (the runtime gate
    /// below), so release / TestFlight / dev-sim builds never append — the
    /// array stays empty and there is no storage cost or unbounded growth. The
    /// only consumer that drains/cancels the list is `cancelBackgroundWork()`,
    /// which is itself `#if DEBUG` and only invoked under `_resetForTesting()`
    /// / wiring-suite tearDown. Using the XCTest env-var gate rather than
    /// `#if DEBUG` on these production call sites keeps the crawl-spawn paths
    /// free of conditional compilation (blast-radius BR-2).
    private static let _isRunningUnderXCTest =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    private let _trackedCrawlTasksLock = NSLock()
    private var _trackedCrawlTasks: [Task<Void, Never>] = []

    /// Register a spawned background crawl task so `cancelBackgroundWork()` can
    /// cancel it. No-op outside an XCTest process.
    private func _trackCrawlTask(_ task: Task<Void, Never>) {
        guard Self._isRunningUnderXCTest else { return }
        _trackedCrawlTasksLock.lock()
        _trackedCrawlTasks.append(task)
        _trackedCrawlTasksLock.unlock()
    }

    /// Initializer is `internal` rather than `private` so `AppContainer` can
    /// construct the single live instance directly. Outside of `AppContainer`
    /// (and tests that need an isolated instance), do not call this directly
    /// — read `appContainer.accountsManager` instead.
    ///
    /// - Parameter defaults: UserDefaults backing store for
    ///   `currentAccountIdentifierKey` reads/writes. Defaults to `.standard`
    ///   so production callers stay green; tests pass a per-suite instance.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
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
        // DEBUG-only arm: use `Task.detached` so the background work is
        // cancellable from `cancelBackgroundWork()` (called by
        // `AppContainer._resetForTesting()`). Production continues to use
        // `DispatchQueue.global(qos: .background).async` — byte-identical to
        // the prior behaviour. swarm_4b64e4e0 Fix 2.
        backgroundFetchTask = Task.detached(priority: .background) { [weak self] in
            self?.loadCatalogs(completion: nil)
        }
        #else
        DispatchQueue.global(qos: .background).async { [weak self] in
            self?.loadCatalogs(completion: nil)
        }
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
        // Gated on `hasCachedCatalogData` (full-cache freshness): the slim
        // snapshot carries no separate metadata, so a truly-expired cache still
        // falls through to the no-op below rather than hydrating stale data.
        if hasCachedCatalogData(hash: hash), hydrateSlimLaunchSnapshot(hash: hash) {
            refreshSlimLaunchSnapshotOffMain(hash: hash)
            return
        }
        // Slow path: no slim snapshot yet (first launch after this ships, or a
        // fresh install whose catalog cache was just written). Hydrate the full
        // set synchronously exactly as before so behaviour is unchanged on that
        // one launch, then seed a slim snapshot off-main so the NEXT launch takes
        // the fast path above.
        guard hasCachedCatalogData(hash: hash),
              let cachedData = readCachedAccountsCatalogData(hash: hash) else {
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
        guard let url = slimSnapshotUrl(hash: hash),
              FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else {
            return false
        }
        do {
            let feed = try OPDS2CatalogsFeed.fromData(data)
            let accounts = feed.catalogs.map {
                Account(publication: $0, imageCache: ImageCache.shared)
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
                if case .notLoaded = AccountStateStore.shared.state(for: account.uuid) {
                    account._setState(.basicInfoLoaded)
                }
            }
            // Drive the current account's auth-doc so `awaitReady()` consumers
            // (audiobook open, token refresh, bookmark sync, CarPlay auth)
            // resolve without waiting on the full off-main materialization.
            // `currentAccount` resolves via `account(_:)`'s slim fallback.
            driveCurrentAccountAuthDocIfNeeded()
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
                Account(publication: $0, imageCache: ImageCache.shared)
            }
            mutateAccountSets { $0[hash] = accounts }
            // Account state-machine wiring (3.2.0): Phase 1 — drive every
            // preloaded account into `.basicInfoLoaded`. Display-only
            // consumers (Settings/Libraries) can render the row immediately;
            // critical-path readers `awaitReady()` continue blocking until
            // the auth-doc transition completes.
            for account in accounts {
                if case .notLoaded = AccountStateStore.shared.state(for: account.uuid) {
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
        let task = Task.detached(priority: .utility) { [weak self] in
            guard let self, !Task.isCancelled else { return }
            guard let data = self.readCachedAccountsCatalogData(hash: hash) else { return }
            guard !Task.isCancelled else { return }
            self.writeSlimSnapshot(fromFullCatalogData: data, hash: hash)
        }
        _trackCrawlTask(task)
    }

    /// Carve the current + settings accounts out of the full catalog blob and
    /// persist them as a small OPDS2 feed at `accounts_catalog_slim_<hash>.json`.
    /// Runs on a background queue (never the launch main thread). CP-D1.
    private func writeSlimSnapshot(fromFullCatalogData data: Data, hash: String) {
        let keepUUIDs = slimSnapshotUUIDs()
        guard !keepUUIDs.isEmpty, let url = slimSnapshotUrl(hash: hash) else { return }
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
                ImageCache.shared.evictDecodedImages()
                // Reset the cover-fetch circuit breaker: a host that tripped while
                // the prior library was active must not keep cover fetches
                // suppressed for the newly selected library.
                TPPBookCoverRegistry.shared.resetHostFailures()
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
                AccountStateStore.shared.setState(
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
        MyBooksDownloadCenter.clearAllBorrowReauthState()

        Task { @MainActor [weak self] in
            if let coordinator = AppContainer.production().navigationCoordinatorHub.coordinator {
                let pathCount = coordinator.path.count
                Log.debug(#file, "  Navigation path has \(pathCount) items")

                if Self.shouldPopToRoot(navigationPathCount: pathCount) {
                    Log.info(#file, "  🔄 Popping to root to clean up active content before account switch")
                    coordinator.popToRoot()

                    try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
                }
            }
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
            if isCacheStale(hash: hash) {
                refreshInBackground(targetUrl: targetUrl, hash: hash)
            }
            return
        }

        // 2. Try disk cache first (stale-while-revalidate)
        if hasCachedCatalogData(hash: hash),
           let cachedData = readCachedAccountsCatalogData(hash: hash) {
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

        // 2.5. No disk cache — try the build-time bundled snapshot for
        // immediate library-picker display (PP-4258). The network fetch
        // still runs to pick up anything that changed since the snapshot
        // was cut, so this is purely a fast-path for cold first launch.
        if let bundledData = BundledRegistrySnapshot.load() {
            // Cooperative-cancel guard: if our enclosing Task was cancelled
            // between the bundled-load decision and the disk write, skip the
            // cache write. Mirrors the guard in `fetchFromNetwork` on the
            // post-await branch. Without this, a cancelled background
            // `loadCatalogs` Task can still race a fixture-seeded test:
            // cancel→continue→write-bundled-snapshot overwrites the test's
            // 171-account fixture with the 1142 bundled accounts on disk.
            if Task.isCancelled { return }
            Log.info(#file, "First launch — loading bundled registry snapshot for hash \(hash), dataSize=\(bundledData.count)")
            // isBundled=true keeps the cache flagged as non-authoritative so
            // every subsequent loadCatalogs call still triggers refresh until
            // a real network response overwrites the metadata.
            cacheAccountsCatalogData(bundledData, hash: hash, isBundled: true)
            loadAccountSetsAndAuthDoc(fromCatalogData: bundledData, key: hash) { _ in
                NotificationCenter.default.post(name: .TPPCatalogDidLoad, object: nil)
            }
            // Fall through to the network fetch — the caller's completion
            // fires when the fresh data arrives, not on the bundled load.
        }

        // 3. No cache or expired - must fetch from network
        Log.debug(#file, "Loading catalogs from network for hash \(hash)…")

        // dedupe concurrent loads
        if addLoadingHandler(for: hash, completion) { return }

        fetchFromNetwork(targetUrl: targetUrl, hash: hash)
    }

    /// Fetches catalog data using the first-page fast path:
    /// 1. Fetch first page (~35KB, ~260ms) → display immediately
    /// 2. Paginate remaining pages in background → update cache when done
    /// Falls back to a direct GET if even the first page fails.
    private func fetchFromNetwork(targetUrl: URL, hash: String) {
        // A developer-configured explicit registry URL is fetched verbatim via a
        // direct GET — no crawlable rewrite — so the exact endpoint (e.g. a bare
        // /libraries feed) is exercised. Gated behind a custom registry being set;
        // production registry loading still uses the crawler below.
        if TPPConfiguration.customRegistryIsExplicitURL() {
            fallbackFetchFromNetwork(targetUrl: targetUrl, hash: hash)
            return
        }
        let crawlTask = Task(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            Log.debug(#file, "Fetching catalogs via first-page fast path for hash \(hash)")

            let crawler = LibraryRegistryCrawler(fetcher: URLSessionCrawlerFetcher(), hash: hash)

            // Step 1: Fetch first page for immediate display
            let firstPageResult = await crawler.crawlFirstPage(baseURL: targetUrl)
            // Cooperative cancellation observation (swarm_4b64e4e0 Fix 2):
            // if `cancelBackgroundWork()` was called while we were awaiting
            // `crawlFirstPage`, drop the result on the floor instead of
            // writing through to `accountSets` / `cacheAccountsCatalogData`.
            // Without this, a test that `_resetForTesting()`s the AppContainer
            // mid-fetch still sees the prior `AccountsManager`'s response
            // land in its caches a few ms later.
            if Task.isCancelled { return }

            switch firstPageResult {
            case .success(let firstPageData, let firstPage):
                // Display first page immediately
                self.cacheAccountsCatalogData(firstPageData, hash: hash)
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
                let paginationTask = Task(priority: .utility) { [weak self] in
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
                        self.cacheAccountsCatalogData(fullData, hash: hash)
                        self.loadAccountSetsAndAuthDoc(fromCatalogData: fullData, key: hash) { _ in
                            NotificationCenter.default.post(name: .TPPCatalogDidLoad, object: nil)
                        }
                    }
                    self.triggerCatalogPreload()
                }
                self._trackCrawlTask(paginationTask)

            case .noChanges:
                self.callAndClearLoadingHandlers(for: hash, true)

            case .failure(let error):
                Log.info(#file, "First page crawl failed: \(error), falling back to direct GET to \(targetUrl)")
                self.fallbackFetchFromNetwork(targetUrl: targetUrl, hash: hash)
            }
        }
        _trackCrawlTask(crawlTask)
    }

    /// Fallback direct GET when crawler fails on first launch.
    private func fallbackFetchFromNetwork(targetUrl: URL, hash: String) {
        networkExecutor.GET(targetUrl, useTokenIfAvailable: false) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let data, _):
                self.cacheAccountsCatalogData(data, hash: hash)
                self.loadAccountSetsAndAuthDoc(fromCatalogData: data, key: hash) { success in
                    NotificationCenter.default.post(name: .TPPCatalogDidLoad, object: nil)
                    self.callAndClearLoadingHandlers(for: hash, success)
                }
            case .failure(let error, _):
                Log.error(#file, "Failed to load catalogs from network: \(error.localizedDescription)")
                if let data = self.readCachedAccountsCatalogData(hash: hash) {
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
        let refreshTask = Task(priority: .utility) { [weak self] in
            guard let self = self else { return }
            Log.debug(#file, "Starting background refresh (crawl) for catalog hash \(hash)")

            // Parse existing cached publications for merge
            let existingPubs: [OPDS2Publication]
            let existingMetadata: OPDS2CatalogsFeed.Metadata?
            if let cachedData = self.readCachedAccountsCatalogData(hash: hash),
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
                self.cacheAccountsCatalogData(data, hash: hash)
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
        _trackCrawlTask(refreshTask)
    }

    /// Fallback to direct GET when crawlable endpoint fails.
    private func fallbackDirectRefresh(targetUrl: URL, hash: String) {
        networkExecutor.GET(targetUrl, useTokenIfAvailable: false) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let data, _):
                Log.info(#file, "Fallback direct refresh successful for hash \(hash)")
                self.cacheAccountsCatalogData(data, hash: hash)
                self.loadAccountSetsAndAuthDoc(fromCatalogData: data, key: hash) { _ in
                    NotificationCenter.default.post(name: .TPPCatalogDidLoad, object: nil)
                }
            case .failure(let error, _):
                Log.debug(#file, "Fallback direct refresh also failed for hash \(hash): \(error.localizedDescription)")
            }
        }
    }

    /// Triggers catalog feed preloading for active accounts.
    private func triggerCatalogPreload() {
        let preloadTask = Task(priority: .utility) { [weak self] in
            guard let self = self else { return }
            await self.catalogPreloader.preloadCatalogs(
                currentAccount: self.currentAccount,
                recentAccountUUIDs: self.settings.settingsAccountIdsList,
                accountProvider: { self.account($0) }
            )
        }
        _trackCrawlTask(preloadTask)
    }

    // MARK: – Disk cache helpers

    private func accountsCatalogUrl(hash: String) -> URL? {
        guard let appSupport = try? FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true)
        else { return nil }
        return appSupport.appendingPathComponent("accounts_catalog_\(hash).json")
    }

    private func cacheMetadataUrl(hash: String) -> URL? {
        guard let appSupport = try? FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true)
        else { return nil }
        return appSupport.appendingPathComponent("accounts_catalog_metadata_\(hash).json")
    }

    /// On-disk location of the CP-D1 slim launch snapshot (current + settings
    /// accounts). The `accounts_catalog_slim_` name shares the
    /// `accounts_catalog_` prefix, so `clearCache()` and the wiring-suite
    /// disk-cache purge already sweep it with no extra bookkeeping. CP-D1.
    private func slimSnapshotUrl(hash: String) -> URL? {
        guard let appSupport = try? FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true)
        else { return nil }
        return appSupport.appendingPathComponent("accounts_catalog_slim_\(hash).json")
    }

    private func cacheAccountsCatalogData(_ data: Data, hash: String, isBundled: Bool = false) {
        // Save catalog data
        guard let url = accountsCatalogUrl(hash: hash) else { return }
        try? data.write(to: url)

        // Save metadata with current timestamp. `isBundled` distinguishes
        // build-time-snapshot writes from authoritative network writes so
        // staleness logic can keep refresh alive on bundled-origin caches.
        let metadata = CatalogCacheMetadata(timestamp: Date(), hash: hash, isBundled: isBundled)
        if let metadataUrl = cacheMetadataUrl(hash: hash),
           let metadataData = try? JSONEncoder().encode(metadata) {
            try? metadataData.write(to: metadataUrl)
        }
    }

    private func readCachedAccountsCatalogData(hash: String) -> Data? {
        guard let url = accountsCatalogUrl(hash: hash) else { return nil }
        return try? Data(contentsOf: url)
    }

    /// Reads cache metadata for the given hash
    private func readCacheMetadata(hash: String) -> CatalogCacheMetadata? {
        guard let url = cacheMetadataUrl(hash: hash),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CatalogCacheMetadata.self, from: data)
    }

    /// Returns true if cached data exists and is not expired (can be stale but usable).
    ///
    /// Existence is probed with `FileManager.fileExists` — NOT a full
    /// `Data(contentsOf:)` — so this check never reads the ~2.4MB catalog blob
    /// off disk. The single authoritative byte read happens exactly once per
    /// launch at the caller (`preloadAccountsFromDiskCacheSync` and the
    /// `loadCatalogs` stale-while-revalidate branch), which pair this gate with
    /// one `readCachedAccountsCatalogData` and thread those bytes into the
    /// decode. The prior implementation read the entire file here purely to
    /// test existence, then the caller read the same file again — two full
    /// reads of the same 2.4MB blob per launch.
    private func hasCachedCatalogData(hash: String) -> Bool {
        guard let url = accountsCatalogUrl(hash: hash),
              FileManager.default.fileExists(atPath: url.path) else { return false }
        guard let metadata = readCacheMetadata(hash: hash) else {
            // Data exists but no metadata - treat as usable but stale
            return false
        }
        return !metadata.isExpired
    }

    /// Returns true if cache exists and is stale (needs background refresh)
    private func isCacheStale(hash: String) -> Bool {
        let metadata = readCacheMetadata(hash: hash)
        let serverMaxAge = readCrawlState(hash: hash)?.serverMaxAge
        return Self.isCacheStale(metadata: metadata, serverMaxAge: serverMaxAge)
    }

    /// Pure variant of `isCacheStale(hash:)` that doesn't touch the file
    /// system. Returns `true` when metadata is missing OR when the metadata
    /// reports staleness against `serverMaxAge`. Extracted from the private
    /// version so tests can exercise the nil-metadata → refresh path that
    /// previously had no test coverage (F-013).
    static func isCacheStale(
        metadata: CatalogCacheMetadata?,
        serverMaxAge: TimeInterval?
    ) -> Bool {
        guard let metadata else {
            // No metadata means we should refresh
            return true
        }
        return metadata.isStale(serverMaxAge: serverMaxAge)
    }

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

    /// Reads crawl state for the given hash (used for dynamic TTL adjustment)
    private func readCrawlState(hash: String) -> CrawlState? {
        guard let appSupport = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) else { return nil }
        let url = appSupport.appendingPathComponent("crawl_state_\(hash).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CrawlState.self, from: data)
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
        inflightAuthDocLock.lock()
        let alreadyInflight = inflightAuthDocFetches.contains(account.uuid)
        if !alreadyInflight {
            inflightAuthDocFetches.insert(account.uuid)
        }
        inflightAuthDocLock.unlock()

        if alreadyInflight {
            // A fetch for this UUID is already in flight. Don't fire a
            // duplicate HTTP request — the state stream's broadcast covers
            // multi-consumer observation. Caller's completion gets `true`
            // so the calling DispatchGroup (if any) balances.
            completion(true)
            return
        }

        account._setState(.detailsLoading)
        account.loadAuthenticationDocument(using: self.currentUserAccount) { [weak self] success in
            guard let self = self else {
                completion(success)
                return
            }
            self.inflightAuthDocLock.lock()
            self.inflightAuthDocFetches.remove(account.uuid)
            self.inflightAuthDocLock.unlock()

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
                currentState: AccountStateStore.shared.state(for: account.uuid)
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
        switch AccountStateStore.shared.state(for: account.uuid) {
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
                return Account(publication: publication, imageCache: ImageCache.shared)
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
                        ImageCache.shared.remove(for: newAccount.uuid)
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
                } else if case .notLoaded = AccountStateStore.shared.state(for: newAccount.uuid) {
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
        updateAccountSet(completion: nil)
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
        // file caches — delete all files matching known prefixes written to the
        // Application Support root. (`authentication_document_` was removed: no
        // code path writes a file with that prefix — auth docs live in `Account`
        // state / are re-fetched, not persisted as files — so it cleared nothing.)
        let prefixes = [
            "library_list_",
            "accounts_catalog_",
            "accounts_catalog_metadata_",
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

#if DEBUG
extension AccountsManager {
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
    /// Residual race window (documented intentional): if `loadCatalogs` is
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
        // Cancel the unstructured crawl / pagination / preload tasks spawned by
        // loadCatalogs. These are independent of backgroundFetchTask, so
        // without this they leak a live registry crawl past the test boundary
        // and pollute the next test (the intermittent cross-test CI crash).
        _trackedCrawlTasksLock.lock()
        let crawlTasks = _trackedCrawlTasks
        _trackedCrawlTasks.removeAll()
        _trackedCrawlTasksLock.unlock()
        crawlTasks.forEach { $0.cancel() }
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
        // Capture the in-flight tasks BEFORE cancelBackgroundWork() clears them.
        _trackedCrawlTasksLock.lock()
        let crawlTasks = _trackedCrawlTasks
        _trackedCrawlTasksLock.unlock()
        let fetchTask = backgroundFetchTask
        let tasksToDrain = crawlTasks + [fetchTask].compactMap { $0 }

        cancelBackgroundWork() // requests cancellation, nils handles, clears list

        guard !tasksToDrain.isEmpty else { return }

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
