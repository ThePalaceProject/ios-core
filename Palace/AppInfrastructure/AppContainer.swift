import SwiftUI
import Combine

/// Centralized dependency container for injecting services into SwiftUI views
/// via `@Environment(\.appContainer)`.
///
/// All properties default to the production singletons so existing call sites
/// that create views without an explicit container continue to work.
struct AppContainer {
    static let shared = AppContainer()

    let bookRegistry: TPPBookRegistryProvider
    let networkExecutor: TPPNetworkExecutor
    let accountsManager: AccountsManager
    let settings: TPPSettings
    let downloadCenter: MyBooksDownloadCenter

    init(
        bookRegistry: TPPBookRegistryProvider = TPPBookRegistry.shared,
        networkExecutor: TPPNetworkExecutor = .shared,
        accountsManager: AccountsManager = .shared,
        settings: TPPSettings = .shared,
        downloadCenter: MyBooksDownloadCenter = .shared
    ) {
        self.bookRegistry = bookRegistry
        self.networkExecutor = networkExecutor
        self.accountsManager = accountsManager
        self.settings = settings
        self.downloadCenter = downloadCenter
    }
}

// MARK: - SwiftUI Environment Integration

private struct AppContainerKey: EnvironmentKey {
    static let defaultValue = AppContainer()
}

extension EnvironmentValues {
    var appContainer: AppContainer {
        get { self[AppContainerKey.self] }
        set { self[AppContainerKey.self] = newValue }
    }
}
