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
    /// Owns the pre-dispatch parsing of URL session download
    /// completions: rights resolution + cache write-back, problem-doc
    /// detection, OPDS entry / OPDS2 publication routing, and the
    /// canCompleteDownload guard. Returns a typed result MBDC's
    /// per-rights dispatch switch consumes.
    private let completionParser: DownloadCompletionParser
    /// Owns the per-rights-management dispatch step that follows
    /// successful parsing: routes Adobe / LCP / bearer-token /
    /// Overdrive / open-content payloads to the right service and
    /// returns the (failureRequiringAlert, failureError) update the
    /// auth-retry / alert tail consumes.
    private let rightsDispatcher: RightsManagementDispatcher
    /// Owns URL-session task lifecycle bookkeeping: post-creation
    /// state seeding + resume() + .downloading registry transition
    /// for `addDownloadTask`, and the `didCompleteWithError`
    /// callback's redirect cleanup + completion registration +
    /// real-error alerting for `handleTaskCompletionError`.
    private let taskLifecycleService: DownloadTaskLifecycleService
    /// Owns the cancelDownload(for:) state machine: the no-task
    /// path (state-based cancellation during a borrow request /
    /// retry wait) and the with-task path (URLSessionDownloadTask
    /// cancel + dictionary cleanup). Adobe DRM short-circuits to
    /// adobeDRMService.cancelFulfillment so it can drive its own
    /// state machine.
    private let cancellationHandler: DownloadCancellationHandler
    /// Owns startBorrow + startDownloadAsync + startDownloadIfAvailable.
    /// MBDC's `startBorrow` / `startDownload` / `startDownloadAsync`
    /// methods stay as 1-line delegators so the @objc public surface
    /// and the DownloadStartDispatcherDelegate.startBorrow hop both
    /// remain intact.
    private let startCoordinator: DownloadStartCoordinator
    /// Owns the complete borrow lifecycle (borrowAsync + auth-error
    /// retry + OIDC silent reauth + sign-in modal + error
    /// presentation). MBDC's `borrowAsync(_:attemptDownload:)` in
    /// MyBooksDownloadCenter+Async.swift is a 1-line forwarder.
    let borrowOperation: BorrowOperation
    /// Owns the URLSession willPerformHTTPRedirection decision: cap
    /// the redirect chain at the configured max + reject HTTPS →
    /// non-HTTPS downgrades. Stateless — counters live in
    /// stateManager.downloadCoordinator.
    private let redirectPolicy: RedirectPolicy
    /// Owns the start-download dispatch flow: the unregistered-state
    /// seed, the credential-bound dispatch (borrow / Overdrive /
    /// regular), and the inner regular-download routing (re-borrow,
    /// auto-borrow, Wi-Fi guard, request resolution, SAML branch,
    /// addDownloadTask handoff). MBDC's startDownloadAsync calls into
    /// this dispatcher after the active-cap / throttling / credential-
    /// prompt branches have settled.
    private let startDispatcher: DownloadStartDispatcher
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
    /// Holds the connectivityPublisher subscription installed by
    /// `bindReachability()`. PP-4114 follow-up: lets a mid-flight reachability
    /// drop trigger `failActiveDownloadsForNetworkLoss()` without parking the
    /// subscription on a Set we don't otherwise need.
    private var reachabilityCancellable: AnyCancellable?
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
        completionParser: DownloadCompletionParser? = nil,
        rightsDispatcher: RightsManagementDispatcher? = nil,
        taskLifecycleService: DownloadTaskLifecycleService? = nil,
        cancellationHandler: DownloadCancellationHandler? = nil,
        startCoordinator: DownloadStartCoordinator? = nil,
        borrowOperation: BorrowOperation? = nil,
        redirectPolicy: RedirectPolicy? = nil,
        startDispatcher: DownloadStartDispatcher? = nil,
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
        // Parses URL session download completions before MBDC's per-
        // rights dispatch runs. Shares the same backgroundDownloadHandler
        // (rights detection, OPDS routing) and stateManager (rights cache
        // read/write) MBDC owns so cache + routing decisions stay coherent.
        self.completionParser = completionParser ?? DownloadCompletionParser(
            routing: self.backgroundDownloadHandler,
            stateManager: stateManager
        )
        // Per-rights-management dispatcher. Shares stateManager (for
        // bearer-token re-registration), backgroundDownloadHandler (for
        // overdrive/none file ops), bookRegistry (for the Adobe failure
        // path), and a userAccount provider closure that resolves
        // through the just-resolved accountsManager — same library-
        // switch semantics as the rest of MBDC. Adobe DRM service is
        // wired only when FEATURE_DRM_CONNECTOR is on.
        let resolveAccountForDispatcher: () -> TPPUserAccount = {
            userAccount ?? accountsManager.currentUserAccount
        }
        #if FEATURE_DRM_CONNECTOR
        self.rightsDispatcher = rightsDispatcher ?? RightsManagementDispatcher(
            stateManager: stateManager,
            fileOps: self.backgroundDownloadHandler,
            bookRegistry: bookRegistry,
            userAccountProvider: resolveAccountForDispatcher,
            adobeDRMService: .shared
        )
        #else
        self.rightsDispatcher = rightsDispatcher ?? RightsManagementDispatcher(
            stateManager: stateManager,
            fileOps: self.backgroundDownloadHandler,
            bookRegistry: bookRegistry,
            userAccountProvider: resolveAccountForDispatcher
        )
        #endif
        // URL-session task lifecycle bookkeeping. Shares the same
        // stateManager / registry / announcer MBDC owns so the
        // taskIdentifierToBook map and `.downloading` state stay
        // coherent with the rest of the download flow.
        self.taskLifecycleService = taskLifecycleService ?? DownloadTaskLifecycleService(
            stateManager: stateManager,
            bookRegistry: bookRegistry,
            downloadAnnouncementService: downloadAnnouncementService
        )
        // Cancellation handler owns the cancelDownload state machine.
        // Shares stateManager (for SafeDictionaries + downloadCoordinator)
        // + registry. Adobe DRM service is wired only when
        // FEATURE_DRM_CONNECTOR is on so the .adobe rights short-circuit
        // can call adobeDRMService.cancelFulfillment.
        #if FEATURE_DRM_CONNECTOR
        self.cancellationHandler = cancellationHandler ?? DownloadCancellationHandler(
            stateManager: stateManager,
            bookRegistry: bookRegistry,
            adobeDRMService: .shared
        )
        #else
        self.cancellationHandler = cancellationHandler ?? DownloadCancellationHandler(
            stateManager: stateManager,
            bookRegistry: bookRegistry
        )
        #endif
        // Closures route through stateManager.downloadCoordinator so the
        // per-task redirect counters stay in the same actor-isolated store
        // the rest of MBDC reads via `downloadCoordinator.*`.
        let redirectCoordinator = stateManager.downloadCoordinator
        self.redirectPolicy = redirectPolicy ?? RedirectPolicy(
            getRedirectAttempts: { taskID in
                await redirectCoordinator.getRedirectAttempts(for: taskID)
            },
            incrementRedirectAttempts: { taskID in
                await redirectCoordinator.incrementRedirectAttempts(for: taskID)
            }
        )
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
        // DownloadStartDispatcher takes the same userAccount provider /
        // settings / reachability / memory monitor MBDC owns so the
        // Wi-Fi-only check + bearer-auth resolution + auto-borrow flow
        // sees the same view of the world the rest of MBDC does.
        // Overdrive gating is per-target — the dispatcher accepts the
        // overdrive handler when FEATURE_OVERDRIVE is on so its
        // distributor=Overdrive branch can dispatch without a back-
        // delegate hop into MBDC.
        let resolveAccountForDispatcher2: () -> TPPUserAccount = {
            userAccount ?? accountsManager.currentUserAccount
        }
        let dispatcherReachability = reachability
        #if FEATURE_OVERDRIVE
        self.startDispatcher = startDispatcher ?? DownloadStartDispatcher(
            userAccountProvider: resolveAccountForDispatcher2,
            settings: settings,
            isOnWiFi: { dispatcherReachability.isOnWiFi },
            memoryPressureMonitor: memoryPressureMonitor,
            overdriveHandler: self.overdriveDownloadHandler
        )
        #else
        self.startDispatcher = startDispatcher ?? DownloadStartDispatcher(
            userAccountProvider: resolveAccountForDispatcher2,
            settings: settings,
            isOnWiFi: { dispatcherReachability.isOnWiFi },
            memoryPressureMonitor: memoryPressureMonitor
        )
        #endif
        // Owns the four borrow/start entry points lifted out of MBDC.
        // The userAccountProvider closure preserves library-switch
        // resolution semantics. Constructed AFTER startDispatcher /
        // queueOrchestrator / credentialPromptCoordinator so the
        // coordinator can hold those concrete services directly
        // (smaller delegate surface than routing through MBDC).
        let resolveAccountForStart: () -> TPPUserAccount = {
            userAccount ?? accountsManager.currentUserAccount
        }
        let coordinatorDispatcher = self.startDispatcher
        let coordinatorCredentialPrompt = self.credentialPromptCoordinator
        self.startCoordinator = startCoordinator ?? DownloadStartCoordinator(
            stateManager: stateManager,
            bookRegistry: bookRegistry,
            userAccountProvider: resolveAccountForStart,
            errorActivityTracker: errorActivityTracker,
            queueOrchestrator: self.queueOrchestrator,
            processUnregistered: { book, location, loginRequired in
                coordinatorDispatcher.processUnregisteredState(for: book, location: location, loginRequired: loginRequired)
            },
            processWithCredentials: { book, state, request in
                coordinatorDispatcher.processDownloadWithCredentials(for: book, withState: state, andRequest: request)
            },
            requestCredentials: { book in
                coordinatorCredentialPrompt.requestCredentialsAndStartDownload(for: book)
            }
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

        // BorrowOperation owns the complete borrow lifecycle. Closures
        // wrap the production OPDS fetch (with DownloadErrorRecovery
        // retries), the TPPAlertUtils error-presentation path, the
        // SignInModalPresenter, and the OIDC silent-reauth web session.
        // Tests substitute simpler stubs.
        let resolveAccountForBorrowOp: () -> TPPUserAccount = {
            userAccount ?? accountsManager.currentUserAccount
        }
        let opdsFeedServiceForBorrow = opdsFeedService
        let fetchBookClosure: (URL, Bool, Bool) async throws -> TPPBook = { url, resetCache, useToken in
            let recovery = DownloadErrorRecovery()
            return try await recovery.executeWithRetry(
                policy: DownloadErrorRecovery.RetryPolicy.borrowOperation
            ) {
                try await opdsFeedServiceForBorrow.fetchBook(
                    from: url,
                    resetCache: resetCache,
                    useToken: useToken
                )
            }
        }
        let presentBorrowErrorAlertClosure: @MainActor (String, String, NSError?, TPPProblemDocument?, TPPBook, (() -> Void)?) -> Void = { title, message, originalError, problemDoc, book, retryAction in
            let alert = TPPAlertUtils.alertWithDetails(
                title: title,
                message: message,
                error: originalError,
                problemDocument: problemDoc,
                bookIdentifier: book.identifier,
                bookTitle: book.title,
                retryAction: retryAction
            )
            TPPAlertUtils.presentFromViewControllerOrNil(
                alertController: alert,
                viewController: nil,
                animated: true,
                completion: nil
            )
        }
        let presentSignInModalClosure: @MainActor (@escaping () -> Void) -> Void = { completion in
            SignInModalPresenter.presentSignInModalForCurrentAccount(completion: completion)
        }
        let attemptOIDCReauthClosure: () async -> Bool = {
            await BorrowOperation.attemptOIDCSilentReauth(userAccount: resolveAccountForBorrowOp())
        }
        #if FEATURE_DRM_CONNECTOR
        self.borrowOperation = borrowOperation ?? BorrowOperation(
            bookRegistry: bookRegistry,
            downloadAnnouncementService: downloadAnnouncementService,
            errorActivityTracker: errorActivityTracker,
            debugSettings: debugSettings,
            userRetryTracker: userRetryTracker,
            userAccountProvider: resolveAccountForBorrowOp,
            adobeDRMService: .shared,
            fetchBook: fetchBookClosure,
            presentBorrowErrorAlert: presentBorrowErrorAlertClosure,
            presentSignInModal: presentSignInModalClosure,
            attemptOIDCReauth: attemptOIDCReauthClosure
        )
        #else
        self.borrowOperation = borrowOperation ?? BorrowOperation(
            bookRegistry: bookRegistry,
            downloadAnnouncementService: downloadAnnouncementService,
            errorActivityTracker: errorActivityTracker,
            debugSettings: debugSettings,
            userRetryTracker: userRetryTracker,
            userAccountProvider: resolveAccountForBorrowOp,
            fetchBook: fetchBookClosure,
            presentBorrowErrorAlert: presentBorrowErrorAlertClosure,
            presentSignInModal: presentSignInModalClosure,
            attemptOIDCReauth: attemptOIDCReauthClosure
        )
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
        self.rightsDispatcher.delegate = self
        self.startDispatcher.delegate = self
        self.taskLifecycleService.delegate = self
        self.cancellationHandler.delegate = self
        self.startCoordinator.delegate = self
        self.borrowOperation.delegate = self
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

        // PP-4114 follow-up: react to mid-flight reachability drops. PR #901
        // fixed the borrow path on BookCellModel; the parallel gap on this
        // side was that an in-progress URLSession download could sit in
        // flight for up to 60 s (per-request default) or longer (no resource
        // timeout set on the background session) before iOS surfaced
        // didCompleteWithError. Result: spinner forever, no alert. Mirror
        // the BookCellModel pattern — dropFirst() skips the
        // CurrentValueSubject's initial-value replay so we only act on real
        // transitions.
        self.bindReachability()
    }

    // MARK: - PP-4114: mid-flight network drop handling

    /// Subscribe to reachability transitions and fail any in-flight downloads
    /// when connectivity drops. Mirrors the BookCellModel.bindReachability()
    /// pattern from PR #901, but covers the in-progress-download case rather
    /// than the borrow-button case.
    ///
    /// `dropFirst()` skips the `CurrentValueSubject`'s replay of its initial
    /// `true` value so the suite of regression tests around fresh init don't
    /// trip the failure path on a fully-online sim. `.filter { !$0 }` only
    /// admits actual offline transitions.
    private func bindReachability() {
        reachabilityCancellable = reachability.connectivityPublisher
            .dropFirst()
            .filter { !$0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.failActiveDownloadsForNetworkLoss()
            }
    }

    /// For every active download, transition the book to `.downloadFailed`,
    /// surface a retryable alert, and cancel the URLSession task so iOS
    /// frees the connection. The cancelled completion that fires later is
    /// filtered by `DownloadTaskLifecycleService.handleTaskCompletionError`,
    /// so there's no double-alert.
    func failActiveDownloadsForNetworkLoss() {
        Task { [weak self] in
            guard let self else { return }
            // Snapshot active state before mutations — failDownloadWithAlert
            // empties the dicts asynchronously.
            let activePairs = await self.stateManager.taskIdentifierToBook.allPairs()
            let activeInfos = await self.stateManager.bookIdentifierToDownloadInfo.values()
            guard !activePairs.isEmpty else { return }

            // Filter to books that are *genuinely* in flight. `taskIdentifierToBook`
            // can retain stale entries from previously-completed downloads (the
            // success path doesn't always clear it), and without this guard
            // airplane-mode flips already-downloaded books to .downloadFailed —
            // the regression of PP-4114 reported on iPad. Only states that
            // represent an in-progress URLSession task warrant the failure
            // transition; everything else (e.g. .downloadSuccessful, .used)
            // must be left alone.
            let registry = self.bookRegistry
            let booksToFail: [TPPBook] = await MainActor.run {
                activePairs.compactMap { (_, book) -> TPPBook? in
                    let state = registry.state(for: book.identifier)
                    return (state == .downloading || state == .SAMLStarted) ? book : nil
                }
            }

            // Cancel pending URLSession tasks first so iOS stops trying to
            // drive them. Safe to cancel all active infos here — cancel is a
            // no-op for tasks the system has already finished.
            for info in activeInfos {
                info.downloadTask.cancel()
            }

            guard !booksToFail.isEmpty else { return }

            // Surface the alert + state transition for each book.
            let message = NSLocalizedString(
                "The connection was lost during the download.",
                comment: "Body for the network-loss alert that fires when reachability drops mid-download (PP-4114)."
            )
            await MainActor.run { [weak self] in
                guard let self else { return }
                for book in booksToFail {
                    self.failDownloadWithAlert(for: book, withMessage: message)
                }
            }
        }
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

    /// Legacy callback-based borrow entry. Delegated to
    /// DownloadStartCoordinator; preserved here as a 1-line forwarder
    /// because external callers (and DownloadStartDispatcherDelegate)
    /// reach it by name on MBDC.
    func startBorrow(for book: TPPBook, attemptDownload shouldAttemptDownload: Bool, borrowCompletion: (() -> Void)? = nil) {
        startCoordinator.startBorrow(for: book, attemptDownload: shouldAttemptDownload, borrowCompletion: borrowCompletion)
    }

    private func startDownloadIfAvailable(book: TPPBook) {
        startCoordinator.startDownloadIfAvailable(book: book)
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
        // PP-4114 follow-up: pre-flight reachability before kicking off a new
        // URLSession download task. The Retry button on the failure alert
        // routes through DownloadAlertPresenter.makeRetryAction → this method,
        // bypassing BookCellModel's pre-flight. Without this guard, tapping
        // Retry while still offline would spin the same way the original bug
        // did. Re-surface the same retryable alert (idempotent — registry
        // state is already .downloadFailed, the user just needs the prompt).
        if !reachability.isConnectedToNetwork() {
            failDownloadWithAlert(
                for: book,
                withMessage: Strings.MyDownloadCenter.noConnectionMessage
            )
            return
        }
        Task {
            await startDownloadAsync(for: book, withRequest: initedRequest)
        }
    }

    func startDownloadAsync(for book: TPPBook, withRequest initedRequest: URLRequest? = nil) async {
        await startCoordinator.startDownloadAsync(for: book, withRequest: initedRequest)
    }

    // processUnregisteredState moved to DownloadStartDispatcher
    // (called via startDispatcher.processUnregisteredState above).

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

    // processDownloadWithCredentials moved to DownloadStartDispatcher.

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

    // deferOverdriveFulfillment / processOverdriveDownload / handleOverdriveResponse
    // live on OverdriveDownloadHandler. The DownloadStartDispatcher's
    // processDownloadWithCredentials calls them directly when
    // FEATURE_OVERDRIVE is on and the book's distributor matches.
    // processRegularDownload moved to DownloadStartDispatcher.

    func logInvalidURLRequest(for book: TPPBook, withState state: TPPBookState, url: URL?, request: URLRequest?) {
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

            let model = SignInWebSheetViewModel(
                cookies: someCookies,
                request: mutableRequest,
                universalLinksURL: AppContainer.production().settings.universalLinksURL,
                autoPresentIfNeeded: true,
                loginCompletionHandler: nil,
                loginCancelHandler: loginCancelHandler,
                bookFoundHandler: bookFoundHandler,
                problemFoundHandler: problemFoundHandler
            )
            Task { @MainActor in
                SignInWebSheetPresenter.presentOnTop(model: model)
            }
        }
    }

    func handleSAMLStartedState(for book: TPPBook, withRequest request: URLRequest, cookies: [HTTPCookie]) {
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

    func clearAndSetCookies() {
        signInRedirectHandler.clearAndSetCookies()
    }

    @objc func cancelDownload(for identifier: String) {
        cancellationHandler.cancelDownload(for: identifier)
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

        let parseResult = await completionParser.parse(
            book: book,
            task: task,
            location: location,
            session: session
        )

        let rights: MyBooksDownloadInfo.MyBooksDownloadRightsManagement
        let mimeType: String
        let problemDoc: TPPProblemDocument?
        var failureRequiringAlert: Bool
        var failureError = task.error

        switch parseResult {
        case .followUpStarted:
            return
        case .failure(let parsedDoc, let parsedMime, let parsedRights):
            failureRequiringAlert = true
            problemDoc = parsedDoc
            mimeType = parsedMime
            rights = parsedRights
        case .proceed(let parsedRights, let parsedMime):
            failureRequiringAlert = false
            problemDoc = nil
            rights = parsedRights
            mimeType = parsedMime
        }

        if failureRequiringAlert {
            logBookDownloadFailure(book, reason: "Download Error", downloadTask: task, metadata: ["problemDocument": problemDoc?.dictionaryValue ?? "N/A", "mimeType": mimeType])
        } else {
            TPPProblemDocumentCacheManager.sharedInstance().clearCachedDoc(book.identifier)

            let dispatchResult = await rightsDispatcher.dispatch(
                book: book,
                task: task,
                location: location,
                session: session,
                rights: rights,
                failureError: failureError
            )
            failureRequiringAlert = dispatchResult.failureRequiringAlert
            failureError = dispatchResult.failureError
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

        // CRITICAL: Remove from bookIdentifierToDownloadInfo so retry works.
        // Also remove the taskIdentifierToBook entry so the airplane-mode
        // handler doesn't later misread the completed task as in-flight and
        // flip the (now-downloaded) book to .downloadFailed.
        await bookIdentifierToDownloadInfo.remove(book.identifier)
        await taskIdentifierToBook.remove(task.taskIdentifier)
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
        Task {
            let decision = await redirectPolicy.decide(
                taskIdentifier: task.taskIdentifier,
                originalScheme: task.originalRequest?.url?.scheme,
                newRequest: request
            )
            completionHandler(decision)
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
        await taskLifecycleService.handleTaskCompletionError(task: task, error: error)
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

        Task {
            await self.taskLifecycleService.registerStartedTask(
                task,
                book: book,
                maxConcurrentDownloads: self.maxConcurrentDownloads
            )
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

    /// Posts the legacy `.TPPMyBooksDownloadCenterDidChange` notification
    /// from the MBDC instance so subscribers that filter on `object: self`
    /// keep working. Used by services (e.g. DownloadTaskLifecycleService)
    /// that need to broadcast a state change without holding a back-
    /// reference to MBDC.
    func notifyDownloadCenterDidChange() {
        runOnMainAsync { [weak self] in
            guard let self else { return }
            NotificationCenter.default.post(name: .TPPMyBooksDownloadCenterDidChange, object: self)
        }
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

extension MyBooksDownloadCenter: RightsManagementDispatcherDelegate {}

extension MyBooksDownloadCenter: DownloadTaskLifecycleServiceDelegate {}

extension MyBooksDownloadCenter: DownloadCancellationHandlerDelegate {}

extension MyBooksDownloadCenter: DownloadStartCoordinatorDelegate {}

extension MyBooksDownloadCenter: BorrowOperationDelegate {}

// MARK: - DownloadStartDispatcherDelegate
//
// Every required surface already exists on MBDC: `bookRegistry` (Provider
// getter), `startBorrow`, `addDownloadTask`, `clearAndSetCookies`
// (delegator to signInRedirectHandler), `handleSAMLStartedState`
// (delegator to signInRedirectHandler), `failWithWifiRequired`,
// `logInvalidURLRequest` (kept on MBDC because it presents
// TPPCookiesWebViewController and is heavily UIKit-coupled).
extension MyBooksDownloadCenter: DownloadStartDispatcherDelegate {}

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
