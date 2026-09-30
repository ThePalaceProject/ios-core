import Foundation
import PalacePreferences
import PalaceLogging
import PalaceCatalog
import PalaceBookRegistry

let currentAccountIdentifierKey = "TPPCurrentAccountIdentifier"

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

/// Manages library accounts asynchronously with authentication & image loading.
///
/// `@unchecked Sendable`: a process-wide singleton shared across actors (background
/// crawl Tasks, `@MainActor` UI, token-refresh / audiobook / bookmark consumers),
/// and its crawl Tasks capture `self`. All mutable state lives in internally
/// synchronized collaborators (`AccountRegistryStore`, `AccountRegistryLoader`,
/// `AuthDocumentLoader`, `AccountCredentialResolver`) or behind a lock
/// (`_isAccountSwitching`); the rest is `let` or `#if DEBUG` test state.
/// `@MainActor` was not used because it would move `loadCatalogs` onto the main actor.
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

    /// Lock-backed storage for `isAccountSwitching`. Written from the
    /// `currentAccount` setter and the `@MainActor` cleanup Task; read from the
    /// sign-in-modal presenter.
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
    /// Account-switch borrow-reauth circuit-breaker reset. See `BorrowReauthResetting`.
    private let borrowReauthResetter: any BorrowReauthResetting
    /// Account-switch cleanup collaborators. See `AccountSwitchDependencies`.
    private let switchDeps: AccountSwitchDependencies
    /// Resolved through the injected provider on every use, never during init:
    /// AccountsManager is constructed inline by AppContainer._cached's initializer, so
    /// resolving the executor during init re-enters that lock. Not cached: a `lazy var`
    /// has no lock.
    private var networkExecutor: any AccountNetworking { switchDeps.networkExecutorProvider() }
    /// Per-account auth-document fetch. Built in `init` before `super.init()` (its
    /// closures reach the manager through `AccountsManagerOwnerRef`) because first
    /// access is concurrent on a cold launch. Release binds `isTornDown` to `{ false }`.
    private let authDocLoader: AuthDocumentLoader
    /// Injectable background-crawl spawn seam (see `CatalogCrawlScheduler`).
    /// Immutable `Sendable` `let`; `.production` by default, recording under test.
    private let crawlScheduler: CrawlTaskScheduler
    /// Catalog load orchestration, owned background crawl, and drain.
    /// A `lazy var` because its provider closures capture `self`. A `lazy var` is
    /// not synchronized and the `.TPPUseBetaDidChange` observer can reach this from
    /// a global queue, so `init` forces construction before registering that
    /// observer; see the call site.
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
    /// On-disk catalog cache (`DiskAccountRegistryCache` by default).
    private let registryCache: any AccountRegistryCaching
    /// Account-registry state and its thread-safe access. See `AccountRegistryStore`.
    private let registryStore: AccountRegistryStore

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
    /// Defaults to `true` when hosted by XCTest (`XCTestConfigurationFilePath`
    /// set), so the first cached `AppContainer.production()`, which can happen
    /// before any setUp, does not start a load that races test fixtures. Tests
    /// that need the background load (e.g. `AppContainerResetTests`) set it to
    /// `false`. Not compiled into release builds.
    private static let _deferInitialLoadCatalogsForTesting = AccountsManagerBoolFlag(
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    )
    /// Lock-backed so this test-only global is concurrency-safe.
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
    /// take >5s on memory-pressured CI with ~1138 cached accounts. Scope the flip
    /// to `setUp`/`tearDown`. Not compiled into release builds.
    private static let _deferDiskCachePreloadForTesting = AccountsManagerBoolFlag(false)
    /// Lock-backed test-only flag.
    internal static var deferDiskCachePreloadForTesting: Bool {
        get { _deferDiskCachePreloadForTesting.value }
        set { _deferDiskCachePreloadForTesting.value = newValue }
    }

    /// Test-only flag flipped to `true` inside `cancelBackgroundWork()` BEFORE
    /// the `.cancel()` is issued on `backgroundFetchTask`. Used by
    /// `AccountsManagerCancellationTests` to disambiguate "explicit cancel was
    /// called" from "task handle was nilled out by some other path."
    private var _explicitCancelCalled: Bool = false

    /// Test-only: forwards to the loader's single-flight seed.
    func _seedInflightAuthDocForTesting(uuid: String, age: TimeInterval) {
        authDocLoader._seedInflightAuthDocForTesting(uuid: uuid, age: age)
    }

    /// Test-only read of whether a UUID currently occupies the loader's single-flight map.
    func _inflightAuthDocContainsForTesting(uuid: String) -> Bool {
        authDocLoader._inflightAuthDocContainsForTesting(uuid: uuid)
    }

    /// The loader's `isTornDown` binding; release binds `{ false }` (the flag is DEBUG-only).
    static func tornDownProbe(_ owner: AccountsManagerOwnerRef) -> @Sendable () -> Bool {
        { owner.manager?._explicitCancelCalled ?? true }
    }
    #else
    static func tornDownProbe(_ owner: AccountsManagerOwnerRef) -> @Sendable () -> Bool { { false } }
    #endif

    // Forwarders to `AccountRegistryLoader` for AppContainer and test call sites.

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
    ///   Tests inject a spy; `AppContainer` passes it explicitly.
    /// - Parameter crawlScheduler: injectable background-crawl spawn seam
    ///   (PP-4754).
    /// - Parameter switchDependencies: account-switch cleanup collaborators;
    ///   `.production` binds the live ones, tests spy.
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
        // Build the auth-doc + credential collaborators here, not lazily on first use:
        // first use is concurrent on a cold launch. They reach the manager through
        // `owner`, which is bound right after `super.init()` — before the preload and
        // the background load below can call them.
        let owner = AccountsManagerOwnerRef()
        self.authDocLoader = AuthDocumentLoader(
            accountStateStore: switchDependencies.accountStateStore,
            currentAccountProvider: { owner.manager?.currentAccount },
            signedInStateProvider: { owner.manager?.currentUserAccount },
            isTornDown: AccountsManager.tornDownProbe(owner)
        )
        self.credentialResolver = AccountCredentialResolver(currentAccountIdProvider: { owner.manager?.currentAccountId })
        super.init()
        owner.manager = self
        // Seed the registry store's current hash. The write is synchronous, so the
        // `preloadAccountsFromDiskCacheSync` read below observes it.
        registryStore.setCurrentHash(
            TPPConfiguration.customUrlHash()
                ?? (settings.useBetaLibraries
                        ? TPPConfiguration.betaUrlHash
                        : TPPConfiguration.prodUrlHash)
        )
        // Force `registryLoader`'s construction on THIS thread before the observer
        // below goes live. The observer's handler hops to a global queue and reaches
        // `registryLoader` through `updateAccountSet` -> `loadCatalogs`; a `lazy var`
        // has no synchronisation, so that background first-touch can race the one on
        // the constructing thread. The synchronous preload further down used to be the
        // only thing forcing it, and it runs AFTER this registration — and the DEBUG
        // `deferDiskCachePreloadForTesting` path skips the preload entirely, leaving
        // the handler as a plausible first toucher. This costs nothing:
        // `AccountRegistryLoader.init` is pure assignment, no dispatch and no I/O.
        _ = registryLoader

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
        // Owned, drainable background load (PP-4754).
        registryLoader.spawnInitialBackgroundLoad()
    }

    /// Forwards the launch preload to `registryLoader`. `internal` so contract-snapshot
    /// tests can drive it after seeding the on-disk cache.
    internal func preloadAccountsFromDiskCacheSync() {
        registryLoader.preloadAccountsFromDiskCacheSync()
    }

    // MARK: – Account index (static shim)

    /// Forwards to `AccountRegistryStore.buildAccountIndex`; kept for
    /// `AccountsManagerAccountIndexTests`.
    static func buildAccountIndex(_ sets: [String: [Account]]) -> [String: Account] {
        AccountRegistryStore.buildAccountIndex(sets)
    }

    /// Forwards to `AccountRegistryLoader`; kept for `AccountsManagerLaunchSnapshotTests`.
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

            // On a library switch, give lingering `awaitReady()` callers on the
            // prior account a definitive terminal. `.notLoaded` would leave them
            // hanging; `.detailsFailed(.accountNotFound)` would read as a real
            // 404 (PR #1021). Awaiters throw `AccountLoadError.evicted`. The marker
            // is overwritten via `.basicInfoLoaded` if the UUID becomes current again.
            if let prev = previousAccountId, prev != newAccountId {
                switchDeps.accountStateStore.setState(
                    .detailsEvicted(.libraryDeselected(uuid: prev)),
                    for: prev
                )
            }

            // Drive the new currentAccount past `.basicInfoLoaded` after the
            // switch, like the `loadCatalogs` warm-path driver (PR #975).
            // Without this, every
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
            // Rewrite the slim launch snapshot (off-main, best-effort) so it lists
            // the new current account; otherwise the next cold launch resolves
            // `currentAccount` nil until the full catalog loads.
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
    /// requiring a real OPDS2 catalog fixture load.
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

    /// Per-account credential resolution; see `AccountCredentialResolver`. Built once
    /// in `init`: two resolvers would each cache their own `TPPUserAccount` per UUID.
    /// `currentAccountIdProvider` is a live read so the switch-window ride-out works.
    private let credentialResolver: AccountCredentialResolver

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
    /// `registryLoader`.
    func loadCatalogs(completion: ((Bool) -> Void)?) {
        registryLoader.loadCatalogs(completion: completion)
    }

    // MARK: – Account-switch pure helpers

    /// Pure helper for `cleanupActiveContentBeforeAccountSwitch`'s
    /// `pathCount > 0` guard — extracted so the bound check is testable.
    static func shouldPopToRoot(navigationPathCount: Int) -> Bool {
        return navigationPathCount > 0
    }

    /// Pure helper for the `currentAccount.didSet` decision of whether to
    /// finish the account-switch synchronously.
    static func shouldFinishSwitchingImmediately(
        previousAccountId: String?,
        newAccountId: String?
    ) -> Bool {
        return previousAccountId == newAccountId || previousAccountId == nil
    }

    // MARK: – Auth Document fetch with state-machine wiring (facades → AuthDocumentLoader)

    /// Forwards to `AuthDocumentLoader`; kept for the wiring/snapshot tests.
    static func fetchCompletionMayWriteTerminal(currentState: Account.LoadState) -> Bool {
        AuthDocumentLoader.fetchCompletionMayWriteTerminal(currentState: currentState)
    }

    /// Forwards to `authDocLoader`. Exposed `internal` so contract-snapshot
    /// tests can drive the wiring path directly without the full `loadCatalogs` cycle.
    internal func fetchAuthDocumentWithStateMachine(
        for account: Account,
        completion: @escaping (Bool) -> Void
    ) {
        authDocLoader.fetchAuthDocumentWithStateMachine(for: account, completion: completion)
    }

    /// Forwards to `authDocLoader`. Called synchronously from the `currentAccount`
    /// setter, the slim-hydrate drive, and the `loadCatalogs` warm path.
    internal func driveCurrentAccountAuthDocIfNeeded() {
        authDocLoader.driveCurrentAccountAuthDocIfNeeded()
    }

    // MARK: – Parsing & notifying

    /// Forwards to `registryLoader`. `internal` so the cache-read and launch-snapshot
    /// contract tests can drive registry materialization directly.
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
        // file caches
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
final class AccountsManagerLiveRegistry: @unchecked Sendable {
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
    static let _liveInstancesForTesting = AccountsManagerLiveRegistry()

