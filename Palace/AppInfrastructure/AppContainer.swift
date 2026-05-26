import SwiftUI
import Combine
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
    let userAccountPublisher: UserAccountPublisher
    let opdsFeedService: OPDSFeedService
    let readerService: ReaderService
    let navigationCoordinatorHub: NavigationCoordinatorHub
    let tabRouterHub: AppTabRouterHub
    let drmAuthorizerProvider: () -> TPPDRMAuthorizing?

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

    @MainActor private static var _bookCellModelCache: BookCellModelCache?
    @MainActor private static var _samplePreviewManager: SamplePreviewManager?

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
        userAccountPublisher: UserAccountPublisher,
        opdsFeedService: OPDSFeedService,
        readerService: ReaderService,
        navigationCoordinatorHub: NavigationCoordinatorHub,
        tabRouterHub: AppTabRouterHub,
        drmAuthorizerProvider: @escaping () -> TPPDRMAuthorizing?
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
        self.userAccountPublisher = userAccountPublisher
        self.opdsFeedService = opdsFeedService
        self.readerService = readerService
        self.navigationCoordinatorHub = navigationCoordinatorHub
        self.tabRouterHub = tabRouterHub
        self.drmAuthorizerProvider = drmAuthorizerProvider
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
        let bookRegistry = TPPBookRegistry(accountsManager: accountsManager)
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
        let downloadCenter = MyBooksDownloadCenter(
            bookRegistry: bookRegistry,
            accountsManager: accountsManager,
            networkExecutor: executor,
            accessibilityAnnouncements: accessibilityAnnouncer,
            downloadAnnouncementService: downloadAnnouncementService,
            reachability: reachability
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
            imageCache: ImageCache.shared,
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
            }
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
