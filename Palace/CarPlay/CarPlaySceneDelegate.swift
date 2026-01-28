//
//  CarPlaySceneDelegate.swift
//  Palace
//
//  Created for CarPlay audiobook support.
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import CarPlay
import Combine

/// CarPlay scene delegate that manages the CarPlay interface lifecycle
/// and coordinates audiobook playback from the vehicle's infotainment system.
/// Note: This class is referenced by name in Info.plist as "CarPlaySceneDelegate"
@objc(CarPlaySceneDelegate)
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
  
  // MARK: - Properties
  
  private var interfaceController: CPInterfaceController?
  private var templateManager: CarPlayTemplateManager?
  private var cancellables = Set<AnyCancellable>()
  
  // MARK: - CPTemplateApplicationSceneDelegate
  
  func templateApplicationScene(
    _ templateApplicationScene: CPTemplateApplicationScene,
    didConnect interfaceController: CPInterfaceController
  ) {
    self.interfaceController = interfaceController
    
    // Check feature flag - if CarPlay is disabled, show coming soon message
    guard RemoteFeatureFlags.shared.isCarPlayEnabledCached else {
      Log.info(#file, "🚗 CarPlay scene connected but feature is DISABLED - showing coming soon message")
      showComingSoonTemplate(interfaceController: interfaceController)
      return
    }
    
    Log.info(#file, "🚗 CarPlay scene connected - setting up templates")
    
    PlaybackBootstrapper.shared.ensureInitializedForCarPlay()
    
    self.templateManager = CarPlayTemplateManager(interfaceController: interfaceController)
    
    // Set up the root template
    templateManager?.setupRootTemplate()
    
    // Subscribe to book registry changes to refresh the library
    subscribeToBookRegistryChanges()
    
    Log.info(#file, "🚗 CarPlay setup complete")
  }
  
  func templateApplicationScene(
    _ templateApplicationScene: CPTemplateApplicationScene,
    didDisconnect interfaceController: CPInterfaceController
  ) {
    Log.info(#file, "🚗 CarPlay disconnected")
    
    cancellables.removeAll()
    templateManager = nil
    self.interfaceController = nil
    
    // Note: We don't stop playback on CarPlay disconnect since:
    // 1. User might still be listening on phone
    // 2. Phone app UI may still be showing the player
    // Playback lifecycle is managed by AudiobookSessionManager
  }
  
  func templateApplicationScene(
    _ templateApplicationScene: CPTemplateApplicationScene,
    didSelect navigationAlert: CPNavigationAlert
  ) {
    // Handle navigation alerts if needed
  }
  
  // MARK: - Private Methods
  
  private func showComingSoonTemplate(interfaceController: CPInterfaceController) {
    // Create a list template with a "Coming Soon" message
    // Note: Audio apps can only use CPListTemplate, not CPInformationTemplate
    
    // Create and resize the Palace logo for CarPlay
    let logoImage = createCarPlayLogo()
    
    // Header item with Palace logo
    let headerItem = CPListItem(
      text: "Palace",
      detailText: "CarPlay Support Coming Soon"
    )
    headerItem.isEnabled = false
    if let logo = logoImage {
      headerItem.setImage(logo)
    }
    
    // Feature description
    let featureItem = CPListItem(
      text: "Audiobook Playback",
      detailText: "Listen while you drive"
    )
    featureItem.isEnabled = false
    featureItem.setImage(UIImage(systemName: "headphones"))
    
    // Status update
    let statusItem = CPListItem(
      text: "Under Development",
      detailText: "Stay tuned for updates"
    )
    statusItem.isEnabled = false
    statusItem.setImage(UIImage(systemName: "hammer.fill"))
    
    // Alternative suggestion
    let alternativeItem = CPListItem(
      text: "Use Palace App",
      detailText: "Enjoy audiobooks on your device"
    )
    alternativeItem.isEnabled = false
    alternativeItem.setImage(UIImage(systemName: "iphone"))
    
    let section = CPListSection(
      items: [headerItem, featureItem, statusItem, alternativeItem],
      header: nil,
      sectionIndexTitle: nil
    )
    
    let comingSoonTemplate = CPListTemplate(title: "Palace", sections: [section])
    
    interfaceController.setRootTemplate(comingSoonTemplate, animated: true, completion: nil)
  }
  
  private func createCarPlayLogo() -> UIImage? {
    // Try to load the Palace logo from assets
    guard let logoImage = UIImage(named: "LaunchImageLogo") ?? UIImage(named: "WelcomeLogo") else {
      return nil
    }
    
    // Resize for CarPlay list item (recommended size is around 90x90 points)
    let size = CGSize(width: 90, height: 90)
    let renderer = UIGraphicsImageRenderer(size: size)
    
    return renderer.image { _ in
      // Calculate aspect-fit rect to maintain logo proportions
      let aspectRatio = logoImage.size.width / logoImage.size.height
      var drawRect = CGRect(origin: .zero, size: size)
      
      if aspectRatio > 1 {
        // Wider than tall
        drawRect.size.height = size.width / aspectRatio
        drawRect.origin.y = (size.height - drawRect.size.height) / 2
      } else {
        // Taller than wide
        drawRect.size.width = size.height * aspectRatio
        drawRect.origin.x = (size.width - drawRect.size.width) / 2
      }
      
      logoImage.draw(in: drawRect)
    }
  }
  
  private func subscribeToBookRegistryChanges() {
    // Subscribe to registry changes (fires when books are loaded from disk or synced)
    TPPBookRegistry.shared.registryPublisher
      .dropFirst() // Skip initial empty state
      .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
      .sink { [weak self] _ in
        Log.debug(#file, "🚗 Registry updated - refreshing CarPlay library")
        self?.templateManager?.refreshLibrary()
      }
      .store(in: &cancellables)
    
    // Also subscribe to individual book state changes (download progress, etc.)
    TPPBookRegistry.shared.bookStatePublisher
      .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
      .sink { [weak self] _ in
        self?.templateManager?.refreshLibrary()
      }
      .store(in: &cancellables)
  }
}
