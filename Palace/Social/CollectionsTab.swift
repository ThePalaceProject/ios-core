//
//  CollectionsTab.swift
//  Palace
//
//  Created for Social Features — factory for the Collections tab bar item.
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import SwiftUI
import UIKit

/// Factory that creates a UIViewController hosting the Collections view.
/// Gate the tab behind a feature flag before adding it to the tab bar.
enum CollectionsTab {

    /// The Firebase Remote Config key for the collections feature.
    private static let featureFlagKey = "collections_enabled"

    /// Whether the Collections feature is enabled.
    /// Checks Firebase Remote Config if available, defaults to true for development.
    static var isEnabled: Bool {
        // Check UserDefaults for a local override first, then default to true.
        // When Firebase Remote Config integration is wired up, this can delegate
        // to RemoteFeatureFlags with a new FeatureFlag case.
        UserDefaults.standard.object(forKey: featureFlagKey) as? Bool ?? true
    }

    /// Creates the UIViewController for the Collections tab.
    /// - Parameters:
    ///   - collectionService: The collection service to inject.
    ///   - bookRegistry: The book registry for resolving book IDs.
    /// - Returns: A UIViewController ready for use in a UITabBarController.
    static func makeViewController(
        collectionService: BookCollectionServiceProtocol? = nil,
        bookRegistry: TPPBookRegistryProvider? = nil
    ) -> UIViewController {
        let service = collectionService ?? BookCollectionService()
        let viewModel = CollectionsViewModel(collectionService: service)
        let collectionsView = CollectionsView(viewModel: viewModel)
        let hostingController = UIHostingController(rootView: collectionsView)
        hostingController.tabBarItem = UITabBarItem(
            title: "Collections",
            image: UIImage(systemName: "folder"),
            selectedImage: UIImage(systemName: "folder.fill")
        )
        return hostingController
    }
}
