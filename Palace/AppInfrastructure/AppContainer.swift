import SwiftUI
import PalacePreferences
import PalaceFeatureFlags
import Combine
import os
import PalaceAuth
import PalaceNetwork
import PalaceCatalog // swarm_27c181b5 A5: shared CatalogRepository / DefaultCatalogAPI accessor
import PalaceBookModel
import PalaceBookRegistry

// Swift 6 `complete` — `@unchecked Sendable` invariant: every stored member is
// an immutable `let` established once at the composition root and only read
// thereafter; the struct is a value-typed bag of long-lived DI references
// (`_cachedValue()` builds it once and hands out copies). It cannot synthesize
// `: Sendable` because `drmAuthorizerProvider` is a non-`@Sendable` closure and
// several collaborator classes (`TPPNetworkExecutor`, `AccountsManager`, …) are
// not yet Sendable-audited upstream — forcing `: Sendable` here would cascade
// the requirement across the entire DI graph. The value carries no unguarded
// mutable state of its own, so sharing a copy across the `OSAllocatedUnfairLock`
// slot and the test-only rebuild `@Sendable` closure is data-race-free. This
// comment is the documented invariant, not a bare waiver.
struct AppContainer: @unchecked Sendable {

    let bookRegistry: TPPBookRegistryProvider
    let networkExecutor: TPPNetworkExecutor
    let networkQueue: NetworkQueue
    let reachability: Reachability
    let accountsManager: AccountsManager
    let settings: TPPSettings
    /// THE feature-flag read seam (Wave 1b). Protocol-typed so tests inject
    /// MockFeatureFlagProvider; production binds RemoteFeatureFlags.shared.
    let featureFlags: FeatureFlagProviding
    let downloadCenter: MyBooksDownloadCenter
    let downloadAnnouncementService: DownloadAnnouncementService
    let debugSettings: DebugSettings
    let imageCache: ImageCacheType
    let imageLoader: ImageLoading
    let userAccountPublisher: UserAccountPublisher
    let opdsFeedService: OPDSFeedService
    let readerService: ReaderService
    let navigationCoordinatorHub: NavigationCoordinatorHub
    let tabRouterHub: AppTabRouterHub
    let drmAuthorizerProvider: () -> TPPDRMAuthorizing?

    /// Single auth-refresh dispatcher (swarm_66819d80 Module A + C). All
    /// network consumers that see a 401/403 route through this coordinator
    /// instead of carrying per-call-site IdP-dispatch logic. Constructed
    /// once at composition root; held as a strong reference for app
    /// lifetime.
    let authCoordinator: AuthCoordinator

    /// Instance-local override for `signInModalSheetPresenter`. Production
    /// `_cached` value has this as `nil` — the computed property falls
    /// through to the static cache. Tests set this via
    /// `withSignInModalSheetPresenter(_:)` to inject a spy without
    /// disturbing the global `_signInModalSheetPresenter` cache. The
    /// override stays as a `let` per struct value; the modifier produces
    /// a NEW struct value rather than mutating `self`.
    ///
    /// swarm_d8f11437 Module B (wave 4) — closes wall-failure cs_9a267b63
    /// by giving Module A's wiring test a no-bloat way to inject a spy
    /// presenter into AppContainer-driven seams.
    private let _signInModalSheetPresenterOverride: SignInModalSheetPresenter?

    /// Instance-local override for `audiobookSessionPresenter`. Production
    /// containers leave this `nil` — the computed property falls through
    /// to the static cache. Tests set this via
    /// `withAudiobookSessionPresenter(_:)` to inject a spy without
    /// disturbing the global `_audiobookSessionPresenter` cache. The
    /// override stays as a `let` per struct value; the modifier produces a
    /// NEW struct value rather than mutating `self`.
    ///
    /// swarm_0b7616e7 Module C — mirrors the
    /// `_signInModalSheetPresenterOverride` precedent so Module D's tests
    /// 12-13 (AppTabHostView mini-player + fullScreenCover bindings) can
    /// inject a spy presenter without going through the static cache.
    private let _audiobookSessionPresenterOverride: AudiobookSessionPresenter?

    /// SwiftUI-observable facade over the static `SignInModalPresenter`
    /// API (swarm_18b0d071 Module A wave 3). Wave 3 migrates ONE caller
    /// (`TPPReauthenticator`) to prove the pattern; wave 4 migrates the
    /// remaining 9 callers. Held by the container for app lifetime so
    /// SwiftUI consumers that bind to `$presentationState` observe the
    /// same instance across screens.
    ///
    /// Resolution order:
    ///   1. Instance-local `_signInModalSheetPresenterOverride` (test seam,
    ///      set via `withSignInModalSheetPresenter(_:)`).
    ///   2. Static `_signInModalSheetPresenter` cache (production path).
    ///   3. Lazy-init a fresh presenter wired to `self`, store in the
    ///      static cache, return it.
    @MainActor
    var signInModalSheetPresenter: SignInModalSheetPresenter {
        if let override = _signInModalSheetPresenterOverride { return override }
        if let cached = AppContainer._signInModalSheetPresenter { return cached }
        let presenter = SignInModalSheetPresenter(appContainer: self)
        AppContainer._signInModalSheetPresenter = presenter
        return presenter
    }

    @MainActor private static var _signInModalSheetPresenter: SignInModalSheetPresenter?

