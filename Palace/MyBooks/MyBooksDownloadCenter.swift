//
//  TPPMyBookDownloadCenter.swift
//  Palace
//
//  Created by Maurice Carrier on 6/13/23.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import Foundation
import UIKit
import PalaceAudiobookToolkit
import Combine

#if FEATURE_OVERDRIVE
import OverdriveProcessor
import PalaceLogging
import PalaceNetwork
import PalaceCatalog
#endif

// DownloadCoordinator is defined in MyBooksDownloadQueue.swift

@objc class MyBooksDownloadCenter: NSObject, URLSessionDelegate {
    typealias DisplayStrings = Strings.MyDownloadCenter

    /// Optional override used by tests / fault-injection harnesses to pin a
    /// specific user account. Production code MUST NOT set this — leave nil
    /// so `userAccount` always resolves to the current account via
    /// `AccountsManager`. Capturing a reference at init time silently breaks
    /// download / read flows after the user switches library or signs in to
    /// a different account (per-account TPPUserAccount instances are
    /// account-scoped, not global).
    private let injectedUserAccount: TPPUserAccount?

    /// The user account whose credentials should drive download requests.
    /// Always reflects the *current* account so library switches and fresh
    /// sign-ins propagate to in-flight download decisions.
    public var userAccount: TPPUserAccount {
        injectedUserAccount ?? accountsManager.currentUserAccount
    }

    private var reauthenticator: Reauthenticator
    var bookRegistry: TPPBookRegistryProvider
    private let accountsManager: AccountsManager
    private let networkExecutor: TPPNetworkExecutor
    private let accessibilityAnnouncements: TPPAccessibilityAnnouncementCenter
    let downloadAnnouncementService: DownloadAnnouncementService
    private let bookFileManager: BookFileManager
    private let diskBudgetManager: DiskBudgetManager
    private let localContentService: LocalBookContentService
    private let returnService: BookReturnService
    private let alertPresenter: DownloadAlertPresenter
    private let authRetryHandler: DownloadAuthRetryHandler
    private let throttlingService: DownloadThrottlingService
    private let queueOrchestrator: DownloadQueueOrchestrator
    private let borrowErrorPresenter: BorrowErrorPresenter
    private let signInRedirectHandler: BookSignInRedirectHandler
    private let contentResetService: BookContentResetService
    #if FEATURE_OVERDRIVE
    private let overdriveDownloadHandler: OverdriveDownloadHandler
    #endif
    private let credentialPromptCoordinator: CredentialPromptCoordinator
    /// Shared with `BorrowErrorPresenter` so the borrow-error path and
    /// the start-download path can't both fire concurrent sign-in modals.
    private let credentialRequestState = CredentialRequestState()
    #if LCP
    private let lcpFulfillmentHandler: LCPFulfillmentHandler
    #endif

    // Phase 4 (Architectural Triad) — services formerly reached through
    // `.shared` are now stored properties initialized via the constructor.
    // Production callers fall back to `.shared` defaults so the long-form
    // designated init still works without a container; the AppContainer
    // composition root constructs a single instance and tests can substitute
    // mocks via the parameter list.
    let errorActivityTracker: ErrorActivityTracker
    let userRetryTracker: UserRetryTracker
    let reachability: Reachability
    let memoryPressureMonitor: MemoryPressureMonitor
    let bookmarkDeletionLog: TPPBookmarkDeletionLog
    let deviceSpecificErrorMonitor: DeviceSpecificErrorMonitor
    let opdsFeedService: OPDSFeedService
    let debugSettings: DebugSettings
    let settings: TPPSettings
    #if FEATURE_DRM_CONNECTOR
    let adobeDRMService: AdobeDRMService
    private let adobeDRMHandler = AdobeDRMHandler()
    #endif
    #if FEATURE_OVERDRIVE
    let overdriveAPIExecutor: OverdriveAPIExecutor
    #endif

    private var bookIdentifierOfBookToRemove: String?
    private var session: URLSession!

    /// Owns the thread-safe download tracking dictionaries + DownloadCoordinator
    /// + maxConcurrentDownloads. The properties below are computed wrappers
    /// that route through this single state owner — preserves the call-site
    /// shape across MBDC's ~97 internal SafeDictionary accesses while
    /// eliminating the duplicate state previously stored on MBDC.
    /// Internal access (was private) so BackgroundDownloadHandlerDelegate +
    /// TokenRefreshInterceptorDelegate's `var stateManager` getters resolve.
    let stateManager: DownloadStateManager

    /// 401-detection / token-refresh / SAML+OIDC re-auth orchestration.
    /// MBDC owns this so BackgroundDownloadHandler can reach it through the
    /// delegate (`delegate.tokenInterceptor`) when a download fails on auth.
    let tokenInterceptor: TokenRefreshInterceptor

    /// URLSessionDownloadDelegate-helper extraction. Holds the rights-mgmt
    /// detection, OPDS-entry follow-through, file move/replace/validate
    /// helpers. MBDC is its delegate — the URLSession delegate methods on
    /// MBDC remain in place and will route helper logic through this in a
    /// follow-up commit.
    private let backgroundDownloadHandler: BackgroundDownloadHandler

    // Thread-safe actor-based dictionaries — wrapper accessors over stateManager.
    private var bookIdentifierToDownloadInfo: SafeDictionary<String, MyBooksDownloadInfo> {
        stateManager.bookIdentifierToDownloadInfo
    }
    private var bookIdentifierToDownloadTask: SafeDictionary<String, URLSessionDownloadTask> {
        stateManager.bookIdentifierToDownloadTask
    }
    private var taskIdentifierToBook: SafeDictionary<Int, TPPBook> {
        stateManager.taskIdentifierToBook
    }

    // Serial execution for download operations (replaces downloadQueue)
    private let downloadExecutor = SerialExecutor()

    let downloadProgressPublisher: PassthroughSubject<(String, Double), Never>

    /// Publishes download error alerts for a given book identifier.
    /// Subscribers (e.g. view models showing a half sheet) can present the
    /// error inline via SwiftUI `.alert` instead of relying on UIKit
    /// presentation, which can fail when a SwiftUI sheet is topmost.
    let downloadErrorPublisher: PassthroughSubject<DownloadErrorInfo, Never>

    /// Owns the Combine publishers + broadcast-throttling state machine.
    /// MyBooksDownloadCenter exposes its publishers as the same passthrough
    /// instances so external subscribers see one continuous stream.
    /// Internal access (was private) so the delegate protocols of
    /// BackgroundDownloadHandler / TokenRefreshInterceptor can read it.
    let progressReporter: DownloadProgressReporter

    private var maxConcurrentDownloads: Int {
        get { stateManager.maxConcurrentDownloads }
        set { stateManager.maxConcurrentDownloads = newValue }
    }
    private var downloadCoordinator: DownloadCoordinator { stateManager.downloadCoordinator }

