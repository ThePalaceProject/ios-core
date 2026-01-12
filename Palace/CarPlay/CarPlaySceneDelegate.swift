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
    Log.info(#file, "CarPlay connected")
    
    self.interfaceController = interfaceController
    self.templateManager = CarPlayTemplateManager(interfaceController: interfaceController)
    
    // Set up the root template
    templateManager?.setupRootTemplate()
    
    // Subscribe to book registry changes to refresh the library
    subscribeToBookRegistryChanges()
  }
  
  func templateApplicationScene(
    _ templateApplicationScene: CPTemplateApplicationScene,
    didDisconnect interfaceController: CPInterfaceController
  ) {
    Log.info(#file, "CarPlay disconnected")
    
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
    NotificationCenter.default.publisher(for: .TPPBookRegistryStateChanged)
      .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
      .sink { [weak self] _ in
        self?.templateManager?.refreshLibrary()
      }
      .store(in: &cancellables)
  }
}
