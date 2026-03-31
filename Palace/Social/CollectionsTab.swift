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

    /// Whether the Collections feature is enabled.
    static var isEnabled: Bool {
        RemoteFeatureFlags.shared.isFeatureEnabled(.socialCollectionsEnabled)
    }

    /// Creates the UIViewController for the Collections tab.
    /// - Parameters:
    ///   - collectionService: The collection service to inject.
    ///   - bookRegistry: The book registry for resolving book IDs.
    /// - Returns: A UIViewController ready for use in a UITabBarController.
    @MainActor
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
