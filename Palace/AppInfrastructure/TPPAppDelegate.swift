import Foundation
import Combine
import os
import FirebaseCore
import FirebaseAnalytics
import FirebaseCrashlytics
import PalaceBookRegistry
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

    // PP-4329: state for the first-run library picker. The catalog-loaded
    // publisher fires from several load paths, and every listener re-invokes
    // presentFirstRunFlowIfNeeded, so more than one live listener stacks
    // library pickers on a fresh install. Holding one subscription and
    // replacing it keeps a single listener; the flag prevents re-presentation
    // once a picker is on screen.
    private var firstRunFlowSubscription: AnyCancellable?
    private var hasPresentedFirstRunFlow = false

    /// PP-5070 — when the first pre-configuration attempt of a launch began.
    /// Bounds the wait for a managed install's configured library to appear in
    /// the registry (see `ManagedLibraryPreconfigurator.registryWaitLimit`).
    /// Keyed to the configuration, not to the launch: an MDM can change the
    /// value while the app is starting, and the new one must get its own grace
    /// period rather than inheriting the old one's elapsed time.
    private var managedWaitClock = ManagedLibraryWaitClock()

    /// Whether MDM library pre-selection is on.
    ///
    /// Computed, not stored: the flag is remote and can go off mid-session, and
    /// the watcher's callback depends on seeing that. One locator read behind a
    /// name, rather than four `AppContainer.production()` calls scattered
    /// through the launch path — the composition root is the right place for a
    /// service lookup, and one of them is enough.
    private var managedLibraryConfigurationEnabled: Bool {
        AppContainer.production().featureFlags.isManagedLibraryConfigurationEnabled
    }

    /// One deadline check per launch, not one per deferred attempt.
    private var hasScheduledManagedPreconfigurationDeadline = false

    /// PP-5070 — the library picker while it is on screen, so a managed
    /// configuration that arrives AFTER we gave up waiting can take it away
    /// again rather than leaving a student staring at a list of hundreds.
    private weak var presentedFirstRunPicker: UIViewController?

    /// PP-5070 — notices a configuration that lands, or changes, after launch.
    /// Held for the app's lifetime; it filters cheaply and does nothing at all
    /// on an unmanaged install.
    private var managedLibraryWatcher: ManagedLibraryConfigurationWatcher?

    /// PP-5070 — armed ONLY when the picker was shown while a managed
    /// configuration was still pending, so a registry that arrives after the
    /// wait expired can still be honoured. Unmanaged installs never arm it.
    private var managedRegistryRetrySubscription: AnyCancellable?

    // MARK: - Application Lifecycle

    func applicationDidFinishLaunching(_ application: UIApplication) {
        #if DEBUG
        // Must run before the first `AppContainer.production()` call so the
        // registry and every session start against the UI test's scenario.
        if ProcessInfo.processInfo.environment[MockBackendLaunchRequest.scenarioKey] != nil {
            MockBackendLaunchHook.applyFromProcessEnvironment()
        }
        #endif

        // Instrument cold-launch timing (AppLaunchTracker). `processStart` is
        // captured as early as possible so `timeToFirstFrame` / `timeToInteractive`
        // compute non-nil once `.firstFrame` (SceneDelegate) and `.catalogLoaded`
        // (CatalogViewModel) land. Both are recorded in a single Task so their
        // actor-serialized timestamps stay ordered (processStart ≤ didFinishLaunching).
        Task {
            await AppLaunchTracker.shared.recordMilestone(.processStart)
            await AppLaunchTracker.shared.recordMilestone(.didFinishLaunching)
        }

        // Register Crashlytics forwarder before any Log call fires.
        // PalaceLogging is Firebase-free; the host app supplies the bridge.
        Log.crashlyticsBridge = FirebaseCrashlyticsBridge()

        // ErrorHandling reads account context through this registered
        // provider instead of importing Accounts.
        ErrorReportingContext.libraryNameProvider = {
            AppContainer.production().accountsManager.currentAccount?.name
        }

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
                _ = AppContainer.production().featureFlags.isCarPlayEnabled
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

        let memoryMonitor = MemoryPressureMonitor.shared
        memoryMonitor.start()
        let networkExecutor = AppContainer.production().networkExecutor
        AppCacheSizes.register(
            on: memoryMonitor.memoryEvents,
            sources: .production(networkResponses: { networkExecutor.cacheMemoryUsage })
        )
        AppContainer.production().bookCoverStore.useDeviceIdiom(
            isPad: UIDevice.current.userInterfaceIdiom == .pad
        )

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.startWatchingForManagedLibraryConfiguration()
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
            // Route the audiobook toolkit's logging into the app's persistent
            // log. `ATLog` writes to os_log and to this handler only, and
            // nothing had ever installed one — so every toolkit stall, loader
            // failure, decrypt error and watchdog event was absent from the log
            // a patron exports, which is the log an audiobook defect has to be
            // diagnosed from. Warnings and errors only: the toolkit logs
            // per-read detail at info, which would swamp the file.
            DefaultAudiobookManager.setLogHandler { level, message, error in
                guard level == .warn || level == .error else { return }
                let detail = error.map { "\(message): \($0.localizedDescription)" } ?? message
                if level == .error {
                    Log.error("AudiobookToolkit", detail)
                } else {
                    Log.warn("AudiobookToolkit", detail)
                }
            }

            self.audiobookLifecycleManager.didFinishLaunching()

            // TODO: Implement audiobook downloads migration from Caches to Application Support
            // This would prevent iOS from purging downloaded audiobook files
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

        let container = AppContainer.production()
        return Self.routeSignInRedirect(userActivity,
                                        universalLinksURL: container.settings.universalLinksURL,
                                        to: container.signInRedirects)
    }

    /// Hands a universal link on the sign-in redirect host to the sign-in
    /// waiting in the browser. Returns whether the link was that redirect.
    static func routeSignInRedirect(_ userActivity: NSUserActivity,
                                    universalLinksURL: URL,
                                    to relay: SignInRedirectRelay) -> Bool {
        guard userActivity.activityType == NSUserActivityTypeBrowsingWeb,
              let url = userActivity.webpageURL,
              url.host == universalLinksURL.host else {
            return false
        }
        relay.deliver(url)
        return true
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
        // Resume Firebase operations when app becomes active
        FirebaseManager.shared.applicationDidBecomeActive()

        // Record an app-open for the rating-prompt engagement signals (PP-4087).
        AppContainer.production().appRatingService.recordSession()

        // Update feature flag cache after Remote Config is refreshed
        Task {
            // Small delay to let Remote Config fetch complete
            try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
            _ = AppContainer.production().featureFlags.isCarPlayEnabled
        }

    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        // Pause Firebase operations when app goes to background
        // This helps prevent the "recursive_mutex lock failed" crash
        FirebaseManager.shared.applicationDidEnterBackground()

        #if FEATURE_DRM_CONNECTOR
        // iPad-on-Mac watchdog-exit guard. Once Adobe DRM has been used
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
        AppContainer.production().bookRegistry.flushPendingPositions()
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
        // Route the book download center's background
        // session wake to MyBooksDownloadCenter — store its system completion
        // handler (invoked once, then cleared, in urlSessionDidFinishEvents) and,
        // by accessing `downloadCenter`, ensure its background session is
        // instantiated so iOS reconnects and re-delivers the pending delegate
        // callbacks. Every OTHER identifier keeps the byte-for-byte audiobook
        // route.
        if MyBooksDownloadCenter.isDownloadCenterBackgroundSession(identifier) {
            AppContainer.production().downloadCenter.setBackgroundCompletionHandler(completionHandler)
        } else {
            audiobookLifecycleManager.handleEventsForBackgroundURLSession(for: identifier, completionHandler: completionHandler)
        }
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
        let accountsManager = AppContainer.production().accountsManager

        // PP-5220: the decision itself is `FirstRunFlowDecision.step`, a pure
        // function with its own tests. Everything below is the machinery that
        // carries state in and acts on the answer — deliberately kept free of
        // decisions of its own, because this method cannot be reached from a
        // test and anything decided here is decided untested.
        //
        // The managed step is evaluated first because it is the only input that
        // requires work (reading the configuration and resolving it), and the
        // pure function takes its RESULT rather than the means of getting it.
        let managedStep = managedLibraryLaunchStep(accountsHaveLoaded: accountsManager.accountsHaveLoaded)

        switch FirstRunFlowDecision.step(
            hasPresented: hasPresentedFirstRunFlow,
            catalogHasLoaded: accountsManager.accountsHaveLoaded,
            managedStep: managedStep,
            hasCurrentAccount: accountsManager.currentAccountId != nil
        ) {
        case .alreadyHandled:
            return
        case .waitForCatalog:
            deferFirstRunFlowUntilCatalogLoads(accountsManager: accountsManager)
            return
        case .librarySelected:
            hasPresentedFirstRunFlow = true
            return
        case .waitForManagedLibrary:
            deferFirstRunFlowUntilRegistryChanges()
            return
        case .nothingToDo:
            clearFirstRunFlowSubscription()
            return
        case .presentPicker:
            clearFirstRunFlowSubscription()
            presentLibraryPicker(accountsManager: accountsManager)
            return
        }
    }

    /// Evaluates the managed-configuration arm, including its bounded wait.
    /// Returns `.presentPicker` (meaning "nothing to say") when the catalog has
    /// not loaded yet, so the pure decision sees a single consistent shape.
    private func managedLibraryLaunchStep(accountsHaveLoaded: Bool) -> ManagedLibraryLaunchStep {
        guard accountsHaveLoaded else { return .presentPicker }
        guard managedLibraryConfigurationEnabled else {
            return .presentPicker
        }

        let decision = ManagedLibraryPreconfigurator.production().applyIfNeeded()
        let elapsed = managedWaitClock.elapsed(
            for: ManagedAppConfiguration.configurationIdentity(defaults: .standard)
        )
        let step = ManagedLibraryPreconfigurator.launchStep(for: decision, elapsed: elapsed)

        // PP-5221 — tell ourselves when a school's configuration is wrong,
        // because otherwise the only signal is a ticket saying "we set it up
        // and nothing happened". Bounded twice over: silent until the registry
        // wait has expired, since before that an unresolved library is the
        // ordinary cold-launch state, and at most once per configuration value,
        // so one misconfigured device does not file a report a day forever.
        // Inside the feature-flag guard above, so an unmanaged install reports
        // nothing and pays nothing.
        ManagedLibraryDiagnostics.reportIfNeeded(
            decision: decision,
            waitHasExpired: elapsed >= ManagedLibraryPreconfigurator.registryWaitLimit,
            defaults: .standard,
            reporter: ManagedLibraryCrashlyticsReporter()
        )
        // The wait expired with a configuration still pending: show the picker
        // but keep trying, because a school network in the morning outlasts any
        // timeout worth setting.
        if step == .presentPicker, decision == .unresolved || decision == .registryNotLoaded {
            retryManagedPreconfigurationWhenRegistryChanges()
        }
        return step
    }

    private func clearFirstRunFlowSubscription() {
        firstRunFlowSubscription = nil
    }

    /// The pre-existing wait for the library list, unchanged in behaviour.
    private func deferFirstRunFlowUntilCatalogLoads(accountsManager: AccountsManager) {
        legacyDeferFirstRunFlow(accountsManager: accountsManager)
    }

    private func legacyDeferFirstRunFlow(accountsManager: AccountsManager) {
        // PP-4329: replace, never add, so re-entering this method keeps a
        // single listener (four stacked library pickers on iOS 26.4.2).
        firstRunFlowSubscription = accountsManager.catalogLoadedPublisher
            .sink { [weak self] in
                // The publisher delivers on main; `assumeIsolated` calls the
                // `@MainActor` method without a re-hop.
                MainActor.assumeIsolated {
                    self?.presentFirstRunFlowIfNeeded()
                }
            }
        accountsManager.loadCatalogs(completion: nil)
    }

    /// Presents the library picker. Reached only when the decision says so.
    private func presentLibraryPicker(accountsManager: AccountsManager) {
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

            accountsManager.requestCurrentLibraryRefresh()
            nav?.dismiss(animated: true)
            // The patron has chosen. Stop trying to apply a pending managed
            // configuration over the top of their choice.
            self?.disarmManagedRegistryRetry()
            self?.presentedFirstRunPicker = nil
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
        presentedFirstRunPicker = nav
        top.present(nav, animated: true)
    }

    /// PP-5070 — keeps trying to honour a pending configuration after the
    /// picker has already been presented.
    ///
    /// Armed only when a configuration was pending as the picker went up, so an
    /// unmanaged install never registers this observer at all. Disarms itself
    /// the moment it succeeds.
    private func retryManagedPreconfigurationWhenRegistryChanges() {
        guard managedRegistryRetrySubscription == nil else { return }
        guard managedLibraryConfigurationEnabled else {
            return
        }
        managedRegistryRetrySubscription = AppContainer.production().accountsManager.catalogLoadedPublisher
            .sink { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let decision = ManagedLibraryPreconfigurator.production().applyIfNeeded()
                    guard case .apply = decision else { return }
                    self.disarmManagedRegistryRetry()
                    guard let picker = self.presentedFirstRunPicker else { return }
                    self.presentedFirstRunPicker = nil
                    picker.dismiss(animated: true)
                }
            }
    }

    private func disarmManagedRegistryRetry() {
        managedRegistryRetrySubscription = nil
    }

    /// PP-5070 — starts watching for a managed configuration that arrives after
    /// the launch decision was already made.
    ///
    /// Apple does not promise the configuration is present before first launch,
    /// and if it is not, the picker goes up and the first-run flow marks itself
    /// done. Rather than delay the picker for every unmanaged install on the
    /// chance a configuration might be coming — which would penalise almost
    /// every Palace user for one partner's benefit — the app shows it on time
    /// and takes it away again if a configuration turns up.
    private func startWatchingForManagedLibraryConfiguration() {
        guard managedLibraryWatcher == nil else { return }
        // Flag OFF means no observer is registered at all, rather than one that
        // wakes and decides to do nothing.
        guard managedLibraryConfigurationEnabled else {
            return
        }
        let watcher = ManagedLibraryConfigurationWatcher(
            defaults: .standard,
            preconfigurator: ManagedLibraryPreconfigurator.production()
        )
        managedLibraryWatcher = watcher
        watcher.start { [weak self] decision in
            guard let self else { return }
            // Re-checked here, not only when the observer was installed. The
            // flag is remote, so it can go off mid-session — and an observer
            // that keeps acting after the feature was turned off is the kind
            // of switch that does not switch anything.
            guard managedLibraryConfigurationEnabled else {
                return
            }
            // A configuration arriving late can be just as wrong as one present
            // at launch. Without this the launch path is the only place that
            // reports, so a school that pushed a typo after the app was already
            // open would hear nothing back.
            ManagedLibraryDiagnostics.reportIfNeeded(
                decision: decision,
                waitHasExpired: self.managedWaitClock.elapsed(
                    for: ManagedAppConfiguration.configurationIdentity(defaults: .standard)
                ) >= ManagedLibraryPreconfigurator.registryWaitLimit,
                defaults: .standard,
                reporter: ManagedLibraryCrashlyticsReporter()
            )
            switch ManagedLibraryPreconfigurator.watchAction(for: decision) {
            case .dismissPicker:
                self.hasPresentedFirstRunFlow = true
                self.disarmManagedRegistryRetry()
                guard let picker = self.presentedFirstRunPicker else { return }
                self.presentedFirstRunPicker = nil
                picker.dismiss(animated: true)
            case .keepTrying:
                // A configuration arrived but the registry cannot resolve it
                // yet. Without this the app would drop it on the floor: the
                // launch-time retry is armed only when a configuration was
                // pending as the picker went up, and in this case there was
                // none to be pending.
                self.retryManagedPreconfigurationWhenRegistryChanges()
            case .doNothing:
                break
            }
        }
    }

    /// Re-arms the catalog-loaded listener so `presentFirstRunFlowIfNeeded`
    /// runs again when the registry changes, and schedules one deadline check so
    /// a device whose network never delivers a further load still reaches the
    /// picker instead of sitting on an empty catalog forever.
    private func deferFirstRunFlowUntilRegistryChanges() {
        firstRunFlowSubscription = AppContainer.production().accountsManager.catalogLoadedPublisher
            .sink { [weak self] in
                MainActor.assumeIsolated {
                    self?.presentFirstRunFlowIfNeeded()
                }
            }

        guard !hasScheduledManagedPreconfigurationDeadline else { return }
        hasScheduledManagedPreconfigurationDeadline = true
        let delay = ManagedLibraryPreconfigurator.registryWaitLimit + 0.5
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.presentFirstRunFlowIfNeeded()
        }
    }

    private func switchToCatalogTab() {
        if let host = window?.rootViewController as? UIHostingController<AppTabHostView> {
            _ = host
        }
    }
}

