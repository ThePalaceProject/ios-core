import Foundation
import os
import FirebaseCore
import FirebaseAnalytics
import FirebaseCrashlytics
// `@preconcurrency`: FirebaseDynamicLinks is not Sendable-audited upstream; its
// `DynamicLink` crosses into a `@MainActor` Task when routing a universal link.
// Honest ceiling until Firebase annotates its concurrency (see fix vocabulary).
@preconcurrency import FirebaseDynamicLinks
import BackgroundTasks
import SwiftUI
import CarPlay
import PalaceAudiobookToolkit
import PalaceLogging

@main
class TPPAppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?
    let audiobookLifecycleManager = AudiobookLifecycleManager()
    var isSigningIn = false

    // PP-4329: state for the first-run library picker. Without these,
    // presentFirstRunFlowIfNeeded leaked a new .TPPCatalogDidLoad observer
    // on every recursive call (AccountsManager posts that notification
    // from 8 sites — main catalog load, fallback GET, beta/prod hash
    // switch, etc.). Each observer re-invoked presentFirstRunFlowIfNeeded,
    // which presented another TPPAccountList modal, stacking 2-4 selectors
    // on a fresh install depending on how many posts fired before the
    // user picked. The token lets us remove the previous observer before
    // adding a new one (and after we've successfully gone past the
    // deferred-load state); the flag prevents re-presentation once a
    // selector is already on screen.
    private var firstRunFlowObserver: NSObjectProtocol?
    private var hasPresentedFirstRunFlow = false

    // MARK: - Application Lifecycle

    func applicationDidFinishLaunching(_ application: UIApplication) {
        // Register Crashlytics forwarder before any Log call fires.
        // PalaceLogging is Firebase-free; the host app supplies the bridge.
        Log.crashlyticsBridge = FirebaseCrashlyticsBridge()

        let startupQueue = DispatchQueue.global(qos: .userInitiated)

        // Build identifier marker — logged on every app launch so a sysdiagnose
        // unambiguously identifies which 3.0.2 build is running.
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let buildNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let iosVersion = UIDevice.current.systemVersion
        let deviceModel = UIDevice.current.model
        Log.info(#file, "[BUILD MARKER] App=\(appVersion) (\(buildNumber)), iOS=\(iosVersion), device=\(deviceModel)")

        // NOTE: the iPad-on-Mac watchdog-exit interceptor is NOT installed here.
        // A launch-time atexit install is too early: Adobe RMSDK's recursive_mutex
        // destructor is registered (via __cxa_atexit) at first DRM use, which can
        // be LATER than launch — so a launch-time handler would be LIFO-popped
        // AFTER Adobe's faulting dtor. The interceptor is instead installed right
        // after the first Adobe-DRM decode (AdobeDRMContentProtection), where it is
        // LIFO-after Adobe's dtor regardless of whether the mutex is constructed at
        // dylib-load or lazily. See AdobeDRMService.registerStaticDestructorBypassIfNeeded.

        // CRITICAL: Initialize playback infrastructure FIRST for CarPlay cold starts
        // This ensures MPRemoteCommandCenter handlers are registered before any UI loads
        // Without this, CarPlay remote controls won't work when the app is launched
        // directly from CarPlay without the phone UI ever being shown
        Log.info(#file, "📱 App launch - initializing playback bootstrapper")
        AppContainer.production().playbackBootstrapper.ensureInitialized()

        // Configure Firebase once at startup. The SDK MUST be initialized
        // (other code paths assume FirebaseApp.app() is non-nil and call
        // Analytics.logEvent directly), but when running under XCTest we
        // disable the network-firing subsystems so:
        //   - no LocalUploadTask requests to app-analytics-services.com
        //     build up behind suite-wide DNS timeouts (~30s each), which
        //     were wedging the simulator partway through long runs.
        //   - no Crashlytics uploads race test tearDown and post from a
        //     half-torn-down process.
        //   - no Remote Config fetch, which was already gated but left
        //     other subsystems firing.
        FirebaseApp.configure()

        if TPPProcessInfo.isRunningTests {
            Analytics.setAnalyticsCollectionEnabled(false)
            Crashlytics.crashlytics().setCrashlyticsCollectionEnabled(false)
        } else {
            Task {
                await FirebaseManager.shared.fetchAndActivateRemoteConfig()
                _ = RemoteFeatureFlags.shared.isCarPlayEnabled
            }
            TPPErrorLogger.configureCrashAnalytics()
        }
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

    // `nonisolated`: deliberately dispatched on `startupQueue` (background) 0.5s
    // after launch. Body touches only nonisolated APIs; the one `@MainActor`
    // access (`audiobookLifecycleManager.didFinishLaunching()`) hops to the main
    // actor explicitly below. `complete`-mode satisfied without forcing this
    // off-main work onto the main actor.
    nonisolated private func performBackgroundStartupTasks() {
        let isFreshInstall = AppContainer.production().settings.appVersion == nil
        TPPKeychainManager.validateKeychain()
        TPPMigrationManager.migrate()
        AppContainer.production().networkQueue.addObserverForOfflineQueue()
        AppContainer.production().reachability.startMonitoring()

        logCredentialStateAtLaunch(isFreshInstall: isFreshInstall)

        PalaceAuthTokenProvider.tokenResolver = {
            AppContainer.production().accountsManager.currentUserAccount.authToken
        }

        // `Task { @MainActor }` (was `DispatchQueue.main.async`): `didFinishLaunching()`
        // touches the `@MainActor`-isolated `audiobookLifecycleManager`; the Task
        // gives the closure main-actor isolation so the access is checked, not a
        // `@Sendable` capture of main-actor state. Same "next main run-loop" timing.
        Task { @MainActor in
            self.audiobookLifecycleManager.didFinishLaunching()

            // TODO: Implement audiobook downloads migration from Caches to Application Support
            // This would prevent iOS from purging downloaded audiobook files
        }

        if !TPPProcessInfo.isRunningTests {
            TransifexManager.setup()
        }

        // `queue: .main` + `Task { @MainActor }`: `signingIn` mutates the
        // `@MainActor` `isSigningIn` flag. Post can arrive off-main, so hop to the
        // main actor before touching main-actor state (previously `queue: nil`
        // fired on the posting thread — a `complete`-mode data race on `isSigningIn`).
        NotificationCenter.default.addObserver(forName: .TPPIsSigningIn, object: nil, queue: .main) { [weak self] notification in
            Task { @MainActor in
                self?.signingIn(notification)
            }
        }
    }

    // `nonisolated`: called only from the nonisolated `performBackgroundStartupTasks`;
    // reads nonisolated account APIs and logs. No `@MainActor` state.
    nonisolated private func logCredentialStateAtLaunch(isFreshInstall: Bool) {
        let accountsManager = AppContainer.production().accountsManager
        let account = accountsManager.currentUserAccount
        let accountId = accountsManager.currentAccountId ?? "nil"
        let authDef = account.authDefinition
        let authType = authDef?.authType.rawValue ?? "none"
        let hasCredentials = account.hasCredentials()
        let hasBarcode = account.barcode != nil
        let hasPin = account.PIN != nil
        let hasToken = account.authToken != nil
        let authState = account.authState
        let tokenExpired = account.authTokenHasExpired
        let tokenNearExpiry = account.authTokenNearExpiry
        let hasTokenURL = authDef?.tokenURL != nil

        Log.info(#file, "🔑 [LAUNCH] Credential state diagnostic:")
        Log.info(#file, "  freshInstall=\(isFreshInstall), accountId=\(accountId)")
        Log.info(#file, "  authType=\(authType), authState=\(authState)")
        Log.info(#file, "  hasCredentials=\(hasCredentials), hasBarcode=\(hasBarcode), hasPin=\(hasPin)")
        Log.info(#file, "  hasToken=\(hasToken), tokenExpired=\(tokenExpired), tokenNearExpiry=\(tokenNearExpiry)")
        Log.info(#file, "  hasTokenURL=\(hasTokenURL)")

        if hasBarcode, let barcode = account.barcode {
            let barcodeShape: String
            if barcode.allSatisfy({ $0.isNumber }) {
                barcodeShape = "numeric"
            } else if barcode.count > 50 {
                barcodeShape = "token-like"
            } else {
                barcodeShape = "alphanumeric"
            }
            Log.info(#file, "  barcodeShape=\(barcodeShape), barcodeLen=\(barcode.count)")
        }

        if isFreshInstall && hasCredentials {
            Log.warn(#file, "  ⚠️ ANOMALY: Fresh install but credentials exist (keychain may not have been fully cleaned)")
        }

        if hasToken && !hasBarcode && authDef?.isToken == true {
            Log.warn(#file, "  ⚠️ ANOMALY: Has auth token but no barcode - token refresh will fail")
        }
    }

    // `nonisolated`: intentionally invoked on `startupQueue` (a background queue)
    // from `applicationDidFinishLaunching`. Touches only nonisolated APIs
    // (`AppContainer.production()`, `NotificationService.shared`) — no `@MainActor`
    // `self` state — so `complete`-mode isolation is satisfied without a main hop,
    // preserving the deliberate off-main registry priming.
    nonisolated private func setupBookRegistryAndNotifications() {
        // Populate the in-memory registry from disk BEFORE any view path can
        // trigger sync(). Previously this did a fire-and-forget singleton poke
        // on a background queue and never called load() — so sync() calls from
        // AppTabHostView tab switches, applicationDidBecomeActive, or the
        // background refresh task ran against an empty in-memory store, rebuilt
        // the registry from feed-only data, and overwrote the on-disk file.
        // Every previously-downloaded book came back as .downloadNeeded with no
        // location or bookmarks, showing "Download" again on relaunch.
        //
        // load() returns immediately — the disk I/O is dispatched onto the
        // store's own queue — but it primes the `loadingAccount` guard and
        // queues the state transition to .loaded. Any sync() that races it is
        // caught by the .unloaded/.loading guard in BookRegistrySync.sync.
        // PP-2677 side-loading: re-register persisted side-loaded books into the
        // MAIN registry so they open in the reader and appear on the shelf. This
        // MUST run in the `load(completion:)` callback — `load()` is async and a
        // rehydrate that ran before the disk snapshot landed would be clobbered
        // when the store transitions to `.loaded`. `load(completion:)` lives on
        // the concrete `TPPBookRegistry`, not the `TPPBookRegistryProvider`
        // surface, hence the cast; production always resolves to the concrete
        // type. The fallback keeps the original behaviour if that ever changes.
        if let loadableRegistry = AppContainer.production().bookRegistry as? TPPBookRegistry {
            loadableRegistry.load {
                AppContainer.production().sideloadedBookManager.rehydrateAtLaunch()
            }
        } else {
            AppContainer.production().bookRegistry.load()
        }

        NotificationService.shared.setupPushNotifications()
    }

    // MARK: - Background Task Registration

    private func registerBackgroundTasks() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: "org.thepalaceproject.palace.refresh", using: nil) { task in
            guard let refreshTask = task as? BGAppRefreshTask else { return }
            self.handleAppRefresh(task: refreshTask)
        }
    }

    private func handleAppRefresh(task: BGAppRefreshTask) {
        scheduleAppRefresh()
        let startDate = Date()

        AppContainer.production().bookRegistry.sync { errorDocument, newBooks in
            if errorDocument != nil {
                Log.log("[Background Refresh] Failed. Error Document Present. Elapsed Time: \(-startDate.timeIntervalSinceNow)")
                task.setTaskCompleted(success: false)
            } else {
                Log.log("[Background Refresh] \(newBooks ? "New books available" : "No new books fetched"). Elapsed Time: \(-startDate.timeIntervalSinceNow)")

                NotificationService.updateAppIconBadge(heldBooks: AppContainer.production().bookRegistry.heldBooks)

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
                    // `handleUniversalLink`'s completion is `@Sendable`/off-main; hop
                    // to the main actor for the now-`@MainActor` `navigate(to:)`.
                    Task { @MainActor in
                        DLNavigator.shared.navigate(to: dynamicLink)
                    }
                }
            }
        }

        if userActivity.activityType == NSUserActivityTypeBrowsingWeb &&
            userActivity.webpageURL?.host == AppContainer.production().settings.universalLinksURL.host {
            NotificationCenter.default.post(name: .TPPAppDelegateDidReceiveCleverRedirectURL, object: userActivity.webpageURL)
            return true
        }
        return false
    }

    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        // Handle PalaceApp://carplay URL (used by CarPlay to open app on phone)
        if url.scheme == "PalaceApp" && url.host == "carplay" {
            Log.info(#file, "📱 App opened from CarPlay - ready for playback")
            return true
        }

        if let dynamicLink = DynamicLinks.dynamicLinks().dynamicLink(fromCustomSchemeURL: url) {
            if DLNavigator.shared.isValidLink(dynamicLink) {
                DLNavigator.shared.navigate(to: dynamicLink)
                return true
            }
        }
        return false
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        TPPErrorLogger.setUserID(AppContainer.production().accountsManager.currentUserAccount.barcode)

        // Resume Firebase operations when app becomes active
        FirebaseManager.shared.applicationDidBecomeActive()

        // Record an app-open for the rating-prompt engagement signals (PP-4087).
        AppContainer.production().appRatingService.recordSession()

        // Update feature flag cache after Remote Config is refreshed
        Task {
            // Small delay to let Remote Config fetch complete
            try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
            _ = RemoteFeatureFlags.shared.isCarPlayEnabled
        }

        // Sync held books when app becomes active to ensure UI reflects current availability
        syncIfUserHasHolds()
    }

    /// Syncs the book registry if the user has holds to ensure fresh availability data.
    /// Throttled to prevent excessive network calls on frequent app activation.
    private func syncIfUserHasHolds() {
        guard AppContainer.production().accountsManager.currentUserAccount.hasCredentials() else {
            return
        }

        let heldBooks = AppContainer.production().bookRegistry.heldBooks
        guard !heldBooks.isEmpty else {
            return
        }

        // Shared throttle key with NotificationService to coordinate syncs
        let lastSyncKey = "lastForegroundSyncTimestamp"
        let lastSync = UserDefaults.standard.double(forKey: lastSyncKey)
        let now = Date().timeIntervalSince1970

        guard (now - lastSync) > 30 else {
            Log.debug(#file, "[Foreground Sync] Skipped - synced recently")
            return
        }

        UserDefaults.standard.set(now, forKey: lastSyncKey)

        Log.info(#file, "[Foreground Sync] Starting - user has \(heldBooks.count) holds")

        AppContainer.production().bookRegistry.sync { errorDocument, newBooks in
            if let errorDocument = errorDocument {
                Log.error(#file, "[Foreground Sync] Failed: \(errorDocument)")
            } else {
                Log.info(#file, "[Foreground Sync] Completed. New books: \(newBooks)")
                NotificationService.updateAppIconBadge(heldBooks: AppContainer.production().bookRegistry.heldBooks)
            }
        }
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        // Pause Firebase operations when app goes to background
        // This helps prevent the "recursive_mutex lock failed" crash
        FirebaseManager.shared.applicationDidEnterBackground()

        #if FEATURE_DRM_CONNECTOR
        // iPad-on-Mac watchdog-exit guard (WS-4). Once Adobe DRM has been used
        // this session (reader decrypt → its static recursive_mutex dtor is
        // registered), install the _exit(0) atexit interceptor HERE: background
        // entry is (a) guaranteed after every Adobe DRM decode of this session
        // ⇒ LIFO-after Adobe's dtor regardless of when the mutex was constructed,
        // and (b) adjacent to the background suspension where the watchdog forces
        // exit() and the 294 recursive_mutex faults occur (Crashlytics
        // 9a91840677, all iOS_ON_MAC). Idempotent; gated to iPad-on-Mac inside.
        if AdobeDRMService.didUseAdobeDRMThisSession {
            AdobeDRMService.registerStaticDestructorBypassIfNeeded()
        }
        #endif
    }

    func applicationWillTerminate(_ application: UIApplication) {
        // Non-Mac Adobe DRM cleanup: clear our cached NYPLADEPT delegate/ref so
        // we don't touch RMSDK during teardown. NOTE: this is a NO-OP on
        // iPad-on-Mac — `isDRMAvailable` is false there, so this branch is
        // skipped. It does NOT protect the iPad-on-Mac recursive_mutex crash
        // (it never destroyed the C++ object anyway). The actual iPad-on-Mac
        // protection is the `_exit(0)` at the END of this method (Cmd-Q path)
        // plus the background-installed atexit interceptor (watchdog path).
        #if FEATURE_DRM_CONNECTOR
        if AdobeCertificate.isDRMAvailable {
            AdobeDRMService.shared.prepareForTermination()
        }
        #endif

        audiobookLifecycleManager.willTerminate()
        NotificationCenter.default.removeObserver(self)
        AppContainer.production().reachability.stopMonitoring()

        // iPad-on-Mac only: bypass C++ static destructors on normal (Cmd-Q)
        // termination. exit()'s static-destructor pass faults in Adobe RMSDK's
        // static recursive_mutex destructor (Crashlytics 9a91840677, all events
        // iOS_ON_MAC). _exit(0) terminates immediately, skipping atexit handlers
        // and static destructors. MUST be the last statement; never runs on real
        // iOS devices.
        if shouldSkipStaticDestructorsOnExit(isiOSAppOnMac: ProcessInfo.processInfo.isiOSAppOnMac) {
            _exit(0)
        }
    }

    internal func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        audiobookLifecycleManager.handleEventsForBackgroundURLSession(for: identifier, completionHandler: completionHandler)
    }

    // MARK: - Scene Configuration

    /// Provides scene configurations for main app and CarPlay scenes.
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        Log.info(#file, "📱 Configuring scene with role: \(connectingSceneSession.role.rawValue)")

        switch connectingSceneSession.role {
        case .carTemplateApplication:
            Log.info(#file, "🚗 Creating CarPlay scene configuration")
            let config = UISceneConfiguration(name: "CarPlay", sessionRole: connectingSceneSession.role)
            config.delegateClass = CarPlaySceneDelegate.self
            return config

        case .windowApplication:
            let config = UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
            config.delegateClass = SceneDelegate.self
            return config

        default:
            // External displays / AirPlay mirroring — return a bare config so
            // iOS mirrors the main window instead of creating an independent UI.
            Log.info(#file, "Skipping full UI for scene role: \(connectingSceneSession.role.rawValue)")
            return UISceneConfiguration(name: "External", sessionRole: connectingSceneSession.role)
        }
    }

    func application(_ application: UIApplication, didDiscardSceneSessions sceneSessions: Set<UISceneSession>) {
        // Called when the user discards a scene session
        for session in sceneSessions {
            Log.info(#file, "Scene session discarded: \(session.configuration.name ?? "unknown")")
        }
    }

    // MARK: - User Sign-in Tracking

    func signingIn(_ notification: Notification) {
        if let boolValue = notification.object as? Bool {
            isSigningIn = boolValue
        }
    }

    // MARK: - UI Configuration

    private func setupWindow() {
        // When using scenes (iOS 13+), window setup is handled by SceneDelegate
        // Only create window here for non-scene based launches (shouldn't happen with our config)
        guard window == nil else { return }

        // Check if we're using scenes - if so, SceneDelegate will handle window
        if #available(iOS 13.0, *),
           UIApplication.shared.supportsMultipleScenes ||
            Bundle.main.object(forInfoDictionaryKey: "UIApplicationSceneManifest") != nil {
            // Scene-based: SceneDelegate will create window
            return
        }

        // Legacy non-scene setup (fallback)
        let newWindow = UIWindow()
        window = newWindow
        configureWindow(newWindow)
    }

    /// Configures an existing window with the app's root view controller
    func configureWindow(_ window: UIWindow) {
        window.tintColor = TPPConfiguration.mainColor()
        window.tintAdjustmentMode = .normal
        window.rootViewController = createRootViewController()
        window.makeKeyAndVisible()
    }

    /// Creates and returns the app's root view controller
    func createRootViewController() -> UIViewController {
        let container = AppContainer.production()
        let root = AppTabHostView()
            .environment(\.appContainer, container)
        return UIHostingController(rootView: root)
    }

    private func configureUIAppearance() {
        UITabBar.appearance().tintColor = TPPConfiguration.iconColor()
        UITabBar.appearance().backgroundColor = TPPConfiguration.backgroundColor()
        UITabBarItem.appearance().setTitleTextAttributes([.font: UIFont.palaceFont(ofSize: 12)], for: .normal)

        UINavigationBar.appearance().tintColor = TPPConfiguration.iconColor()

        let defaultAppearance = TPPConfiguration.defaultAppearance()
        UINavigationBar.appearance().standardAppearance = defaultAppearance
        UINavigationBar.appearance().compactAppearance = defaultAppearance
        UINavigationBar.appearance().scrollEdgeAppearance = defaultAppearance
        UINavigationBar.appearance().compactScrollEdgeAppearance = defaultAppearance
    }
}

// MARK: - iPad-on-Mac static-destructor bypass

/// Decides whether process exit should bypass C++ static destructors by
/// calling `_exit(0)`. Returns `true` ONLY when running as an iOS app on Mac,
/// where Adobe RMSDK's static `recursive_mutex` destructor faults during
/// teardown (Crashlytics 9a91840677 — all events iOS_ON_MAC).
///
/// On real iOS devices this MUST return `false`: there `exit()`'s normal
/// static-destructor pass is correct and `_exit` would skip legitimate
/// teardown. Pure + injectable so the decision is unit-testable; the
/// crash-at-exit itself can only be validated via simdrive on a Mac host.
func shouldSkipStaticDestructorsOnExit(isiOSAppOnMac: Bool) -> Bool {
    isiOSAppOnMac
}

// MARK: - First Run Flow
extension TPPAppDelegate {
    private func presentFirstRunFlowIfNeeded() {
        // PP-4329: idempotency — once we've presented the picker this
        // launch, any further .TPPCatalogDidLoad posts (the main catalog
        // load triggers up to 8 of them in worst-case fallback paths)
        // must NOT re-present. Without this guard, a fresh install on
        // iOS 26.4.2 stacked 4 TPPAccountList modals.
        guard !hasPresentedFirstRunFlow else { return }

        let accountsManager = AppContainer.production().accountsManager
        // Defer until accounts have loaded to avoid false negatives on currentAccount
        if !accountsManager.accountsHaveLoaded {
            // PP-4329: remove the previous deferred observer (if any)
            // before adding a new one — otherwise observers accumulate
            // every time this method re-enters itself.
            if let token = firstRunFlowObserver {
                NotificationCenter.default.removeObserver(token)
                firstRunFlowObserver = nil
            }
            firstRunFlowObserver = NotificationCenter.default.addObserver(
                forName: .TPPCatalogDidLoad,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                // Registered with `queue: .main`; `assumeIsolated` to call the
                // `@MainActor` `presentFirstRunFlowIfNeeded()` without a re-hop.
                MainActor.assumeIsolated {
                    self?.presentFirstRunFlowIfNeeded()
                }
            }
            accountsManager.loadCatalogs(completion: nil)
            return
        }

        // We're past the deferred-load state; remove the observer so the
        // remaining 7 possible .TPPCatalogDidLoad posts from the same
        // load cycle don't re-fire this method.
        if let token = firstRunFlowObserver {
            NotificationCenter.default.removeObserver(token)
            firstRunFlowObserver = nil
        }

        // Use persisted currentAccountId rather than computed currentAccount to avoid timing issues
        let needsAccount = (accountsManager.currentAccountId == nil)
        guard needsAccount else { return }

        guard let top = topViewController() else { return }

        var nav: UINavigationController!
        let accountList = TPPAccountList { [weak self] account in
            let settings = AppContainer.production().settings
            if !settings.settingsAccountIdsList.contains(account.uuid) {
                settings.settingsAccountIdsList.append(account.uuid)
            }
            if let urlString = account.catalogUrl, let url = URL(string: urlString) {
                settings.accountMainFeedURL = url
            }
            // The lone writer: route through the AppContainer-owned instance
            // (same singleton, but no .shared literal at the call site).
            accountsManager.currentAccount = account

            account.loadAuthenticationDocument { _ in }

            NotificationCenter.default.post(name: .TPPCurrentAccountDidChange, object: nil)
            nav?.dismiss(animated: true)
            // Allow a future cold launch with no account to present again,
            // but on the current launch we're done.
            self?.hasPresentedFirstRunFlow = true
        }
        accountList.requiresSelectionBeforeDismiss = true
        nav = UINavigationController(rootViewController: accountList)
        // Mark presented BEFORE the present call so any synchronous
        // re-entry from a notification fired during the present sees
        // the guard.
        hasPresentedFirstRunFlow = true
        top.present(nav, animated: true)
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
///
/// `@unchecked Sendable` invariant (mirrors `FirebaseManager`): every stored
/// property is either an immutable `let` of a `Sendable` type
/// (`monitorQueue` is a `DispatchQueue`) or the single piece of mutable
/// state (`proactiveMonitoringTask`) which is guarded by
/// `OSAllocatedUnfairLock`. All work runs off the main actor on
/// `monitorQueue` or in a detached `Task`; the type is intentionally NOT
/// `@MainActor` because its job is background pressure monitoring and disk
/// reclamation. Cross-actor hops to the main actor are made explicitly
/// where UIKit-adjacent collaborators require it (see `proactiveCacheCleanup`
/// and `handleMemoryWarning`). This lets the `static let shared` singleton
/// and the `self`-capturing queue/task closures satisfy the `complete`
/// concurrency checker without a `@MainActor` annotation that would be
/// semantically wrong for a background monitor.
final class MemoryPressureMonitor: @unchecked Sendable {
    static let shared = MemoryPressureMonitor()

    private let monitorQueue = DispatchQueue(label: "org.thepalaceproject.memory-pressure", qos: .utility)

    /// The proactive-monitoring loop task. Guarded by
    /// `OSAllocatedUnfairLock` because it is written from `start()` (via
    /// `startProactiveMonitoring()`) and read+cancelled from `stop()`,
    /// which may be invoked from different threads over the monitor's
    /// lifetime.
    private let proactiveMonitoringTask = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)

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
        let task = Task { [weak self] in
            while !Task.isCancelled {
                // Check every 30 seconds
                try? await Task.sleep(nanoseconds: 30_000_000_000)

                await self?.checkMemoryPressure()
            }
        }
        proactiveMonitoringTask.withLock { $0 = task }
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
        switch severity {
        case .high:
            // Aggressive cleanup
            URLCache.shared.removeAllCachedResponses()
            AppContainer.production().networkExecutor.clearCache()
            await MainActor.run {
                AppContainer.production().downloadCenter.pauseAllDownloads()
            }
            Log.info(#file, "Performed aggressive cache cleanup due to high memory pressure")

        case .medium:
            // Moderate cleanup - just network caches
            URLCache.shared.removeAllCachedResponses()
            Log.info(#file, "Performed moderate cache cleanup due to medium memory pressure")
        }
    }

    func stop() {
        proactiveMonitoringTask.withLock { task in
            task?.cancel()
            task = nil
        }
    }

    @objc private func handleMemoryWarning() {
        monitorQueue.async {
            URLCache.shared.removeAllCachedResponses()
            AppContainer.production().networkExecutor.clearCache()

            DispatchQueue.main.async {
                AppContainer.production().downloadCenter.pauseAllDownloads()
            }

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
            AppContainer.production().downloadCenter.limitActiveDownloads(max: maxActive)
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
        AppContainer.production().imageLoader.clearAll()
        GeneralCache<String, Data>.clearAllCaches()

        // Evict least-recently-used book files
        AppContainer.production().downloadCenter.enforceContentDiskBudgetIfNeeded(adding: 0)

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
