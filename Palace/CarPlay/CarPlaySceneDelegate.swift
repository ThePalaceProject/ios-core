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
    Log.info(#file, "🚗 CarPlay scene connected - setting up templates")
    
    self.interfaceController = interfaceController
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
  }
  
  func templateApplicationScene(
    _ templateApplicationScene: CPTemplateApplicationScene,
    didSelect navigationAlert: CPNavigationAlert
  ) {
    // Handle navigation alerts if needed
  }
  
  // MARK: - Private Methods
  
  private func subscribeToBookRegistryChanges() {
    TPPBookRegistry.shared.bookStatePublisher
      .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
      .sink { [weak self] _ in
        self?.templateManager?.refreshLibrary()
      }
      .store(in: &cancellables)
  }
}
