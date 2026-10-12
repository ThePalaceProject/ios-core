import SwiftUI
import PalacePreferences
import PalaceFeatureFlags
import Combine
import os
import PalaceAuth
import PalaceNetwork
import PalaceCatalog // shared CatalogRepository / DefaultCatalogAPI accessor
import PalaceBookModel
import PalaceBookRegistry
import PalaceLogging

// `@unchecked Sendable`: every stored member is set once at the composition
// root (the private `var`s change only on a local copy before it is returned).
// It cannot synthesize `: Sendable` because `drmAuthorizerProvider` is a
// non-`@Sendable` closure and several collaborators (`TPPNetworkExecutor`,
// `AccountsManager`, …) are not Sendable-audited; forcing it would cascade
// across the DI graph. The only mutable state it reaches is
// `AppContainerOwnedServices`, which is `@MainActor`-isolated.
struct AppContainer: @unchecked Sendable {

    let bookRegistry: TPPBookRegistryProvider
    let networkExecutor: TPPNetworkExecutor
    let networkQueue: NetworkQueue
    let reachability: Reachability
    let accountsManager: AccountsManager
    let settings: TPPSettings
    /// The feature-flag read seam. Protocol-typed so tests inject
    /// MockFeatureFlagProvider; production binds RemoteFeatureFlags.shared.
    let featureFlags: FeatureFlagProviding
    let downloadCenter: MyBooksDownloadCenter
    /// Fails `downloadCenter`'s in-flight downloads when connectivity drops.
    /// Held for the container's lifetime. Tests that build a container around
    /// another container's download center leave it `nil`, so one center never
    /// gets two monitors.
    let downloadNetworkLossMonitor: DownloadNetworkLossMonitor?
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

    /// Single auth-refresh dispatcher. Every network consumer that sees a
    /// 401/403 routes through it instead of carrying per-call-site IdP
    /// dispatch. Held for app lifetime.
    let authCoordinator: AuthCoordinator

    /// Test-only override for `signInModalSheetPresenter`; `nil` in
    /// production. Set via `withSignInModalSheetPresenter(_:)`.
    private var _signInModalSheetPresenterOverride: SignInModalSheetPresenter?

    /// Test-only override for `audiobookSessionPresenter`; `nil` in
    /// production. Set via `withAudiobookSessionPresenter(_:)`.
    private var _audiobookSessionPresenterOverride: AudiobookSessionPresenter?

    /// The services this container owns (see `AppContainerOwnedServices`).
    /// Plain copies share the link, so `production()` reads and SwiftUI
    /// environment copies resolve one set of services. `with...` copies get a
    /// new owner link; `nonOwningCopy()` gets a weak one.
    private var ownedServicesLink: OwnedServicesLink

    /// The storage this container resolves owned services from. When a
    /// non-owning copy outlives its owner, it gets a throwaway storage, so
    /// each read builds a working but uncached service.
    @MainActor
    private var ownedServices: AppContainerOwnedServices {
        switch ownedServicesLink {
        case .owner(let storage):
            return storage
        case .nonOwning(let reference):
            return reference.storage ?? AppContainerOwnedServices()
        }
    }

    /// A copy that resolves this container's owned services without keeping
    /// them alive. Services the container owns hold this form of their
    /// container, so they do not form a retain cycle with it.
    func nonOwningCopy() -> AppContainer {
        var copy = self
        switch ownedServicesLink {
        case .owner(let storage):
            copy.ownedServicesLink = .nonOwning(WeakOwnedServices(storage))
        case .nonOwning:
            break
        }
        return copy
    }

    /// SwiftUI-observable facade over the static `SignInModalPresenter` API.
    /// Owned by this container, so every consumer reading through the same
    /// container observes one instance. An override set via
    /// `withSignInModalSheetPresenter(_:)` takes precedence.
    @MainActor
    var signInModalSheetPresenter: SignInModalSheetPresenter {
        if let override = _signInModalSheetPresenterOverride { return override }
        let storage = ownedServices
        if let cached = storage.signInModalSheetPresenter { return cached }
        let presenter = SignInModalSheetPresenter(appContainer: nonOwningCopy())
        storage.signInModalSheetPresenter = presenter
        return presenter
    }