    /// Returns a copy of this container with `signInModalSheetPresenter`
    /// resolved from `presenter` instead of the static cache.
    ///
    /// **Test-only seam.** Production code MUST NOT call this — the default
    /// `signInModalSheetPresenter` resolved from `AppContainer.production()`
    /// is the single composition-root instance held by the static cache.
    /// This modifier exists so tests can inject a spy presenter via:
    ///
    /// ```swift
    /// let testContainer = AppContainer.production()
    ///     .withSignInModalSheetPresenter(spy)
    /// ```
    ///
    /// then pass `testContainer` to a system-under-test whose code path
    /// resolves `appContainer.signInModalSheetPresenter`. The override is
    /// preferred over the static cache by the computed property; the
    /// static cache itself is unaffected.
    ///
    /// Modifies a struct copy — does NOT mutate `self` or the static cache.
    ///
    /// swarm_d8f11437 Module B (wave 4) — closes wall-failure cs_9a267b63.
    @MainActor
    func withSignInModalSheetPresenter(_ presenter: SignInModalSheetPresenter) -> AppContainer {
        return AppContainer(
            bookRegistry: self.bookRegistry,
            networkExecutor: self.networkExecutor,
            networkQueue: self.networkQueue,
            reachability: self.reachability,
            accountsManager: self.accountsManager,
            settings: self.settings,
            featureFlags: self.featureFlags,
            downloadCenter: self.downloadCenter,
            downloadAnnouncementService: self.downloadAnnouncementService,
            debugSettings: self.debugSettings,
            imageCache: self.imageCache,
            imageLoader: self.imageLoader,
            userAccountPublisher: self.userAccountPublisher,
            opdsFeedService: self.opdsFeedService,
            readerService: self.readerService,
            navigationCoordinatorHub: self.navigationCoordinatorHub,
            tabRouterHub: self.tabRouterHub,
            drmAuthorizerProvider: self.drmAuthorizerProvider,
            authCoordinator: self.authCoordinator,
            signInModalSheetPresenterOverride: presenter,
            audiobookSessionPresenterOverride: self._audiobookSessionPresenterOverride
        )
    }

    /// Returns a copy of this container with `audiobookSessionPresenter`
    /// resolved from `presenter` instead of the static cache.
    ///
    /// **Test-only seam.** Production code MUST NOT call this — the default
    /// `audiobookSessionPresenter` resolved from `AppContainer.production()`
    /// is the single composition-root instance held by the static cache.
    /// This modifier exists so tests can inject a spy presenter via:
    ///
    /// ```swift
    /// let testContainer = AppContainer.production()
    ///     .withAudiobookSessionPresenter(spy)
    /// ```
    ///
    /// then pass `testContainer` to a system-under-test whose code path
    /// resolves `appContainer.audiobookSessionPresenter`. The override is
    /// preferred over the static cache by the computed property; the
    /// static cache itself is unaffected.
    ///
    /// Modifies a struct copy — does NOT mutate `self` or the static cache.
    /// Chaining with `withSignInModalSheetPresenter(_:)` preserves both
    /// overrides because each modifier forwards the other's override.
    ///
    /// swarm_0b7616e7 Module C — unblocks Module D's tests 12-13 which
    /// inject a spy presenter into AppTabHostView-driven seams. Mirrors
    /// the `withSignInModalSheetPresenter(_:)` precedent from
    /// swarm_d8f11437 Module B (wave 4).
    @MainActor
    func withAudiobookSessionPresenter(_ presenter: AudiobookSessionPresenter) -> AppContainer {
        return AppContainer(
            bookRegistry: self.bookRegistry,
            networkExecutor: self.networkExecutor,
            networkQueue: self.networkQueue,
            reachability: self.reachability,
            accountsManager: self.accountsManager,
            settings: self.settings,
            featureFlags: self.featureFlags,
            downloadCenter: self.downloadCenter,
            downloadAnnouncementService: self.downloadAnnouncementService,
            debugSettings: self.debugSettings,
            imageCache: self.imageCache,
            imageLoader: self.imageLoader,
            userAccountPublisher: self.userAccountPublisher,
            opdsFeedService: self.opdsFeedService,
            readerService: self.readerService,
            navigationCoordinatorHub: self.navigationCoordinatorHub,
            tabRouterHub: self.tabRouterHub,
            drmAuthorizerProvider: self.drmAuthorizerProvider,
            authCoordinator: self.authCoordinator,
            signInModalSheetPresenterOverride: self._signInModalSheetPresenterOverride,
            audiobookSessionPresenterOverride: presenter
        )
    }

    // Lazy-init on MainActor: BookCellModelCache and SamplePreviewManager are
    // @MainActor-isolated, but `_cached`'s static-let initializer can run on
    // any thread (first consumer of `production()` wins). Eager construction
    // there crashed with EXC_BREAKPOINT on background-thread first access.
    @MainActor
    var bookCellModelCache: BookCellModelCache {
        if let cached = AppContainer._bookCellModelCache { return cached }
        let cache = BookCellModelCache(
            imageCache: imageCache,
            bookRegistry: bookRegistry,
            downloadCenter: downloadCenter,
            accountsManager: accountsManager,
            samplePreviewManager: samplePreviewManager,
            readerService: readerService
        )
        AppContainer._bookCellModelCache = cache
        return cache
    }

    @MainActor
    var samplePreviewManager: SamplePreviewManager {
        if let cached = AppContainer._samplePreviewManager { return cached }
        let manager = SamplePreviewManager()
        AppContainer._samplePreviewManager = manager
        return manager
    }

    /// Process-wide audiobook session manager. Reads
    /// `accountsManager.currentAccount` internally on every operation, so
    /// account switches are observed without per-account caching. The cache
    /// cell stores the concrete `AudiobookSessionManager`; callers see only
    /// the `AudiobookSessionManaging` protocol surface.
    @MainActor
    var audiobookSession: AudiobookSessionManaging {
        if let cached = AppContainer._audiobookSession { return cached }
        // Pass the flag provider explicitly so the frozen god-class default arg
        // (RemoteFeatureFlags.shared, exception E4) stops firing in production.
        // FeatureFlagProviding is Sendable, so capturing `flags` in the
        // @escaping () -> Bool is clean under Swift 6 `complete`.
        let flags = self.featureFlags
        let session = AudiobookSessionManager(
            appContainer: self,
            inAppPlaybackNavEnabledProvider: { flags.isInAppPlaybackNavEnabled }
        )
        AppContainer._audiobookSession = session
        return session
    }

