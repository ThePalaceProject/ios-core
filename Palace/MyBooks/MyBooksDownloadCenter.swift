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
    private let alertPresenter: DownloadAlertPresenter
    private let throttlingService: DownloadThrottlingService

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
        alertPresenter: DownloadAlertPresenter? = nil,
        throttlingService: DownloadThrottlingService? = nil,
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
        // DownloadThrottlingService shares the same DownloadStateManager
        // MBDC owns so cap + suspend/resume policy stays coherent with the
        // rest of the download state machine. Tests can inject a mock state
        // manager + NotificationCenter to drive the network-monitor branch.
        self.throttlingService = throttlingService ?? DownloadThrottlingService(
            stateManager: stateManager
        )
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
        self.throttlingService.delegate = self

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

    @MainActor private var hasAttemptedAuthentication = false
    @MainActor private var isRequestingCredentials = false

    private func process(error: [String: Any]?, for book: TPPBook) {
        guard let errorType = error?["type"] as? String else {
            showGenericBorrowFailedAlert(for: book)
            return
        }

        let alertTitle = DisplayStrings.borrowFailed

        switch errorType {
        case TPPProblemDocument.TypeLoanAlreadyExists:
            let alertMessage = DisplayStrings.loanAlreadyExistsAlertMessage
            runOnMainAsync {
                self.publishAndAnnounceError(DownloadErrorInfo(bookId: book.identifier, title: alertTitle, message: alertMessage, kind: .borrow))
            }

        case TPPProblemDocument.TypeInvalidCredentials:
            Task { @MainActor [weak self] in
                guard let self else { return }

                guard !self.hasAttemptedAuthentication else {
                    self.showAlert(for: book, with: error, alertTitle: alertTitle)
                    return
                }

                guard !self.isRequestingCredentials else {
                    NSLog("Already requesting credentials, skipping re-authentication for: \(book.title)")
                    return
                }

                self.hasAttemptedAuthentication = true
                self.isRequestingCredentials = true

                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    self?.isRequestingCredentials = false
                }

                await self.handleInvalidCredentials(for: book)
            }
            return

        default:
            showAlert(for: book, with: error, alertTitle: alertTitle)
        }
    }

    @MainActor private func handleInvalidCredentials(for book: TPPBook) {
        reauthenticator.authenticateIfNeeded(userAccount, usingExistingCredentials: false) { [weak self] in
            guard let self = self else { return }

            Task { @MainActor [weak self] in
                self?.isRequestingCredentials = false

                if self?.userAccount.hasCredentials() == true {
                    self?.startDownload(for: book)
                } else {
                    NSLog("Authentication completed but no credentials present, user may have cancelled")
                }
            }
        }
    }

    private func showAlert(for book: TPPBook, with error: [String: Any]?, alertTitle: String) {
        var alertMessage = String(format: DisplayStrings.borrowFailedMessage, book.title)

        if let error = error {
            let problemDoc = TPPProblemDocument.fromDictionary(error)
            if let detail = problemDoc.detail {
                alertMessage = "\(alertMessage)\n\n\(detail)"
            }
        }

        // Legacy borrow errors from problem documents - offer retry for transient issues
        let retryAction: (() -> Void)? = {
            let operationId = "borrow-\(book.identifier)"
            guard self.userRetryTracker.canRetry(operationId: operationId) else { return nil }
            return { [weak self] in
                guard let self else { return }
                self.userRetryTracker.recordRetry(operationId: operationId)
                self.startBorrow(for: book, attemptDownload: true)
            }
        }()

        runOnMainAsync {
            self.publishAndAnnounceError(DownloadErrorInfo(bookId: book.identifier, title: alertTitle, message: alertMessage, kind: .borrow, retryAction: retryAction))
        }
    }

    private func showGenericBorrowFailedAlert(for book: TPPBook) {
        let formattedMessage = String(format: DisplayStrings.borrowFailedMessage, book.title)

        let retryAction: (() -> Void)? = {
            let operationId = "borrow-\(book.identifier)"
            guard self.userRetryTracker.canRetry(operationId: operationId) else { return nil }
            return { [weak self] in
                guard let self else { return }
                self.userRetryTracker.recordRetry(operationId: operationId)
                self.startBorrow(for: book, attemptDownload: true)
            }
        }()

        runOnMainAsync {
            self.publishAndAnnounceError(DownloadErrorInfo(bookId: book.identifier, title: DisplayStrings.borrowFailed, message: formattedMessage, kind: .borrow, retryAction: retryAction))
        }
    }

    @objc func startDownload(for book: TPPBook, withRequest initedRequest: URLRequest? = nil) {
        Task {
            await startDownloadAsync(for: book, withRequest: initedRequest)
        }
    }

    private func startDownloadAsync(for book: TPPBook, withRequest initedRequest: URLRequest? = nil) async {
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
            enqueuePending(book)
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
        Task { @MainActor [weak self] in
            guard let self else { return }

            guard !self.isRequestingCredentials else {
                NSLog("Already requesting credentials for authentication, skipping duplicate request for: \(book.title)")
                return
            }

            self.isRequestingCredentials = true

            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                self?.isRequestingCredentials = false
            }

            #if FEATURE_DRM_CONNECTOR
            if AdobeCertificate.defaultCertificate?.hasExpired ?? false {
                self.isRequestingCredentials = false
                TPPAlertUtils.presentFromViewControllerOrNil(alertController: TPPAlertUtils.expiredAdobeDRMAlert(), viewController: nil, animated: true, completion: nil)
                return
            }
            #endif

            SignInModalPresenter.presentSignInModalForCurrentAccount { [weak self] in
                guard let self = self else { return }

                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.isRequestingCredentials = false

                    if self.userAccount.hasCredentials() == true {
                        self.startDownload(for: book)
                    } else {
                        Log.info(#file, "Sign-in cancelled or failed for '\(book.title)' - cleaning up download state")
                        // Clean up download coordinator since we registered a start but won't proceed
                        await self.downloadCoordinator.registerCompletion(identifier: book.identifier)
                    }
                }
            }
        }
    }

    private var isWifiOnlyEnforced: Bool {
        self.settings.downloadOnlyOnWiFi && !self.reachability.isOnWiFi
    }

    private func failWithWifiRequired(for book: TPPBook) {
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

    private func deferOverdriveFulfillment(for book: TPPBook) {
        Log.warn(#file, "Overdrive audiobook '\(book.title)' routed to fulfillment but default acquisition is still borrow — deferring and syncing loans feed")
        Task { await downloadCoordinator.registerCompletion(identifier: book.identifier) }
        bookRegistry.sync()
        runOnMainAsync {
            self.publishAndAnnounceError(
                DownloadErrorInfo(
                    bookId: book.identifier,
                    title: DisplayStrings.borrowFailed,
                    message: DisplayStrings.loanAlreadyExistsAlertMessage,
                    kind: .borrow
                )
            )
        }
    }

    #if FEATURE_OVERDRIVE
    private func processOverdriveDownload(for book: TPPBook, withState state: TPPBookState) {
        if isWifiOnlyEnforced {
            failWithWifiRequired(for: book)
            return
        }

        guard let url = book.defaultAcquisition?.hrefURL else { return }

        let completion: ([AnyHashable: Any]?, Error?) -> Void = { [weak self] responseHeaders, error in
            self?.handleOverdriveResponse(for: book, url: url, withState: state, responseHeaders: responseHeaders, error: error)
        }

        if let token = userAccount.authToken {
            self.overdriveAPIExecutor.fulfillBook(urlString: url.absoluteString, authType: .token(token), completion: completion)
        } else if let username = userAccount.username, let pin = userAccount.PIN {
            self.overdriveAPIExecutor.fulfillBook(urlString: url.absoluteString, authType: .basic(username: username, pin: pin), completion: completion)
        }
    }
    #endif

    #if FEATURE_OVERDRIVE
    private func handleOverdriveResponse(
        for book: TPPBook,
        url: URL?,
        withState state: TPPBookState,
        responseHeaders: [AnyHashable: Any]?,
        error: Error?
    ) {
        let summaryWrongHeaders = "Overdrive audiobook fulfillment: wrong headers"
        let nA = "N/A"
        let responseHeadersKey = "responseHeaders"
        let acquisitionURLKey = "acquisitionURL"
        let bookKey = "book"
        let bookRegistryStateKey = "bookRegistryState"

        if let error = error {
            let summary = "Overdrive audiobook fulfillment error"

            TPPErrorLogger.logError(error, summary: summary, metadata: [
                responseHeadersKey: responseHeaders ?? nA,
                acquisitionURLKey: url?.absoluteString ?? nA,
                bookKey: book.loggableDictionary,
                bookRegistryStateKey: TPPBookStateHelper.stringValue(from: state)
            ])
            self.failDownloadWithAlert(for: book)
            return
        }

        let normalizedHeaders = responseHeaders?.mapKeys { String(describing: $0).lowercased() }
        let scopeKey = "x-overdrive-scope"
        let patronAuthorizationKey = "x-overdrive-patron-authorization"
        let locationKey = "location"

        guard let scope = normalizedHeaders?[scopeKey] as? String,
              let patronAuthorization = normalizedHeaders?[patronAuthorizationKey] as? String,
              let requestURLString = normalizedHeaders?[locationKey] as? String,
              let request = self.overdriveAPIExecutor.getManifestRequest(urlString: requestURLString, token: patronAuthorization, scope: scope)
        else {
            TPPErrorLogger.logError(withCode: .overdriveFulfillResponseParseFail, summary: summaryWrongHeaders, metadata: [
                responseHeadersKey: responseHeaders ?? nA,
                acquisitionURLKey: url?.absoluteString ?? nA,
                bookKey: book.loggableDictionary,
                bookRegistryStateKey: TPPBookStateHelper.stringValue(from: state)
            ])
            self.failDownloadWithAlert(for: book)
            return
        }

        self.addDownloadTask(with: request, book: book)
    }
    #endif

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
        bookRegistry.setState(.SAMLStarted, for: book.identifier)

        runOnMainAsync { [weak self] in
            var mutableRequest = request
            mutableRequest.cachePolicy = .reloadIgnoringCacheData

            let loginCompletionHandler: (URL, [HTTPCookie]) -> Void = { _, newCookies in
                guard let self = self else { return }

                self.userAccount.setCookies(newCookies)
                Log.info(#file, "SAML login completed successfully, got \(newCookies.count) cookies")

                self.bookRegistry.setState(.downloadNeeded, for: book.identifier)

                Task { @MainActor in
                    if let topVC = UIApplication.shared.mainKeyWindow?.rootViewController {
                        var current = topVC
                        while let presented = current.presentedViewController {
                            current = presented
                        }
                        if current is UINavigationController || current is TPPCookiesWebViewController {
                            current.presentingViewController?.dismiss(animated: true) {
                                // After dismissal, retry download with new cookies
                                self.startDownload(for: book)
                            }
                        }
                    }
                }
            }

            let model = TPPCookiesWebViewModel(
                cookies: cookies,
                request: mutableRequest,
                loginCompletionHandler: loginCompletionHandler,
                loginCancelHandler: {
                    self?.handleLoginCancellation(for: book)
                },
                bookFoundHandler: { [weak self] request, newCookies in
                    guard let self = self else { return }
                    Log.info(#file, "SAML book found with \(newCookies.count) fresh cookies")
                    self.handleBookFound(for: book, withRequest: request, cookies: newCookies)
                },
                problemFoundHandler: { [weak self] problemDocument in
                    Log.warn(#file, "SAML web view encountered problem: \(problemDocument?.type ?? "unknown")")
                    self?.handleProblem(for: book, problemDocument: problemDocument)
                },
                autoPresentIfNeeded: true  // Auto-present and auto-dismiss
            )

            let cookiesVC = TPPCookiesWebViewController(model: model)
            cookiesVC.loadViewIfNeeded()
            Log.info(#file, "SAML web view initialized for '\(book.title)'")
        }
    }

    private func handleLoginCancellation(for book: TPPBook) {
        bookRegistry.setState(.downloadNeeded, for: book.identifier)
        cancelDownload(for: book.identifier)
    }

    private func handleBookFound(for book: TPPBook, withRequest request: URLRequest?, cookies: [HTTPCookie]) {
        userAccount.setCookies(cookies)
        if let request = request {
            startDownload(for: book, withRequest: request)
        }
    }

    private func handleProblem(for book: TPPBook, problemDocument: TPPProblemDocument?) {
        let authDef = userAccount.authDefinition
        let hasCredentials = userAccount.hasCredentials()
        let currentState = bookRegistry.state(for: book.identifier)

        // CIRCUIT BREAKER: If already in .SAMLStarted, SAML web view failed - show sign-in without signing out
        if currentState == .SAMLStarted {
            Log.warn(#file, "SAML re-auth already attempted for '\(book.title)' - showing sign-in modal")

            Task { @MainActor in
                await self.bookIdentifierToDownloadInfo.remove(book.identifier)
                await self.downloadCoordinator.registerCompletion(identifier: book.identifier)

                bookRegistry.setState(.downloadFailed, for: book.identifier)

                // Show the problem document message if available (session expired, etc.)
                if let problemDoc = problemDocument {
                    let alert = TPPAlertUtils.alert(
                        title: problemDoc.title ?? Strings.Error.sessionExpiredTitle,
                        message: problemDoc.detail ?? Strings.Error.sessionExpiredMessage
                    )
                    TPPPresentationUtils.safelyPresent(alert)
                }

                guard !self.isRequestingCredentials else { return }

                self.isRequestingCredentials = true
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    self.isRequestingCredentials = false
                }

                // Show sign-in modal WITHOUT signing out - let user re-authenticate gracefully
                Log.info(#file, "Showing sign-in modal for session refresh")
                self.reauthenticator.authenticateIfNeeded(self.userAccount, usingExistingCredentials: false) { [weak self] in
                    Task { @MainActor in
                        self?.isRequestingCredentials = false
                        if self?.userAccount.hasCredentials() == true {
                            Log.info(#file, "Sign-in completed, retrying download")
                            self?.startDownload(for: book)
                        }
                    }
                }
            }
            return
        }

        // For SAML with expired cookies, try SAML flow once
        if authDef?.isSaml == true && hasCredentials {
            Log.info(#file, "SAML cookies expired - triggering SAML re-auth flow")

            Task {
                await self.bookIdentifierToDownloadInfo.remove(book.identifier)
                await self.downloadCoordinator.registerCompletion(identifier: book.identifier)

                await MainActor.run {
                    self.bookRegistry.setState(.SAMLStarted, for: book.identifier)
                    Log.info(#file, "Cleared download state, retrying with SAML re-auth")
                    self.startDownload(for: book)
                }
            }
            return
        }

        // For non-SAML or no credentials, set to downloadNeeded and show sign-in if needed
        bookRegistry.setState(.downloadNeeded, for: book.identifier)

        // Only show sign-in if truly no credentials
        if !hasCredentials {
            Task { @MainActor [weak self] in
                guard let self else { return }

                guard !self.isRequestingCredentials else {
                    NSLog("Already requesting credentials, skipping re-authentication in handleProblem for: \(book.title)")
                    return
                }

                self.isRequestingCredentials = true

                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    self?.isRequestingCredentials = false
                }

                self.reauthenticator.authenticateIfNeeded(self.userAccount, usingExistingCredentials: false) { [weak self] in
                    Task { @MainActor [weak self] in
                        self?.isRequestingCredentials = false

                        if self?.userAccount.hasCredentials() == true {
                            self?.startDownload(for: book)
                        } else {
                            NSLog("Authentication completed but no credentials present, user may have cancelled")
                        }
                    }
                }
            }
        } else {
            // Has credentials but download failed - log for debugging
            Log.warn(#file, "Download failed for authenticated user: \(book.identifier)")
        }
    }

    private func clearAndSetCookies() {
        let cookieStorage = self.session.configuration.httpCookieStorage
        cookieStorage?.cookies?.forEach { cookie in
            cookieStorage?.deleteCookie(cookie)
        }
        self.userAccount.cookies?.forEach { cookie in
            cookieStorage?.setCookie(cookie)
        }
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

    /// Silently re-downloads the .lcpa content file for an LCP audiobook that only
    /// has the .lcpl license. The book stays in downloadSuccessful state (playable
    /// via streaming) while the download runs in the background (PP-3704).
    func redownloadLCPContentFile(for book: TPPBook) {
        #if LCP
        guard LCPAudiobooks.canOpenBook(book) else { return }
        guard let licenseURL = lcpLicenseURL(forBookIdentifier: book.identifier) else {
            Log.warn(#file, "📥 [LCP RE-DOWNLOAD] No license file found for '\(book.title)' — skipping")
            return
        }
        guard let destURL = fileUrl(for: book.identifier) else { return }

        // Skip if .lcpa already exists (another re-download may have completed)
        if FileManager.default.fileExists(atPath: destURL.path) {
            Log.info(#file, "📥 [LCP RE-DOWNLOAD] .lcpa already exists for '\(book.title)' — skipping")
            return
        }

        Log.info(#file, "📥 [LCP RE-DOWNLOAD] Starting background .lcpa download for '\(book.title)'")

        let lcpService = LCPLibraryService()
        _ = lcpService.fulfill(licenseURL, progress: { _ in }) { localUrl, error in
            if let error {
                Log.error(#file, "📥 [LCP RE-DOWNLOAD] ❌ Failed for '\(book.title)': \(error.localizedDescription)")
                return
            }
            guard let localUrl else {
                Log.error(#file, "📥 [LCP RE-DOWNLOAD] ❌ No local URL returned for '\(book.title)'")
                return
            }

            do {
                let parentDir = destURL.deletingLastPathComponent()
                if !FileManager.default.fileExists(atPath: parentDir.path) {
                    try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
                }
                try FileManager.default.moveItem(at: localUrl, to: destURL)
                Log.info(#file, "📥 [LCP RE-DOWNLOAD] ✅ .lcpa stored for '\(book.title)' — local playback now available")
            } catch {
                Log.warn(#file, "📥 [LCP RE-DOWNLOAD] ⚠️ File move failed for '\(book.title)': \(error.localizedDescription) — streaming still available")
            }
        }
        #endif
    }

    /// Returns the .lcpl license URL for an LCP audiobook, if it exists on disk.
    private func lcpLicenseURL(forBookIdentifier identifier: String) -> URL? {
        guard let bookURL = fileUrl(for: identifier) else { return nil }
        let licenseURL = bookURL.deletingPathExtension().appendingPathExtension("lcpl")
        return FileManager.default.fileExists(atPath: licenseURL.path) ? licenseURL : nil
    }

    func deleteLocalContent(for identifier: String, account: String? = nil) {
        guard let book = bookRegistry.book(forIdentifier: identifier) else {
            Log.warn(#file, "Could not find book to delete local content \(identifier)")
            return
        }
        deleteLocalContent(forBook: book, account: account)
    }

    /// Delete local content using a book reference directly, without reading the
    /// book registry. Use this from callers that already hold the book (or that
    /// are running inside a registry write barrier — looking up the identifier
    /// through `bookRegistry` there would re-enter the barrier and trip Swift's
    /// exclusivity check, e.g. BookRegistrySync.sync()'s reconciliation pass
    /// deleting expired/returned downloads.
    func deleteLocalContent(forBook book: TPPBook, account: String? = nil) {
        let current_account: String? = account ?? accountsManager.currentAccountId
        guard let bookURL = fileUrl(for: book, account: current_account) else {
            Log.warn(#file, "Could not resolve fileUrl to delete local content \(book.identifier)")
            return
        }

        do {
            switch book.defaultBookContentType {
            case .epub, .pdf:
                if FileManager.default.fileExists(atPath: bookURL.path) {
                    try FileManager.default.removeItem(at: bookURL)
                } else {
                    Log.info(#file, "Content file already missing (nothing to delete): \(bookURL.lastPathComponent)")
                }
                #if LCP
                if book.defaultBookContentType == .pdf {
                    try LCPPDFs.deletePdfContent(url: bookURL)
                }
                #endif
            case .audiobook:
                try deleteLocalAudiobookContent(forAudiobook: book, at: bookURL)
            case .unsupported:
                Log.warn(#file, "Unsupported content type for deletion.")
            }
        } catch {
            Log.error(#file, "Failed to remove local content for book with identifier \(book.identifier): \(error.localizedDescription)")
        }
    }

    private func deleteLocalAudiobookContent(forAudiobook book: TPPBook, at bookURL: URL) throws {
        #if LCP
        let isLcpAudiobook = LCPAudiobooks.canOpenBook(book)
        #else
        let isLcpAudiobook = false
        #endif

        // LCP Audiobooks are a single binary file, without an easily loaded manifest.
        // So they skip this logic that deleted the local audio files, used by other
        // audiobook types.
        // TODO: Update LCP so we don't have to special case it here.
        if !isLcpAudiobook {
            let manifestData = try Data(contentsOf: bookURL)
            let manifest = try Manifest.customDecoder().decode(Manifest.self, from: manifestData)
            AudiobookFactory.audiobookClass(for: manifest).deleteLocalContent(manifest: manifest, bookIdentifier: book.identifier)
        }

        if FileManager.default.fileExists(atPath: bookURL.path) {
            try FileManager.default.removeItem(at: bookURL)
        } else {
            Log.info(#file, "Audiobook content already missing (nothing to delete): \(bookURL.lastPathComponent)")
        }
        Log.info(#file, "Successfully deleted audiobook manifest & content \(book.identifier)")
    }

    @objc func returnBook(withIdentifier identifier: String, completion: (() -> Void)? = nil) {
        guard let book = bookRegistry.book(forIdentifier: identifier) else {
            completion?()
            return
        }

        downloadAnnouncementService.announceReturnStarted(for: book)

        let state = bookRegistry.state(for: identifier)
        let downloaded = (state == .downloadSuccessful) || (state == .used)

        // Process Adobe Return
        #if FEATURE_DRM_CONNECTOR
        if let fulfillmentId = bookRegistry.fulfillmentId(forIdentifier: identifier),
           userAccount.authDefinition?.needsAuth == true {
            NSLog("Return attempt for book. userID: %@", userAccount.userID ?? "")
            self.adobeDRMService.returnLoan(fulfillmentId,
                                            userID: userAccount.userID,
                                            deviceID: userAccount.deviceID) { success, _ in
                if !success {
                    NSLog("Failed to return loan via NYPLAdept.")
                }
            }
        }
        #endif

        if book.revokeURL == nil {
            if downloaded {
                deleteLocalContent(for: identifier)
                purgeAllAudiobookCaches(force: true)
            }

            // Delete all server bookmarks before removing book to prevent
            // old bookmarks from reappearing when the book is re-borrowed
            TPPAnnotations.deleteAllBookmarks(forBook: book) { [weak self] in
                guard let self = self else {
                    completion?()
                    return
                }
                // Clear the deletion log since we're returning the book
                self.bookmarkDeletionLog.clearAllDeletions(forBook: identifier)
                self.bookRegistry.setState(.unregistered, for: identifier)
                self.bookRegistry.removeBook(forIdentifier: identifier)
                self.performPostReturnSyncThen {
                    self.downloadAnnouncementService.announceReturnSucceeded(for: book)
                    completion?()
                }
            }
        } else {
            bookRegistry.setProcessing(true, for: book.identifier)

            Task { [weak self] in
                guard let self, let revokeURL = book.revokeURL else {
                    await MainActor.run {
                        self?.bookRegistry.setProcessing(false, for: book.identifier)
                        self?.downloadAnnouncementService.announceReturnFailed(for: book)
                        completion?()
                    }
                    return
                }

                do {
                    let feed = try await self.opdsFeedService.fetchFeed(from: revokeURL)
                    await MainActor.run {
                        self.bookRegistry.setProcessing(false, for: book.identifier)
                    }

                    guard feed.entries.count == 1, let entry = feed.entries[0] as? TPPOPDSEntry else {
                        Log.error(#file, "Revoke response had \(feed.entries.count) entries, expected 1")
                        await MainActor.run {
                            self.downloadAnnouncementService.announceReturnFailed(for: book)
                            completion?()
                        }
                        return
                    }

                    guard let returnedBook = TPPBook(entry: entry) else {
                        Log.error(#file, "Failed to create book from revoke entry")
                        await MainActor.run {
                            self.downloadAnnouncementService.announceReturnFailed(for: book)
                            completion?()
                        }
                        return
                    }

                    if downloaded {
                        self.deleteLocalContent(for: identifier)
                        self.purgeAllAudiobookCaches(force: true)
                    }

                    TPPAnnotations.deleteAllBookmarks(forBook: book) {
                        self.bookmarkDeletionLog.clearAllDeletions(forBook: identifier)
                        self.bookRegistry.updateAndRemoveBook(returnedBook)
                        self.bookRegistry.setState(.unregistered, for: identifier)
                        self.performPostReturnSyncThen {
                            self.downloadAnnouncementService.announceReturnSucceeded(for: book)
                            completion?()
                        }
                    }

                } catch {
                    await MainActor.run {
                        self.bookRegistry.setProcessing(false, for: book.identifier)
                    }

                    // The OverDrive revoke endpoint returns XML that isn't a
                    // valid OPDS feed (e.g., a simple success response). The
                    // OPDS parser rejects it → PalaceError.parsing(.opdsFeedInvalid).
                    // The revoke likely SUCCEEDED server-side — clean up locally
                    // and sync to confirm, rather than showing an error.
                    if case .parsing(.opdsFeedInvalid) = error as? PalaceError {
                        Log.info(#file, "Revoke response was not a valid OPDS feed — treating as success and syncing to verify")
                        if downloaded {
                            self.deleteLocalContent(for: identifier)
                            self.purgeAllAudiobookCaches(force: true)
                        }
                        TPPAnnotations.deleteAllBookmarks(forBook: book) {
                            self.bookmarkDeletionLog.clearAllDeletions(forBook: identifier)
                            self.bookRegistry.setState(.unregistered, for: identifier)
                            self.bookRegistry.removeBook(forIdentifier: identifier)
                            self.performPostReturnSyncThen {
                                self.downloadAnnouncementService.announceReturnSucceeded(for: book)
                                completion?()
                            }
                        }
                        return
                    }

                    // Extract problem document from the typed error
                    let problemDoc = (error as NSError).problemDocument
                    let problemType = problemDoc?.type

                    Log.error(#file, "Return failed for '\(book.title)': \(error.localizedDescription), problemDoc type: \(problemType ?? "nil")")

                    // Loan already gone on server — clean up locally
                    let isLoanGone = problemType == TPPProblemDocument.TypeNoActiveLoan
                        || (problemDoc?.detail?.contains(TPPProblemDocument.DetailLoanTermLimitReached) == true)

                    if isLoanGone {
                        if downloaded {
                            self.deleteLocalContent(for: identifier)
                            self.purgeAllAudiobookCaches(force: true)
                        }
                        TPPAnnotations.deleteAllBookmarks(forBook: book) {
                            self.bookmarkDeletionLog.clearAllDeletions(forBook: identifier)
                            self.bookRegistry.setState(.unregistered, for: identifier)
                            self.bookRegistry.removeBook(forIdentifier: identifier)
                            self.performPostReturnSyncThen {
                                self.downloadAnnouncementService.announceReturnSucceeded(for: book)
                                completion?()
                            }
                        }
                        return
                    }

                    // Invalid credentials — re-authenticate and retry
                    if problemType == TPPProblemDocument.TypeInvalidCredentials {
                        Log.info(#file, "Invalid credentials on return — triggering re-auth")
                        await MainActor.run {
                            self.reauthenticator.authenticateIfNeeded(self.userAccount, usingExistingCredentials: false) { [weak self] in
                                guard let self else { return }
                                if self.userAccount.hasCredentials() {
                                    self.returnBook(withIdentifier: identifier, completion: completion)
                                } else {
                                    runOnMainAsync {
                                        self.downloadAnnouncementService.announceReturnFailed(for: book)
                                        completion?()
                                    }
                                }
                            }
                        }
                        return
                    }

                    // All other errors — show alert with problem document if available
                    await MainActor.run {
                        let serverDetail = problemDoc?.detail
                            ?? (error as NSError).userInfo["problemDocumentDetail"] as? String
                            ?? error.localizedDescription
                        let formattedMessage = String(format: Strings.MyDownloadCenter.returnFailedMessage, book.title)
                            + "\n\n" + serverDetail

                        let operationId = "return-\(identifier)"
                        let retryAction: (() -> Void)? = {
                            guard self.userRetryTracker.canRetry(operationId: operationId) else { return nil }
                            return { [weak self] in
                                guard let self else { return }
                                self.userRetryTracker.recordRetry(operationId: operationId)
                                self.returnBook(withIdentifier: identifier, completion: completion)
                            }
                        }()

                        let message = (retryAction == nil && !self.userRetryTracker.canRetry(operationId: operationId))
                            ? Strings.MyDownloadCenter.tryAgainLater
                            : formattedMessage

                        let alert = UIAlertController(title: Strings.MyDownloadCenter.returnFailed, message: message, preferredStyle: .alert)

                        if let retryAction = retryAction {
                            alert.addAction(UIAlertAction(title: Strings.MyDownloadCenter.retry, style: .default) { _ in retryAction() })
                        }

                        alert.addAction(UIAlertAction(title: NSLocalizedString("Remove from Device", comment: "Button to remove a book locally when server return fails"), style: .destructive) { [weak self] _ in
                            guard let self else { return }
                            if downloaded {
                                self.deleteLocalContent(for: identifier)
                                self.purgeAllAudiobookCaches(force: true)
                            }
                            self.bookmarkDeletionLog.clearAllDeletions(forBook: identifier)
                            self.bookRegistry.setState(.unregistered, for: identifier)
                            self.bookRegistry.removeBook(forIdentifier: identifier)
                            self.downloadAnnouncementService.announceReturnSucceeded(for: book)
                            completion?()
                        })

                        alert.addAction(UIAlertAction(title: Strings.Generic.cancel, style: .cancel))

                        if let doc = problemDoc {
                            TPPAlertUtils.setProblemDocument(controller: alert, document: doc, append: true)
                        }

                        TPPPresentationUtils.safelyPresent(alert)
                        self.downloadAnnouncementService.announceReturnFailed(for: book)
                        completion?()
                    }
                }
            }
        }
    }

    /// Performs a registry sync after a return. On failure, posts `TPPSyncFailed` so the
    /// Reservations tab can show the sync error banner; completion is always called so the return UI is dismissed.
    private func performPostReturnSyncThen(completion: @escaping () -> Void) {
        Task { [weak self] in
            do {
                // Use the injected `bookRegistry` rather than reaching into
                // AppContainer here, so unit tests can substitute a registry
                // double. `syncAsync` is defined on the concrete
                // `TPPBookRegistry` rather than the protocol; the cast is
                // safe in production where `bookRegistry` is always the
                // app-scoped instance constructed by AppContainer._cached.
                if let registry = self?.bookRegistry as? TPPBookRegistry {
                    _ = try await registry.syncAsync()
                }
            } catch {
                Log.error(#file, "Post-return sync failed: \(error.localizedDescription)")
                NotificationCenter.default.post(name: .TPPSyncFailed, object: nil, userInfo: nil)
            }
            runOnMainAsync(completion)
        }
    }
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
            runOnMainAsync {
                let hasCredentials = self.userAccount.hasCredentials()
                let loginRequired = self.userAccount.authDefinition?.needsAuth ?? false

                // A 401 from a third-party domain (e.g., biblioboard.com) should NOT
                // trigger re-authentication since our Palace credentials are not the issue
                let originalURL = task.originalRequest?.url
                let httpResponse = task.response as? HTTPURLResponse
                let reauthStrategy = self.userAccount.authDefinition?.reauthStrategy ?? .none

                if httpResponse?.indicatesAuthenticationNeedsRefresh(with: problemDoc, originalRequestURL: originalURL) == true {
                    // If user has credentials but got 401, this is a session/token expiry issue
                    if hasCredentials {
                        // Mark credentials as stale - preserves Adobe DRM activation
                        self.userAccount.markCredentialsStale()

                        switch reauthStrategy {
                        case .browser:
                            if self.userAccount.authDefinition?.isSaml == true {
                                // SAML cookies expired - need to re-auth via IDP
                                Log.info(#file, "SAML session expired - triggering SAML re-auth flow")

                                Task {
                                    await self.bookIdentifierToDownloadInfo.remove(book.identifier)
                                    await self.taskIdentifierToBook.remove(task.taskIdentifier)
                                    await self.downloadCoordinator.registerCompletion(identifier: book.identifier)

                                    await MainActor.run {
                                        self.bookRegistry.setState(.SAMLStarted, for: book.identifier)
                                        Log.info(#file, "Cleared failed download, now retrying with SAML re-auth")
                                        self.startDownload(for: book)
                                    }
                                }
                            } else {
                                // OIDC or other browser-based auth - present sign-in modal
                                Log.info(#file, "Browser-based auth expired - triggering re-auth via sign-in modal")

                                // Clean up download tracking before presenting modal
                                Task { [weak self] in
                                    guard let self else { return }
                                    await self.bookIdentifierToDownloadInfo.remove(book.identifier)
                                    await self.taskIdentifierToBook.remove(task.taskIdentifier)
                                    await self.downloadCoordinator.registerCompletion(identifier: book.identifier)

                                    await MainActor.run { [weak self] in
                                        guard let self else { return }
                                        self.bookRegistry.setState(.downloadNeeded, for: book.identifier)

                                        self.reauthenticator.authenticateIfNeeded(
                                            self.userAccount,
                                            usingExistingCredentials: false,
                                            authenticationCompletion: { [weak self] in
                                                Task { @MainActor [weak self] in
                                                    guard let self else { return }
                                                    guard self.userAccount.authState == .loggedIn else {
                                                        Log.info(#file, "Re-auth cancelled or incomplete, not retrying download for \(book.identifier)")
                                                        return
                                                    }
                                                    Log.info(#file, "Re-auth completed, retrying download for \(book.identifier)")
                                                    self.startDownload(for: book)
                                                }
                                            }
                                        )
                                    }
                                }
                            }
                            return

                        case .tokenRefresh:
                            // Token refresh was already attempted by TPPNetworkResponder
                            Log.warn(#file, "Token refresh failed for \(book.identifier) - showing error")

                        case .credentialPrompt, .none:
                            Log.warn(#file, "Auth failed for \(book.identifier) - showing error")
                        }
                    } else if loginRequired {
                        // No credentials - show sign-in
                        Log.info(#file, "No credentials - showing sign-in modal")
                        self.reauthenticator.authenticateIfNeeded(
                            self.userAccount,
                            usingExistingCredentials: false,
                            authenticationCompletion: { [weak self] in
                                Task { @MainActor [weak self] in
                                    guard let self else { return }
                                    // Only retry if user successfully authenticated; if they cancelled, bail out
                                    guard self.userAccount.hasCredentials() else {
                                        Log.info(#file, "Authentication cancelled, not retrying download for \(book.identifier)")
                                        return
                                    }
                                    Log.info(#file, "Authentication completed, retrying download for \(book.identifier)")
                                    self.startDownload(for: book)
                                }
                            }
                        )
                        return  // DON'T show error alert - sign-in is handling it
                    }
                } else if !hasCredentials && loginRequired {
                    // No auth error, but no credentials - show sign-in
                    Log.info(#file, "No credentials - showing sign-in modal")
                    self.reauthenticator.authenticateIfNeeded(
                        self.userAccount,
                        usingExistingCredentials: false,
                        authenticationCompletion: { [weak self] in
                            Task { @MainActor [weak self] in
                                guard let self else { return }
                                // Only retry if user successfully authenticated; if they cancelled, bail out
                                guard self.userAccount.hasCredentials() else {
                                    Log.info(#file, "Authentication cancelled, not retrying download for \(book.identifier)")
                                    return
                                }
                                self.startDownload(for: book)
                            }
                        }
                    )
                    return
                }

                // Check if the error is "No active loan" - attempt to re-borrow
                if let problemDoc = problemDoc, problemDoc.type == TPPProblemDocument.TypeNoActiveLoan {

                    // PP-3716: When browser-based auth expires, the server may return
                    // "no-active-loan" (400) instead of 401. Treat as session expiry.
                    if reauthStrategy == .browser && hasCredentials {
                        self.userAccount.markCredentialsStale()

                        if self.userAccount.authDefinition?.isSaml == true {
                            Log.info(#file, "SAML: 'no-active-loan' treating as session expiry (PP-3716)")
                            Task {
                                await self.bookIdentifierToDownloadInfo.remove(book.identifier)
                                await self.taskIdentifierToBook.remove(task.taskIdentifier)
                                await self.downloadCoordinator.registerCompletion(identifier: book.identifier)

                                await MainActor.run {
                                    self.bookRegistry.setState(.SAMLStarted, for: book.identifier)
                                    Log.info(#file, "SAML: Cleared failed download, retrying with SAML re-auth for \(book.identifier)")
                                    self.startDownload(for: book)
                                }
                            }
                        } else {
                            Log.info(#file, "Browser auth: 'no-active-loan' treating as session expiry")
                            Task { [weak self] in
                                guard let self else { return }
                                await self.bookIdentifierToDownloadInfo.remove(book.identifier)
                                await self.taskIdentifierToBook.remove(task.taskIdentifier)
                                await self.downloadCoordinator.registerCompletion(identifier: book.identifier)

                                await MainActor.run { [weak self] in
                                    guard let self else { return }
                                    self.bookRegistry.setState(.downloadNeeded, for: book.identifier)

                                    self.reauthenticator.authenticateIfNeeded(
                                        self.userAccount,
                                        usingExistingCredentials: false,
                                        authenticationCompletion: { [weak self] in
                                            Task { @MainActor [weak self] in
                                                guard let self else { return }
                                                guard self.userAccount.authState == .loggedIn else {
                                                    Log.info(#file, "Re-auth cancelled or incomplete, not retrying download for \(book.identifier)")
                                                    return
                                                }
                                                Log.info(#file, "Re-auth completed, retrying download for \(book.identifier)")
                                                self.startDownload(for: book)
                                            }
                                        }
                                    )
                                }
                            }
                        }
                        return
                    }

                    Log.info(#file, "Download failed: No active loan for \(book.identifier). Auto-borrowing...")

                    // Update state to unregistered so borrow logic will work
                    self.bookRegistry.setState(.unregistered, for: book.identifier)

                    // Try to borrow the book (which will auto-download if successful)
                    self.startBorrow(for: book, attemptDownload: true) { [weak self] in
                        guard let self else { return }

                        // If borrow completed, check if download started
                        let newState = self.bookRegistry.state(for: book.identifier)
                        Log.debug(#file, "Auto-borrow after 'no active loan' completed, new state: \(newState)")

                        if newState != .downloading && newState != .downloadSuccessful {
                            // Borrow failed or didn't result in download
                            Log.warn(#file, "Auto-borrow failed for \(book.identifier), showing error to user")
                            self.alertForProblemDocument(problemDoc, error: failureError, book: book)
                        } else {
                            Log.info(#file, "Auto-borrow successful for \(book.identifier), download started")
                        }
                    }
                    // Don't call alertForProblemDocument here - wait for borrow completion
                    return
                }

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

    private func addDownloadTask(with request: URLRequest, book: TPPBook) {
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
    private func enqueuePending(_ book: TPPBook) {
        // CRITICAL UI FIX: Update book state so button shows "Downloading" feedback
        // Otherwise button appears unresponsive when hitting queue limit
        bookRegistry.setState(.downloading, for: book.identifier)

        Task {
            await downloadCoordinator.enqueuePending(book)
            let queueSize = await downloadCoordinator.queueCount
            Log.debug(#file, "📋 Enqueued '\(book.title)' for download, queue size: \(queueSize)")

            // Notify UI to refresh
            runOnMainAsync {
                NotificationCenter.default.post(name: .TPPMyBooksDownloadCenterDidChange, object: self)
            }
        }
    }

    func schedulePendingStartsIfPossible() {
        Task {
            await schedulePendingStartsAsync()
        }
    }

    func schedulePendingStartsAsync() async {
        let activeCount = await downloadCoordinator.activeCount
        let capacity = maxConcurrentDownloads - activeCount

        guard capacity > 0 else { return }

        let toStart = await downloadCoordinator.dequeuePending(capacity: capacity)
        guard !toStart.isEmpty else { return }

        let queueRemaining = await downloadCoordinator.queueCount
        Log.info(#file, "📋 Starting \(toStart.count) pending downloads (capacity: \(capacity), queue remaining: \(queueRemaining))")

        for book in toStart {
            await startDownloadAsync(for: book, withRequest: nil)
        }
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
        let lcpService = LCPLibraryService()
        let licenseUrl = fileUrl.deletingPathExtension().appendingPathExtension(lcpService.licenseExtension)

        do {
            _ = try FileManager.default.replaceItemAt(licenseUrl, withItemAt: fileUrl)
        } catch {
            TPPErrorLogger.logError(error, summary: "Error renaming LCP license file", metadata: [
                "fileUrl": fileUrl.absoluteString,
                "licenseUrl": licenseUrl.absoluteString,
                "book": book.loggableDictionary
            ])
            failDownloadWithAlert(for: book, withMessage: error.localizedDescription)
            return
        }

        let lcpProgress: (Double) -> Void = { [weak self] progressValue in
            guard let self = self else { return }
            Task {
                if let info = await self.downloadInfoAsync(forBookIdentifier: book.identifier)?.withDownloadProgress(progressValue) {
                    await self.bookIdentifierToDownloadInfo.set(book.identifier, value: info)
                }
                // Publish to progress publisher so UI updates (HalfSheet, BookCell, etc.)
                await MainActor.run {
                    self.downloadProgressPublisher.send((book.identifier, progressValue))
                }
                self.broadcastUpdate()
            }
        }

        let lcpCompletion: (URL?, Error?) -> Void = { [weak self] localUrl, error in
            guard let self = self else { return }
            if let error = error {
                let summary = "\(String(describing: book.distributor)) LCP license fulfillment error"
                TPPErrorLogger.logError(error, summary: summary, metadata: [
                    "book": book.loggableDictionary,
                    "licenseURL": licenseUrl.absoluteString,
                    "localURL": localUrl?.absoluteString ?? "N/A"
                ])
                let errorMessage = "Fulfilment Error: \(error.localizedDescription)"
                self.failDownloadWithAlert(for: book, withMessage: errorMessage)
                return
            }
            guard let localUrl = localUrl,
                  let license = TPPLCPLicense(url: licenseUrl)
            else {
                let errorMessage = "Error with LCP license fulfillment: \(localUrl?.absoluteString ?? "")"
                self.failDownloadWithAlert(for: book, withMessage: errorMessage)
                return
            }
            self.bookRegistry.setFulfillmentId(license.identifier, for: book.identifier)

            if !self.backgroundDownloadHandler.replaceBook(book, withFileAtURL: localUrl, forDownloadTask: downloadTask) {
                if book.defaultBookContentType == .audiobook {
                    Log.warn(#file, "Content storage failed for audiobook, but streaming still available")
                } else {
                    let errorMessage = "Error replacing content file with file \(localUrl.absoluteString)"
                    self.failDownloadWithAlert(for: book, withMessage: errorMessage)
                    return
                }
            } else {
                if book.defaultBookContentType == .audiobook {
                    Log.info(#file, "Audiobook content stored successfully, offline playback now available")
                }
            }

            Task {
                if book.defaultBookContentType == .pdf,
                   let bookURL = self.fileUrl(for: book.identifier) {
                    self.bookRegistry.setState(.downloading, for: book.identifier)
                    _ = try? await LCPPDFs(url: bookURL)?.extract(url: bookURL)
                    self.markDownloadSuccessful(for: book)
                }
            }
        }

        let fulfillmentDownloadTask = lcpService.fulfill(licenseUrl, progress: lcpProgress, completion: lcpCompletion)

        if book.defaultBookContentType == .audiobook {
            Log.info(#file, "LCP audiobook license fulfilled, ready for streaming: \(book.identifier)")

            if let license = TPPLCPLicense(url: licenseUrl) {
                self.bookRegistry.setFulfillmentId(license.identifier, for: book.identifier)
            } else {
                Log.error(#file, "🔑 ❌ Failed to read license for fulfillment ID")
            }

            self.copyLicenseForStreaming(book: book, sourceLicenseUrl: licenseUrl)
            self.markDownloadSuccessful(for: book)

            runOnMainAsync {
                self.broadcastUpdate()
            }
        }

        if let fulfillmentDownloadTask = fulfillmentDownloadTask {
            let downloadInfo = MyBooksDownloadInfo(downloadProgress: 0.0, downloadTask: fulfillmentDownloadTask, rightsManagement: .none)
            Task {
                await self.bookIdentifierToDownloadInfo.set(book.identifier, value: downloadInfo)
            }
        }
        #endif
    }

    /// Copies the LCP license file to the content directory for streaming support
    /// while preserving the existing fulfillment flow
    private func copyLicenseForStreaming(book: TPPBook, sourceLicenseUrl: URL) {
        #if LCP
        Log.info(#file, "🎵 Starting license copy for streaming: \(book.identifier)")

        guard let finalContentURL = self.fileUrl(for: book.identifier) else {
            Log.error(#file, "🎵 ❌ Unable to determine final content URL for streaming license copy")
            return
        }

        let streamingLicenseUrl = finalContentURL.deletingPathExtension().appendingPathExtension("lcpl")
        Log.info(#file, "🎵 Copying license FROM: \(sourceLicenseUrl.path)")
        Log.info(#file, "🎵 Copying license TO: \(streamingLicenseUrl.path)")

        do {
            try? FileManager.default.removeItem(at: streamingLicenseUrl)
            try FileManager.default.copyItem(at: sourceLicenseUrl, to: streamingLicenseUrl)
        } catch {
            TPPErrorLogger.logError(error, summary: "Failed to copy LCP license for streaming", metadata: [
                "book": book.loggableDictionary,
                "sourceLicenseUrl": sourceLicenseUrl.absoluteString,
                "targetLicenseUrl": streamingLicenseUrl.absoluteString
            ])
        }
        #endif
    }

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
        reset(account: libraryID)
    }

    func reset(account: String) {
        if accountsManager.currentAccountId == account {
            reset()
        } else {
            deleteAudiobooks(forAccount: account)
            do {
                if let url = contentDirectoryURL(account) {
                    try FileManager.default.removeItem(at: url)
                }
            } catch {
                // Handle error, if needed
            }
        }
    }

    func reset() {
        guard let currentAccountId = accountsManager.currentAccountId else {
            return
        }

        deleteAudiobooks(forAccount: currentAccountId)

        Task {
            let allInfo = await bookIdentifierToDownloadInfo.values()
            for info in allInfo {
                info.downloadTask.cancel(byProducingResumeData: { _ in })
            }

            await bookIdentifierToDownloadInfo.removeAll()
            await taskIdentifierToBook.removeAll()
            await downloadCoordinator.reset()
        }

        bookIdentifierOfBookToRemove = nil

        do {
            if let url = contentDirectoryURL(currentAccountId) {
                try FileManager.default.removeItem(at: url)
            }
        } catch {
            // Handle error, if needed
        }

        broadcastUpdate()
    }

    func deleteAudiobooks(forAccount account: String) {
        bookRegistry.with(account: account) { registry in
            let books = registry.allBooks
            for book in books {
                if book.defaultBookContentType == .audiobook {
                    deleteLocalContent(for: book.identifier, account: account)
                }
            }
        }
    }

    // Purge cached audio fragments (e.g., streaming or decrypted chunks) from the Caches directory.
    // If `force` is false, purges only when there are no active audiobooks in the registry.
    func purgeAllAudiobookCaches(force: Bool = false) {
        if !force && hasActiveAudiobooks() { return }
        let fm = FileManager.default
        guard let cachesDir = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let audioExtensions: Set<String> = ["mp3", "m4a", "mp4", "aac", "oga", "wav"]
        if let contents = try? fm.contentsOfDirectory(at: cachesDir, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: [.skipsHiddenFiles]) {
            for url in contents {
                do {
                    let rv = try url.resourceValues(forKeys: [.isDirectoryKey])
                    if rv.isDirectory == true { continue }
                    if audioExtensions.contains(url.pathExtension.lowercased()) {
                        try? fm.removeItem(at: url)
                    }
                } catch {
                    // ignore
                }
            }
        }
    }

    private func hasActiveAudiobooks() -> Bool {
        let matchingStates: [TPPBookState] = [ .downloadNeeded, .downloading, .downloadSuccessful, .used ]
        var hasActive = false
        let accountId = accountsManager.currentAccountId ?? ""
        bookRegistry.with(account: accountId) { registry in
            let audiobooks = registry.myBooks.filter { $0.defaultBookContentType == .audiobook }
            hasActive = audiobooks.contains { matchingStates.contains(registry.state(for: $0.identifier)) }
        }
        return hasActive
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
