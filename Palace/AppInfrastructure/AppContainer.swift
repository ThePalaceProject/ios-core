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

    init(
        bookRegistry: TPPBookRegistryProvider,
        networkExecutor: TPPNetworkExecutor,
        accountsManager: AccountsManager,
        settings: TPPSettings,
        downloadCenter: MyBooksDownloadCenter,
        debugSettings: DebugSettings
    ) {
        self.bookRegistry = bookRegistry
        self.networkExecutor = networkExecutor
        self.accountsManager = accountsManager
        self.settings = settings
        self.downloadCenter = downloadCenter
        self.debugSettings = debugSettings
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
            debugSettings: .shared
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
