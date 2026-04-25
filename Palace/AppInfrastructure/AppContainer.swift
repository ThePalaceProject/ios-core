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
        self.drmAuthorizerProvider = drmAuthorizerProvider
    }

    /// The single composition root. App entry points (AppDelegate,
    /// SceneDelegate, the SwiftUI `@Environment` default) call this and
    /// only this to construct the live service graph.
    static func production() -> AppContainer {
        AppContainer(
            bookRegistry: TPPBookRegistry.shared,
            networkExecutor: .shared,
            accountsManager: .shared,
            settings: .shared,
            downloadCenter: .shared,
            debugSettings: .shared,
            bookCellModelCache: .shared,
            imageCache: ImageCache.shared,
            userAccountPublisher: .shared,
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