    /// Returns a copy of this container whose `signInModalSheetPresenter` is
    /// `presenter`. Test-only seam; production code must not call this.
    ///
    /// The copy keeps every collaborator and the other override, so chained
    /// `with...` calls preserve both. It owns new storage: its other owned
    /// services are built against the copy, and `self`'s are left untouched.
    @MainActor
    func withSignInModalSheetPresenter(_ presenter: SignInModalSheetPresenter) -> AppContainer {
        var copy = withNewOwnedServices()
        copy._signInModalSheetPresenterOverride = presenter
        return copy
    }

    /// Returns a copy of this container whose `audiobookSessionPresenter` is
    /// `presenter`. Test-only seam; production code must not call this.
    /// Same copy semantics as `withSignInModalSheetPresenter(_:)`.
    @MainActor
    func withAudiobookSessionPresenter(_ presenter: AudiobookSessionPresenter) -> AppContainer {
        var copy = withNewOwnedServices()
        copy._audiobookSessionPresenterOverride = presenter
        return copy
    }

    private func withNewOwnedServices() -> AppContainer {
        var copy = self
        copy.ownedServicesLink = .owner(AppContainerOwnedServices())
        return copy
    }

    // Lazy-init on MainActor: BookCellModelCache and SamplePreviewManager are
    // @MainActor-isolated, but `_cached`'s static-let initializer can run on
    // any thread (first consumer of `production()` wins). Eager construction
    // there crashed with EXC_BREAKPOINT on background-thread first access.
    @MainActor
    var bookCellModelCache: BookCellModelCache {
        let storage = ownedServices
        if let cached = storage.bookCellModelCache { return cached }
        let cache = BookCellModelCache(
            imageCache: imageCache,
            bookRegistry: bookRegistry,
            downloadCenter: downloadCenter,
            accountsManager: accountsManager,
            samplePreviewManager: samplePreviewManager,
            readerService: readerService
        )
        storage.bookCellModelCache = cache
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

    /// Wall-clock open-time tracker keyed by book identifier. Audiobook +
    /// reader open-paths record into it. Its only reader (the "Continue"
    /// catalog rows) was removed in PP-4910, so the tracker is currently
    /// write-only — retained because the recording call sites live in the
    /// critical-path reader/audiobook flows and a future "resume" re-entry
    /// point would consume it. See PP-4910's removal note.
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
    /// catalog lane. File-backed shared cache, lazy + cached the
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
    /// top of `sideloadedBookRegistry`. Writes the main `bookRegistry` too, so
    /// the reader sees the book as `.downloadSuccessful`. Lazy + cached like
    /// `sideloadedBookRegistry`; `_resetForTesting()` nils it so a stale
    /// manager doesn't outlive the registry it was wired to.
    var sideloadedBookManager: SideloadedBookManager {
        if let cached = AppContainer._sideloadedBookManager.withLock({ $0 }) { return cached }
        // Built outside the lock (see `sideloadedBookRegistry`). Reads
        // `self.sideloadedBookRegistry`, which acquires a DIFFERENT lock —
        // consistent manager→registry ordering, no reverse path, no deadlock.
        let manager = SideloadedBookManager(
            bookRegistry: self.bookRegistry,
            sideloadedRegistry: self.sideloadedBookRegistry,
            bookFileManager: BookFileManager(accountScope: self.downloadAccountContext)
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
    /// the mini-player + full-screen-cover surfaces in `AppTabHostView`.
    /// Resolution order mirrors `signInModalSheetPresenter`. See
    /// `docs/architecture/in-app-navigation-during-playback.md`.
    @MainActor
    var audiobookSessionPresenter: AudiobookSessionPresenter {
        if let override = _audiobookSessionPresenterOverride { return override }
        if let cached = AppContainer._audiobookSessionPresenter { return cached }
        let presenter = AudiobookSessionPresenter(
            sessionManager: self.audiobookSession,
            // The player's download bar must distinguish the `.lcpa` network
            // fetch from local track decryption; the download centre is the
            // only thing that knows. Same signal the half-sheet consumes.
            archiveTransferPublisher: self.downloadCenter.lcpContentDownloadPublisher.eraseToAnyPublisher(),
            archiveProgressPublisher: self.downloadCenter.progressReporter.downloadProgressPublisher.eraseToAnyPublisher(),
            isArchiveTransferActive: { [weak downloadCenter = self.downloadCenter] identifier in
                downloadCenter?.progressReporter.isLCPContentTransferActive(for: identifier) ?? false
            }
        )
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
            // appRatingConfig returns RatingConfig (an app-target type), so it
            // is read off the concrete impl here and is deliberately not on the
            // FeatureFlagProviding protocol.
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

    // MARK: - Catalog Repository / API
    //
    // One `DefaultCatalogAPI` + `CatalogRepository` per container, so the
    // stale-while-revalidate cache stays warm across catalog navigation instead
    // of each view building a throwaway repository. The repository is scoped by
    // account UUID so one library's catalog is never served to another.

    @MainActor
    var catalogAPI: DefaultCatalogAPI {
        let storage = ownedServices
        if let cached = storage.catalogAPI { return cached }
        let api = DefaultCatalogAPI(
            client: URLSessionNetworkClient(executor: self.networkExecutor),
            parser: OPDSParser(),
            featureFlags: self.featureFlags
        )
        storage.catalogAPI = api
        return api
    }

    @MainActor
    var catalogRepository: CatalogRepositoryProtocol {
        let storage = ownedServices
        if let cached = storage.catalogRepository { return cached }
        let accountsManager = self.accountsManager
        let repository = CatalogRepository(
            api: catalogAPI,
            accountID: { [weak accountsManager] in accountsManager?.currentAccount?.uuid }
        )
        storage.catalogRepository = repository
        return repository
    }

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
        downloadNetworkLossMonitor: DownloadNetworkLossMonitor? = nil
    ) {
        self.bookRegistry = bookRegistry
        self.networkExecutor = networkExecutor
        self.networkQueue = networkQueue
        self.reachability = reachability
        self.accountsManager = accountsManager
        self.settings = settings
        self.featureFlags = featureFlags
        self.downloadCenter = downloadCenter
        self.downloadNetworkLossMonitor = downloadNetworkLossMonitor
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
        self.ownedServicesLink = .owner(AppContainerOwnedServices())
    }

    /// Binds a network-loss monitor to `downloadCenter`'s reachability (the one
    /// its pre-flight checks read), active-download maps, registry and failure
    /// alert. The monitor gets those, not the center.
    @MainActor
    static func makeDownloadNetworkLossMonitor(
        for downloadCenter: MyBooksDownloadCenter
    ) -> DownloadNetworkLossMonitor {
        DownloadNetworkLossMonitor(
            connectivity: downloadCenter.reachability.connectivityPublisher,
            activeTasks: downloadCenter.stateManager.taskIdentifierToBook,
            activeDownloads: downloadCenter.stateManager.bookIdentifierToDownloadInfo,
            bookRegistry: downloadCenter.bookRegistry,
            failDownload: { [weak downloadCenter] book, message in
                downloadCenter?.failDownloadWithAlert(for: book, withMessage: message)
            }
        )
    }

    static func production() -> AppContainer {
        let container = _cachedValue()
        container.ensureOfflineQueueExecutorRegistered()
        return container
    }

    /// Installs the offline-queue executor exactly once. The coordinator is
    /// retained in a process-wide slot so its `[weak self]` executor closure
    /// stays alive; the `setExecutor` call lives in
    /// `OfflineQueueCoordinator.registerExecutor()`. No-op on later calls.
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

    /// The cached app-wide composition graph. The first `production()` read
    /// builds it once under the lock; later reads return it. Reassignable
    /// (rather than a `static let`) so the test-only `_resetForTesting()` seam
    /// can rebuild the graph between test cases. Lock-guarded so the mutable
    /// static is race-free without pinning `AppContainer` to an actor.
    private static let _cachedLock = OSAllocatedUnfairLock<AppContainer?>(initialState: nil)

    private static func _cachedValue() -> AppContainer {
        _cachedLock.withLock { slot in
            if let existing = slot { return existing }
            let built = Self._buildCachedAppContainer()
            slot = built
            return built
        }
    }

    /// Test seam, empty in production. Tests set it (via `PalaceTestSetup`) so
    /// the shared network executor's `URLSession` includes
    /// `NoNetworkURLProtocol`: `URLProtocol.registerClass` covers only
    /// `URLSession.shared`, not a `URLSession(configuration:)`, so without this
    /// the executor `AccountsManager.fallbackDirectRefresh` uses would reach the
    /// real registry in unit tests. Deliberately not `#if DEBUG`, so it stays
    /// available in the non-DEBUG test configuration.
    private static let _testExecutorProtocolClassesLock =
        OSAllocatedUnfairLock<[AnyClass]>(initialState: [])

    internal static var testExecutorProtocolClasses: [AnyClass] {
        get { _testExecutorProtocolClassesLock.withLock { $0 } }
        set { _testExecutorProtocolClassesLock.withLock { $0 = newValue } }
    }

    /// Builds the shared network executor. In production
    /// `testExecutorProtocolClasses` is empty and this is the default
    /// `.fallback` executor; otherwise the test protocol classes are prepended
    /// onto a normal `.fallback` session configuration.
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

    /// Test seam that production never calls. Rebuilds the cached graph so its
    /// executor picks up `testExecutorProtocolClasses`: the host app builds the
    /// graph at launch, before the test bundle can install the classes, and
    /// `_resetForTesting` is compiled out of non-DEBUG test builds.
    /// `PalaceTestSetup` calls this once, after installing the protocol classes.
    internal static func _rebuildCachedForTestProtocols() {
        _cachedLock.withLock { $0 = _buildCachedAppContainer() }
    }

    private static func _buildCachedAppContainer() -> AppContainer {
        let executor = makeNetworkExecutor()
        let reachability = Reachability()
        // Every collaborator is constructed inline and passed explicitly: a
        // default argument that reads `AppContainer.production()` while this
        // builder runs re-enters the lock and deadlocks on first launch.
        // `AccountsManager.init` hydrates only a slim snapshot synchronously and
        // loads the full ~1,100-account registry off-main; do not add a
        // synchronous full-account preload here (~0.3-0.6s on device).
        // `DownloadCenterBorrowReauthResetter` is stateless and forwards to a
        // static, so it is safe to pass before MyBooksDownloadCenter exists.
        // `.production` switch dependencies defer their executor and nav-hub
        // reads into closures, so evaluating it here does not re-enter.
        let accountsManager = AccountsManager(
            borrowReauthResetter: DownloadCenterBorrowReauthResetter(),
            switchDependencies: .production
        )
        // Built before TPPBookRegistry, which takes ImageLoading as a required
        // init parameter (a default-arg resolution here would re-enter the lock).
        let imageCache = ImageCache.shared
        let imageLoader: ImageLoading = ImageLoader(imageCache: imageCache)
        // Must be configured before the first TPPBook is constructed (the
        // registry construction below parses records).
        TPPBookImageContext.imageCacheProvider = { imageCache }
        TPPBookImageContext.imageLoaderProvider = { imageLoader }
        // The convenience init's dependency closures resolve
        // `AppContainer.production()` lazily, on first use, so construction here
        // does not re-enter the lock and a test rebuild can't capture a stale graph.
        let bookRegistry = TPPBookRegistry(accountsManager: accountsManager, imageLoader: imageLoader)
        // One announcer shared by the service and MyBooksDownloadCenter (which
        // still calls `announceStatus` directly) keeps deduplication coherent.
        let accessibilityAnnouncer = TPPAccessibilityAnnouncementCenter()
        let downloadAnnouncementService = DownloadAnnouncementService(announcer: accessibilityAnnouncer)
        // Auth coordinator is built before MyBooksDownloadCenter so its
        // BookReturnService gets a non-nil coordinator. `assumeIsolated` because
        // `CoordinatorSignInModalPresenter` is `@MainActor` and this builder runs
        // on the first consumer's thread (main in practice). The library UUID is
        // read at emission time so account switches show up in the next event.
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
        let downloadNetworkLossMonitor = MainActor.assumeIsolated {
            makeDownloadNetworkLossMonitor(for: downloadCenter)
        }
        // `UserAccountPublisher.shared` is `@MainActor`; the builder only runs
        // from app launch or main-thread test setup, the same precondition
        // `authCoordinator` already asserts above.
        let userAccountPublisher = MainActor.assumeIsolated { UserAccountPublisher.shared }
        // PP-5022 — the navigation hub resolves "which stack is on screen" by
        // asking the tab router which tab is selected, so the two hubs are one
        // unit. Built as a pair here, in the one place both exist, so a
        // mis-paired hub is not something a caller can assemble by accident.
        let tabRouterHub = AppTabRouterHub()
        let navigationCoordinatorHub = NavigationCoordinatorHub(tabRouterHub: tabRouterHub)

        return AppContainer(
            bookRegistry: bookRegistry,
            networkExecutor: executor,
            // Bind the drain-time credential provider HERE, where
            // `accountsManager` is already in scope — the default closure would
            // otherwise re-enter `AppContainer.production()` from the queue's
            // serial queue at drain time. Same reasoning as the featureFlags
            // note below: the composition root is the binding site.
            networkQueue: NetworkQueue.live(
                executor: executor,
                reachability: reachability,
                accountsManager: accountsManager
            ),
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
            navigationCoordinatorHub: navigationCoordinatorHub,
            tabRouterHub: tabRouterHub,
            drmAuthorizerProvider: {
                #if FEATURE_DRM_CONNECTOR
                return AdobeCertificate.isDRMAvailable ? AdobeDRMService.shared.adeptInstance : nil
                #else
                return nil
                #endif
            },
            authCoordinator: authCoordinator,
            downloadNetworkLossMonitor: downloadNetworkLossMonitor
        )
    }

    #if DEBUG
    /// Test-only: rebuilds the cached graph with the AccountsManager
    /// background-load opt-out enabled. Called by `PalaceTestSetup` between
    /// test cases.
    ///
    /// Leaves `AccountsManager.deferInitialLoadCatalogsForTesting` at `true`:
    /// the next test class inherits it before its own setUp, and `false` lets
    /// any incidental `AccountsManager` spawn a registry crawl that outlives
    /// the test and pollutes the next one. Tests that need the background load
    /// opt in by setting it `false` in their own setUp.
    ///
    /// Residual race (PP-4754): crawl tasks are owned and drained
    /// synchronously, but a crawl that passes its cancellation check while the
    /// cancel happens can spawn a successor; the next boundary's
    /// `_drainAllLiveInstancesForTesting()` catches it.
    internal static func _resetForTesting() {
        // `#if DEBUG` is also on in TestFlight and dev builds; only act when
        // XCTest is the host.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil else {
            return
        }
        AccountsManager.deferInitialLoadCatalogsForTesting = true
        // Cancel and synchronously drain the cached manager's crawl before
        // rebuilding. Cancelling alone left a crawl holding the
        // `accountSetsLock` barrier, which the next test's main-actor reauth
        // `.sync` read deadlocked against. Build outside the lock, then assign.
        _cachedValue().accountsManager.cancelAndDrainBackgroundWork()
        // Also drain managers built by earlier tests that were never torn down;
        // their late writes to `AccountStateStore.shared` are then wiped by
        // that store's resetter, which `PalaceTestSetup` runs after this one.
        AccountsManager._drainAllLiveInstancesForTesting()
        let rebuilt = Self._buildCachedAppContainer()
        _cachedLock.withLock { $0 = rebuilt }
        // The audiobook/rating statics are the only members the builder does
        // not rebuild. Left intact, the presenter carries active-session state
        // across test classes (e.g. a presenter left `.playing`). Test resets
        // always run on main, hence `assumeIsolated`.
        MainActor.assumeIsolated {
            _audiobookSession = nil
            _audiobookSessionPresenter = nil
            _playbackBootstrapper = nil
            _appRatingService = nil
            _ratingPromptPresenter = nil
        }
        // The side-loaded registry is a file-backed cache that would bleed
        // manifest state across test classes; the manager holds a reference to
        // it, so both are cleared together.
        _sideloadedBookRegistry.withLock { $0 = nil }
        _sideloadedBookManager.withLock { $0 = nil }
        // Leave the flag at the test-safe `true`; see the doc comment above.
        AccountsManager.deferInitialLoadCatalogsForTesting = true
    }
    #endif
}

// MARK: - Downloads account-context seam

extension AppContainer {
    /// Downloads-owned account-context adapter over this container's
    /// `accountsManager`. Computed, so every container (production or test)
    /// yields an adapter scoped to its own `accountsManager`. Consumed by
    /// `BookFileManager` in place of the concrete `AccountsManager`.
    var downloadAccountContext: AccountsManagerDownloadContextAdapter {
        AccountsManagerDownloadContextAdapter(accountsManager: accountsManager)
    }
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

// MARK: - Account-switch cleanup deps

extension AccountSwitchDependencies {
    /// The live account-switch cleanup collaborators, bound at the composition
    /// root. The network-executor and nav-hub reads are closures so they
    /// resolve on the first account switch, never while `production()` is
    /// still building the manager.
    static var production: AccountSwitchDependencies {
        AccountSwitchDependencies(
            imageCache: ImageCache.shared,
            accountStateStore: .shared,
            resetCoverCircuitBreaker: { TPPBookCoverRegistry.shared.resetHostFailures() },
            networkExecutorProvider: { AppContainer.production().networkExecutor },
            popToRootForAccountSwitch: { await AppContainer.popToRootForAccountSwitch() }
        )
    }
}

extension AppContainer {
    /// Main-actor navigation cleanup for an account switch: pop the active
    /// navigation stack to root when it is non-empty, then wait to settle.
    @MainActor
    fileprivate static func popToRootForAccountSwitch() async {
        popAllToRootForAccountSwitch(hub: AppContainer.production().navigationCoordinatorHub)
        try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
    }

    /// Sends the patron to a tab's ROOT, for navigation the APP initiates rather
    /// than the patron.
    ///
    /// PP-5051 — every `tabRouterHub.navigate(to:)` site is "take them to that
    /// tab to see a specific thing": a ready hold, their downloaded books, the
    /// new library's catalog. Those relied on the destination already being at
    /// its root, which was true only because leaving a tab reset it. Tabs now
    /// keep their stacks, so a hold-ready notification could land the patron on
    /// whatever book detail they happened to leave in the Holds tab. Preserving
    /// your place is for the tabs YOU tap; being sent somewhere is not that.
    ///
    /// Popped BEFORE the switch so the destination is already at its root as it
    /// appears — no flash of the previous screen.
    ///
    /// Animated only when the patron is already ON that tab, because then they
    /// are watching the stack collapse and an instant cut has no tab transition
    /// to hide behind. Arriving from another tab stays un-animated, for the
    /// reason recorded on `NavigationCoordinator.popToRoot`.
    @MainActor
    func navigateToTabRoot(_ tab: AppTab) {
        let animated = Self.shouldAnimateArrival(currentTab: tabRouterHub.currentTab,
                                                 destination: tab)
        navigationCoordinatorHub.coordinator(for: tab)?.popToRoot(animated: animated)
        tabRouterHub.navigate(to: tab)
    }

    /// Whether the pop in `navigateToTabRoot` should animate.
    ///
    /// Animate only when the patron is ALREADY on the destination tab: they are
    /// watching that stack, there is no cross-tab transition to hide an instant
    /// cut behind, and `navigate(to:)` writes an unchanged value so no tab
    /// animation races it. Arriving from another tab — or from an unknown tab,
    /// which is a fresh arrival — stays instant.
    ///
    /// Extracted so the two cells are a table rather than a condition inside a
    /// call, matching `shouldPopToRoot` / `shouldFinishSwitchingImmediately` /
    /// `tabTapOutcome`.
    static func shouldAnimateArrival(currentTab: AppTab?, destination: AppTab) -> Bool {
        currentTab == destination
    }

    /// Clears active content out of EVERY tab before a library switch.
    ///
    /// PP-5051 — this used to pop only the tab in view, which was sufficient
    /// only because leaving a tab reset it, so no other stack could be holding
    /// anything. Tabs now keep their stacks: without this, switching libraries
    /// would leave the previous library's book details, lanes, and search
    /// results sitting in the three tabs the patron is not looking at, ready to
    /// be found later with no indication they belong to a library they left.
    ///
    /// Takes the hub explicitly so the sweep is exercisable without the
    /// production graph.
    @MainActor
    static func popAllToRootForAccountSwitch(hub: NavigationCoordinatorHub) {
        for coordinator in hub.allRegisteredCoordinators() {
            guard AccountsManager.shouldPopToRoot(navigationPathCount: coordinator.path.count) else { continue }
            Log.info(#file, "  🔄 Popping a tab to root to clean up active content before account switch")
            coordinator.popToRoot(animated: false)
        }
    }
}