// MARK: - Memory and Disk Pressure Handling
import UIKit
import PalaceUtilities

/// Centralized observer for memory pressure, thermal state, and disk space cleanup.
/// Performs cache purges, download throttling, and space reclamation when needed.
///
/// `@unchecked Sendable` invariant (mirrors `FirebaseManager`): every stored
/// property is either an immutable `let` of a `Sendable` type
/// (`monitorQueue` is a `DispatchQueue`) or mutable state guarded by
/// `OSAllocatedUnfairLock` (`pressureSource`). Work runs off the main actor
/// on `monitorQueue`; the type is intentionally NOT `@MainActor` because its
/// job is background pressure monitoring and disk reclamation. Hops to the
/// main actor are made explicitly where a collaborator requires it (see
/// `registerReleaseSteps`).
final class MemoryPressureMonitor: @unchecked Sendable {
    static let shared = MemoryPressureMonitor()

    private let monitorQueue = DispatchQueue(label: "org.thepalaceproject.memory-pressure", qos: .utility)

    /// Writes the footprint and cache sizes at each memory event (PP-5509).
    let memoryEvents = MemoryEventRecorder()

    /// The system memory pressure source. It only records; releasing happens
    /// on the memory warning, through `MemoryReleaseCoordinator`.
    private let pressureSource = OSAllocatedUnfairLock<DispatchSourceMemoryPressure?>(initialState: nil)

