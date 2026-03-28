import SwiftUI

/// Factory for creating the Discovery tab, ready to plug into the main tab bar.
/// Usage: Add `DiscoveryTab.makeTab()` to the tab bar controller's viewControllers array.
/// Gated by `RemoteFeatureFlags.FeatureFlag.aiDiscoveryEnabled`.
enum DiscoveryTab {
    /// Whether the AI Discovery feature is enabled.
    static var isEnabled: Bool {
        RemoteFeatureFlags.shared.isFeatureEnabled(.aiDiscoveryEnabled)
    }

    /// Creates a UIViewController wrapping the Discovery SwiftUI view, suitable for tab bar embedding.
    /// Returns nil if the feature flag is disabled.
    static func makeViewController(catalogAPI: CatalogAPI) -> UIViewController? {
        guard isEnabled else { return nil }
        let viewModel = makeViewModel(catalogAPI: catalogAPI)
        let discoveryView = DiscoveryView(viewModel: viewModel)
        let hostingController = UIHostingController(rootView: discoveryView)
        hostingController.tabBarItem = UITabBarItem(
            title: DiscoveryStrings.Discovery.discover,
            image: UIImage(systemName: "sparkle.magnifyingglass"),
            selectedImage: UIImage(systemName: "sparkle.magnifyingglass")
        )
        hostingController.tabBarItem.accessibilityLabel = DiscoveryStrings.Discovery.discover

        let navController = UINavigationController(rootViewController: hostingController)
        navController.navigationBar.prefersLargeTitles = true

        return navController
    }

    /// Creates the DiscoveryViewModel with all dependencies wired up.
    static func makeViewModel(catalogAPI: CatalogAPI) -> DiscoveryViewModel {
        let configuration = DefaultDiscoveryConfiguration()
        let fallback = LocalDiscoveryFallback()
        let discoveryService = ClaudeDiscoveryService(
            configuration: configuration,
            fallback: fallback
        )
        let searchService = CrossLibrarySearchService(catalogAPI: catalogAPI)

        return DiscoveryViewModel(
            discoveryService: discoveryService,
            searchService: searchService
        )
    }
}
