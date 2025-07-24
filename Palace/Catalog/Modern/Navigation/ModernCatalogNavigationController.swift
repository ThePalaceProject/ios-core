//
//  ModernCatalogNavigationController.swift
//  Palace
//
//  Created by Palace Modernization on Catalog Renovation
//  Copyright © 2025 The Palace Project. All rights reserved.
//

import SwiftUI
import UIKit

/// Modern catalog navigation controller that hosts SwiftUI views
@objc class ModernCatalogNavigationController: UINavigationController {
    
    // MARK: - Properties
    
    private var catalogHostingController: UIHostingController<CatalogView>?
    
    // MARK: - Initialization
    
    override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
        setupCatalogView()
        setupTabBarItem()
        observeNotifications()
    }
    
    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        setupCatalogView()
        setupTabBarItem()
        observeNotifications()
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    // MARK: - View Lifecycle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        configureAppearance()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        if UIAccessibility.isVoiceOverRunning {
            UIAccessibility.post(notification: .screenChanged, argument: nil)
        }
    }
    
    // MARK: - Private Methods
    
    private func setupCatalogView() {
        let catalogView = CatalogView()
        let hostingController = UIHostingController(rootView: catalogView)
        
        // Configure hosting controller
        hostingController.title = NSLocalizedString("Catalog", comment: "Catalog tab title")
        
        // Hide the default navigation bar since SwiftUI handles its own
        hostingController.navigationItem.hidesBackButton = true
        
        self.catalogHostingController = hostingController
        self.viewControllers = [hostingController]
    }
    
    private func setupTabBarItem() {
        self.tabBarItem.title = NSLocalizedString("Catalog", comment: "Catalog tab title")
        self.tabBarItem.image = UIImage(named: "Catalog")
        self.navigationItem.title = NSLocalizedString("Catalog", comment: "Catalog navigation title")
    }
    
    private func configureAppearance() {
        // Configure navigation bar appearance for modern look
        if #available(iOS 13.0, *) {
            let appearance = UINavigationBarAppearance()
            appearance.configureWithOpaqueBackground()
            appearance.backgroundColor = UIColor.systemBackground
            appearance.titleTextAttributes = [.foregroundColor: UIColor.label]
            appearance.largeTitleTextAttributes = [.foregroundColor: UIColor.label]
            
            navigationBar.standardAppearance = appearance
            navigationBar.scrollEdgeAppearance = appearance
            navigationBar.compactAppearance = appearance
        }
        
        // Enable large titles
        navigationBar.prefersLargeTitles = true
        
        // Configure for better SwiftUI integration
        navigationBar.isTranslucent = true
    }
    
    private func observeNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(currentAccountChanged),
            name: .TPPCurrentAccountDidChange,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(syncBegan),
            name: .TPPSyncBegan,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(syncEnded),
            name: .TPPSyncEnded,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(didSignOut),
            name: .TPPDidSignOut,
            object: nil
        )
    }
    
    // MARK: - Notification Handlers
    
    @objc private func currentAccountChanged() {
        // The SwiftUI view will handle account changes reactively
        // No need to manually reload here
    }
    
    @objc private func syncBegan() {
        // Disable navigation during sync
        navigationItem.leftBarButtonItem?.isEnabled = false
    }
    
    @objc private func syncEnded() {
        // Re-enable navigation after sync
        navigationItem.leftBarButtonItem?.isEnabled = true
    }
    
    @objc private func didSignOut() {
        // The SwiftUI view will handle sign out reactively
        // No need to manually reload here
    }
    
    // MARK: - Public Methods
    
    /// Force refresh the catalog view (for compatibility)
    @objc func loadTopLevelCatalogViewController() {
        // SwiftUI view handles this automatically
        // This method is kept for backward compatibility
    }
    
    /// Update catalog feed setting for current account (for compatibility)
    @objc func updateCatalogFeedSettingCurrentAccount(_ account: Account) {
        // SwiftUI view handles this automatically
        // This method is kept for backward compatibility
    }
}

// MARK: - SwiftUI Integration Helper

extension ModernCatalogNavigationController {
    
    /// Create a SwiftUI-compatible view controller for use in mixed UI scenarios
    static func createSwiftUIWrapper() -> UIViewController {
        let catalogView = CatalogView()
        let hostingController = UIHostingController(rootView: catalogView)
        
        hostingController.title = NSLocalizedString("Catalog", comment: "Catalog title")
        
        return hostingController
    }
}

// MARK: - Backward Compatibility

extension ModernCatalogNavigationController {
    
    /// Legacy method support for existing code that might call this
    @objc func updateFeedAndRegistryOnAccountChange() {
        // The SwiftUI view handles this automatically through reactive bindings
        // This method is kept for backward compatibility
    }
} 