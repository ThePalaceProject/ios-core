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

    MemoryPressureMonitor.shared.start()

    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.presentFirstRunFlowIfNeeded()
    }
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
    request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)

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
    MyBooksDownloadCenter.shared.purgeAllAudiobookCaches(force: false)
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

// MARK: - First Run Flow
extension TPPAppDelegate {
  private func presentFirstRunFlowIfNeeded() {
    // Defer until accounts have loaded to avoid false negatives on currentAccount
    if !AccountsManager.shared.accountsHaveLoaded {
      NotificationCenter.default.addObserver(forName: .TPPCatalogDidLoad, object: nil, queue: .main) { [weak self] _ in
        self?.presentFirstRunFlowIfNeeded()
      }
      AccountsManager.shared.loadCatalogs(completion: nil)
      return
    }

    let showOnboarding = !TPPSettings.shared.userHasSeenWelcomeScreen
    // Use persisted currentAccountId rather than computed currentAccount to avoid timing issues
    let needsAccount = (AccountsManager.shared.currentAccountId == nil)
    guard showOnboarding || needsAccount else { return }

    guard let top = topViewController() else { return }

    func presentOnboarding(over presenter: UIViewController) {
      let onboardingVC = TPPOnboardingViewController.makeSwiftUIView(dismissHandler: {
        TPPSettings.shared.userHasSeenWelcomeScreen = true
        presenter.presentedViewController?.dismiss(animated: true)
      })
      presenter.present(onboardingVC, animated: true)
    }

    if needsAccount {
      var nav: UINavigationController!
      let accountList = TPPAccountList { account in
        // Match CatalogView's Add Library flow: persist, switch account, update feed URL, notify, dismiss
        if !TPPSettings.shared.settingsAccountIdsList.contains(account.uuid) {
          TPPSettings.shared.settingsAccountIdsList.append(account.uuid)
        }
        AccountsManager.shared.currentAccount = account
        if let urlString = account.catalogUrl, let url = URL(string: urlString) {
          TPPSettings.shared.accountMainFeedURL = url
        }
        NotificationCenter.default.post(name: .TPPCurrentAccountDidChange, object: nil)
        nav?.dismiss(animated: true)
      }
      accountList.requiresSelectionBeforeDismiss = true
      nav = UINavigationController(rootViewController: accountList)
      top.present(nav, animated: true) {
        if showOnboarding {
          presentOnboarding(over: nav)
        }
      }
    } else if showOnboarding {
      presentOnboarding(over: top)
    }
  }

  private func switchToCatalogTab() {
    if let host = window?.rootViewController as? UIHostingController<AppTabHostView> {
      _ = host
    }
  }

  private func reloadCatalogForCurrentAccount() {
    // Notify observers again in case catalog view needs a kick
    NotificationCenter.default.post(name: .TPPCurrentAccountDidChange, object: nil)
  }
}

// MARK: - Memory and Disk Pressure Handling
import UIKit

/// Centralized observer for memory pressure, thermal state, and disk space cleanup.
/// Performs cache purges, download throttling, and space reclamation when needed.
final class MemoryPressureMonitor {
  static let shared = MemoryPressureMonitor()

  private let monitorQueue = DispatchQueue(label: "org.thepalaceproject.memory-pressure", qos: .utility)
  private let memoryManager = AdaptiveMemoryManager.shared

  private init() {}

