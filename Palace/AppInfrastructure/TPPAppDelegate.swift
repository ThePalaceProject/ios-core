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

    // Configure Firebase once at startup
    FirebaseApp.configure()
    
    // Initialize FirebaseManager (consolidated Firebase access to prevent mutex crashes)
    // This replaces separate DeviceSpecificErrorMonitor and RemoteFeatureFlags initialization
    Task {
      await FirebaseManager.shared.fetchAndActivateRemoteConfig()
    }

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
      
      // Migrate audiobook downloads from Caches to Application Support
      // This prevents iOS from purging downloaded audiobook files
      Task.detached(priority: .utility) {
        AudiobookSessionManager.migrateDownloadsFromCaches()
      }
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
        
        TPPUserNotifications.updateAppIconBadge(heldBooks: TPPBookRegistry.shared.heldBooks)
        
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
    
    // Resume Firebase operations when app becomes active
    FirebaseManager.shared.applicationDidBecomeActive()
  }
  
  func applicationDidEnterBackground(_ application: UIApplication) {
    // Pause Firebase operations when app goes to background
    // This helps prevent the "recursive_mutex lock failed" crash
    FirebaseManager.shared.applicationDidEnterBackground()
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
        if !TPPSettings.shared.settingsAccountIdsList.contains(account.uuid) {
          TPPSettings.shared.settingsAccountIdsList.append(account.uuid)
        }
        if let urlString = account.catalogUrl, let url = URL(string: urlString) {
          TPPSettings.shared.accountMainFeedURL = url
        }
        AccountsManager.shared.currentAccount = account
        
        account.loadAuthenticationDocument { _ in }
        
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

/// Severity levels for cache cleanup operations
private enum CleanupSeverity {
  case medium
  case high
}

/// Centralized observer for memory pressure, thermal state, and disk space cleanup.
/// Performs cache purges, download throttling, and space reclamation when needed.
final class MemoryPressureMonitor {
  static let shared = MemoryPressureMonitor()

  private let monitorQueue = DispatchQueue(label: "org.thepalaceproject.memory-pressure", qos: .utility)
  private var proactiveMonitoringTask: Task<Void, Never>?

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
    
    // Start proactive memory monitoring
    startProactiveMonitoring()
  }
  
  /// Proactively monitors memory usage and cleans up before hitting critical levels
  private func startProactiveMonitoring() {
    proactiveMonitoringTask = Task {
      while !Task.isCancelled {
        // Check every 30 seconds
        try? await Task.sleep(nanoseconds: 30_000_000_000)
        
        await checkMemoryPressure()
      }
    }
  }
  
  /// Checks current memory usage and takes action if needed
  private func checkMemoryPressure() async {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
    
    let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
        task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
      }
    }
    
    guard kerr == KERN_SUCCESS else { return }
    
    let usedMemoryMB = Int64(info.resident_size) / (1024 * 1024)
    let totalMemoryMB = Int64(ProcessInfo.processInfo.physicalMemory) / (1024 * 1024)
    let memoryPercentage = Double(usedMemoryMB) / Double(totalMemoryMB)
    
    // Take proactive action if memory usage is high
    if memoryPercentage > 0.75 {
      Log.warn(#file, "High memory usage detected: \(usedMemoryMB)MB / \(totalMemoryMB)MB (\(Int(memoryPercentage * 100))%)")
      await proactiveCacheCleanup(severity: .high)
    } else if memoryPercentage > 0.60 {
      await proactiveCacheCleanup(severity: .medium)
    }
  }
  
  /// Proactively cleans up caches based on severity
  private func proactiveCacheCleanup(severity: CleanupSeverity) async {
    monitorQueue.async {
      switch severity {
      case .high:
        // Aggressive cleanup
        URLCache.shared.removeAllCachedResponses()
        TPPNetworkExecutor.shared.clearCache()
        MyBooksDownloadCenter.shared.pauseAllDownloads()
        Log.info(#file, "Performed aggressive cache cleanup due to high memory pressure")
        
      case .medium:
        // Moderate cleanup - just network caches
        URLCache.shared.removeAllCachedResponses()
        Log.info(#file, "Performed moderate cache cleanup due to medium memory pressure")
      }
    }
  }
  
  func stop() {
    proactiveMonitoringTask?.cancel()
    proactiveMonitoringTask = nil
  }

  @objc private func handleMemoryWarning() {
    monitorQueue.async {
      URLCache.shared.removeAllCachedResponses()
      TPPNetworkExecutor.shared.clearCache()

      MyBooksDownloadCenter.shared.pauseAllDownloads()

      self.reclaimDiskSpaceIfNeeded(minimumFreeMegabytes: 256)

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
      var maxActive = 10
      
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