    private init() {}

    func start() {
        startMemoryPressureSource()
        registerReleaseSteps(on: .shared)

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

    /// This monitor's part of a memory warning: record the event before
    /// anything is released, clear the response cache, pause downloads until
    /// memory recovers, and free disk space when under 256 MB is left.
    func registerReleaseSteps(on coordinator: MemoryReleaseCoordinator) {
        coordinator.register(self, stage: .record) { monitor in
            monitor.memoryEvents.record(.warning)
        }
        coordinator.register(self, stage: .networkResponses) { monitor in
            monitor.monitorQueue.async {
                // N1: clear the executor's PRIVATE URLCache (feeds live there,
                // not in `URLCache.shared`). URLCache has no call that drops only
                // its memory part, so this also empties the disk part, as before.
                AppContainer.production().networkExecutor.clearCache()
            }
        }
        coordinator.register(self, stage: .downloads) { _ in
            DispatchQueue.main.async {
                AppContainer.production().downloadCenter.pauseDownloadsForMemoryWarning()
            }
        }
        coordinator.register(self, stage: .diskSpace) { monitor in
            monitor.monitorQueue.async {
                monitor.reclaimDiskSpaceIfNeeded(minimumFreeMegabytes: 256)
            }
        }
    }

    private func startMemoryPressureSource() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: monitorQueue)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let event = source?.data else { return }
            self.memoryEvents.record(MemoryEventKind(pressure: event))
        }
        pressureSource.withLock { existing in
            existing?.cancel()
            existing = source
        }
        source.resume()
    }

    func stop() {
        pressureSource.withLock { source in
            source?.cancel()
            source = nil
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

        // Clear caches first — N1: the executor's PRIVATE URLCache serves feeds,
        // so clear it (not `URLCache.shared`).
        AppContainer.production().networkExecutor.clearCache()
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