    init(
        // Test-only override. Production code passes nil so `userAccount`
        // resolves to the current account via `accountsManager` on every
        // access. See the property doc on `injectedUserAccount` for why
        // capturing a reference at init time is a bug.
        userAccount: TPPUserAccount? = nil,
        reauthenticator: Reauthenticator = TPPReauthenticator(),
        bookRegistry: TPPBookRegistryProvider = AppContainer.production().bookRegistry,
        accountsManager: AccountsManager = AppContainer.production().accountsManager,
        networkExecutor: TPPNetworkExecutor = AppContainer.production().networkExecutor,
        accessibilityAnnouncements: TPPAccessibilityAnnouncementCenter = TPPAccessibilityAnnouncementCenter(),
        downloadAnnouncementService: DownloadAnnouncementService = DownloadAnnouncementService(),
        bookFileManager: BookFileManager? = nil,
        diskBudgetManager: DiskBudgetManager? = nil,
        localContentService: LocalBookContentService? = nil,
        returnService: BookReturnService? = nil,
        alertPresenter: DownloadAlertPresenter? = nil,
        authRetryHandler: DownloadAuthRetryHandler? = nil,
        throttlingService: DownloadThrottlingService? = nil,
        borrowErrorPresenter: BorrowErrorPresenter? = nil,
        signInRedirectHandler: BookSignInRedirectHandler? = nil,
        contentResetService: BookContentResetService? = nil,
        queueOrchestrator: DownloadQueueOrchestrator? = nil,
        stateManager: DownloadStateManager = DownloadStateManager(),
        tokenInterceptor: TokenRefreshInterceptor? = nil,
        backgroundDownloadHandler: BackgroundDownloadHandler? = nil,
        errorActivityTracker: ErrorActivityTracker = .shared,
        userRetryTracker: UserRetryTracker = .shared,
        reachability: Reachability = AppContainer.production().reachability,
        memoryPressureMonitor: MemoryPressureMonitor = .shared,
        bookmarkDeletionLog: TPPBookmarkDeletionLog = .shared,
        deviceSpecificErrorMonitor: DeviceSpecificErrorMonitor = .shared,
        opdsFeedService: OPDSFeedService = OPDSFeedService(),
        debugSettings: DebugSettings = DebugSettings(),
        settings: TPPSettings = TPPSettings(),
        // Test seam: inject a URLSession (e.g. one configured with a custom
        // URLProtocol) so chaos / fault-injection tests can drive download
        // failure paths without standing up a real network. When `nil`, the
        // production background session is constructed as before — behavior
        // preserved exactly. When provided, the caller is responsible for
        // pointing the session's delegate at this instance.
        urlSession: URLSession? = nil
    ) {
        self.injectedUserAccount = userAccount
        self.bookRegistry = bookRegistry
        self.reauthenticator = reauthenticator
        self.accountsManager = accountsManager
        self.networkExecutor = networkExecutor
        self.accessibilityAnnouncements = accessibilityAnnouncements
        self.downloadAnnouncementService = downloadAnnouncementService
        // BookFileManager pulls from the *same* registry + accounts manager
        // we just resolved — passing nil here uses those, avoiding a second
        // re-entrant AppContainer.production() lookup (the same cycle that
        // motivated AppContainer.production()'s explicit-deps comment).
        self.bookFileManager = bookFileManager ?? BookFileManager(
            bookRegistry: bookRegistry,
            accountsManager: accountsManager
        )
        // DiskBudgetManager pulls from the same registry + accounts manager
        // we just resolved AND shares the BookFileManager instance — so
        // path resolution stays coherent across the two managers.
        self.diskBudgetManager = diskBudgetManager ?? DiskBudgetManager(
            bookRegistry: bookRegistry,
            accountsManager: accountsManager,
            bookFileManager: self.bookFileManager
        )
        // Shares the same registry / accounts manager / file manager so
        // path resolution + book lookup stays coherent with the rest of
        // MBDC's lifecycle paths.
        self.localContentService = localContentService ?? LocalBookContentService(
            bookRegistry: bookRegistry,
            accountsManager: accountsManager,
            bookFileManager: self.bookFileManager
        )
        // BookReturnService takes the just-resolved registry / local-
        // content service / OPDS feed service / announcer / bookmark
        // deletion log / reauthenticator / retry tracker. The userAccount
        // provider closure preserves MBDC's just-in-time userAccount
        // resolution semantics across library switches.
        let resolveAccountForReturn: () -> TPPUserAccount = {
            userAccount ?? accountsManager.currentUserAccount
        }
        self.returnService = returnService ?? BookReturnService(
            bookRegistry: bookRegistry,
            localContentService: self.localContentService,
            opdsFeedService: opdsFeedService,
            downloadAnnouncementService: downloadAnnouncementService,
            bookmarkDeletionLog: bookmarkDeletionLog,
            reauthenticator: reauthenticator,
            userRetryTracker: userRetryTracker,
            userAccountProvider: resolveAccountForReturn
        )
        self.stateManager = stateManager
        // DownloadAlertPresenter built eagerly so `self` can wire as its
        // delegate after `super.init()`. Production passes nil so the
        // presenter is constructed from the just-resolved registry +
        // stateManager + downloadAnnouncementService — same instances MBDC
        // owns, keeping the presenter's view of the download state machine
        // coherent with the rest of MBDC. Tests can substitute mocks.
        // The progress reporter wire-up happens after `let reporter =
        // DownloadProgressReporter(...)` below since the presenter needs the
        // same reporter MBDC publishes through.
        // Build TokenRefreshInterceptor + BackgroundDownloadHandler eagerly so
        // `self` can wire as their delegate after `super.init()`. Both default
        // to nil-init so callers (production + tests) can substitute mocks.
        self.tokenInterceptor = tokenInterceptor ?? TokenRefreshInterceptor(
            reauthenticator: reauthenticator
        )
        self.backgroundDownloadHandler = backgroundDownloadHandler ?? BackgroundDownloadHandler()
        // Build the DownloadProgressReporter from the same announcer the
        // download center uses, AND share the same DownloadAnnouncementService
        // instance. The reporter's lifecycle announce wrappers delegate to
        // the service, so book→title bridging has a single source of truth
        // across MBDC and the reporter.
        let reporter = DownloadProgressReporter(
            accessibilityAnnouncements: accessibilityAnnouncements,
            downloadAnnouncementService: downloadAnnouncementService
        )
        self.progressReporter = reporter
        self.downloadProgressPublisher = reporter.downloadProgressPublisher
        self.downloadErrorPublisher = reporter.downloadErrorPublisher
        // DownloadAlertPresenter shares the same reporter / stateManager /
        // announcer / registry MBDC just wired so all download-failure paths
        // funnel through one DownloadErrorPublisher subscriber chain.
        self.alertPresenter = alertPresenter ?? DownloadAlertPresenter(
            bookRegistry: bookRegistry,
            stateManager: stateManager,
            progressReporter: reporter,
            downloadAnnouncementService: downloadAnnouncementService,
            errorActivityTracker: errorActivityTracker,
            userRetryTracker: userRetryTracker
        )
        // DownloadAuthRetryHandler shares the same stateManager / registry /
        // reauthenticator / alertPresenter MBDC owns. The userAccountProvider
        // closure resolves through `accountsManager.currentUserAccount` each
        // call so library switches mid-flow are observed correctly (matches
        // MBDC's `userAccount` computed property semantics).
        let resolveAccount: () -> TPPUserAccount = {
            userAccount ?? accountsManager.currentUserAccount
        }
        self.authRetryHandler = authRetryHandler ?? DownloadAuthRetryHandler(
            stateManager: stateManager,
            bookRegistry: bookRegistry,
            reauthenticator: reauthenticator,
            alertPresenter: self.alertPresenter,
            userAccountProvider: resolveAccount
        )
        // DownloadThrottlingService shares the same DownloadStateManager
        // MBDC owns so cap + suspend/resume policy stays coherent with the
        // rest of the download state machine. Tests can inject a mock state
        // manager + NotificationCenter to drive the network-monitor branch.
        self.throttlingService = throttlingService ?? DownloadThrottlingService(
            stateManager: stateManager
        )
        // BorrowErrorPresenter shares the credentialRequestState with
        // MBDC's `requestCredentialsAndStartDownload` so concurrent
        // sign-in modals across the borrow + start-download paths are
        // prevented at the source.
        let resolveAccountForBorrow: () -> TPPUserAccount = {
            userAccount ?? accountsManager.currentUserAccount
        }
        self.borrowErrorPresenter = borrowErrorPresenter ?? BorrowErrorPresenter(
            progressReporter: reporter,
            userRetryTracker: userRetryTracker,
            reauthenticator: reauthenticator,
            userAccountProvider: resolveAccountForBorrow,
            credentialRequestState: self.credentialRequestState
        )
        // BookSignInRedirectHandler shares stateManager + registry +
        // reauthenticator + credentialRequestState with the rest of
        // MBDC. cookieStorageProvider closes over `self.session` —
        // session is set up post `super.init()`, so the closure resolves
        // lazily at each call (matching the original code's late-bound
        // session reference).
        // Cookie storage is read via the delegate (MBDC) so the late-
        // initialized session reference resolves at call time rather
        // than at handler-init time.
        self.signInRedirectHandler = signInRedirectHandler ?? BookSignInRedirectHandler(
            bookRegistry: bookRegistry,
            stateManager: stateManager,
            reauthenticator: reauthenticator,
            userAccountProvider: resolveAccountForBorrow,
            credentialRequestState: self.credentialRequestState
        )
        // BookContentResetService runs the bulk-reset flows; shares the
        // same registry / state / file-manager / progress reporter /
        // local-content-service MBDC owns so cleanup observers see one
        // coherent state transition.
        self.contentResetService = contentResetService ?? BookContentResetService(
            bookRegistry: bookRegistry,
            accountsManager: accountsManager,
            stateManager: stateManager,
            bookFileManager: self.bookFileManager,
            progressReporter: reporter,
            localContentService: self.localContentService
        )
        #if FEATURE_OVERDRIVE
        self.overdriveDownloadHandler = OverdriveDownloadHandler(
            bookRegistry: bookRegistry,
            stateManager: stateManager,
            progressReporter: reporter,
            alertPresenter: self.alertPresenter,
            userAccountProvider: resolveAccountForBorrow
        )
        #endif
        // CredentialPromptCoordinator presents sign-in modals during
        // start-download when the user has no stored credentials.
        // Closures over SignInModalPresenter + AdobeCertificate so
        // tests can substitute fakes without UIKit/DRM at hand.
        self.credentialPromptCoordinator = CredentialPromptCoordinator(
            stateManager: stateManager,
            userAccountProvider: resolveAccountForBorrow,
            credentialRequestState: self.credentialRequestState,
            presentSignInModal: { completion in
                SignInModalPresenter.presentSignInModalForCurrentAccount(completion: completion)
            },
            isAdobeDRMExpired: {
                #if FEATURE_DRM_CONNECTOR
                return AdobeCertificate.defaultCertificate?.hasExpired ?? false
                #else
                return false
                #endif
            },
            presentAdobeExpiredAlert: {
                #if FEATURE_DRM_CONNECTOR
                TPPAlertUtils.presentFromViewControllerOrNil(alertController: TPPAlertUtils.expiredAdobeDRMAlert(), viewController: nil, animated: true, completion: nil)
                #endif
            }
        )
        // DownloadQueueOrchestrator shares the same DownloadStateManager
        // (so the active-count + max-concurrent-downloads + dequeue all
        // resolve through one state owner) and the same TPPBookRegistry
        // so the `.downloading` UI state set on enqueue stays coherent
        // with the rest of the registry. The delegate (this MBDC
        // instance) is wired after `super.init()` below.
        self.queueOrchestrator = queueOrchestrator ?? DownloadQueueOrchestrator(
            bookRegistry: bookRegistry,
            stateManager: stateManager
        )
        #if LCP
        // Build the LCP handler from the same shared services MBDC already
        // wired (registry / state / reporter / presenter / file manager /
        // background handler) so error reporting, progress publishing, and
        // file moves stay coherent across the LCP code path.
        let backgroundHandler = self.backgroundDownloadHandler
        self.lcpFulfillmentHandler = LCPFulfillmentHandler(
            bookRegistry: bookRegistry,
            stateManager: stateManager,
            progressReporter: reporter,
            alertPresenter: self.alertPresenter,
            bookFileManager: self.bookFileManager,
            backgroundDownloadHandler: backgroundHandler
        )
        #endif
        self.errorActivityTracker = errorActivityTracker
        self.userRetryTracker = userRetryTracker
        self.reachability = reachability
        self.memoryPressureMonitor = memoryPressureMonitor
        self.bookmarkDeletionLog = bookmarkDeletionLog
        self.deviceSpecificErrorMonitor = deviceSpecificErrorMonitor
        self.opdsFeedService = opdsFeedService
        self.debugSettings = debugSettings
        self.settings = settings
        #if FEATURE_DRM_CONNECTOR
        self.adobeDRMService = .shared
        #endif
        #if FEATURE_OVERDRIVE
        self.overdriveAPIExecutor = .shared
        #endif

        super.init()

        // Notification sender has to outlive `super.init()` since the
        // reporter holds it weakly — set after self is fully constructed.
        progressReporter.notificationSender = self

        // Both helpers are weak-delegate types; safe to wire here. Use
        // `self.` to disambiguate from the init parameters (which are
        // Optional and shadow the stored properties at this scope).
        self.tokenInterceptor.delegate = self
        self.backgroundDownloadHandler.delegate = self
        self.alertPresenter.delegate = self
        self.returnService.delegate = self
        self.authRetryHandler.delegate = self
        self.throttlingService.delegate = self
        self.borrowErrorPresenter.delegate = self
        self.signInRedirectHandler.delegate = self
        #if FEATURE_OVERDRIVE
        self.overdriveDownloadHandler.delegate = self
        #endif
        self.credentialPromptCoordinator.delegate = self
        self.queueOrchestrator.delegate = self
        #if LCP
        self.lcpFulfillmentHandler.delegate = self
        #endif

        #if FEATURE_DRM_CONNECTOR
        // Use safe DRM container to prevent EXC_BREAKPOINT crashes during initialization
        if AdobeCertificate.isDRMAvailable {
            self.adobeDRMHandler.delegate = self
            self.adobeDRMService.setDelegate(self.adobeDRMHandler)
        }
        #else
        NSLog("Cannot import ADEPT")
        #endif

        if let injected = urlSession {
            self.session = injected
        } else {
            #if DEBUG
            // When mock backend is active, use a default (non-background) session
            // so MockBackendURLProtocol can intercept download requests.
            // Background sessions don't support custom URLProtocol classes.
            if MockBackendURLProtocol.activeScenario != nil {
                let configuration = URLSessionConfiguration.default
                self.session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
            } else {
                let backgroundIdentifier = (Bundle.main.bundleIdentifier ?? "") + ".downloadCenterBackgroundIdentifier"
                let configuration = URLSessionConfiguration.background(withIdentifier: backgroundIdentifier)
                configuration.isDiscretionary = false
                configuration.waitsForConnectivity = false
                configuration.allowsConstrainedNetworkAccess = true
                self.session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
            }
            #else
            let backgroundIdentifier = (Bundle.main.bundleIdentifier ?? "") + ".downloadCenterBackgroundIdentifier"
            let configuration = URLSessionConfiguration.background(withIdentifier: backgroundIdentifier)
            configuration.isDiscretionary = false
            configuration.waitsForConnectivity = false
            if #available(iOS 13.0, *) {
                configuration.allowsConstrainedNetworkAccess = true
            }
            self.session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
            #endif
        }