    static func _registerLiveInstanceForTesting(_ m: AccountsManager) {
        _liveInstancesForTesting.add(m)
    }

    /// Test-only: the registry store, so a test can seed and read its current
    /// hash on a manager built through `makeFreshAccountsManager()`.
    var _registryStoreForTesting: AccountRegistryStore { registryStore }

    /// Test-only seam: populate an accountSets bucket without going through
    /// OPDS2 parsing, through `registryStore.mutate` so the index stays coherent.
    /// Multi-bucket scenarios for `account(_ uuid:)` are not otherwise reachable.
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
    /// Cooperative: returns immediately. `_resetForTesting()` uses the
    /// synchronous `cancelAndDrainBackgroundWork()` instead.
    ///
    /// A response already past the `Task.isCancelled` check still lands on the
    /// old instance, which is unreachable from `AppContainer.production()`
    /// after reset.
    func cancelBackgroundWork() {
        // Flip the hub-owned explicit-cancel flag BEFORE delegating so the observation
        // surface `_backgroundFetchTaskWasExplicitlyCancelled` (which reads this flag)
        // distinguishes "we called cancel" from "handle nilled by another path."
        _explicitCancelCalled = true
        registryLoader.cancelBackgroundWork()
    }

    /// Test-only: cancel + synchronously DRAIN the in-flight background crawl (pumping the
    /// run loop) before returning, so no orphan crawl outlives the test boundary. The drain
    /// body lives on the loader; the hub sets `_explicitCancelCalled` FIRST so the torn-down
    /// semantics engage for the pending auth-doc main-hop.
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
    /// instance.
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
