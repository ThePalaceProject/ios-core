import SwiftUI
import Combine
import PalaceAuth
import PalaceNetwork

struct AppContainer {

    let bookRegistry: TPPBookRegistryProvider
    let networkExecutor: TPPNetworkExecutor
    let networkQueue: NetworkQueue
    let reachability: Reachability
    let accountsManager: AccountsManager
    let settings: TPPSettings
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
        let session = AudiobookSessionManager(appContainer: self)
        AppContainer._audiobookSession = session
        return session
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

    @MainActor private static var _bookCellModelCache: BookCellModelCache?
    @MainActor private static var _samplePreviewManager: SamplePreviewManager?
    @MainActor private static var _audiobookSession: AudiobookSessionManager?
    @MainActor private static var _playbackBootstrapper: PlaybackBootstrapper?

    init(
        bookRegistry: TPPBookRegistryProvider,
        networkExecutor: TPPNetworkExecutor,
        networkQueue: NetworkQueue,
        reachability: Reachability,
        accountsManager: AccountsManager,
        settings: TPPSettings,
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
        authCoordinator: AuthCoordinator
    ) {
        self.bookRegistry = bookRegistry
        self.networkExecutor = networkExecutor
        self.networkQueue = networkQueue
        self.reachability = reachability
        self.accountsManager = accountsManager
        self.settings = settings
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
    }

    static func production() -> AppContainer {
        _cached
    }

    private static let _cached: AppContainer = {
        let executor = TPPNetworkExecutor(cachingStrategy: .fallback)
        let reachability = Reachability()
        // AccountsManager and TPPBookRegistry are constructed inline here.
        // TPPBookRegistry.init takes AccountsManager as an explicit dependency,
        // and reading either via `AppContainer.production()` during this
        // dispatch_once would deadlock on first launch (the cycle that
        // motivated killing TPPBookRegistry.shared in Phase 6.6). We hand
        // both into AppContainer.init — and into every collaborator built
        // here — explicitly so no default arg ever fires.
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
        return AppContainer(
            bookRegistry: bookRegistry,
            networkExecutor: executor,
            networkQueue: NetworkQueue(transport: executor.transport, reachability: reachability),
            reachability: reachability,
            accountsManager: accountsManager,
            settings: TPPSettings(),
            downloadCenter: downloadCenter,
            downloadAnnouncementService: downloadAnnouncementService,
            debugSettings: DebugSettings(),
            imageCache: imageCache,
            imageLoader: imageLoader,
            userAccountPublisher: .shared,
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
    }()
}

// MARK: - SwiftUI Environment Integration

private struct AppContainerKey: EnvironmentKey {
    static let defaultValue = AppContainer.production()
}

extension EnvironmentValues {
    var appContainer: AppContainer {
        get { self[AppContainerKey.self] }
        set { self[AppContainerKey.self] = newValue }
    }
}
