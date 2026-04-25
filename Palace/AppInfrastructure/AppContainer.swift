import SwiftUI
import Combine

/// Centralized dependency container for injecting services into SwiftUI views
/// via `@Environment(\.appContainer)`.
///
/// The container's `init` takes every service explicitly — no `.shared`
/// defaults. Tests construct containers with mocks directly; the app's
/// single composition root calls `AppContainer.production()` which is the
/// only sanctioned place that reads singletons.
struct AppContainer {

    let bookRegistry: TPPBookRegistryProvider
    let networkExecutor: TPPNetworkExecutor
    let accountsManager: AccountsManager
    let settings: TPPSettings
    let downloadCenter: MyBooksDownloadCenter
    let debugSettings: DebugSettings
    let bookCellModelCache: BookCellModelCache
    let imageCache: ImageCacheType
    let userAccountPublisher: UserAccountPublisher
    let opdsFeedService: OPDSFeedService
    let samplePreviewManager: SamplePreviewManager
    let readerService: ReaderService
    let navigationCoordinatorHub: NavigationCoordinatorHub
    let tabRouterHub: AppTabRouterHub
    /// DRM authorizer factory. Built behind `#if FEATURE_DRM_CONNECTOR`
    /// at the composition root so VMs/Views never reference
    /// `AdobeDRMService.shared` directly. Returns `nil` in DRM-disabled
    /// builds and on devices where the certificate is unavailable.
    let drmAuthorizerProvider: () -> TPPDRMAuthorizing?

    init(
        bookRegistry: TPPBookRegistryProvider,
        networkExecutor: TPPNetworkExecutor,
        accountsManager: AccountsManager,
        settings: TPPSettings,
        downloadCenter: MyBooksDownloadCenter,
        debugSettings: DebugSettings,
        bookCellModelCache: BookCellModelCache,
        imageCache: ImageCacheType,
        userAccountPublisher: UserAccountPublisher,
        opdsFeedService: OPDSFeedService,
        samplePreviewManager: SamplePreviewManager,
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
        self.bookCellModelCache = bookCellModelCache
        self.imageCache = imageCache
        self.userAccountPublisher = userAccountPublisher
        self.opdsFeedService = opdsFeedService
        self.samplePreviewManager = samplePreviewManager
        self.readerService = readerService
        self.navigationCoordinatorHub = navigationCoordinatorHub
        self.tabRouterHub = tabRouterHub
        self.drmAuthorizerProvider = drmAuthorizerProvider
    }

    /// The single composition root. App entry points (AppDelegate,
    /// SceneDelegate, the SwiftUI `@Environment` default) call this and
    /// only this to construct the live service graph.
    ///
    /// Constructs `BookCellModelCache` directly from already-resolved
    /// partner singletons rather than reading `BookCellModelCache.shared`.
    /// That removes the historical init cycle in which a re-entrant
    /// `\.appContainer` access during `BookCellModelCache.shared`'s
    /// factory deadlocked the static-let init lock — `production()` no
    /// longer touches `BookCellModelCache.shared`, so the cycle is closed.
    /// `BookCellModelCache.shared` itself stays alive for legacy
    /// default-arg callers; it will be removed once those migrate.
    static func production() -> AppContainer {
        let imageCache: ImageCacheType = ImageCache.shared
        let bookRegistry: TPPBookRegistryProvider = TPPBookRegistry.shared
        let downloadCenter = MyBooksDownloadCenter.shared
        let accountsManager = AccountsManager.shared
        let samplePreviewManager = SamplePreviewManager.shared
        let readerService = ReaderService.shared

        // BookCellModelCache is `@MainActor`-isolated. `production()` is
        // called either from app init (main thread) or via SwiftUI's
        // EnvironmentKey defaultValue (also main thread), so the
        // assumeIsolated assertion is sound. Without it, the constructor
        // call would be an isolation-crossing error.
        let bookCellModelCache = MainActor.assumeIsolated {
            BookCellModelCache(
                imageCache: imageCache,
                bookRegistry: bookRegistry,
                downloadCenter: downloadCenter,
                accountsManager: accountsManager,
                samplePreviewManager: samplePreviewManager,
                readerService: readerService
            )
        }

        return AppContainer(
            bookRegistry: bookRegistry,
            networkExecutor: .shared,
            accountsManager: accountsManager,
            settings: .shared,
            downloadCenter: downloadCenter,
            debugSettings: .shared,
            bookCellModelCache: bookCellModelCache,
            imageCache: imageCache,
            userAccountPublisher: .shared,
            opdsFeedService: .shared,
            samplePreviewManager: samplePreviewManager,
            readerService: readerService,
            navigationCoordinatorHub: .shared,
            tabRouterHub: .shared,
            drmAuthorizerProvider: {
                #if FEATURE_DRM_CONNECTOR
                return AdobeCertificate.isDRMAvailable ? AdobeDRMService.shared.adeptInstance : nil
                #else
                return nil
                #endif
            }
        )
    }
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