        // Setup intelligent download management — observer registration
        // lives on the throttlingService which holds the handle for cleanup.
        self.throttlingService.setupNetworkMonitoring()
    }

    /// Phase 4 (Architectural Triad) convenience init that pulls injectable
    /// services from `AppContainer`. Composition roots that already hold an
    /// `AppContainer` should prefer this over the long-form designated init —
    /// it keeps the wiring out of feature code and ensures the same service
    /// graph the rest of the app uses.
    ///
    /// Services not yet in `AppContainer` (`errorActivityTracker`,
    /// `userRetryTracker`, `reachability`, `memoryPressureMonitor`,
    /// `bookmarkDeletionLog`, `deviceSpecificErrorMonitor`) still default to
    /// their `.shared` singletons here. As more of those land in the container
    /// they will move from this convenience init into the parameter list.
    convenience init(appContainer: AppContainer) {
        self.init(
            bookRegistry: appContainer.bookRegistry,
            accountsManager: appContainer.accountsManager,
            networkExecutor: appContainer.networkExecutor,
            downloadAnnouncementService: appContainer.downloadAnnouncementService,
            opdsFeedService: appContainer.opdsFeedService,
            debugSettings: appContainer.debugSettings,
            settings: appContainer.settings
        )
    }

    #if DEBUG
    /// Recreate the download session to pick up mock backend protocol changes.
    /// Background sessions don't support URLProtocol, so when the mock is active
    /// we use a default session instead.
    func recreateSessionForMockBackend() {
        session.invalidateAndCancel()
        if MockBackendURLProtocol.activeScenario != nil {
            let configuration = URLSessionConfiguration.default
            session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
            Log.info(#file, "MyBooksDownloadCenter: switched to default session for mock backend")
        } else {
            let backgroundIdentifier = (Bundle.main.bundleIdentifier ?? "") + ".downloadCenterBackgroundIdentifier"
            let configuration = URLSessionConfiguration.background(withIdentifier: backgroundIdentifier)
            configuration.isDiscretionary = false
            configuration.waitsForConnectivity = false
            configuration.allowsConstrainedNetworkAccess = true
            session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
            Log.info(#file, "MyBooksDownloadCenter: restored background session")
        }
    }
    #endif

    deinit {
        session?.invalidateAndCancel()
    }

    // MARK: - Error Announcements (PP-3673)

    /// Publishes an error to `downloadErrorPublisher` and simultaneously announces
    /// it via VoiceOver so assistive technology users hear the error without
    /// needing to navigate to the alert element.
    private func publishAndAnnounceError(_ errorInfo: DownloadErrorInfo) {
        progressReporter.publishAndAnnounceError(errorInfo)
    }

    func markDownloadSuccessful(for book: TPPBook) {
        bookRegistry.setState(.downloadSuccessful, for: book.identifier)
        downloadAnnouncementService.announceDownloadCompleted(for: book)
    }

    /// Legacy callback-based borrow method - wraps the modern async implementation
    func startBorrow(for book: TPPBook, attemptDownload shouldAttemptDownload: Bool, borrowCompletion: (() -> Void)? = nil) {
        Task {
            do {
                _ = try await borrowAsync(book, attemptDownload: shouldAttemptDownload)

                // CRITICAL: If borrow succeeded but resulted in holding state (not downloadable),
                // release the download slot. Otherwise downloads get stuck in queue.
                let newState = bookRegistry.state(for: book.identifier)
                if newState == .holding {
                    await downloadCoordinator.registerCompletion(identifier: book.identifier)
                    let remainingCount = await downloadCoordinator.activeCount
                    Log.info(#file, "📊 Borrow resulted in hold for '\(book.title)', released slot, remaining active: \(remainingCount)")
                    schedulePendingStartsIfPossible()
                }

                borrowCompletion?()
            } catch {
                Log.error(#file, "Borrow failed: \(error.localizedDescription)")
                // CRITICAL: Release the download slot when borrow fails
                // Otherwise the slot is never freed and downloads get stuck in queue
                await downloadCoordinator.registerCompletion(identifier: book.identifier)
                let remainingCount = await downloadCoordinator.activeCount
                Log.info(#file, "📊 Borrow failed for '\(book.title)', released slot, remaining active: \(remainingCount)")
                schedulePendingStartsIfPossible()
                borrowCompletion?()
            }
        }
    }

    private func startDownloadIfAvailable(book: TPPBook) {
        let downloadAction = { [weak self] in
            self?.startDownload(for: book)
        }

        book.defaultAcquisition?.availability.match(unavailable: 
            nil,
            limited: { _ in downloadAction() },
            unlimited: { _ in downloadAction() },
            reserved: nil,
            ready: { _ in downloadAction() })
    }

    private func process(error: [String: Any]?, for book: TPPBook) {
        borrowErrorPresenter.process(error: error, for: book)
    }

    // process / showAlert / showGenericBorrowFailedAlert / handleInvalidCredentials
    // moved to BorrowErrorPresenter. The `hasAttemptedAuthentication` flag
    // moved with them. `isRequestingCredentials` lives on the shared
    // `credentialRequestState` (see property above) so the borrow-error path
    // and the start-download path can't both fire concurrent sign-in modals.

    @objc func startDownload(for book: TPPBook, withRequest initedRequest: URLRequest? = nil) {
        Task {
            await startDownloadAsync(for: book, withRequest: initedRequest)
        }
    }

    func startDownloadAsync(for book: TPPBook, withRequest initedRequest: URLRequest? = nil) async {
        let existingInfo = await downloadInfoAsync(forBookIdentifier: book.identifier)
        if existingInfo != nil {
            Log.debug(#file, "Download already in progress for '\(book.title)', skipping duplicate start")
            return
        }

        var state = bookRegistry.state(for: book.identifier)
        let location = bookRegistry.location(forIdentifier: book.identifier)
        let loginRequired = (userAccount.authDefinition?.needsAuth ?? false) && !userAccount.hasCredentials()

        Log.info(#file, "📥 Starting download for '\(book.title)' - state: \(state), hasCredentials: \(userAccount.hasCredentials()), loginRequired: \(loginRequired)")

        await self.errorActivityTracker.log("Starting download for '\(book.title)'", category: .download)

        switch state {
        case .unregistered:
            state = processUnregisteredState(
                for: book,
                location: location,
                loginRequired: loginRequired
            )
        case .downloading:
            Log.debug(#file, "Book '\(book.title)' is already downloading (state check), skipping")
            return
        case .downloadFailed, .downloadNeeded, .holding, .SAMLStarted:
            break
        case .downloadSuccessful, .used, .unsupported, .returning:
            NSLog("Ignoring nonsensical download request.")
            return
        }

        let canStart = await downloadCoordinator.canStartDownload(maxConcurrent: maxConcurrentDownloads)
        let activeCount = await downloadCoordinator.activeCount

        if !canStart {
            Log.debug(#file, "Max concurrent downloads reached (\(activeCount)/\(maxConcurrentDownloads)), enqueueing '\(book.title)'")
            queueOrchestrator.enqueuePending(book)
            return
        }

        let throttleDelay = await downloadCoordinator.shouldThrottleStart()
        if throttleDelay > 0 {
            Log.info(#file, "⏱️ Throttling download start for '\(book.title)' by \(String(format: "%.1f", throttleDelay))s")
            try? await Task.sleep(nanoseconds: UInt64(throttleDelay * 1_000_000_000))
        }

        await downloadCoordinator.registerStart(identifier: book.identifier)

        if loginRequired {
            Log.info(#file, "Login required for '\(book.title)', requesting credentials")
            requestCredentialsAndStartDownload(for: book)
        } else {
            Log.info(#file, "Credentials available, processing download for '\(book.title)'")
            processDownloadWithCredentials(for: book, withState: state, andRequest: initedRequest)
        }
    }

    private func processUnregisteredState(for book: TPPBook, location: TPPBookLocation?, loginRequired: Bool?) -> TPPBookState {
        if book.defaultAcquisitionIfBorrow == nil && (book.defaultAcquisitionIfOpenAccess != nil || !(loginRequired ?? false)) {
            bookRegistry.addBook(book, location: location, state: .downloadNeeded, fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)
            return .downloadNeeded
        }
        return .unregistered
    }

    private func requestCredentialsAndStartDownload(for book: TPPBook) {
        credentialPromptCoordinator.requestCredentialsAndStartDownload(for: book)
    }

    var isWifiOnlyEnforced: Bool {
        self.settings.downloadOnlyOnWiFi && !self.reachability.isOnWiFi
    }

    func failWithWifiRequired(for book: TPPBook) {
        Log.info(#file, "Download blocked for '\(book.title)' — Wi-Fi only mode is enabled and device is not on Wi-Fi")
        runOnMainAsync {
            self.publishAndAnnounceError(
                DownloadErrorInfo(
                    bookId: book.identifier,
                    title: DisplayStrings.wifiRequired,
                    message: DisplayStrings.downloadRestrictedToWiFi
                )
            )
        }
        Task { await self.downloadCoordinator.registerCompletion(identifier: book.identifier) }
    }

    private func processDownloadWithCredentials(
        for book: TPPBook,
        withState state: TPPBookState,
        andRequest initedRequest: URLRequest?
    ) {
        if state == .unregistered || state == .holding {
            startBorrow(for: book, attemptDownload: true, borrowCompletion: nil)
        } else {
            #if FEATURE_OVERDRIVE
            if book.distributor == OverdriveDistributorKey && book.defaultBookContentType == .audiobook {
                if Self.shouldDeferOverdriveFulfillment(for: book, state: state) {
                    deferOverdriveFulfillment(for: book)
                    return
                }
                processOverdriveDownload(for: book, withState: state)
                return
            }
            #endif
            processRegularDownload(for: book, withState: state, andRequest: initedRequest)
        }
    }

    /// Returns `true` when a book would be routed to the Overdrive fulfillment
    /// path but its default acquisition is still a borrow relation — meaning
    /// the post-borrow OPDS entry didn't expose a fulfillment URL.
    ///
    /// `OverdriveAPIExecutor.fulfillBook()` expects the target URL to return a
    /// 302 carrying `x-overdrive-scope` and `x-overdrive-patron-authorization`
    /// headers. Hitting the Palace CM's `/borrow` URL with an active loan
    /// returns a 200 OPDS atom entry instead, producing a spurious "wrong
    /// headers" error. When this guard fires we defer the download, sync the
    /// loans feed, and surface a retry-able message to the user.
    static func shouldDeferOverdriveFulfillment(for book: TPPBook, state: TPPBookState) -> Bool {
        guard state != .unregistered, state != .holding else { return false }
        return book.defaultAcquisitionIfBorrow != nil
    }

    #if FEATURE_OVERDRIVE
    private func deferOverdriveFulfillment(for book: TPPBook) {
        overdriveDownloadHandler.deferOverdriveFulfillment(for: book)
    }
    #endif

    #if FEATURE_OVERDRIVE
    private func processOverdriveDownload(for book: TPPBook, withState state: TPPBookState) {
        overdriveDownloadHandler.processOverdriveDownload(for: book, withState: state)
    }
    #endif

    // handleOverdriveResponse moved to OverdriveDownloadHandler
    // (private there).

    private func processRegularDownload(for book: TPPBook, withState state: TPPBookState, andRequest initedRequest: URLRequest?) {
        // The book parameter might be stale (from before borrowing completed)
        let currentBook = bookRegistry.book(forIdentifier: book.identifier) ?? book

        if currentBook.isExpired && currentBook.defaultAcquisitionIfBorrow != nil {
            Log.warn(#file, "Book \(book.identifier) is expired. Attempting to re-borrow before download.")
            bookRegistry.setState(.unregistered, for: book.identifier)
            startBorrow(for: currentBook, attemptDownload: true, borrowCompletion: nil)
            return
        }

        // Check if book needs to be borrowed before download
        // Using currentBook ensures we have the latest acquisition links
        if state == .downloadNeeded && currentBook.defaultAcquisitionIfBorrow != nil {
            Log.info(#file, "Book \(book.identifier) is downloadNeeded with borrow acquisition - auto-borrowing before download")
            bookRegistry.setState(.unregistered, for: book.identifier)
            startBorrow(for: currentBook, attemptDownload: true) { [weak self] in
                guard let self else { return }
                let newState = self.bookRegistry.state(for: book.identifier)
                Log.debug(#file, "Auto-borrow completed for \(book.identifier), new state: \(newState)")

                // If still not in a downloadable state, something went wrong
                if newState != .downloading && newState != .downloadSuccessful && newState != .downloadNeeded {
                    Log.warn(#file, "Auto-borrow completed but book is not downloadable, state: \(newState)")
                }
            }
            return
        }

        if isWifiOnlyEnforced {
            failWithWifiRequired(for: currentBook)
            return
        }

        // Use currentBook for download URL to ensure we have the latest fulfillment link
        let request: URLRequest
        if let initedRequest = initedRequest {
            request = initedRequest
        } else if let url = currentBook.defaultAcquisition?.hrefURL {
            request = TPPNetworkExecutor.bearerAuthorized(request: URLRequest(url: url, applyingCustomUserAgent: true))
        } else {
            logInvalidURLRequest(for: currentBook, withState: state, url: nil, request: nil)
            return
        }

        guard request.url != nil else {
            logInvalidURLRequest(for: currentBook, withState: state, url: currentBook.defaultAcquisition?.hrefURL, request: request)
            return
        }

        // Reclaim space only when free disk is genuinely low. The previous
        // unconditional `enforceContentDiskBudgetIfNeeded(adding: 0)` ran on
        // every new download against a tight 2.5 GB budget, silently evicting
        // older books to make room — the root cause of "titles revert to
        // Download Needed after quits/library changes." The reclaim call
        // below handles actual low-disk scenarios without that collateral.
        self.memoryPressureMonitor.reclaimDiskSpaceIfNeeded(minimumFreeMegabytes: 512)

        if state == .SAMLStarted, let cookies = userAccount.cookies {
            Log.info(#file, "SAML authentication flow for '\(currentBook.title)'")
            handleSAMLStartedState(for: currentBook, withRequest: request, cookies: cookies)
        } else {
            // Apply saved cookies (if any) and proceed with download
            // Server will return 401 if cookies are expired, triggering re-auth
            if userAccount.authToken != nil {
                Log.debug(#file, "Auth token present for '\(currentBook.title)', proceeding with download")
            } else if userAccount.cookies != nil {
                Log.debug(#file, "Using saved SAML cookies for '\(currentBook.title)', proceeding with download")
            }
            clearAndSetCookies()
            // Use currentBook to ensure registry has correct book object
            addDownloadTask(with: request, book: currentBook)
        }
    }

    private func logInvalidURLRequest(for book: TPPBook, withState state: TPPBookState, url: URL?, request: URLRequest?) {
        bookRegistry.setState(.SAMLStarted, for: book.identifier)
        guard let someCookies = self.userAccount.cookies, var mutableRequest = request else { return }

        runOnMainAsync { [weak self] in
            guard let self = self else { return }

            mutableRequest.cachePolicy = .reloadIgnoringCacheData

            let loginCancelHandler: () -> Void = { [weak self] in
                self?.bookRegistry.setState(.downloadNeeded, for: book.identifier)
                self?.cancelDownload(for: book.identifier)
            }

            let bookFoundHandler: (_ request: URLRequest?, _ cookies: [HTTPCookie]) -> Void = { [weak self] _, cookies in
                self?.userAccount.setCookies(cookies)
                self?.startDownload(for: book, withRequest: mutableRequest)
            }

            let problemFoundHandler: (_ problemDocument: TPPProblemDocument?) -> Void = { [weak self] problemDocument in
                guard let self = self else { return }

                // Use the shared handleProblem method for consistent behavior
                self.handleProblem(for: book, problemDocument: problemDocument)
            }

            let model = TPPCookiesWebViewModel(
                cookies: someCookies,
                request: mutableRequest,
                loginCompletionHandler: nil,
                loginCancelHandler: loginCancelHandler,
                bookFoundHandler: bookFoundHandler,
                problemFoundHandler: problemFoundHandler,
                autoPresentIfNeeded: true
            )
            let cookiesVC = TPPCookiesWebViewController(model: model)
            cookiesVC.loadViewIfNeeded()
        }
    }

    private func handleSAMLStartedState(for book: TPPBook, withRequest request: URLRequest, cookies: [HTTPCookie]) {
        signInRedirectHandler.handleSAMLStartedState(for: book, withRequest: request, cookies: cookies)
    }

    // handleLoginCancellation / handleBookFound / handleProblem /
    // clearAndSetCookies moved to BookSignInRedirectHandler. The
    // 3 internal call sites (loginCancelHandler / bookFoundHandler /
    // problemFoundHandler closures) are now wired in the handler. The
    // 1 remaining external call site for handleProblem is from
    // `handleSAMLStartedState`'s callback closure (which now lives on
    // the handler too).
    private func handleProblem(for book: TPPBook, problemDocument: TPPProblemDocument?) {
        signInRedirectHandler.handleProblem(for: book, problemDocument: problemDocument)
    }

    private func clearAndSetCookies() {
        signInRedirectHandler.clearAndSetCookies()
    }

    @objc func cancelDownload(for identifier: String) {
        let state = bookRegistry.state(for: identifier)

        // Handle case where there's no download task (e.g., during borrow request, waiting for retry, etc.)
        guard let info = downloadInfo(forBookIdentifier: identifier) else {
            // Allow cancellation for states that indicate a download/borrow is in progress
            let cancellableStates: [TPPBookState] = [.downloading, .downloadFailed, .SAMLStarted]

            if cancellableStates.contains(state) {
                Log.info(#file, "📊 Cancelling download without task for '\(identifier)' (state: \(state.stringValue()))")
                bookRegistry.setState(.downloadNeeded, for: identifier)
                broadcastUpdate()

                Task {
                    // Clean up coordinator even without a download task
                    await self.downloadCoordinator.removeCachedDownloadInfo(for: identifier)
                    await self.downloadCoordinator.registerCompletion(identifier: identifier)
                    let remainingCount = await self.downloadCoordinator.activeCount
                    Log.info(#file, "📊 Download cancelled (no task) for '\(identifier)', remaining active: \(remainingCount)")
                    self.schedulePendingStartsIfPossible()
                }
                return
            }

            NSLog("Ignoring nonsensical cancellation request for state: \(state.stringValue())")
            return
        }

        #if FEATURE_DRM_CONNECTOR
        if info.rightsManagement == .adobe {
            self.adobeDRMService.cancelFulfillment(withTag: identifier)
            return
        }
        #endif

        let taskId = info.downloadTask.taskIdentifier

        // First, update UI immediately so user sees feedback
        bookRegistry.setState(.downloadNeeded, for: identifier)
        broadcastUpdate()

        // Then cancel the task
        info.downloadTask.cancel { [weak self] _ in
            guard let self else { return }

            Task {
                // CRITICAL: Remove from tracking dictionaries so retry works
                await self.bookIdentifierToDownloadInfo.remove(identifier)
                await self.taskIdentifierToBook.remove(taskId)
                await self.downloadCoordinator.removeCachedDownloadInfo(for: identifier)
                await self.downloadCoordinator.registerCompletion(identifier: identifier)
                let remainingCount = await self.downloadCoordinator.activeCount
                Log.info(#file, "📊 Download cancelled for '\(identifier)', remaining active: \(remainingCount)")
                self.schedulePendingStartsIfPossible()
            }
        }
    }
}

extension MyBooksDownloadCenter {

    func redownloadLCPContentFile(for book: TPPBook) {
        localContentService.redownloadLCPContentFile(for: book)
    }

    func deleteLocalContent(for identifier: String, account: String? = nil) {
        localContentService.deleteLocalContent(for: identifier, account: account)
    }

    func deleteLocalContent(forBook book: TPPBook, account: String? = nil) {
        localContentService.deleteLocalContent(forBook: book, account: account)
    }

    // lcpLicenseURL + deleteLocalAudiobookContent moved to LocalBookContentService
    // (private there).

    @objc func returnBook(withIdentifier identifier: String, completion: (() -> Void)? = nil) {
        returnService.returnBook(withIdentifier: identifier, completion: completion)
    }

    // returnBook full body + performPostReturnSyncThen moved to
    // BookReturnService. ~230 LOC of return-state-machine + the
    // post-return sync helper now lives in that file.
}

extension MyBooksDownloadCenter: URLSessionDownloadDelegate {
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didResumeAtOffset fileOffset: Int64,
        expectedTotalBytes: Int64
    ) {
        NSLog("Ignoring unexpected resumption.")
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let key = downloadTask.taskIdentifier

        // Bridge to async for actor access
        Task {
            guard let book = await taskIdentifierToBook.get(key) else {
                return
            }

            await backgroundDownloadHandler.handleDownloadProgress(
                for: book,
                task: downloadTask,
                bytesWritten: bytesWritten,
                totalBytesWritten: totalBytesWritten,
                totalBytesExpectedToWrite: totalBytesExpectedToWrite
            )
        }
    }

    // detectRightsManagement / isOPDSEntryMimeType moved to
    // BackgroundDownloadHandler. Internal call sites below route through
    // `backgroundDownloadHandler` directly.

    /// Checks if the MIME type indicates an OPDS 2 publication JSON response
    // isOPDS2PublicationMimeType / handleOPDS2PublicationResponse moved to
    // BackgroundDownloadHandler. The URLSessionDownloadDelegate callback
    // routes through `backgroundDownloadHandler.X(...)` directly.

    // handleOPDSEntryResponse + followAcquisitionLink moved to
    // BackgroundDownloadHandler. The OPDS-entry XML callsite (URL-finished
    // callback) and the OPDS2 JSON publication callsites
    // (handleOPDS2PublicationResponse) now route through
    // `backgroundDownloadHandler.X(...)` directly. The handler's version
    // adds a defensive `!opds-catalog` guard against infinite-redirect
    // loops on malformed entries / publications.
    // handleDownloadProgress moved to BackgroundDownloadHandler. The
    // URLSessionDownloadDelegate progress callback above now routes through
    // `backgroundDownloadHandler.handleDownloadProgress(...)` directly.

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // Move file to a safe location first
        let tempDir = FileManager.default.temporaryDirectory
        let safeLocation = tempDir.appendingPathComponent(UUID().uuidString + "_" + location.lastPathComponent)

        do {
            try FileManager.default.moveItem(at: location, to: safeLocation)
        } catch {
            Log.error(#file, "Failed to preserve download file: \(error.localizedDescription)")
            return
        }

        // Now process async with preserved file
        Task {
            await handleDownloadCompletion(session: session, task: downloadTask, location: safeLocation)
        }
    }

    func handleDownloadCompletion(session: URLSession, task: URLSessionDownloadTask, location: URL) async {
        guard let book = await taskIdentifierToBook.get(task.taskIdentifier) else {
            return
        }

        await downloadCoordinator.clearRedirectAttempts(for: task.taskIdentifier)

        var failureRequiringAlert = false
        var failureError = task.error
        var problemDoc: TPPProblemDocument?
        var rights = await downloadInfoAsync(forBookIdentifier: book.identifier)?.rightsManagement ?? .unknown

        if rights == .unknown, let mimeType = task.response?.mimeType {
            Log.info(#file, "⚠️ Rights unknown, detecting from completion MIME type: \(mimeType)")
            rights = backgroundDownloadHandler.detectRightsManagement(from: mimeType)
            if let info = await downloadInfoAsync(forBookIdentifier: book.identifier)?.withRightsManagement(rights) {
                await bookIdentifierToDownloadInfo.set(book.identifier, value: info)
            }
        }

        Log.info(#file, "Download completed for \(book.identifier) with rights: \(rights)")

        if let response = task.response, response.isProblemDocument() {
            let problemDocData = (try? Data(contentsOf: location)) ?? Data()
            problemDoc = TPPProblemDocument.fromProblemResponseData(problemDocData)
            if problemDoc == nil {
                TPPErrorLogger.logProblemDocumentParseError(NSError(domain: "MyBooksDownloadCenter", code: -1, userInfo: [NSLocalizedDescriptionKey: "Could not parse problem document"]), problemDocumentData: problemDocData.isEmpty ? nil : problemDocData, url: location, summary: "Error parsing problem doc downloading \(String(describing: book.distributor)) book", metadata: ["book": book.loggableShortString])
            }

            try? FileManager.default.removeItem(at: location)
            failureRequiringAlert = true
        }

        // Check for OPDS entry XML response - this may contain the actual acquisition link
        let mimeType = task.response?.mimeType ?? ""
        if !failureRequiringAlert && backgroundDownloadHandler.isOPDSEntryMimeType(mimeType) {
            Log.info(#file, "📖 Received OPDS entry response for \(book.identifier), attempting to extract acquisition link")

            if await backgroundDownloadHandler.handleOPDSEntryResponse(at: location, for: book, originalTask: task, session: session) {
                // Successfully started follow-up download, don't fail this one
                try? FileManager.default.removeItem(at: location)
                return
            } else {
                Log.warn(#file, "⚠️ Failed to extract acquisition link from OPDS entry for \(book.identifier)")
                try? FileManager.default.removeItem(at: location)
                failureRequiringAlert = true
            }
        } else if !failureRequiringAlert && backgroundDownloadHandler.isOPDS2PublicationMimeType(mimeType) {
            Log.info(#file, "📖 Received OPDS2 publication JSON for \(book.identifier), extracting fulfillment link")

            if await backgroundDownloadHandler.handleOPDS2PublicationResponse(at: location, for: book, originalTask: task, session: session) {
                try? FileManager.default.removeItem(at: location)
                return
            } else {
                Log.warn(#file, "⚠️ Failed to extract fulfillment link from OPDS2 publication for \(book.identifier)")
                try? FileManager.default.removeItem(at: location)
                failureRequiringAlert = true
            }
        } else if !book.canCompleteDownload(withContentType: mimeType) {
            try? FileManager.default.removeItem(at: location)
            failureRequiringAlert = true
        }

        if failureRequiringAlert {
            logBookDownloadFailure(book, reason: "Download Error", downloadTask: task, metadata: ["problemDocument": problemDoc?.dictionaryValue ?? "N/A", "mimeType": mimeType])
        } else {
            TPPProblemDocumentCacheManager.sharedInstance().clearCachedDoc(book.identifier)

            switch rights {
            case .unknown:
                Log.error(#file, "❌ Rights management is unknown for book: \(book.identifier) - LCP fulfillment will NOT be called")
                logBookDownloadFailure(book, reason: "Unknown rights management", downloadTask: task, metadata: nil)
                failureRequiringAlert = true
            case .adobe:
                #if FEATURE_DRM_CONNECTOR
                if let acsmData = try? Data(contentsOf: location),
                   let acsmString = String(data: acsmData, encoding: .utf8),
                   acsmString.contains(">application/pdf</dc:format>") {
                    let msg = NSLocalizedString("\(book.title) is an Adobe PDF, which is not supported.", comment: "")
                    failureError = NSError(domain: TPPErrorLogger.clientDomain, code: TPPErrorCode.ignore.rawValue, userInfo: [NSLocalizedDescriptionKey: msg])
                    logBookDownloadFailure(book, reason: "Received PDF for AdobeDRM rights", downloadTask: task, metadata: nil)
                    failureRequiringAlert = true
                } else if let acsmData = try? Data(contentsOf: location) {
                    // Ensure Adobe DRM device is activated before attempting ACSM fulfillment.
                    // PP-3649 deferred activation from login to borrow time, but the download-retry
                    // path bypasses the borrow flow — so activation must also be checked here.
                    Task { [weak self] in
                        guard let self else { return }
                        do {
                            try await self.adobeDRMService.ensureDeviceActivated()
                            let ua = self.userAccount
                            Log.info(#file, "Adobe DRM activated — fulfilling ACSM for '\(book.title)' with userID: \(ua.userID ?? "nil")")
                            await MainActor.run {
                                self.adobeDRMService.fulfill(withACSMData: acsmData, tag: book.identifier, userID: ua.userID, deviceID: ua.deviceID)
                            }
                        } catch {
                            Log.error(#file, "Adobe DRM activation failed for '\(book.title)': \(error.localizedDescription)")
                            await MainActor.run {
                                self.bookRegistry.setState(.downloadFailed, for: book.identifier)
                                self.alertForProblemDocument(nil, error: error, book: book)
                            }
                        }
                    }
                }
                #endif
            case .lcp:
                fulfillLCPLicense(fileUrl: location, forBook: book, downloadTask: task)
            case .simplifiedBearerTokenJSON:
                if let data = try? Data(contentsOf: location) {
                    if let dictionary = TPPJSONObjectFromData(data) as? [String: Any],
                       let simplifiedBearerToken = MyBooksSimplifiedBearerToken.simplifiedBearerToken(with: dictionary) {
                        let cmFulfillURL = task.originalRequest?.url
                        simplifiedBearerToken.fulfillURL = cmFulfillURL

                        var mutableRequest = URLRequest(url: simplifiedBearerToken.location, applyingCustomUserAgent: true)
                        mutableRequest.setValue("Bearer \(simplifiedBearerToken.accessToken)", forHTTPHeaderField: "Authorization")
                        let newTask = session.downloadTask(with: mutableRequest as URLRequest)
                        let downloadInfo = MyBooksDownloadInfo(
                            downloadProgress: 0.0,
                            downloadTask: newTask,
                            rightsManagement: .none,
                            bearerToken: simplifiedBearerToken
                        )
                        await bookIdentifierToDownloadInfo.set(book.identifier, value: downloadInfo)
                        book.bearerToken = simplifiedBearerToken.accessToken
                        book.bearerTokenFulfillURL = cmFulfillURL
                        await taskIdentifierToBook.set(newTask.taskIdentifier, value: book)
                        newTask.resume()
                    } else {
                        logBookDownloadFailure(book, reason: "No Simplified Bearer Token in deserialized data", downloadTask: task, metadata: nil)
                        failDownloadWithAlert(for: book)
                    }
                } else {
                    logBookDownloadFailure(book, reason: "No Simplified Bearer Token data available on disk", downloadTask: task, metadata: nil)
                    failDownloadWithAlert(for: book)
                }
            case .overdriveManifestJSON:
                failureRequiringAlert = !backgroundDownloadHandler.replaceBook(book, withFileAtURL: location, forDownloadTask: task)
            case .none:
                failureRequiringAlert = !backgroundDownloadHandler.moveFile(at: location, toDestinationForBook: book, forDownloadTask: task)
            }
        }

        if failureRequiringAlert {
            runOnMainAsync { [weak self] in
                guard let self else { return }
                let handled = self.authRetryHandler.handleAuthFailureIfApplicable(
                    book: book,
                    task: task,
                    problemDoc: problemDoc,
                    failureError: failureError
                )
                guard !handled else { return }

                // For other errors, show alert immediately
                self.alertForProblemDocument(problemDoc, error: failureError, book: book)

                // Set state to downloadFailed INSIDE runOnMainAsync to ensure it happens
                // AFTER the alert is dispatched, preventing view hierarchy race conditions
                self.bookRegistry.setState(.downloadFailed, for: book.identifier)
            }
        }

        // Cleanup must wait for the state change to be processed
        // Use a small delay to ensure UI updates from setState complete first
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms

        broadcastUpdate()

        // CRITICAL: Remove from bookIdentifierToDownloadInfo so retry works
        await bookIdentifierToDownloadInfo.remove(book.identifier)
        await downloadCoordinator.removeCachedDownloadInfo(for: book.identifier)
        await downloadCoordinator.registerCompletion(identifier: book.identifier)
        let remainingCount = await downloadCoordinator.activeCount
        Log.info(#file, "📊 Download flow completed for '\(book.identifier)', remaining active: \(remainingCount)")

        schedulePendingStartsIfPossible()
    }

    /// Async-first download info accessor with cache update
    func downloadInfoAsync(forBookIdentifier bookIdentifier: String) async -> MyBooksDownloadInfo? {
        guard let downloadInfo = await bookIdentifierToDownloadInfo.get(bookIdentifier) else {
            await downloadCoordinator.removeCachedDownloadInfo(for: bookIdentifier)
            return nil
        }

        if downloadInfo is MyBooksDownloadInfo {
            await downloadCoordinator.cacheDownloadInfo(downloadInfo, for: bookIdentifier)
            return downloadInfo
        } else {
            Log.error(#file, "Corrupted download info detected for book \(bookIdentifier), removing entry")
            await bookIdentifierToDownloadInfo.remove(bookIdentifier)
            await downloadCoordinator.removeCachedDownloadInfo(for: bookIdentifier)
            return nil
        }
    }

    /// Synchronous accessor for legacy compatibility (@objc, UIKit delegates).
    /// Reads from SafeDictionary's lock-protected synchronous mirror — no async
    /// bridging, no semaphores, no data races.
    @objc func downloadInfo(forBookIdentifier bookIdentifier: String) -> MyBooksDownloadInfo? {
        bookIdentifierToDownloadInfo.syncGet(bookIdentifier)
    }

    func broadcastUpdate() {
        progressReporter.broadcastUpdate()
    }

}

extension MyBooksDownloadCenter: URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let handler = TPPBasicAuth(credentialsProvider: userAccount)
        handler.handleChallenge(challenge, completion: completionHandler)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let maxRedirectAttempts: UInt = 10

        Task {
            let redirectAttempts = await downloadCoordinator.getRedirectAttempts(for: task.taskIdentifier)

            if redirectAttempts >= maxRedirectAttempts {
                completionHandler(nil)
                return
            }

            await downloadCoordinator.incrementRedirectAttempts(for: task.taskIdentifier)

            // Prevent redirection from HTTPS to a non-HTTPS URL.
            if task.originalRequest?.url?.scheme == "https" && request.url?.scheme != "https" {
                completionHandler(nil)
                return
            }

            // Do NOT forward any auth headers on redirects.
            // For No DRM (open access): The redirect target doesn't need auth - content is open.
            // For Bearer Token protected: We receive a JSON document (not a redirect) with
            // the distributor's specific token, which we use in a NEW request.
            // URLSession already strips Authorization headers on redirects for security;
            // we simply allow that behavior and don't re-add them.
            completionHandler(request)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        Task {
            await handleTaskCompletionError(task: task, error: error)
        }
    }

    func handleTaskCompletionError(task: URLSessionTask, error: Error?) async {
        guard let book = await taskIdentifierToBook.get(task.taskIdentifier) else {
            return
        }

        await downloadCoordinator.clearRedirectAttempts(for: task.taskIdentifier)
        await downloadCoordinator.registerCompletion(identifier: book.identifier)
        let remainingCount = await downloadCoordinator.activeCount
        Log.info(#file, "📊 Download completed for '\(book.title)', remaining active: \(remainingCount)")

        if let error = error as NSError?, error.code != NSURLErrorCancelled {
            logBookDownloadFailure(book, reason: "networking error", downloadTask: task, metadata: ["urlSessionError": error])
            failDownloadWithAlert(for: book)
            return
        }

        schedulePendingStartsIfPossible()
    }

    func addDownloadTask(with request: URLRequest, book: TPPBook) {
        var modifiableRequest = request
        // `downloadTask(with:)` throws NSGenericException("Task created in a session
        // that has been invalidated") if the session has been torn down between the
        // enclosing detached-Task scheduling and this call. That path is reachable
        // whenever app lifecycle (or test teardown) invalidates the session while a
        // start-download Task is still queued. Catch it and bail cleanly instead
        // of crashing the process.
        var task: URLSessionDownloadTask?
        let exception = TPPObjCExceptionCatcher.catchException {
            task = self.session.downloadTask(with: modifiableRequest.applyCustomUserAgent())
        }
        guard let task, exception == nil else {
            Log.warn(#file, "addDownloadTask: session unavailable, skipping download of '\(book.title)' (\(exception?.name.rawValue ?? "task=nil"))")
            return
        }

        let downloadInfo = MyBooksDownloadInfo(
            downloadProgress: 0.0,
            downloadTask: task,
            rightsManagement: .unknown
        )

        Task {
            await self.bookIdentifierToDownloadInfo.set(book.identifier, value: downloadInfo)
            await self.taskIdentifierToBook.set(task.taskIdentifier, value: book)

            let currentCount = await downloadCoordinator.activeCount
            Log.info(#file, "📊 Active downloads: \(currentCount)/\(maxConcurrentDownloads) (started '\(book.title)')")

            // Resume task AFTER storage to ensure delegate callbacks can find it
            task.resume()

            // Update registry and notify
            self.bookRegistry.addBook(book,
                                      location: self.bookRegistry.location(forIdentifier: book.identifier),
                                      state: .downloading,
                                      fulfillmentId: nil,
                                      readiumBookmarks: nil,
                                      genericBookmarks: nil)

            self.downloadAnnouncementService.announceDownloadStarted(for: book)

            runOnMainAsync {
                NotificationCenter.default.post(name: .TPPMyBooksDownloadCenterDidChange, object: self)
            }

            // After starting one, see if we can start pending ones within capacity
            self.schedulePendingStartsIfPossible()
        }
    }
}

// MARK: - Download Throttling and Disk Budget
extension MyBooksDownloadCenter {
    // Pending-download queue management lifted into
    // `DownloadQueueOrchestrator`. The two pump methods stay on MBDC's
    // surface as 1-line delegators so external callers (the
    // BackgroundDownloadHandler / DownloadAlertPresenter delegate
    // protocols + the URLSession completion paths inside MBDC) keep the
    // exact signatures they relied on.

    func schedulePendingStartsIfPossible() {
        queueOrchestrator.schedulePendingStartsIfPossible()
    }

    func schedulePendingStartsAsync() async {
        await queueOrchestrator.schedulePendingStartsAsync()
    }

    /// Enforces a soft content disk budget. If `adding` is >0, assumes that many bytes will be added
    /// and makes room accordingly, deleting least-recently-used content first.
    ///
    /// Delegates to `performDiskBudgetEviction(in:adding:budgetOverrideBytes:)` against the current
    /// account's content directory. The inner method is the unit-test seam.
    @objc func enforceContentDiskBudgetIfNeeded(adding bytesToAdd: Int64) {
        diskBudgetManager.enforceContentDiskBudgetIfNeeded(adding: bytesToAdd)
    }

    /// Test-friendly delegator preserved for the existing 7-test
    /// MyBooksDownloadCenterEvictionTests suite, which calls this directly to
    /// drive the LRU eviction state machine end-to-end without resolving a
    /// content directory. Production code goes through `enforceContentDiskBudgetIfNeeded`.
    internal func performDiskBudgetEviction(
        in dir: URL,
        adding bytesToAdd: Int64,
        budgetOverrideBytes: Int64?
    ) {
        diskBudgetManager.performDiskBudgetEviction(in: dir, adding: bytesToAdd, budgetOverrideBytes: budgetOverrideBytes)
    }
}

extension MyBooksDownloadCenter {
    // Public throttling helpers preserved for the @objc TPPAppDelegate +
    // memoryPressureMonitor callers. All logic lives on
    // DownloadThrottlingService; MBDC just forwards.
    @objc func limitActiveDownloads(max: Int) {
        throttlingService.limitActiveDownloads(max: max)
    }

    @objc func pauseAllDownloads() {
        throttlingService.pauseAllDownloads()
    }

    @objc func resumeIntelligentDownloads() {
        throttlingService.resumeIntelligentDownloads()
    }

    func logBookDownloadFailure(_ book: TPPBook, reason: String, downloadTask: URLSessionTask, metadata: [String: Any]?) {
        let rights = downloadInfo(forBookIdentifier: book.identifier)?.rightsManagementString ?? ""

        var dict: [String: Any] = metadata ?? [:]
        dict["book"] = book.loggableDictionary
        dict["rightsManagement"] = rights
        dict["taskOriginalRequest"] = downloadTask.originalRequest?.loggableString
        dict["taskCurrentRequest"] = downloadTask.currentRequest?.loggableString
        dict["response"] = downloadTask.response ?? "N/A"
        dict["downloadError"] = downloadTask.error ?? "N/A"

        // Use enhanced logging if enabled
        Task { [weak self] in
            await self?.deviceSpecificErrorMonitor.logDownloadFailure(
                book: book,
                reason: reason,
                error: downloadTask.error,
                metadata: dict
            )
        }
    }

    func fulfillLCPLicense(fileUrl: URL, forBook book: TPPBook, downloadTask: URLSessionDownloadTask) {
        #if LCP
        lcpFulfillmentHandler.fulfillLCPLicense(fileUrl: fileUrl, forBook: book, downloadTask: downloadTask)
        #endif
    }

    // copyLicenseForStreaming moved to LCPFulfillmentHandler (private there).

    func failDownloadWithAlert(for book: TPPBook, withMessage message: String? = nil) {
        alertPresenter.failDownloadWithAlert(for: book, withMessage: message)
    }

    func alertForProblemDocument(_ problemDoc: TPPProblemDocument?, error: Error?, book: TPPBook) {
        alertPresenter.alertForProblemDocument(problemDoc, error: error, book: book)
    }

    // moveFile / replaceBook / validateDownloadedFile moved to BackgroundDownloadHandler.
    // Internal call sites now route through `backgroundDownloadHandler.X(...)`.

    @objc func fileUrl(for identifier: String) -> URL? {
        bookFileManager.fileUrl(for: identifier)
    }

    func fileUrl(for identifier: String, account: String?) -> URL? {
        bookFileManager.fileUrl(for: identifier, account: account)
    }

    /// Returns the file URL for a book, accepting the book directly instead of looking it up in the registry.
    /// This is useful during registry loading when the registry hasn't been populated yet.
    func fileUrl(for book: TPPBook, account: String?) -> URL? {
        bookFileManager.fileUrl(for: book, account: account)
    }

    func contentDirectoryURL(_ account: String?) -> URL? {
        bookFileManager.contentDirectoryURL(account)
    }

    func pathExtension(for book: TPPBook?) -> String {
        bookFileManager.pathExtension(for: book)
    }
}

extension MyBooksDownloadCenter: TPPBookDownloadsDeleting {
    func reset(_ libraryID: String!) {
        contentResetService.reset(account: libraryID)
        bookIdentifierOfBookToRemove = nil
    }

    func reset(account: String) {
        contentResetService.reset(account: account)
        if accountsManager.currentAccountId == account {
            bookIdentifierOfBookToRemove = nil
        }
    }

    /// Required by MyBooksDownloadCenterProviding. Resets the current
    /// account.
    func reset() {
        contentResetService.reset()
        bookIdentifierOfBookToRemove = nil
    }

    func deleteAudiobooks(forAccount account: String) {
        contentResetService.deleteAudiobooks(forAccount: account)
    }

    func purgeAllAudiobookCaches(force: Bool = false) {
        contentResetService.purgeAllAudiobookCaches(force: force)
    }

    @objc func downloadProgress(for bookIdentifier: String) -> Double {
        Double(self.downloadInfo(forBookIdentifier: bookIdentifier)?.downloadProgress ?? 0.0)
    }
}

#if FEATURE_DRM_CONNECTOR
extension MyBooksDownloadCenter: AdobeDRMHandlerDelegate {

    func handleAdobeDownloadProgress(_ progress: Double, for tag: String) {
        Task {
            if let info = await self.downloadInfoAsync(forBookIdentifier: tag)?.withDownloadProgress(progress) {
                await self.bookIdentifierToDownloadInfo.set(tag, value: info)
            }
            // Publish to progress publisher so UI updates (HalfSheet, BookCell, etc.)
            await MainActor.run {
                self.downloadProgressPublisher.send((tag, progress))
            }
            self.broadcastUpdate()
        }
    }
}
#endif

// MARK: - BackgroundDownloadHandlerDelegate
//
// Empty conformance — every required property and method already exists on
// MyBooksDownloadCenter at the right access level. Establishes the delegate
// seam so BackgroundDownloadHandler can read MBDC's stateManager /
// progressReporter / bookRegistry / userAccount / tokenInterceptor and call
// back into MBDC's handleDownloadCompletion / handleTaskCompletionError /
// schedulePendingStartsIfPossible / failDownloadWithAlert /
// alertForProblemDocument / logBookDownloadFailure / fileUrl /
// fulfillLCPLicense surface. The next commit can route MBDC's URLSession
// delegate methods through this handler instead of duplicating the helper
// logic that already lives there.
extension MyBooksDownloadCenter: BackgroundDownloadHandlerDelegate {}

// MARK: - TokenRefreshInterceptorDelegate
//
// Empty conformance — every required surface (bookRegistry, userAccount,
// stateManager, progressReporter, startDownload, startBorrow,
// failDownloadWithAlert, alertForProblemDocument) already exists on
// MyBooksDownloadCenter. The interceptor uses these to drive 401-detection
// + SAML/OIDC re-auth + retry after credential refresh.
extension MyBooksDownloadCenter: TokenRefreshInterceptorDelegate {}

// MARK: - DownloadAlertPresenterDelegate
//
// MBDC's `startDownload(for:withRequest:)` already exists with the
// signature the protocol requires (the @objc default-arg method exposed
// to legacy callers); `schedulePendingStartsIfPossible()` is internal
// (promoted in commit 7) and matches the protocol's surface. Empty
// conformance — no synthesis needed.

extension MyBooksDownloadCenter: DownloadAlertPresenterDelegate {}

// MARK: - DownloadThrottlingServiceDelegate
//
// `schedulePendingStartsAsync()` is internal (promoted in this commit
// from private) and matches the protocol's surface. Empty conformance
// — no synthesis needed.

extension MyBooksDownloadCenter: DownloadThrottlingServiceDelegate {}

// MARK: - DownloadQueueOrchestratorDelegate
//
// `startDownloadAsync(for:withRequest:)` is internal (promoted in this
// commit from private) and matches the protocol's surface. Empty
// conformance — the orchestrator drives MBDC's existing per-book
// download workflow when a queued book is dequeued.

extension MyBooksDownloadCenter: DownloadQueueOrchestratorDelegate {}

// MARK: - DownloadAuthRetryHandlerDelegate
//
// `startDownload(for:withRequest:)` and
// `startBorrow(for:attemptDownload:borrowCompletion:)` already exist on
// MBDC's surface. Empty conformance.

extension MyBooksDownloadCenter: DownloadAuthRetryHandlerDelegate {}

// MARK: - BorrowErrorPresenterDelegate
//
// `startBorrow` and `startDownload(for:withRequest:)` already exist on
// MBDC's surface. Empty conformance.

extension MyBooksDownloadCenter: BorrowErrorPresenterDelegate {}

// MARK: - BookSignInRedirectHandlerDelegate
//
// `cancelDownload(for:)` and `startDownload(for:withRequest:)` already
// exist on MBDC's surface. Empty conformance.

extension MyBooksDownloadCenter: BookSignInRedirectHandlerDelegate {
    var cookieStorage: HTTPCookieStorage? {
        session.configuration.httpCookieStorage
    }
}

// MARK: - OverdriveDownloadHandlerDelegate
//
// `isWifiOnlyEnforced`, `failWithWifiRequired(for:)`, and
// `addDownloadTask(with:book:)` already exist on MBDC's surface.
// Empty conformance.

#if FEATURE_OVERDRIVE
extension MyBooksDownloadCenter: OverdriveDownloadHandlerDelegate {}
#endif

// MARK: - CredentialPromptCoordinatorDelegate
//
// `startDownload(for:withRequest:)` already exists on MBDC. Empty conformance.

extension MyBooksDownloadCenter: CredentialPromptCoordinatorDelegate {}

// MARK: - BookReturnServiceDelegate
//
// `purgeAllAudiobookCaches(force:)` is internal on MBDC. Empty
// conformance.

extension MyBooksDownloadCenter: BookReturnServiceDelegate {}

// MARK: - LCPFulfillmentHandlerDelegate
//
// `markDownloadSuccessful(for:)` is internal on MBDC (promoted in
// commit 2). Empty conformance gated on `#if LCP` since the protocol
// itself only exists in LCP builds.

#if LCP
extension MyBooksDownloadCenter: LCPFulfillmentHandlerDelegate {}
#endif