    /// Polish-phase (in-app-nav-polish-2026-06-01) — wall-clock open-time
    /// tracker keyed by book identifier. Used by `RecentlyReadingService`
    /// to surface the genuinely last-opened book on the Continue Reading
    /// row (without it, EPUB/PDF locations fall back to `book.updated`
    /// from the OPDS feed and the row shows the wrong book). Audiobook
    /// + reader open-paths record into this tracker.
    @MainActor
    var bookOpenTracker: BookOpenTracking {
        if let cached = AppContainer._bookOpenTracker { return cached }
        let tracker = BookOpenTracker()
        AppContainer._bookOpenTracker = tracker
        return tracker
    }
    @MainActor private static var _bookOpenTracker: BookOpenTracking?

    /// Side-loading (PP-2678) — process-wide registry of side-loaded books.
    /// Source of truth for the sync-exemption set (consumed by
    /// `BookRegistrySync.sync()` via a lazy provider) and the side-loaded
    /// catalog lane (Module D). File-backed shared cache, lazy + cached the
    /// same way `bookOpenTracker` is; `_resetForTesting()` nils it so its
    /// on-disk manifest state does not bleed across test classes.
    var sideloadedBookRegistry: SideloadedBookRegistry {
        if let cached = AppContainer._sideloadedBookRegistry.withLock({ $0 }) { return cached }
        // Built outside the lock (matches the prior non-atomic check-then-set
        // race semantics — `SideloadedBookRegistry()` does no `production()`
        // re-entry, so no deadlock even if two first-callers each build one).
        // The lock re-checks on store so a concurrent winner is honored and
        // the loser's instance is discarded; production callers observe a
        // single stable registry either way.
        let registry = SideloadedBookRegistry()
        return AppContainer._sideloadedBookRegistry.withLock { slot in
            if let existing = slot { return existing }
            slot = registry
            return registry
        }
    }
    /// Swift 6: `OSAllocatedUnfairLock`-guarded so the off-main first access
    /// (its `identifiers` is read off-main) is concurrency-safe without a
    /// `@MainActor` annotation that would forbid the off-main read. The
    /// stored value (`SideloadedBookRegistry`) is itself `@unchecked Sendable`.
    private static let _sideloadedBookRegistry = OSAllocatedUnfairLock<SideloadedBookRegistry?>(initialState: nil)

    /// Side-loading (PP-2677) — orchestrates the import/remove/rehydrate flow on
    /// top of `sideloadedBookRegistry`. Consumes the side-loaded registry (truth
    /// store + sync-exemption), the main `bookRegistry` (so the reader sees the
    /// book as `.downloadSuccessful`), and a `BookFileManager` for the fixed-
    /// account file path. Lazy + cached the same way `sideloadedBookRegistry` is;
    /// `_resetForTesting()` nils it so a stale manager doesn't outlive the
    /// registry it was wired to. Additive property only — the big `init`,
    /// `_buildCachedAppContainer()` return, and `with*Presenter` copies are NOT
    /// touched (Module A owns this property region; Module C appends here).
    var sideloadedBookManager: SideloadedBookManager {
        if let cached = AppContainer._sideloadedBookManager.withLock({ $0 }) { return cached }
        // Built outside the lock (see `sideloadedBookRegistry`). Reads
        // `self.sideloadedBookRegistry`, which acquires a DIFFERENT lock —
        // consistent manager→registry ordering, no reverse path, no deadlock.
        let manager = SideloadedBookManager(
            bookRegistry: self.bookRegistry,
            sideloadedRegistry: self.sideloadedBookRegistry,
            bookFileManager: BookFileManager()
        )
        return AppContainer._sideloadedBookManager.withLock { slot in
            if let existing = slot { return existing }
            slot = manager
            return manager
        }
    }
    /// Swift 6: `OSAllocatedUnfairLock`-guarded (see `_sideloadedBookRegistry`).
    /// Stored value is `@unchecked Sendable`.
    private static let _sideloadedBookManager = OSAllocatedUnfairLock<SideloadedBookManager?>(initialState: nil)

    /// Process-wide audiobook session presenter — the root-level
    /// SwiftUI-observable bridge between the manager's published state and
    /// the mini-player + full-screen-cover surfaces Module D wires into
    /// `AppTabHostView`. Lazy + cached the same way `audiobookSession` is.
    ///
    /// Resolution order (mirrors `signInModalSheetPresenter`):
    ///   1. Instance-local `_audiobookSessionPresenterOverride` (test seam,
    ///      set via `withAudiobookSessionPresenter(_:)`).
    ///   2. Static `_audiobookSessionPresenter` cache (production path).
    ///   3. Lazy-init a fresh presenter wired to `self.audiobookSession`,
    ///      store in the static cache, return it.
    ///
    /// swarm_0b7616e7 Module C — introduced for P3 of the in-app audiobook
    /// navigation design (`docs/architecture/in-app-navigation-during-playback.md`).
    @MainActor
    var audiobookSessionPresenter: AudiobookSessionPresenter {
        if let override = _audiobookSessionPresenterOverride { return override }
        if let cached = AppContainer._audiobookSessionPresenter { return cached }
        let presenter = AudiobookSessionPresenter(sessionManager: self.audiobookSession)
        AppContainer._audiobookSessionPresenter = presenter
        return presenter
    }

