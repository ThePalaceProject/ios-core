//
//  SceneDelegate.swift
//  Palace
//
//  Created for scene-based app lifecycle support.
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import UIKit
import SwiftUI

/// Scene delegate for the main app window.
/// Required when using UIApplicationSceneManifest for CarPlay support.
class SceneDelegate: UIResponder, UIWindowSceneDelegate {
  
  var window: UIWindow?
  
  func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    guard let windowScene = scene as? UIWindowScene else { return }
    
    Log.info(#file, "📱 Main app scene connecting")
    
    // Create window for this scene
    let newWindow = UIWindow(windowScene: windowScene)
    newWindow.tintColor = TPPConfiguration.mainColor()
    newWindow.tintAdjustmentMode = .normal
    
    // Create root view controller directly to avoid any timing issues
    let rootView = AppTabHostView()
    let hostingController = UIHostingController(rootView: rootView)
    newWindow.rootViewController = hostingController
    newWindow.makeKeyAndVisible()
    
    window = newWindow
    
    // Also set on AppDelegate for backward compatibility
    if let appDelegate = UIApplication.shared.delegate as? TPPAppDelegate {
      appDelegate.window = newWindow
    }
    
    Log.info(#file, "📱 Main app window configured successfully")
    
    // Handle any URLs passed at launch
    if let urlContext = connectionOptions.urlContexts.first {
      let appDelegate = UIApplication.shared.delegate as? TPPAppDelegate
      _ = appDelegate?.application(UIApplication.shared, open: urlContext.url, options: [:])
    }
  }
  
  func sceneDidDisconnect(_ scene: UIScene) {
    Log.info(#file, "📱 Main app scene disconnected")
  }
  
  func sceneDidBecomeActive(_ scene: UIScene) {
    // Restart any tasks paused when scene was inactive
  }
  
  func sceneWillResignActive(_ scene: UIScene) {
    // Called when scene will move to inactive state
  }
  
  func sceneWillEnterForeground(_ scene: UIScene) {
    // Called as scene transitions from background to foreground
  }
  
  func sceneDidEnterBackground(_ scene: UIScene) {
    // Save data, release resources, store scene state
  }
  
  func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    guard let url = URLContexts.first?.url else { return }
    let appDelegate = UIApplication.shared.delegate as? TPPAppDelegate
    _ = appDelegate?.application(UIApplication.shared, open: url, options: [:])
  }
}
