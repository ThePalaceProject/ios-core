import Foundation
import FirebaseCore
import FirebaseDynamicLinks
import BackgroundTasks
import SwiftUI
import PalaceAudiobookToolkit

@main
class TPPAppDelegate: UIResponder, UIApplicationDelegate {

  var window: UIWindow?
  let audiobookLifecycleManager = AudiobookLifecycleManager()
  var notificationsManager: TPPUserNotifications!
  var isSigningIn = false

  // MARK: - Application Lifecycle

  func applicationDidFinishLaunching(_ application: UIApplication) {
    let startupQueue = DispatchQueue.global(qos: .userInitiated)

    FirebaseApp.configure()

    TPPErrorLogger.configureCrashAnalytics()
    TPPErrorLogger.logNewAppLaunch()
    
    GeneralCache<String, Data>.clearCacheOnUpdate()

    setupWindow()
    configureUIAppearance()

    startupQueue.async {
      self.setupBookRegistryAndNotifications()
    }

    startupQueue.asyncAfter(deadline: .now() + 0.5) {
      self.performBackgroundStartupTasks()
    }

    registerBackgroundTasks()
  }

  private func performBackgroundStartupTasks() {
    TPPKeychainManager.validateKeychain()
    TPPMigrationManager.migrate()
    NetworkQueue.shared().addObserverForOfflineQueue()
    Reachability.shared.startMonitoring()

    DispatchQueue.main.async {
      self.audiobookLifecycleManager.didFinishLaunching()
    }

    TransifexManager.setup()

    NotificationCenter.default.addObserver(forName: .TPPIsSigningIn, object: nil, queue: nil) { [weak self] notification in
      self?.signingIn(notification)
    }
  }

  private func setupBookRegistryAndNotifications() {
    DispatchQueue.global(qos: .background).async {
      _ = TPPBookRegistry.shared
    }

    NotificationService.shared.setupPushNotifications()
  }

  // MARK: - Background Task Registration

  private func registerBackgroundTasks() {
    BGTaskScheduler.shared.register(forTaskWithIdentifier: "org.thepalaceproject.palace.refresh", using: nil) { task in
      self.handleAppRefresh(task: task as! BGAppRefreshTask)
    }
  }

  private func handleAppRefresh(task: BGAppRefreshTask) {
    scheduleAppRefresh()
    let startDate = Date()

    TPPBookRegistry.shared.sync { errorDocument, newBooks in
      if errorDocument != nil {
        Log.log("[Background Refresh] Failed. Error Document Present. Elapsed Time: \(-startDate.timeIntervalSinceNow)")
        task.setTaskCompleted(success: false)
      } else {
        Log.log("[Background Refresh] \(newBooks ? "New books available" : "No new books fetched"). Elapsed Time: \(-startDate.timeIntervalSinceNow)")
        task.setTaskCompleted(success: true)
      }
    }

    task.expirationHandler = {
      Log.log("[Background Refresh] Task expired. Elapsed Time: \(-startDate.timeIntervalSinceNow)")
      task.setTaskCompleted(success: false)
    }
  }

  private func scheduleAppRefresh() {
    let request = BGAppRefreshTaskRequest(identifier: "org.thepalaceproject.palace.refresh")
    request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60) // 15 minutes

    do {
      try BGTaskScheduler.shared.submit(request)
    } catch {
      Log.error(error.localizedDescription, "Failed to submit BGAppRefreshTask: \(error.localizedDescription)")
    }
  }

  // MARK: - URL Handling (Dynamic Links)

  func application(_ application: UIApplication, continue userActivity: NSUserActivity, restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) -> Bool {
    if let url = userActivity.webpageURL {
      return DynamicLinks.dynamicLinks().handleUniversalLink(url) { dynamicLink, error in
        if let error = error {
          Log.error(error.localizedDescription, "Dynamic Link error")
          return
        }
        if let dynamicLink = dynamicLink, DLNavigator.shared.isValidLink(dynamicLink) {
          DLNavigator.shared.navigate(to: dynamicLink)
        }
      }
    }

    if userActivity.activityType == NSUserActivityTypeBrowsingWeb &&
        userActivity.webpageURL?.host == TPPSettings.shared.universalLinksURL.host {
      NotificationCenter.default.post(name: .TPPAppDelegateDidReceiveCleverRedirectURL, object: userActivity.webpageURL)
      return true
    }
    return false
  }

  func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
    if let dynamicLink = DynamicLinks.dynamicLinks().dynamicLink(fromCustomSchemeURL: url) {
      if DLNavigator.shared.isValidLink(dynamicLink) {
        DLNavigator.shared.navigate(to: dynamicLink)
        return true
      }
    }
    return false
  }

  func applicationDidBecomeActive(_ application: UIApplication) {
    TPPErrorLogger.setUserID(TPPUserAccount.sharedAccount().barcode)
  }

  func applicationWillTerminate(_ application: UIApplication) {
    audiobookLifecycleManager.willTerminate()
    NotificationCenter.default.removeObserver(self)
    Reachability.shared.stopMonitoring()
  }

  internal func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
    audiobookLifecycleManager.handleEventsForBackgroundURLSession(for: identifier, completionHandler: completionHandler)
  }

  // MARK: - User Sign-in Tracking

  func signingIn(_ notification: Notification) {
    if let boolValue = notification.object as? Bool {
      isSigningIn = boolValue
    }
  }

  // MARK: - UI Configuration

  private func setupWindow() {
    window = UIWindow()
    window?.tintColor = TPPConfiguration.mainColor()
    window?.tintAdjustmentMode = .normal
    window?.makeKeyAndVisible()
    let root = AppTabHostView()
    window?.rootViewController = UIHostingController(rootView: root)
  }

  private func configureUIAppearance() {
    UITabBar.appearance().tintColor = TPPConfiguration.iconColor()
    UITabBar.appearance().backgroundColor = TPPConfiguration.backgroundColor()
    UITabBarItem.appearance().setTitleTextAttributes([.font: UIFont.palaceFont(ofSize: 12)], for: .normal)

    UINavigationBar.appearance().tintColor = TPPConfiguration.iconColor()

    if let defaultAppearance = TPPConfiguration.defaultAppearance() {
      UINavigationBar.appearance().standardAppearance = defaultAppearance
      UINavigationBar.appearance().compactAppearance = defaultAppearance
      UINavigationBar.appearance().scrollEdgeAppearance = defaultAppearance
      UINavigationBar.appearance().compactScrollEdgeAppearance = defaultAppearance
    }
  }
}