    /// Process-wide playback bootstrapper. Owns the warm-start CarPlay
    /// session-initialization invariant previously held by
    /// `PlaybackBootstrapper.shared`. The provider closure resolves the
    /// session lazily through `self.audiobookSession` so cache misses route
    /// through AppContainer rather than spinning up a parallel manager.
    @MainActor
    var playbackBootstrapper: PlaybackBootstrapper {
        if let cached = AppContainer._playbackBootstrapper { return cached }
        let bootstrapper = PlaybackBootstrapper(
            appContainer: self,
            audiobookSessionProvider: { [self] in self.audiobookSession }
        )
        AppContainer._playbackBootstrapper = bootstrapper
        return bootstrapper
    }

    /// App-rating service (Epic PP-4086). Owns engagement tracking + eligibility
    /// evaluation; persists through `self.settings` and reads thresholds from
    /// Remote Config. Lazy + cached like the audiobook services above.
    @MainActor
    var appRatingService: AppRatingService {
        if let cached = AppContainer._appRatingService { return cached }
        let flags = self.featureFlags
        let service = AppRatingService(
            tracker: RatingEngagementTracker(settings: self.settings),
            // Wave 1b exception E1: appRatingConfig returns RatingConfig (an
            // app-target type) — read off the concrete impl at this composition
            // root; it is deliberately NOT on the FeatureFlagProviding protocol.
            configProvider: { RemoteFeatureFlags.shared.appRatingConfig },
            promptEnabledProvider: { flags.isAppRatingPromptEnabled },
            forceEligibleProvider: { flags.isAppRatingForceEligible },
            crashFreeProbe: { FirebaseManager.shared.wasLastSessionCrashFree() },
            now: Date.init
        )
        AppContainer._appRatingService = service
        return service
    }

    /// Root-level presenter driving the app-rating sentiment gate (PP-4089).
    /// Observed by the overlay in `AppTabHostView`; lazy + cached like the
    /// audiobook presenter above.
    @MainActor
    var ratingPromptPresenter: RatingPromptPresenter {
        if let cached = AppContainer._ratingPromptPresenter { return cached }
        let presenter = RatingPromptPresenter(
            service: self.appRatingService,
            reviewRequester: RatingReviewRequester(),
            feedbackPresenter: RatingFeedbackPresenter()
        )
        AppContainer._ratingPromptPresenter = presenter
        return presenter
    }

    // MARK: - Shared Catalog Repository / API (swarm_27c181b5 A5)
    //
    // ONE process-wide `DefaultCatalogAPI` + `CatalogRepository`, resolved
    // lazily and cached statically — same lazy+cached shape as the presenters
    // above. Before this, `CatalogLaneMoreView.searchSection`,
    // `CatalogSearchView`, and `CatalogLaneMoreViewModel` each built a fresh
    // `CatalogRepository(api: DefaultCatalogAPI(...))` on every body/init,
    // giving each render its own throwaway in-memory cache and defeating the
    // account-scoped stale-while-revalidate cache. Sharing one instance keeps
    // the cache warm across catalog navigation. The repository is account-UUID
    // scoped (mirrors `AppTabHostView`'s main catalog repository) so library
    // A's catalog can never be served to library B.

    @MainActor
    var catalogAPI: DefaultCatalogAPI {
        if let cached = AppContainer._catalogAPI { return cached }
        let api = DefaultCatalogAPI(
            client: URLSessionNetworkClient(),
            parser: OPDSParser(),
            featureFlags: self.featureFlags
        )
        AppContainer._catalogAPI = api
        return api
    }

    @MainActor
    var catalogRepository: CatalogRepositoryProtocol {
        if let cached = AppContainer._catalogRepository { return cached }
        let accountsManager = self.accountsManager
        let repository = CatalogRepository(
            api: catalogAPI,
            accountID: { [weak accountsManager] in accountsManager?.currentAccount?.uuid }
        )
        AppContainer._catalogRepository = repository
        return repository
    }

    @MainActor private static var _catalogAPI: DefaultCatalogAPI?
    @MainActor private static var _catalogRepository: CatalogRepositoryProtocol?

    @MainActor private static var _bookCellModelCache: BookCellModelCache?
    @MainActor private static var _samplePreviewManager: SamplePreviewManager?
    @MainActor private static var _audiobookSession: AudiobookSessionManager?
    @MainActor private static var _audiobookSessionPresenter: AudiobookSessionPresenter?
    @MainActor private static var _playbackBootstrapper: PlaybackBootstrapper?
    @MainActor private static var _appRatingService: AppRatingService?
    @MainActor private static var _ratingPromptPresenter: RatingPromptPresenter?

    init(
        bookRegistry: TPPBookRegistryProvider,
        networkExecutor: TPPNetworkExecutor,
        networkQueue: NetworkQueue,
        reachability: Reachability,
        accountsManager: AccountsManager,
        settings: TPPSettings,
        featureFlags: FeatureFlagProviding,
        downloadCenter: MyBooksDownloadCenter,
        downloadAnnouncementService: DownloadAnnouncementService,
        debugSettings: DebugSettings,
        imageCache: ImageCacheType,
        imageLoader: ImageLoading,
        userAccountPublisher: UserAccountPublisher,
        opdsFeedService: OPDSFeedService,
        readerService: ReaderService,
        navigationCoordinatorHub: NavigationCoordinatorHub,
        tabRouterHub: AppTabRouterHub,
        drmAuthorizerProvider: @escaping () -> TPPDRMAuthorizing?,
        authCoordinator: AuthCoordinator,
        signInModalSheetPresenterOverride: SignInModalSheetPresenter? = nil,
        audiobookSessionPresenterOverride: AudiobookSessionPresenter? = nil
    ) {
        self.bookRegistry = bookRegistry
        self.networkExecutor = networkExecutor
        self.networkQueue = networkQueue
        self.reachability = reachability
        self.accountsManager = accountsManager
        self.settings = settings
        self.featureFlags = featureFlags
        self.downloadCenter = downloadCenter
        self.downloadAnnouncementService = downloadAnnouncementService
        self.debugSettings = debugSettings
        self.imageCache = imageCache
        self.imageLoader = imageLoader
        self.userAccountPublisher = userAccountPublisher
        self.opdsFeedService = opdsFeedService
        self.readerService = readerService
        self.navigationCoordinatorHub = navigationCoordinatorHub
        self.tabRouterHub = tabRouterHub
        self.drmAuthorizerProvider = drmAuthorizerProvider
        self.authCoordinator = authCoordinator
        self._signInModalSheetPresenterOverride = signInModalSheetPresenterOverride
        self._audiobookSessionPresenterOverride = audiobookSessionPresenterOverride
    }

