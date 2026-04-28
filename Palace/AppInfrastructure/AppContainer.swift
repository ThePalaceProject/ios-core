import SwiftUI
import Combine

struct AppContainer {

    let bookRegistry: TPPBookRegistryProvider
    let networkExecutor: TPPNetworkExecutor
    let accountsManager: AccountsManager
    let settings: TPPSettings
    let downloadCenter: MyBooksDownloadCenter
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
        accountsManager: AccountsManager,
        settings: TPPSettings,
        downloadCenter: MyBooksDownloadCenter,
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
        self.accountsManager = accountsManager
        self.settings = settings
        self.downloadCenter = downloadCenter
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
        return AppContainer(
            bookRegistry: TPPBookRegistry.shared,
            networkExecutor: .shared,
            accountsManager: AccountsManager.shared,
            settings: TPPSettings(),
            downloadCenter: MyBooksDownloadCenter(),
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
