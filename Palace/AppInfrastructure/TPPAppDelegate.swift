//
//  TPPAppDelegate.swift
//  Palace
//
//  Created by Vladimir Fedorov on 12/05/2023.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import Foundation
import FirebaseCore

@main
class TPPAppDelegate: UIResponder, UIApplicationDelegate {
  
  var window: UIWindow?
  var audiobookLifecycleManager: AudiobookLifecycleManager!
  var reachabilityManager: TPPReachability!
  var notificationsManager: TPPUserNotifications!
  var isSigningIn = false

  // MARK: - Application Lifecycle
  
  func applicationDidFinishLaunching(_ application: UIApplication) {
    FirebaseApp.configure()
    TPPErrorLogger.configureCrashAnalytics()

    // Perform data migrations as early as possible before anything has a chance to access them
    TPPKeychainManager.validateKeychain()
    TPPMigrationManager.migrate()
    
    audiobookLifecycleManager = AudiobookLifecycleManager()
    audiobookLifecycleManager.didFinishLaunching()
    
    TransifexManager.setup()
    
    NotificationCenter.default .addObserver(forName: .TPPIsSigningIn, object: nil, queue: nil, using: signingIn)
    
    // TODO: Remove old reachability functions
    NetworkQueue.shared().addObserverForOfflineQueue()
    reachabilityManager = TPPReachability.shared()
    
    // New reachability notifications
    Reachability.shared.startMonitoring()
    
    // TODO: Refactor this to use SceneDelegate instead
    // If we use SceneDelegate now, the app crashes during TPPRootTabBarController.shared initialization.
    // There can be other places in code that use TPPAppDelegate.window property.
    window = UIWindow()
    window?.tintColor = TPPConfiguration.mainColor()
    window?.tintAdjustmentMode = .normal
    window?.makeKeyAndVisible()
    window?.rootViewController = TPPRootTabBarController.shared()
    
    UITabBar.appearance().tintColor = TPPConfiguration.iconColor()
    UITabBar.appearance().backgroundColor = TPPConfiguration.backgroundColor()
    UITabBarItem.appearance().setTitleTextAttributes([.font: UIFont.palaceFont(ofSize: 12)], for: .normal)
    
    UINavigationBar.appearance().tintColor = TPPConfiguration.iconColor()
    UINavigationBar.appearance().standardAppearance = TPPConfiguration.defaultAppearance()
    UINavigationBar.appearance().compactAppearance = TPPConfiguration.defaultAppearance()
    UINavigationBar.appearance().scrollEdgeAppearance = TPPConfiguration.defaultAppearance()
    if #available(iOS 15.0, *) {
      UINavigationBar.appearance().compactScrollEdgeAppearance = TPPConfiguration.defaultAppearance()
    }

    TPPErrorLogger.logNewAppLaunch()
    
    // Initialize book registry
    _ = TPPBookRegistry.shared
    
    // Push Notificatoins
    // TODO: Enable push notifications when CM starts supporting them
//    NotificationService.shared.setupPushNotifications()
  }
  
  // TODO: This method is deprecated, we should migrate to BGAppRefreshTask in the BackgroundTasks framework instead
  func application(_ application: UIApplication, performFetchWithCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
    let startDate = Date()
    if TPPUserNotifications.backgroundFetchIsNeeded() {
      Log.log(String(format: "%@: %@", #function, "[Background Fetch] Starting book registry sync. ElapsedTime=\(-startDate.timeIntervalSinceNow)"))
      TPPBookRegistry.shared.sync { errorDocument, newBooks in
        var result: String
        if errorDocument != nil {
          result = "error document"
          completionHandler(.failed)
        } else if newBooks {
          result = "new ready books available"
          completionHandler(.newData)
        } else {
          result = "no ready books fetched"
          completionHandler(.noData)
        }
        Log.log(String(format: "%@: %@", #function, "[Background Fetch] Completed with \(result). ElapsedTime=\(-startDate.timeIntervalSinceNow)"))
      }
    } else {
      completionHandler(.noData)
    }
  }
  
  func application(_ application: UIApplication, continue userActivity: NSUserActivity, restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) -> Bool {
    if userActivity.activityType == NSUserActivityTypeBrowsingWeb &&
        userActivity.webpageURL?.host == TPPSettings.shared.universalLinksURL.host {
      NotificationCenter.default.post(name: .TPPAppDelegateDidReceiveCleverRedirectURL, object: userActivity.webpageURL)
      return true
    }
    return false
  }
  
  func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey : Any] = [:]) -> Bool {

    // TODO: Refactor this code.
    // The code below opens a book entry URL, replacing https with http,
    // downloads the entry synchronously.

    // URLs should be a permalink to a feed URL
    let entryUrl = url.replacingScheme(with: "http")
    if let data = try? Data(contentsOf: entryUrl),
       let xml = TPPXML(data: data),
       let entry = TPPOPDSEntry(xml: xml),
       let book = TPPBook(entry: entry) {
      
      if let bookDetailVC = TPPBookDetailViewController(book: book),
         let tbc = TPPRootTabBarController.shared() {
        tbc.selectedIndex = 0
        if let navigationVC = tbc.selectedViewController as? UINavigationController, tbc.traitCollection.horizontalSizeClass == .compact {
          navigationVC.pushViewController(bookDetailVC, animated: true)
        } else if let navigationVC = tbc.selectedViewController?.presentedViewController as? UINavigationController {
          navigationVC.pushViewController(bookDetailVC, animated: true)
        } else {
          let navigationVC = UINavigationController(rootViewController: bookDetailVC)
          navigationVC.modalPresentationStyle = .formSheet
          tbc.selectedViewController?.present(navigationVC, animated: true)
        }
        return true
      } else {
        return false
      }
    } else {
      let alertController = TPPAlertUtils.alert(title: "Error Opening Link", message: "There was an error opening the linked book.", style: .default)
      TPPAlertUtils.presentFromViewControllerOrNil(alertController: alertController, viewController: nil, animated: true, completion: nil)
      Log.log("Failed to create book from deep-linked URL.")
      return false
    }
  }
  
  func applicationDidBecomeActive(_ application: UIApplication) {
    TPPErrorLogger.setUserID(TPPUserAccount.sharedAccount().barcode)
  }
  
  func applicationWillTerminate(_ application: UIApplication) {
    self.audiobookLifecycleManager.willTerminate()
    NotificationCenter.default.removeObserver(self)
  }
  
  func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
    self.audiobookLifecycleManager.handleEventsForBackgroundURLSession(for: identifier, completionHandler: completionHandler)
  }
  
  func signingIn(_ notification: Notification) {
    if let boolValue = notification.object as? Bool {
      self.isSigningIn = boolValue
    }
  }
  
}