  func start() {
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleMemoryWarning),
      name: UIApplication.didReceiveMemoryWarningNotification,
      object: nil
    )

    if #available(iOS 11.0, *) {
      NotificationCenter.default.addObserver(
        self,
        selector: #selector(handleThermalStateChanged),
        name: ProcessInfo.thermalStateDidChangeNotification,
        object: nil
      )
    }

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handlePowerModeChanged),
      name: NSNotification.Name.NSProcessInfoPowerStateDidChange,
      object: nil
    )

    // Opportunistic cleanup at startup
    monitorQueue.async { [weak self] in
      // Relax startup reclamation threshold to avoid aggressive evictions on older devices
      self?.reclaimDiskSpaceIfNeeded(minimumFreeMegabytes: 256)
    }
  }

  @objc private func handleMemoryWarning() {
    monitorQueue.async {
      // Purge URL caches
      URLCache.shared.removeAllCachedResponses()
      TPPNetworkExecutor.shared.clearCache()

      // Purge app caches (memory and disk)
      ImageCache.shared.clear()
      GeneralCache<String, Data>.clearAllCaches()

      // Pause downloads briefly to allow memory to recover
      MyBooksDownloadCenter.shared.pauseAllDownloads()

      // Attempt to free disk space as well, but less aggressively
      self.reclaimDiskSpaceIfNeeded(minimumFreeMegabytes: 256)

      // Resume a limited number of downloads after a short delay
      self.monitorQueue.asyncAfter(deadline: .now() + 5) {
        self.adjustDownloadLimitsForCurrentConditions()
      }
    }
  }

  @objc private func handleThermalStateChanged() {
    adjustDownloadLimitsForCurrentConditions()
  }

  @objc private func handlePowerModeChanged() {
    adjustDownloadLimitsForCurrentConditions()
  }

  private func adjustDownloadLimitsForCurrentConditions() {
    monitorQueue.async {
      let processInfo = ProcessInfo.processInfo
      var maxActive = self.memoryManager.maxConcurrentDownloads
      
      if #available(iOS 11.0, *) {
        switch processInfo.thermalState {
        case .critical:
          maxActive = 1
        case .serious:
          maxActive = min(maxActive, 2)
        case .fair:
          maxActive = min(maxActive, 3)
        default:
          break
        }
      }
      if processInfo.isLowPowerModeEnabled {
        maxActive = min(maxActive, 1)
      }
      MyBooksDownloadCenter.shared.limitActiveDownloads(max: maxActive)
    }
  }

  /// Ensure at least `minimumFreeMegabytes` are available by clearing caches and evicting
  /// least-recently-used book content if necessary.
  func reclaimDiskSpaceIfNeeded(minimumFreeMegabytes: Int) {
    let minimumFreeBytes = Int64(minimumFreeMegabytes) * 1024 * 1024
    let freeBytes = FileSystem.freeDiskSpaceInBytes()
    guard freeBytes < minimumFreeBytes else { return }

    // Clear caches first
    URLCache.shared.removeAllCachedResponses()
    ImageCache.shared.clear()
    GeneralCache<String, Data>.clearAllCaches()

    // Evict least-recently-used book files
    MyBooksDownloadCenter.shared.enforceContentDiskBudgetIfNeeded(adding: 0)

    // As a final step, prune very old files from Caches directory
    pruneOldFilesFromCachesDirectory(olderThanDays: 30)
  }

  private func pruneOldFilesFromCachesDirectory(olderThanDays days: Int) {
    let fm = FileManager.default
    guard let cachesDir = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
    let cutoff = Date().addingTimeInterval(TimeInterval(-days * 24 * 60 * 60))
    if let contents = try? fm.contentsOfDirectory(at: cachesDir, includingPropertiesForKeys: [.contentAccessDateKey, .contentModificationDateKey, .isDirectoryKey], options: [.skipsHiddenFiles]) {
      for url in contents {
        do {
          let rvalues = try url.resourceValues(forKeys: [.isDirectoryKey, .contentAccessDateKey, .contentModificationDateKey])
          if rvalues.isDirectory == true { continue }
          let last = rvalues.contentAccessDate ?? rvalues.contentModificationDate ?? Date.distantPast
          if last < cutoff {
            try? fm.removeItem(at: url)
          }
        } catch {
          // ignore
        }
      }
    }
  }
}

private enum FileSystem {
  static func freeDiskSpaceInBytes() -> Int64 {
    do {
      let attrs = try FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
      if let free = attrs[.systemFreeSize] as? NSNumber { return free.int64Value }
    } catch { }
    return 0
  }
}