    static func production() -> AppContainer {
        let container = _cachedValue()
        container.ensureOfflineQueueExecutorRegistered()
        return container
    }

    /// Reliability WS-C (seam S2): install the offline-queue executor
    /// exactly once. The coordinator is retained in a process-wide slot so
    /// its `[weak self]` executor closure stays alive; the actual
    /// `setExecutor` call lives in `OfflineQueueCoordinator.registerExecutor()`
    /// (WS-C owns the wiring). Empty-fast on every subsequent call.
    private static let _offlineQueueCoordinator =
        OSAllocatedUnfairLock<OfflineQueueCoordinator?>(initialState: nil)

    func ensureOfflineQueueExecutorRegistered() {
        let coordinator: OfflineQueueCoordinator? =
            AppContainer._offlineQueueCoordinator.withLock { slot in
                if slot != nil { return nil }
                let c = OfflineQueueCoordinator.production(
                    downloadCenter: self.downloadCenter,
                    bookRegistry: self.bookRegistry
                )
                slot = c
                return c
            }
        guard let coordinator else { return }
        Task { await coordinator.registerExecutor() }
    }

    /// The cached app-wide composition graph. Initially populated by Swift's
    /// lazy-static initializer (which runs `_buildCachedAppContainer()` once
    /// under the runtime's one-time guard, matching the prior `static let`
    /// dispatch_once semantics byte-for-byte for production callers).
    ///
    /// `static var` (not `let`) so the test-only `_resetForTesting()` seam
    /// can rebuild the graph between XCTestCase runs — see
    /// `_resetForTesting()` below for the rationale and the documented
    /// residual race window.
    ///
    /// swarm_4b64e4e0 Fix 2 — closes the H1 finding from swarm_f88ae9e3 A.
    /// Production behaviour is unchanged: first read materialises the value via
    /// `_buildCachedAppContainer()` under the lock; subsequent reads return it.
    ///
    /// Swift 6 `complete`: `OSAllocatedUnfairLock`-guarded (matching this file's
    /// `_sideloadedBookRegistry` precedent) instead of a bare mutable `static var`,
    /// which is a data-race hazard under strict concurrency. The lock preserves the
    /// prior lazy-once semantics for production callers (first `production()` read
    /// builds once; the test-only rebuild seams reassign through the lock) without
    /// pinning `AppContainer` to any actor.
    private static let _cachedLock = OSAllocatedUnfairLock<AppContainer?>(initialState: nil)

    private static func _cachedValue() -> AppContainer {
        _cachedLock.withLock { slot in
            if let existing = slot { return existing }
            let built = Self._buildCachedAppContainer()
            slot = built
            return built
        }
    }

    /// Builds a fresh AppContainer composition graph. Extracted from the
    /// prior `static let _cached: AppContainer = { ... }()` lambda VERBATIM
    /// — every line below preserves the original dispatch_once-cycle-avoidance
    /// invariants (TPPBookRegistry takes AccountsManager explicitly; no
    /// default arg ever fires; collaborator construction is hand-threaded
    /// through `executor`, `reachability`, `accountsManager`, etc.).
    /// Test seam (NOT `#if DEBUG` — BR-2/blast-radius forbids `#if DEBUG` on
    /// production paths; this is a plain internal hook that is EMPTY in
    /// production, so it changes nothing there). Tests set this (via
    /// `PalaceTestSetup`) so the SHARED network executor's `URLSession` includes
    /// `NoNetworkURLProtocol`: `URLProtocol.registerClass` only covers
    /// `URLSession.shared`, NOT a `URLSession(configuration:)`, which consults
    /// only its `config.protocolClasses` — so the shared executor that
    /// `AccountsManager.fallbackDirectRefresh` uses would otherwise escape to the
    /// real `registry.palaceproject.io` in unit tests. The executor is rebuilt
    /// with this on every `_resetForTesting()` (which re-runs the builder below),
    /// so the protocol applies to every test's graph. Follows AppContainer's
    /// existing lock-backed static pattern (e.g. `_cached`, `_sideloadedBookRegistry`).
    ///
    /// Swift 6 `complete`: backed by an `OSAllocatedUnfairLock` rather than a bare
    /// mutable `static var` (a data-race hazard). The computed accessor keeps the
    /// `AppContainer.testExecutorProtocolClasses = [...]` / read API the test seams
    /// use, so no call site changes. Empty in production — zero behaviour change.
    private static let _testExecutorProtocolClassesLock =
        OSAllocatedUnfairLock<[AnyClass]>(initialState: [])

    internal static var testExecutorProtocolClasses: [AnyClass] {
        get { _testExecutorProtocolClassesLock.withLock { $0 } }
        set { _testExecutorProtocolClassesLock.withLock { $0 = newValue } }
    }

    /// Builds the shared network executor. In production `testExecutorProtocolClasses`
    /// is empty, so this is the verbatim default `TPPNetworkExecutor(cachingStrategy:
    /// .fallback)` — zero production change. When a test installs extra protocol
    /// classes, the executor is built through the EXISTING
    /// `init(... sessionConfiguration:)` seam with those classes prepended onto a
    /// normal `.fallback` config (no new TPPNetworkExecutor/PalaceNetwork surface).
    private static func makeNetworkExecutor() -> TPPNetworkExecutor {
        let extra = testExecutorProtocolClasses
        guard !extra.isEmpty else {
            return TPPNetworkExecutor(cachingStrategy: .fallback)
        }
        let config = TPPCaching.makeURLSessionConfiguration(
            caching: .fallback,
            requestTimeout: TPPNetworkExecutor.defaultRequestTimeout)
        config.protocolClasses = extra + (config.protocolClasses ?? [])
        return TPPNetworkExecutor(cachingStrategy: .fallback, sessionConfiguration: config)
    }

    /// Non-DEBUG test seam (BR-2 forbids `#if DEBUG` on prod paths; this is a
    /// plain internal method that production never calls). Rebuilds the cached
    /// graph so its network executor picks up `testExecutorProtocolClasses`.
    /// Needed because the host app already built the cached graph (and its
    /// executor) during launch — BEFORE the test bundle could install the test
    /// protocol classes — and the per-test `_resetForTesting` rebuild is
    /// `#if DEBUG` (compiled out in the non-DEBUG config `harness test` uses), so
    /// without this the executor would never honor `NoNetworkURLProtocol` locally
    /// (and the FIRST test of any run would escape even under DEBUG/CI).
    /// `PalaceTestSetup` calls this once, after installing the protocol classes.
    internal static func _rebuildCachedForTestProtocols() {
        _cachedLock.withLock { $0 = _buildCachedAppContainer() }
    }

    private static func _buildCachedAppContainer() -> AppContainer {
        let executor = makeNetworkExecutor()
        let reachability = Reachability()
        // AccountsManager and TPPBookRegistry are constructed inline here.
        // TPPBookRegistry.init takes AccountsManager as an explicit dependency,
        // and reading either via `AppContainer.production()` during this
        // dispatch_once would deadlock on first launch (the cycle that
        // motivated killing TPPBookRegistry.shared in Phase 6.6). We hand
        // both into AppContainer.init — and into every collaborator built
        // here — explicitly so no default arg ever fires.
        // CP-D1 LaunchHydration: `AccountsManager.init` no longer eagerly
        // decodes+maps the full ~1142-account registry on this (launch) thread.
        // It hydrates only a SLIM snapshot (current + settings accounts, a few
        // ms) synchronously; the full list materializes OFF-MAIN via the
        // background `loadCatalogs` the initializer dispatches. Do NOT reintroduce
        // a synchronous full-account preload here — `production()` must return
        // without paying the ~207ms (fast sim) / ~0.3-0.6s (device) full decode.
        let accountsManager = AccountsManager()
        // Single image-loading umbrella composed of the existing disk+memory
        // ImageCache and the TPPBookCoverRegistry actor — replaces three
        // overlapping singletons at consumer sites (Track A of the 3.2.0
        // singleton sweep). Constructed BEFORE TPPBookRegistry because the
        // registry now takes ImageLoading as a required init param; the prior
        // ordering relied on a default arg `imageLoader = ImageLoader.production`
        // that re-entered _cached's own dispatch_once and SIGTRAPped on launch.
        let imageCache = ImageCache.shared
        let imageLoader: ImageLoading = ImageLoader(imageCache: imageCache)
        // Wave 2a: configure the package-side image context BEFORE the first
        // TPPBook is constructed (the registry construction below parses records).
        TPPBookImageContext.imageCacheProvider = { imageCache }
        TPPBookImageContext.imageLoaderProvider = { imageLoader }
        // god-class decomposition Wave 2b: the registry engine now lives in the
        // PalaceBookRegistry package and consumes accounts through the value-only
        // `AccountScopeProviding` inversion + a `RegistryExternalDependencies` bundle.
        // The convenience init builds the `AccountsManagerAccountScopeAdapter` and the
        // `.production()` dependency bundle whose provider closures keep the SAME lazy
        // `AppContainer.production()` resolution the engine's inline closures had
        // (deferred to first use, so a mid-reset rebuild can't capture a stale graph
        // and construction here doesn't re-enter the still-resolving dispatch_once).
        let bookRegistry = TPPBookRegistry(accountsManager: accountsManager, imageLoader: imageLoader)
        // Build one accessibility announcer and one DownloadAnnouncementService
        // that wraps it. Sharing this announcer between the service and any
        // other consumers (MyBooksDownloadCenter still calls
        // `announceStatus` directly via its own `accessibilityAnnouncements`
        // field) keeps deduplication coherent across paths.
        let accessibilityAnnouncer = TPPAccessibilityAnnouncementCenter()
        let downloadAnnouncementService = DownloadAnnouncementService(announcer: accessibilityAnnouncer)
        // MyBooksDownloadCenter has *four* default params that resolve via
        // AppContainer.production(): accountsManager, bookRegistry,
        // networkExecutor, reachability. Calling the no-arg init here would
        // re-enter this dispatch_once on every one of them. Pass them all
        // explicitly to break the cycle.
        // swarm_66819d80 Module C — single auth-refresh coordinator.
        // Built BEFORE MyBooksDownloadCenter so MBDC's BookReturnService
        // construction can receive a non-nil coordinator. Held by the
        // AppContainer for app lifetime; injected anywhere a 401/403
        // handler used to live. MainActor.assumeIsolated is required
        // because `CoordinatorSignInModalPresenter` is `@MainActor`-
        // isolated and the dispatch_once block runs on the first
        // consumer's thread.
        // swarm_66819d80 Module D — structured Crashlytics non-fatal for
        // every auth decision. PalaceAuth holds the recorder via the
        // injected `AuthDecisionRecording` protocol; the main-target
        // wrapper (`AuthDecisionRecorder`) is the only piece that touches
        // FirebaseCrashlytics. libraryUUID is a closure read at emission
        // time so account swaps reflect in the next event without
        // rebuilding the coordinator.
        let authDecisionRecorder: AuthDecisionRecording = AuthDecisionRecorder()
        let authCoordinator: AuthCoordinator = MainActor.assumeIsolated {
            AuthCoordinator(
                reauthenticator: TPPReauthenticator(),
                modalPresenter: CoordinatorSignInModalPresenter(accountsManager: accountsManager),
                userAccount: CoordinatorUserAccountAdapter(accountsManager: accountsManager),
                accountProvider: CoordinatorAccountProvider(accountsManager: accountsManager),
                recorder: authDecisionRecorder,
                libraryUUIDProvider: { [weak accountsManager] in
                    accountsManager?.currentAccount?.uuid
                }
            )
        }
        let downloadCenter = MyBooksDownloadCenter(
            bookRegistry: bookRegistry,
            accountsManager: accountsManager,
            networkExecutor: executor,
            accessibilityAnnouncements: accessibilityAnnouncer,
            downloadAnnouncementService: downloadAnnouncementService,
            reachability: reachability,
            authCoordinator: authCoordinator
        )
        // `UserAccountPublisher.shared` is `@MainActor`-isolated; this builder
        // runs on the main thread (it is only ever reached from the first
        // `production()` caller, which is UIKit app-launch lifecycle —
        // `TPPAppDelegate.application(_:didFinishLaunchingWithOptions:)` /
        // `SceneDelegate` — and from main-thread XCTest setup). The same
        // main-thread precondition is already asserted a few lines above where
        // `authCoordinator` is built inside `MainActor.assumeIsolated`, so this
        // read introduces no new precondition. Hoisted behind `assumeIsolated`
        // to satisfy the `targeted` checker without a signature change.
        let userAccountPublisher = MainActor.assumeIsolated { UserAccountPublisher.shared }
        return AppContainer(
            bookRegistry: bookRegistry,
            networkExecutor: executor,
            networkQueue: NetworkQueue(transport: executor.transport, reachability: reachability),
            reachability: reachability,
            accountsManager: accountsManager,
            settings: TPPSettings(),
            // Composition root — the one legitimate binding site for the seam.
            // `.shared` keeps the process-singleton identity (one lastFetchTime,
            // one `.standard`-backed override store, the same instance CarPlay's
            // cached-read path warms). Constructing a second instance here would
            // fork the CarPlay UserDefaults cache writer.
            featureFlags: RemoteFeatureFlags.shared,
            downloadCenter: downloadCenter,
            downloadAnnouncementService: downloadAnnouncementService,
            debugSettings: DebugSettings(),
            imageCache: imageCache,
            imageLoader: imageLoader,
            userAccountPublisher: userAccountPublisher,
            opdsFeedService: OPDSFeedService(),
            readerService: ReaderService(),
            navigationCoordinatorHub: NavigationCoordinatorHub(),
            tabRouterHub: AppTabRouterHub(),
            drmAuthorizerProvider: {
                #if FEATURE_DRM_CONNECTOR
                return AdobeCertificate.isDRMAvailable ? AdobeDRMService.shared.adeptInstance : nil
                #else
                return nil
                #endif
            },
            authCoordinator: authCoordinator
        )
    }

    #if DEBUG
    /// Test-only: reset the cached AppContainer with a fresh graph and the
    /// AccountsManager test opt-out enabled. Called by
    /// `PalaceTestSetup`'s XCTestObservation registry between test cases.
    ///
    /// Sequence:
    ///   1. Flip `AccountsManager.deferInitialLoadCatalogsForTesting = true`
    ///      — this is read inside `AccountsManager.init` and is the entire
    ///      reason this seam exists (the prior cached graph constructed
    ///      AccountsManager WITHOUT the opt-out, spawning the process-wide
    ///      `loadCatalogs` race that drives the `numAccounts=100→1150`
    ///      90-second CI drift documented in swarm_f88ae9e3 A's H1
    ///      finding).
    ///   2. Cancel the prior cached AccountsManager's background work via
    ///      its `cancelBackgroundWork()` seam. Best-effort — cooperative
    ///      cancellation; in-flight URLSession callbacks may still fire
    ///      briefly before observing `Task.isCancelled`.
    ///   3. Atomically reassign `_cached` to a freshly-built AppContainer
    ///      whose AccountsManager observes the opt-out flag.
    ///   4. Leave the AccountsManager opt-out flag at the test-safe value
    ///      `true`. This runs after EVERY test (via the singleton-reset
    ///      observer), so the flag it leaves behind is what the NEXT test
    ///      class inherits before its own setUp runs. Leaving it `false`
    ///      (the prior behaviour) meant any later test that incidentally
    ///      constructed an `AccountsManager` — directly or via
    ///      `AppContainer.production()` — spawned the background registry
    ///      crawl, whose stray Task outlived the test and polluted whatever
    ///      ran next (layout-off-main crashes, token/network bleed, the
    ///      `numAccounts` drift). Tests that genuinely need the background
    ///      load opt IN by setting the flag `false` in their own setUp
    ///      (`AppContainerResetTests`); the safe default between tests is
    ///      `true`, matching `PalaceTestSetup.bootstrap()`.
    ///
    /// Residual race window (DOCUMENTED INTENTIONAL):
    /// Step 2's cancellation is cooperative. If the prior AccountsManager's
    /// `fetchFromNetwork` Task is mid-await on `crawler.crawlFirstPage`, the
    /// completion still fires and writes through to `accountSets` on the OLD
    /// instance — but the OLD instance is no longer reachable from
    /// `production()`, so the write is observable only by code paths that
    /// held a strong reference to the prior `accountsManager` (none in
    /// production; vanishingly few in tests). The next test gets a clean
    /// `production()` graph regardless. This window is the brief moment
    /// between cancel-request and Task cancellation observation; on a
    /// 100Mbps link with the bundled snapshot path, < 50ms in 99% of cases.
    /// Acceptable per swarm_4b64e4e0 outcome.md user direction.
    ///
    /// swarm_4b64e4e0 Fix 2 — DEBUG-only test seam. Not callable from
    /// production code (compile-time gated). The function is `internal` so
    /// the test target can call it via `@testable import Palace`.
    internal static func _resetForTesting() {
        // Runtime gate: in addition to the compile-time `#if DEBUG`, refuse
        // to fire outside of an XCTest process. `#if DEBUG` is on in TestFlight
        // and developer sim builds too — this env-var is XCTest's own seam
        // and is only ever present when xctest is the host. Defense-in-depth
        // against accidental call from a DEBUG build that isn't actually
        // running tests (matches the check-blast-radius BR-2 env-gate rule
        // re: XCTestConfigurationFilePath).
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil else {
            return
        }
        AccountsManager.deferInitialLoadCatalogsForTesting = true
        // Cancel AND synchronously DRAIN the prior cached AccountsManager's
        // background loadCatalogs crawl before rebuilding. The cooperative
        // `cancelBackgroundWork()` alone returned immediately, leaving a
        // just-cancelled crawl mid-flight holding the `accountSetsLock` barrier
        // — which the next test's @MainActor reauth `.sync` read deadlocked
        // against (120s main-jam "auth-state-bleed"). Draining (with run-loop
        // pumping) closes that residual race globally at every test boundary.
        // WS-0 follow-up; see AccountsManager.cancelAndDrainBackgroundWork.
        // Drain the prior cached graph's crawl, then rebuild. Build OUTSIDE the
        // lock (`_buildCachedAppContainer` must not re-enter the lock) and assign
        // the fresh graph through it — same reassign semantics as the old
        // `_cached = ...`, now race-safe under `complete`.
        _cachedValue().accountsManager.cancelAndDrainBackgroundWork()
        // Global drain: the per-manager drain above only touches the CURRENT
        // cached manager. A foreign AccountsManager built by an earlier test
        // (e.g. an `AppContainer.production()` manager a Catalog/Borrow test
        // never tore down) keeps a leaked `loadCatalogs` crawl / deferred
        // auth-doc main-hop that late-writes `AccountStateStore.shared` and
        // pollutes later async victims. Drain ALL live instances here — BEFORE
        // the `AccountStateStore.shared._resetAllForTesting()` resetter (which
        // is registered AFTER this `AppContainer._resetForTesting` resetter in
        // `PalaceTestSetup.registerBuiltInResetters`, so it runs strictly after
        // this whole function) so any flushed late write is then wiped. This is
        // the shared mechanism behind BOTH pollution clusters. Idempotent, so
        // re-draining the current manager captured above is harmless.
        AccountsManager._drainAllLiveInstancesForTesting()
        let rebuilt = Self._buildCachedAppContainer()
        _cachedLock.withLock { $0 = rebuilt }
        // Reset the process-wide audiobook session/presenter statics — the only
        // graph members `_buildCachedAppContainer()` does NOT rebuild. Left
        // intact, `_audiobookSessionPresenter` carries active-session state (and
        // its `.receive(on: main)` subscription) across test-class boundaries:
        // an upstream test that leaves the presenter `.playing` then reds
        // `CarPlayAudiobookBridgePresenterMigrationTests.testCarPlayBridge_dismissBookOnPhone`
        // in-suite (its precondition reads the shared `hasActiveSession`). Nil-ing
        // them here means the next `production()` resolution rebuilds a fresh
        // presenter subscribed to a fresh session, releasing the polluted one —
        // order-independent, neutralizing ANY polluter. Same never-reset-static
        // pattern as the AccountsManager crawl-drain above. M0-reconverge.
        //
        // `MainActor.assumeIsolated` because these are `@MainActor`-isolated
        // statics and `_resetForTesting()` is nonisolated — matching the same
        // assertion `_buildCachedAppContainer()` (called just above) already
        // makes. The test-boundary reset always runs on the main thread.
        MainActor.assumeIsolated {
            _audiobookSession = nil
            _audiobookSessionPresenter = nil
            _playbackBootstrapper = nil
            _appRatingService = nil
            _ratingPromptPresenter = nil
        }
        // Side-loading (PP-2678): the side-loaded registry is a file-backed
        // shared static cache, so it WOULD bleed manifest state across test
        // classes if left intact. Nil it here so the next `production()`
        // resolution rebuilds a fresh instance reading the current manifest.
        // Not `@MainActor`-isolated (its `identifiers` is read off-main), so
        // reset outside the `assumeIsolated` block. Now lock-guarded storage
        // (Swift 6) — clear the slot through the lock.
        _sideloadedBookRegistry.withLock { $0 = nil }
        // Side-loading (PP-2677): the manager caches a reference to the
        // side-loaded registry above, so nil it in lockstep — a stale manager
        // would keep pointing at the reset registry across test classes.
        _sideloadedBookManager.withLock { $0 = nil }
        // Leave the flag at the test-safe `true` (see step 4 above) — do NOT
        // reset to `false`. The next test class inherits this value before its
        // own setUp runs; `false` here is the root of the cross-test
        // background-crawl pollution.
        AccountsManager.deferInitialLoadCatalogsForTesting = true
    }
    #endif
}

// MARK: - SwiftUI Environment Integration

private struct AppContainerKey: EnvironmentKey {
    // Computed so SwiftUI re-routes through production() on every access.
    // When `_resetForTesting()` rebuilds `_cached`, this default tracks the rebuild
    // instead of capturing the pre-reset instance once at first read.
    static var defaultValue: AppContainer { AppContainer.production() }
}

extension EnvironmentValues {
    var appContainer: AppContainer {
        get { self[AppContainerKey.self] }
        set { self[AppContainerKey.self] = newValue }
    }
}
