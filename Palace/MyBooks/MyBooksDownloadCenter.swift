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
#endif

/// Modern Swift actor for coordinating downloads - NO LOCKS!
actor DownloadCoordinator {
    private var activeDownloadIdentifiers: Set<String> = []
    private var startTimes: [String: Date] = [:]
    private let minimumStartDelay: TimeInterval = 0.3
    private var pendingQueue: [TPPBook] = []
    private var downloadInfoCache: [String: MyBooksDownloadInfo] = [:]
    private var redirectAttempts: [Int: Int] = [:]

    var activeCount: Int {
        activeDownloadIdentifiers.count
    }

    var queueCount: Int {
        pendingQueue.count
    }

    func canStartDownload(maxConcurrent: Int) -> Bool {
        activeDownloadIdentifiers.count < maxConcurrent
    }

    func shouldThrottleStart() async -> TimeInterval {
        guard let lastStartTime = startTimes.values.max() else {
            return 0
        }

        let timeSinceLastStart = Date().timeIntervalSince(lastStartTime)
        if timeSinceLastStart < minimumStartDelay {
            return minimumStartDelay - timeSinceLastStart
        }
        return 0
    }

    func registerStart(identifier: String) {
        activeDownloadIdentifiers.insert(identifier)
        startTimes[identifier] = Date()
    }

    func registerCompletion(identifier: String) {
        activeDownloadIdentifiers.remove(identifier)
        startTimes.removeValue(forKey: identifier)
    }

    func enqueuePending(_ book: TPPBook) {
        if !pendingQueue.contains(where: { $0.identifier == book.identifier }) {
            pendingQueue.append(book)
        }
    }

    func dequeuePending(capacity: Int) -> [TPPBook] {
        guard capacity > 0, !pendingQueue.isEmpty else { return [] }

        let toStart = Array(pendingQueue.prefix(capacity))
        pendingQueue.removeFirst(min(capacity, pendingQueue.count))
        return toStart
    }

    func cacheDownloadInfo(_ info: MyBooksDownloadInfo, for identifier: String) {
        downloadInfoCache[identifier] = info
    }

    func getCachedDownloadInfo(for identifier: String) -> MyBooksDownloadInfo? {
        downloadInfoCache[identifier]
    }

    func removeCachedDownloadInfo(for identifier: String) {
        downloadInfoCache.removeValue(forKey: identifier)
    }

    func getRedirectAttempts(for taskID: Int) -> Int {
        redirectAttempts[taskID] ?? 0
    }

    func incrementRedirectAttempts(for taskID: Int) {
        redirectAttempts[taskID] = (redirectAttempts[taskID] ?? 0) + 1
    }

    func clearRedirectAttempts(for taskID: Int) {
        redirectAttempts.removeValue(forKey: taskID)
    }

    func reset() {
        activeDownloadIdentifiers.removeAll()
        startTimes.removeAll()
        pendingQueue.removeAll()
        downloadInfoCache.removeAll()
        redirectAttempts.removeAll()
    }
}

/// Info published when a download or borrow error occurs.
/// Includes retry support so SwiftUI views can offer a "Retry" button.
struct DownloadErrorInfo {
    let bookId: String
    let title: String
    let message: String
    let retryAction: (() -> Void)?

    /// Convenience for non-retryable errors.
    init(bookId: String, title: String, message: String) {
        self.bookId = bookId
        self.title = title
        self.message = message
        self.retryAction = nil
    }

    /// Full initializer with optional retry action.
    init(bookId: String, title: String, message: String, retryAction: (() -> Void)?) {
        self.bookId = bookId
        self.title = title
        self.message = message
        self.retryAction = retryAction
    }
}

// MARK: - MyBooksDownloadCenter (Facade)

@objc class MyBooksDownloadCenter: NSObject, URLSessionDelegate {
    typealias DisplayStrings = Strings.MyDownloadCenter

    @objc static let shared = MyBooksDownloadCenter()

    // MARK: - Public Dependencies

    public var userAccount: TPPUserAccount
    var bookRegistry: TPPBookRegistryProvider

    // MARK: - Extracted Components

    let stateManager = DownloadStateManager()
    let progressReporter: DownloadProgressReporter
    let backgroundHandler: BackgroundDownloadHandler
    let tokenInterceptor: TokenRefreshInterceptor

    // MARK: - Legacy Forwarding Properties

    /// Public publishers forwarded from progressReporter for backward compatibility
    var downloadProgressPublisher: PassthroughSubject<(String, Double), Never> {
        progressReporter.downloadProgressPublisher
    }

    var downloadErrorPublisher: PassthroughSubject<DownloadErrorInfo, Never> {
        progressReporter.downloadErrorPublisher
    }

    // MARK: - Internal State

    private var bookIdentifierOfBookToRemove: String?
    private var session: URLSession!
    private let downloadExecutor = SerialExecutor()

    // MARK: - Convenience Accessors (delegate protocol conformance)

    var bookIdentifierToDownloadInfo: SafeDictionary<String, MyBooksDownloadInfo> {
        stateManager.bookIdentifierToDownloadInfo
    }
    var taskIdentifierToBook: SafeDictionary<Int, TPPBook> {
        stateManager.taskIdentifierToBook
    }
    var downloadCoordinator: DownloadCoordinator {
        stateManager.downloadCoordinator
    }
    var maxConcurrentDownloads: Int {
        get { stateManager.maxConcurrentDownloads }
        set { stateManager.maxConcurrentDownloads = newValue }
    }

    // MARK: - Init

    init(
        userAccount: TPPUserAccount = TPPUserAccount.sharedAccount(),
        reauthenticator: Reauthenticator = TPPReauthenticator(),
        bookRegistry: TPPBookRegistryProvider = TPPBookRegistry.shared,
        accessibilityAnnouncements: TPPAccessibilityAnnouncementCenter = TPPAccessibilityAnnouncementCenter()
    ) {
        self.userAccount = userAccount
        self.bookRegistry = bookRegistry
        self.progressReporter = DownloadProgressReporter(accessibilityAnnouncements: accessibilityAnnouncements)
        self.backgroundHandler = BackgroundDownloadHandler()
        self.tokenInterceptor = TokenRefreshInterceptor(reauthenticator: reauthenticator)

        super.init()

        // Wire up delegate references
        self.progressReporter.notificationSender = self
        self.backgroundHandler.delegate = self
        self.tokenInterceptor.delegate = self

        #if FEATURE_DRM_CONNECTOR
        if AdobeCertificate.isDRMAvailable {
            AdobeDRMService.shared.setDelegate(self)
        }
        #else
        NSLog("Cannot import ADEPT")
        #endif

        let backgroundIdentifier = (Bundle.main.bundleIdentifier ?? "") + ".downloadCenterBackgroundIdentifier"
        let configuration = URLSessionConfiguration.background(withIdentifier: backgroundIdentifier)
        configuration.isDiscretionary = false
        configuration.waitsForConnectivity = false
        if #available(iOS 13.0, *) {
            configuration.allowsConstrainedNetworkAccess = true
        }
        self.session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)

        setupNetworkMonitoring()
    }

    deinit {
        session?.invalidateAndCancel()
    }

    // MARK: - Accessibility Forwarding

    func announceDownloadStarted(for book: TPPBook) { progressReporter.announceDownloadStarted(for: book) }
    func announceDownloadProgress(for book: TPPBook, progress: Double) { progressReporter.announceDownloadProgress(for: book, progress: progress) }
    func announceDownloadCompleted(for book: TPPBook) { progressReporter.announceDownloadCompleted(for: book) }
    func announceDownloadFailed(for book: TPPBook) { progressReporter.announceDownloadFailed(for: book) }
    func announceBorrowStarted(for book: TPPBook) { progressReporter.announceBorrowStarted(for: book) }
    func announceBorrowSucceeded(for book: TPPBook) { progressReporter.announceBorrowSucceeded(for: book) }
    func announceBorrowFailed(for book: TPPBook) { progressReporter.announceBorrowFailed(for: book) }
    func announceReturnStarted(for book: TPPBook) { progressReporter.announceReturnStarted(for: book) }
    func announceReturnSucceeded(for book: TPPBook) { progressReporter.announceReturnSucceeded(for: book) }
    func announceReturnFailed(for book: TPPBook) { progressReporter.announceReturnFailed(for: book) }

    // MARK: - Progress / Error Forwarding

    private func publishAndAnnounceError(_ errorInfo: DownloadErrorInfo) {
        progressReporter.publishAndAnnounceError(errorInfo)
    }

    private func markDownloadSuccessful(for book: TPPBook) {
        bookRegistry.setState(.downloadSuccessful, for: book.identifier)
        announceDownloadCompleted(for: book)
    }

    func broadcastUpdate() {
        progressReporter.broadcastUpdate()
    }

    // MARK: - Download Info (Public API)

    func downloadInfoAsync(forBookIdentifier bookIdentifier: String) async -> MyBooksDownloadInfo? {
        await stateManager.downloadInfoAsync(forBookIdentifier: bookIdentifier)
    }

    @objc func downloadInfo(forBookIdentifier bookIdentifier: String) -> MyBooksDownloadInfo? {
        stateManager.downloadInfo(forBookIdentifier: bookIdentifier)
    }

    @objc func downloadProgress(for bookIdentifier: String) -> Double {
        stateManager.downloadProgress(for: bookIdentifier)
    }

    // MARK: - Borrow

    func startBorrow(for book: TPPBook, attemptDownload shouldAttemptDownload: Bool, borrowCompletion: (() -> Void)? = nil) {
        Task {
            do {
                _ = try await borrowAsync(book, attemptDownload: shouldAttemptDownload)

                let newState = bookRegistry.state(for: book.identifier)
                if newState == .holding {
                    await downloadCoordinator.registerCompletion(identifier: book.identifier)
                    let remainingCount = await downloadCoordinator.activeCount
                    Log.info(#file, "Borrow resulted in hold for '\(book.title)', released slot, remaining active: \(remainingCount)")
                    schedulePendingStartsIfPossible()
                }

                borrowCompletion?()
            } catch {
                Log.error(#file, "Borrow failed: \(error.localizedDescription)")
                await downloadCoordinator.registerCompletion(identifier: book.identifier)
                let remainingCount = await downloadCoordinator.activeCount
                Log.info(#file, "Borrow failed for '\(book.title)', released slot, remaining active: \(remainingCount)")
                schedulePendingStartsIfPossible()
                borrowCompletion?()
            }
        }
    }

    // MARK: - Download Start

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

        Log.info(#file, "Starting download for '\(book.title)' - state: \(state), hasCredentials: \(userAccount.hasCredentials()), loginRequired: \(loginRequired)")

        await ErrorActivityTracker.shared.log("Starting download for '\(book.title)'", category: .download)

        switch state {
        case .unregistered:
            state = processUnregisteredState(for: book, location: location, loginRequired: loginRequired)
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
            Log.info(#file, "Throttling download start for '\(book.title)' by \(String(format: "%.1f", throttleDelay))s")
            try? await Task.sleep(nanoseconds: UInt64(throttleDelay * 1_000_000_000))
        }

        await downloadCoordinator.registerStart(identifier: book.identifier)

        if loginRequired {
            Log.info(#file, "Login required for '\(book.title)', requesting credentials")
            Task { @MainActor in
                self.tokenInterceptor.requestCredentialsAndStartDownload(for: book, downloadCoordinator: self.downloadCoordinator)
            }
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

    private func startDownloadIfAvailable(book: TPPBook) {
        let downloadAction = { [weak self] in
            self?.startDownload(for: book)
        }

        book.defaultAcquisition?.availability.matchUnavailable(
            nil,
            limited: { _ in downloadAction() },
            unlimited: { _ in downloadAction() },
            reserved: nil,
            ready: { _ in downloadAction() })
    }

    // MARK: - Download Processing

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
                processOverdriveDownload(for: book, withState: state)
                return
            }
            #endif
            processRegularDownload(for: book, withState: state, andRequest: initedRequest)
        }
    }

    #if FEATURE_OVERDRIVE
    private func processOverdriveDownload(for book: TPPBook, withState state: TPPBookState) {
        guard let url = book.defaultAcquisition?.hrefURL else { return }

        let completion: ([AnyHashable: Any]?, Error?) -> Void = { [weak self] responseHeaders, error in
            self?.handleOverdriveResponse(for: book, url: url, withState: state, responseHeaders: responseHeaders, error: error)
        }

        if let token = userAccount.authToken {
            OverdriveAPIExecutor.shared.fulfillBook(urlString: url.absoluteString, authType: .token(token), completion: completion)
        } else if let username = userAccount.username, let pin = userAccount.PIN {
            OverdriveAPIExecutor.shared.fulfillBook(urlString: url.absoluteString, authType: .basic(username: username, pin: pin), completion: completion)
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
              let request = OverdriveAPIExecutor.shared.getManifestRequest(urlString: requestURLString, token: patronAuthorization, scope: scope)
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
        let currentBook = bookRegistry.book(forIdentifier: book.identifier) ?? book

        if currentBook.isExpired && currentBook.defaultAcquisitionIfBorrow != nil {
            Log.warn(#file, "Book \(book.identifier) is expired. Attempting to re-borrow before download.")
            bookRegistry.setState(.unregistered, for: book.identifier)
            startBorrow(for: currentBook, attemptDownload: true, borrowCompletion: nil)
            return
        }

        if state == .downloadNeeded && currentBook.defaultAcquisitionIfBorrow != nil {
            Log.info(#file, "Book \(book.identifier) is downloadNeeded with borrow acquisition - auto-borrowing before download")
            bookRegistry.setState(.unregistered, for: book.identifier)
            startBorrow(for: currentBook, attemptDownload: true) { [weak self] in
                guard let self else { return }
                let newState = self.bookRegistry.state(for: book.identifier)
                Log.debug(#file, "Auto-borrow completed for \(book.identifier), new state: \(newState)")
                if newState != .downloading && newState != .downloadSuccessful && newState != .downloadNeeded {
                    Log.warn(#file, "Auto-borrow completed but book is not downloadable, state: \(newState)")
                }
            }
            return
        }

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

        MemoryPressureMonitor.shared.reclaimDiskSpaceIfNeeded(minimumFreeMegabytes: 512)
        enforceContentDiskBudgetIfNeeded(adding: 0)

        if state == .SAMLStarted, let cookies = userAccount.cookies {
            Log.info(#file, "SAML authentication flow for '\(currentBook.title)'")
            handleSAMLStartedState(for: currentBook, withRequest: request, cookies: cookies)
        } else {
            if userAccount.authToken != nil {
                Log.debug(#file, "Auth token present for '\(currentBook.title)', proceeding with download")
            } else if userAccount.cookies != nil {
                Log.debug(#file, "Using saved SAML cookies for '\(currentBook.title)', proceeding with download")
            }
            clearAndSetCookies()
            addDownloadTask(with: request, book: currentBook)
        }
    }

    // MARK: - Borrow Error Handling

    func process(error: [String: Any]?, for book: TPPBook) {
        guard let errorType = error?["type"] as? String else {
            showGenericBorrowFailedAlert(for: book)
            return
        }

        let alertTitle = DisplayStrings.borrowFailed

        switch errorType {
        case TPPProblemDocument.TypeLoanAlreadyExists:
            let alertMessage = DisplayStrings.loanAlreadyExistsAlertMessage
            runOnMainAsync {
                self.publishAndAnnounceError(DownloadErrorInfo(bookId: book.identifier, title: alertTitle, message: alertMessage))
            }

        case TPPProblemDocument.TypeInvalidCredentials:
            tokenInterceptor.handleBorrowInvalidCredentials(for: book, error: error)
            return

        default:
            showAlert(for: book, with: error, alertTitle: alertTitle)
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

        let retryAction: (() -> Void)? = {
            let operationId = "borrow-\(book.identifier)"
            guard UserRetryTracker.shared.canRetry(operationId: operationId) else { return nil }
            return { [weak self] in
                UserRetryTracker.shared.recordRetry(operationId: operationId)
                self?.startBorrow(for: book, attemptDownload: true)
            }
        }()

        runOnMainAsync {
            self.publishAndAnnounceError(DownloadErrorInfo(bookId: book.identifier, title: alertTitle, message: alertMessage, retryAction: retryAction))
        }
    }

    private func showGenericBorrowFailedAlert(for book: TPPBook) {
        let formattedMessage = String(format: DisplayStrings.borrowFailedMessage, book.title)

        let retryAction: (() -> Void)? = {
            let operationId = "borrow-\(book.identifier)"
            guard UserRetryTracker.shared.canRetry(operationId: operationId) else { return nil }
            return { [weak self] in
                UserRetryTracker.shared.recordRetry(operationId: operationId)
                self?.startBorrow(for: book, attemptDownload: true)
            }
        }()

        runOnMainAsync {
            self.publishAndAnnounceError(DownloadErrorInfo(bookId: book.identifier, title: DisplayStrings.borrowFailed, message: formattedMessage, retryAction: retryAction))
        }
    }

    // MARK: - SAML / Cookie Handling

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
                self.tokenInterceptor.handleProblem(for: book, problemDocument: problemDocument)
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
                    self?.tokenInterceptor.handleProblem(for: book, problemDocument: problemDocument)
                },
                autoPresentIfNeeded: true
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

    private func clearAndSetCookies() {
        let cookieStorage = self.session.configuration.httpCookieStorage
        cookieStorage?.cookies?.forEach { cookie in
            cookieStorage?.deleteCookie(cookie)
        }
        self.userAccount.cookies?.forEach { cookie in
            cookieStorage?.setCookie(cookie)
        }
    }

    // MARK: - Cancel

    @objc func cancelDownload(for identifier: String) {
        let state = bookRegistry.state(for: identifier)

        guard let info = downloadInfo(forBookIdentifier: identifier) else {
            let cancellableStates: [TPPBookState] = [.downloading, .downloadFailed, .SAMLStarted]

            if cancellableStates.contains(state) {
                Log.info(#file, "Cancelling download without task for '\(identifier)' (state: \(state.stringValue()))")
                bookRegistry.setState(.downloadNeeded, for: identifier)
                broadcastUpdate()

                Task {
                    await stateManager.cleanupDownload(for: identifier)
                    let remainingCount = await downloadCoordinator.activeCount
                    Log.info(#file, "Download cancelled (no task) for '\(identifier)', remaining active: \(remainingCount)")
                    self.schedulePendingStartsIfPossible()
                }
                return
            }

            NSLog("Ignoring nonsensical cancellation request for state: \(state.stringValue())")
            return
        }

        #if FEATURE_DRM_CONNECTOR
        if info.rightsManagement == .adobe {
            AdobeDRMService.shared.cancelFulfillment(withTag: identifier)
            return
        }
        #endif

        let taskId = info.downloadTask.taskIdentifier

        bookRegistry.setState(.downloadNeeded, for: identifier)
        broadcastUpdate()

        info.downloadTask.cancel { [weak self] _ in
            guard let self else { return }

            Task {
                await self.stateManager.cleanupDownload(for: identifier, taskIdentifier: taskId)
                let remainingCount = await self.downloadCoordinator.activeCount
                Log.info(#file, "Download cancelled for '\(identifier)', remaining active: \(remainingCount)")
                self.schedulePendingStartsIfPossible()
            }
        }
    }
}

// MARK: - Local Content Management

extension MyBooksDownloadCenter {
    func deleteLocalContent(for identifier: String, account: String? = nil) {
        let current_account: String? = account ?? AccountsManager.shared.currentAccountId
        guard let book = bookRegistry.book(forIdentifier: identifier),
              let bookURL = fileUrl(for: identifier, account: current_account) else {
            Log.warn(#file, "Could not find book to delete local content \(identifier)")
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
            Log.error(#file, "Failed to remove local content for book with identifier \(identifier): \(error.localizedDescription)")
        }
    }

    private func deleteLocalAudiobookContent(forAudiobook book: TPPBook, at bookURL: URL) throws {
        #if LCP
        let isLcpAudiobook = LCPAudiobooks.canOpenBook(book)
        #else
        let isLcpAudiobook = false
        #endif

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

        announceReturnStarted(for: book)

        let state = bookRegistry.state(for: identifier)
        let downloaded = (state == .downloadSuccessful) || (state == .used)

        #if FEATURE_DRM_CONNECTOR
        if let fulfillmentId = bookRegistry.fulfillmentId(forIdentifier: identifier),
           userAccount.authDefinition?.needsAuth == true {
            NSLog("Return attempt for book. userID: %@", userAccount.userID ?? "")
            AdobeDRMService.shared.returnLoan(fulfillmentId,
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

            TPPAnnotations.deleteAllBookmarks(forBook: book) { [weak self] in
                guard let self = self else {
                    completion?()
                    return
                }
                TPPBookmarkDeletionLog.shared.clearAllDeletions(forBook: identifier)
                self.bookRegistry.setState(.unregistered, for: identifier)
                self.bookRegistry.removeBook(forIdentifier: identifier)
                Task {
                    try? await TPPBookRegistry.shared.syncAsync()
                    runOnMainAsync {
                        self.announceReturnSucceeded(for: book)
                        completion?()
                    }
                }
            }
        } else {
            bookRegistry.setProcessing(true, for: book.identifier)

            TPPOPDSFeed.withURL(book.revokeURL, shouldResetCache: false, useTokenIfAvailable: true) { feed, error in
                self.bookRegistry.setProcessing(false, for: book.identifier)

                if let feed = feed, feed.entries.count == 1, let entry = feed.entries[0] as? TPPOPDSEntry {
                    if downloaded {
                        self.deleteLocalContent(for: identifier)
                        self.purgeAllAudiobookCaches(force: true)
                    }
                    if let returnedBook = TPPBook(entry: entry) {
                        TPPAnnotations.deleteAllBookmarks(forBook: book) {
                            TPPBookmarkDeletionLog.shared.clearAllDeletions(forBook: identifier)
                            self.bookRegistry.updateAndRemoveBook(returnedBook)
                            self.bookRegistry.setState(.unregistered, for: identifier)
                            Task {
                                try? await TPPBookRegistry.shared.syncAsync()
                                runOnMainAsync {
                                    self.announceReturnSucceeded(for: book)
                                    completion?()
                                }
                            }
                        }
                    } else {
                        NSLog("Failed to create book from entry. Book not removed from registry.")
                        Task {
                            try? await TPPBookRegistry.shared.syncAsync()
                            runOnMainAsync {
                                self.announceReturnFailed(for: book)
                                completion?()
                            }
                        }
                    }
                } else {
                    if let errorType = error?["type"] as? String {
                        let isLoanGone = errorType == TPPProblemDocument.TypeNoActiveLoan
                            || (error?["detail"] as? String)?.contains(TPPProblemDocument.DetailLoanTermLimitReached) == true
                        if isLoanGone {
                            if downloaded {
                                self.deleteLocalContent(for: identifier)
                                self.purgeAllAudiobookCaches(force: true)
                            }
                            TPPAnnotations.deleteAllBookmarks(forBook: book) {
                                TPPBookmarkDeletionLog.shared.clearAllDeletions(forBook: identifier)
                                self.bookRegistry.setState(.unregistered, for: identifier)
                                self.bookRegistry.removeBook(forIdentifier: identifier)
                                Task {
                                    try? await TPPBookRegistry.shared.syncAsync()
                                    runOnMainAsync {
                                        self.announceReturnSucceeded(for: book)
                                        completion?()
                                    }
                                }
                            }
                        } else if errorType == TPPProblemDocument.TypeInvalidCredentials {
                            NSLog("Invalid credentials problem when returning a book, present sign in VC")
                            self.tokenInterceptor.reauthenticator.authenticateIfNeeded(self.userAccount, usingExistingCredentials: false) { [weak self] in
                                guard let self = self else { return }
                                if self.userAccount.hasCredentials() {
                                    self.returnBook(withIdentifier: identifier, completion: completion)
                                } else {
                                    runOnMainAsync {
                                        self.announceReturnFailed(for: book)
                                        completion?()
                                    }
                                }
                            }
                        }
                    } else {
                        runOnMainAsync {
                            let formattedMessage = String(format: Strings.MyDownloadCenter.returnFailedMessage, book.title)

                            let operationId = "return-\(identifier)"
                            let retryAction: (() -> Void)? = {
                                guard UserRetryTracker.shared.canRetry(operationId: operationId) else { return nil }
                                return { [weak self] in
                                    UserRetryTracker.shared.recordRetry(operationId: operationId)
                                    self?.returnBook(withIdentifier: identifier, completion: completion)
                                }
                            }()

                            let message = (retryAction == nil && !UserRetryTracker.shared.canRetry(operationId: operationId))
                                ? Strings.MyDownloadCenter.tryAgainLater
                                : formattedMessage

                            let alert = UIAlertController(title: Strings.MyDownloadCenter.returnFailed, message: message, preferredStyle: .alert)

                            if let retryAction = retryAction {
                                alert.addAction(UIAlertAction(title: Strings.MyDownloadCenter.retry, style: .default) { _ in retryAction() })
                            }

                            alert.addAction(UIAlertAction(title: NSLocalizedString("Remove from Device", comment: "Button to remove a book locally when server return fails"), style: .destructive) { [weak self] _ in
                                guard let self = self else { return }
                                if downloaded {
                                    self.deleteLocalContent(for: identifier)
                                    self.purgeAllAudiobookCaches(force: true)
                                }
                                TPPBookmarkDeletionLog.shared.clearAllDeletions(forBook: identifier)
                                self.bookRegistry.setState(.unregistered, for: identifier)
                                self.bookRegistry.removeBook(forIdentifier: identifier)
                                self.announceReturnSucceeded(for: book)
                                completion?()
                            })

                            alert.addAction(UIAlertAction(title: Strings.Generic.cancel, style: .cancel))

                            if let error = error as? Decoder, let document = try? TPPProblemDocument(from: error) {
                                TPPAlertUtils.setProblemDocument(controller: alert, document: document, append: true)
                            }
                            runOnMainAsync {
                                TPPAlertUtils.presentFromViewControllerOrNil(alertController: alert, viewController: nil, animated: true, completion: nil)
                            }
                        }
                        runOnMainAsync {
                            self.announceReturnFailed(for: book)
                            completion?()
                        }
                    }
                }
            }
        }
    }
}

// MARK: - URLSession Download Delegate

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

        Task {
            guard let book = await taskIdentifierToBook.get(key) else {
                return
            }

            await backgroundHandler.handleDownloadProgress(
                for: book,
                task: downloadTask,
                bytesWritten: bytesWritten,
                totalBytesWritten: totalBytesWritten,
                totalBytesExpectedToWrite: totalBytesExpectedToWrite
            )
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let tempDir = FileManager.default.temporaryDirectory
        let safeLocation = tempDir.appendingPathComponent(UUID().uuidString + "_" + location.lastPathComponent)

        do {
            try FileManager.default.moveItem(at: location, to: safeLocation)
        } catch {
            Log.error(#file, "Failed to preserve download file: \(error.localizedDescription)")
            return
        }

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
            Log.info(#file, "Rights unknown, detecting from completion MIME type: \(mimeType)")
            rights = backgroundHandler.detectRightsManagement(from: mimeType)
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

        let mimeType = task.response?.mimeType ?? ""
        if !failureRequiringAlert && backgroundHandler.isOPDSEntryMimeType(mimeType) {
            Log.info(#file, "Received OPDS entry response for \(book.identifier), attempting to extract acquisition link")

            if await backgroundHandler.handleOPDSEntryResponse(at: location, for: book, originalTask: task, session: session) {
                try? FileManager.default.removeItem(at: location)
                return
            } else {
                Log.warn(#file, "Failed to extract acquisition link from OPDS entry for \(book.identifier)")
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
                Log.error(#file, "Rights management is unknown for book: \(book.identifier) - LCP fulfillment will NOT be called")
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
                    NSLog("Download finished. Fulfilling with userID: \(userAccount.userID ?? "")")
                    AdobeDRMService.shared.fulfill(withACSMData: acsmData, tag: book.identifier, userID: userAccount.userID, deviceID: userAccount.deviceID)
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
                failureRequiringAlert = !replaceBook(book, withFileAtURL: location, forDownloadTask: task)
            case .none:
                failureRequiringAlert = !moveFile(at: location, toDestinationForBook: book, forDownloadTask: task)
            }
        }

        if failureRequiringAlert {
            runOnMainAsync {
                // Delegate auth-related failure handling to tokenInterceptor
                let handled = self.tokenInterceptor.handleDownloadFailureWithAuthCheck(
                    for: book, task: task, problemDoc: problemDoc, failureError: failureError
                )

                if !handled {
                    self.alertForProblemDocument(problemDoc, error: failureError, book: book)
                    self.bookRegistry.setState(.downloadFailed, for: book.identifier)
                }
            }
        }

        try? await Task.sleep(nanoseconds: 100_000_000)

        broadcastUpdate()

        await stateManager.cleanupDownload(for: book.identifier)
        let remainingCount = await downloadCoordinator.activeCount
        Log.info(#file, "Download flow completed for '\(book.identifier)', remaining active: \(remainingCount)")

        schedulePendingStartsIfPossible()
    }
}

// MARK: - URLSession Task Delegate

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

            if task.originalRequest?.url?.scheme == "https" && request.url?.scheme != "https" {
                completionHandler(nil)
                return
            }

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
        Log.info(#file, "Download completed for '\(book.title)', remaining active: \(remainingCount)")

        if let error = error as NSError?, error.code != NSURLErrorCancelled {
            logBookDownloadFailure(book, reason: "networking error", downloadTask: task, metadata: ["urlSessionError": error])
            failDownloadWithAlert(for: book)
            return
        }

        schedulePendingStartsIfPossible()
    }

    private func addDownloadTask(with request: URLRequest, book: TPPBook) {
        var modifiableRequest = request
        let task = self.session.downloadTask(with: modifiableRequest.applyCustomUserAgent())

        let downloadInfo = MyBooksDownloadInfo(
            downloadProgress: 0.0,
            downloadTask: task,
            rightsManagement: .unknown
        )

        Task {
            await self.bookIdentifierToDownloadInfo.set(book.identifier, value: downloadInfo)
            await self.taskIdentifierToBook.set(task.taskIdentifier, value: book)

            let currentCount = await downloadCoordinator.activeCount
            Log.info(#file, "Active downloads: \(currentCount)/\(maxConcurrentDownloads) (started '\(book.title)')")

            task.resume()

            self.bookRegistry.addBook(book,
                                      location: self.bookRegistry.location(forIdentifier: book.identifier),
                                      state: .downloading,
                                      fulfillmentId: nil,
                                      readiumBookmarks: nil,
                                      genericBookmarks: nil)

            self.announceDownloadStarted(for: book)

            runOnMainAsync {
                NotificationCenter.default.post(name: .TPPMyBooksDownloadCenterDidChange, object: self)
            }

            self.schedulePendingStartsIfPossible()
        }
    }
}

// MARK: - Download Throttling and Disk Budget

extension MyBooksDownloadCenter {
    private func enqueuePending(_ book: TPPBook) {
        bookRegistry.setState(.downloading, for: book.identifier)

        Task {
            await downloadCoordinator.enqueuePending(book)
            let queueSize = await downloadCoordinator.queueCount
            Log.debug(#file, "Enqueued '\(book.title)' for download, queue size: \(queueSize)")

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

    private func schedulePendingStartsAsync() async {
        let activeCount = await downloadCoordinator.activeCount
        let capacity = maxConcurrentDownloads - activeCount

        guard capacity > 0 else { return }

        let toStart = await downloadCoordinator.dequeuePending(capacity: capacity)
        guard !toStart.isEmpty else { return }

        let queueRemaining = await downloadCoordinator.queueCount
        Log.info(#file, "Starting \(toStart.count) pending downloads (capacity: \(capacity), queue remaining: \(queueRemaining))")

        for book in toStart {
            await startDownloadAsync(for: book, withRequest: nil)
        }
    }

    @objc func enforceContentDiskBudgetIfNeeded(adding bytesToAdd: Int64) {
        let smallDevice = UIScreen.main.nativeBounds.height <= 1334
        let budgetBytes: Int64 = smallDevice ? (1_200 * 1024 * 1024) : (2_500 * 1024 * 1024)

        let currentUsage = contentDirectoryUsageBytes()
        var neededFree = (currentUsage + bytesToAdd) - budgetBytes
        guard neededFree > 0 else { return }

        let files = listContentFilesSortedByLRU()
        let fm = FileManager.default
        for url in files {
            if neededFree <= 0 { break }
            let ext = url.pathExtension.lowercased()
            if ext == "lcpl" || ext == "lcpa" { continue }
            if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                try? fm.removeItem(at: url)
                neededFree -= Int64(size)
            }
        }
    }

    private func contentDirectoryUsageBytes() -> Int64 {
        guard let dir = contentDirectoryURL(AccountsManager.shared.currentAccountId) else { return 0 }
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0
        for url in contents {
            if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize { total += Int64(size) }
        }
        return total
    }

    private func listContentFilesSortedByLRU() -> [URL] {
        guard let dir = contentDirectoryURL(AccountsManager.shared.currentAccountId) else { return [] }
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentAccessDateKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) else { return [] }
        return contents.sorted { a, b in
            let ra = try? a.resourceValues(forKeys: [.contentAccessDateKey, .contentModificationDateKey])
            let rb = try? b.resourceValues(forKeys: [.contentAccessDateKey, .contentModificationDateKey])
            let da = ra?.contentAccessDate ?? ra?.contentModificationDate ?? Date.distantPast
            let db = rb?.contentAccessDate ?? rb?.contentModificationDate ?? Date.distantPast
            return da < db
        }
    }
}

// MARK: - Download Management (Memory Pressure)

extension MyBooksDownloadCenter {
    @objc func limitActiveDownloads(max: Int) {
        maxConcurrentDownloads = max

        Task {
            await limitActiveDownloadsAsync(max: max)
        }
    }

    private func limitActiveDownloadsAsync(max: Int) async {
        let allInfo = await bookIdentifierToDownloadInfo.values()
        let running = allInfo.compactMap { $0.downloadTask }.filter { $0.state == .running }
        let suspended = allInfo.compactMap { $0.downloadTask }.filter { $0.state == .suspended }

        if running.count > max {
            var nonAudiobookTasks: [URLSessionTask] = []
            for task in running {
                if let book = await taskIdentifierToBook.get(task.taskIdentifier) {
                    if book.defaultBookContentType != .audiobook {
                        nonAudiobookTasks.append(task)
                    }
                } else {
                    nonAudiobookTasks.append(task)
                }
            }

            let tasksToSuspend = nonAudiobookTasks.dropFirst(Swift.max(0, max - (running.count - nonAudiobookTasks.count)))
            for task in tasksToSuspend {
                Log.info(#file, "Suspending non-audiobook download to respect limits")
                task.suspend()
            }
        } else if running.count < max {
            let toResume = min(max - running.count, suspended.count)
            if toResume > 0 {
                for task in suspended.prefix(toResume) { task.resume() }
            }
        }
        await schedulePendingStartsAsync()
    }

    @objc func pauseAllDownloads() {
        Task {
            await pauseAllDownloadsAsync()
        }
    }

    private func pauseAllDownloadsAsync() async {
        let allInfo = await bookIdentifierToDownloadInfo.values()
        for info in allInfo {
            if let book = await taskIdentifierToBook.get(info.downloadTask.taskIdentifier),
               book.defaultBookContentType == .audiobook {
                Log.info(#file, "Preserving audiobook download/streaming for: \(book.title)")
                continue
            }
            info.downloadTask.suspend()
        }
    }

    @objc func resumeIntelligentDownloads() {
        limitActiveDownloads(max: maxConcurrentDownloads)
    }

    func setupNetworkMonitoring() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(networkConditionsChanged),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        Log.info(#file, "Network monitoring setup for download optimization")
    }

    @objc private func networkConditionsChanged() {
        let currentLimit = maxConcurrentDownloads
        limitActiveDownloads(max: currentLimit)
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

        Task {
            await DeviceSpecificErrorMonitor.shared.logDownloadFailure(
                book: book,
                reason: reason,
                error: downloadTask.error,
                metadata: dict
            )
        }
    }

    // MARK: - LCP Fulfillment

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
                await MainActor.run {
                    self.downloadProgressPublisher.send((book.identifier, progressValue))
                }
                self.announceDownloadProgress(for: book, progress: progressValue)
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

            if !self.replaceBook(book, withFileAtURL: localUrl, forDownloadTask: downloadTask) {
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
                Log.error(#file, "Failed to read license for fulfillment ID")
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

    private func copyLicenseForStreaming(book: TPPBook, sourceLicenseUrl: URL) {
        #if LCP
        Log.info(#file, "Starting license copy for streaming: \(book.identifier)")

        guard let finalContentURL = self.fileUrl(for: book.identifier) else {
            Log.error(#file, "Unable to determine final content URL for streaming license copy")
            return
        }

        let streamingLicenseUrl = finalContentURL.deletingPathExtension().appendingPathExtension("lcpl")
        Log.info(#file, "Copying license FROM: \(sourceLicenseUrl.path)")
        Log.info(#file, "Copying license TO: \(streamingLicenseUrl.path)")

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

    // MARK: - Download Failure Alerts

    func failDownloadWithAlert(for book: TPPBook, withMessage message: String? = nil) {
        let location = bookRegistry.location(forIdentifier: book.identifier)

        bookRegistry.addBook(book,
                             location: location,
                             state: .downloadFailed,
                             fulfillmentId: nil,
                             readiumBookmarks: nil,
                             genericBookmarks: nil)

        announceDownloadFailed(for: book)

        Task {
            await ErrorActivityTracker.shared.log(
                "Download failed for '\(book.title)': \(message ?? "unknown reason")",
                category: .download
            )
            await stateManager.cleanupDownload(for: book.identifier)
            let remainingCount = await downloadCoordinator.activeCount
            Log.info(#file, "Download failed for '\(book.title)', remaining active: \(remainingCount)")
            self.schedulePendingStartsIfPossible()
        }

        let errorMessage = message ?? "No error message"
        let formattedMessage = String.localizedStringWithFormat(NSLocalizedString("The download for %@ could not be completed.", comment: ""), book.title)
        let finalMessage = "\(formattedMessage)\n\(errorMessage)"

        let retryAction: (() -> Void)? = {
            let operationId = "download-\(book.identifier)"
            guard UserRetryTracker.shared.canRetry(operationId: operationId) else { return nil }
            return { [weak self] in
                UserRetryTracker.shared.recordRetry(operationId: operationId)
                self?.startDownload(for: book)
            }
        }()

        runOnMainAsync {
            self.publishAndAnnounceError(DownloadErrorInfo(bookId: book.identifier, title: DisplayStrings.downloadFailed, message: finalMessage, retryAction: retryAction))
        }

        broadcastUpdate()
    }

    func alertForProblemDocument(_ problemDoc: TPPProblemDocument?, error: Error?, book: TPPBook) {
        let msg = String(format: NSLocalizedString("The download for %@ could not be completed.", comment: ""), book.title)

        var finalMessage = msg
        if let problemDoc = problemDoc {
            TPPProblemDocumentCacheManager.sharedInstance().cacheProblemDocument(problemDoc, key: book.identifier)
            if let detail = problemDoc.detail {
                finalMessage = "\(msg)\n\n\(detail)"
            }

            if problemDoc.type == TPPProblemDocument.TypeNoActiveLoan {
                bookRegistry.removeBook(forIdentifier: book.identifier)
            }
        } else if let error = error {
            finalMessage = String(format: "%@\n\nError: %@", msg, error.localizedDescription)
        }

        let isNoActiveLoan = problemDoc?.type == TPPProblemDocument.TypeNoActiveLoan
        let retryAction: (() -> Void)? = {
            guard !isNoActiveLoan else { return nil }
            let operationId = "download-\(book.identifier)"
            guard UserRetryTracker.shared.canRetry(operationId: operationId) else { return nil }
            return { [weak self] in
                UserRetryTracker.shared.recordRetry(operationId: operationId)
                self?.startDownload(for: book)
            }
        }()

        runOnMainAsync {
            self.publishAndAnnounceError(DownloadErrorInfo(bookId: book.identifier, title: DisplayStrings.downloadFailed, message: finalMessage, retryAction: retryAction))
        }
    }

    // MARK: - File Operations (delegated to backgroundHandler)

    func moveFile(at sourceLocation: URL, toDestinationForBook book: TPPBook, forDownloadTask downloadTask: URLSessionDownloadTask) -> Bool {
        backgroundHandler.moveFile(at: sourceLocation, toDestinationForBook: book, forDownloadTask: downloadTask)
    }

    private func replaceBook(_ book: TPPBook, withFileAtURL sourceLocation: URL, forDownloadTask downloadTask: URLSessionDownloadTask) -> Bool {
        backgroundHandler.replaceBook(book, withFileAtURL: sourceLocation, forDownloadTask: downloadTask)
    }

    @objc func fileUrl(for identifier: String) -> URL? {
        return fileUrl(for: identifier, account: AccountsManager.shared.currentAccountId)
    }

    func fileUrl(for identifier: String, account: String?) -> URL? {
        guard let book = bookRegistry.book(forIdentifier: identifier) else {
            return nil
        }

        let pathExtension = pathExtension(for: book)
        let contentDirectoryURL = self.contentDirectoryURL(account)
        let hashedIdentifier = identifier.sha256()

        return contentDirectoryURL?.appendingPathComponent(hashedIdentifier).appendingPathExtension(pathExtension)
    }

    func fileUrl(for book: TPPBook, account: String?) -> URL? {
        let pathExtension = pathExtension(for: book)
        let contentDirectoryURL = self.contentDirectoryURL(account)
        let hashedIdentifier = book.identifier.sha256()

        return contentDirectoryURL?.appendingPathComponent(hashedIdentifier).appendingPathExtension(pathExtension)
    }

    func contentDirectoryURL(_ account: String?) -> URL? {
        guard let directoryURL = TPPBookContentMetadataFilesHelper.directory(for: account ?? "")?.appendingPathComponent("content") else {
            NSLog("[contentDirectoryURL] nil directory.")
            return nil
        }

        var isDirectory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory) {
            do {
                try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)
            } catch {
                NSLog("Failed to create directory.")
                return nil
            }
        }

        return directoryURL
    }

    func pathExtension(for book: TPPBook?) -> String {
        #if LCP
        if let book = book {
            if LCPAudiobooks.canOpenBook(book) {
                return "lcpa"
            }

            if LCPPDFs.canOpenBook(book) {
                return "zip"
            }
        }
        #endif
        return "epub"
    }
}

// MARK: - Reset / Account Management

extension MyBooksDownloadCenter: TPPBookDownloadsDeleting {
    func reset(_ libraryID: String!) {
        reset(account: libraryID)
    }

    func reset(account: String) {
        if AccountsManager.shared.currentAccountId == account {
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
        guard let currentAccountId = AccountsManager.shared.currentAccountId else {
            return
        }

        deleteAudiobooks(forAccount: currentAccountId)

        Task {
            await stateManager.resetAll()
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
        let accountId = AccountsManager.shared.currentAccountId ?? ""
        bookRegistry.with(account: accountId) { registry in
            let audiobooks = registry.myBooks.filter { $0.defaultBookContentType == .audiobook }
            hasActive = audiobooks.contains { matchingStates.contains(registry.state(for: $0.identifier)) }
        }
        return hasActive
    }
}

// MARK: - Adobe DRM

#if FEATURE_DRM_CONNECTOR
extension MyBooksDownloadCenter: NYPLADEPTDelegate {

    func adept(_ adept: NYPLADEPT, didFinishDownload: Bool, to adeptToURL: URL?, fulfillmentID: String?, isReturnable: Bool, rightsData: Data, tag: String, error adeptError: Error?) {
        guard let book = bookRegistry.book(forIdentifier: tag),
              let rights = String(data: rightsData, encoding: .utf8) else { return }

        var didSucceedCopying = false

        if didFinishDownload {
            guard let fileURL = fileUrl(for: book.identifier) else { return }
            let fileManager = FileManager.default

            do {
                try fileManager.removeItem(at: fileURL)
            } catch {
                print("Remove item error: \(error)")
            }

            guard let destURL = fileUrl(for: book.identifier), let adeptToURL = adeptToURL else {
                TPPErrorLogger.logError(withCode: .adobeDRMFulfillmentFail, summary: "Adobe DRM error: destination file URL unavailable", metadata: [
                    "adeptError": adeptError ?? "N/A",
                    "fileURLToRemove": adeptToURL ?? "N/A",
                    "book": book.loggableDictionary,
                    "AdobeFulfilmmentID": fulfillmentID ?? "N/A",
                    "AdobeRights": rights,
                    "AdobeTag": tag
                ])
                self.failDownloadWithAlert(for: book)
                return
            }

            do {
                try fileManager.copyItem(at: adeptToURL, to: destURL)
                didSucceedCopying = true
            } catch {
                TPPErrorLogger.logError(withCode: .adobeDRMFulfillmentFail, summary: "Adobe DRM error: failure copying file", metadata: [
                    "adeptError": adeptError ?? "N/A",
                    "copyError": error,
                    "fromURL": adeptToURL,
                    "destURL": destURL,
                    "book": book.loggableDictionary,
                    "AdobeFulfilmmentID": fulfillmentID ?? "N/A",
                    "AdobeRights": rights,
                    "AdobeTag": tag
                ])
            }
        } else {
            TPPErrorLogger.logError(withCode: .adobeDRMFulfillmentFail, summary: "Adobe DRM error: did not finish download", metadata: [
                "adeptError": adeptError ?? "N/A",
                "adeptToURL": adeptToURL ?? "N/A",
                "book": book.loggableDictionary,
                "AdobeFulfilmmentID": fulfillmentID ?? "N/A",
                "AdobeRights": rights,
                "AdobeTag": tag
            ])
        }

        if !didFinishDownload || !didSucceedCopying {
            self.failDownloadWithAlert(for: book)
            return
        }

        guard let rightsFilePath = fileUrl(for: book.identifier)?.path.appending("_rights.xml") else { return }
        do {
            try rightsData.write(to: URL(fileURLWithPath: rightsFilePath))
        } catch {
            print("Failed to store rights data.")
        }

        if isReturnable, let fulfillmentID = fulfillmentID {
            bookRegistry.setFulfillmentId(fulfillmentID, for: book.identifier)
        }

        markDownloadSuccessful(for: book)

        self.broadcastUpdate()
    }

    func adept(_ adept: NYPLADEPT, didUpdateProgress progress: Double, tag: String) {
        Task {
            if let info = await self.downloadInfoAsync(forBookIdentifier: tag)?.withDownloadProgress(progress) {
                await self.bookIdentifierToDownloadInfo.set(tag, value: info)
            }
            await MainActor.run {
                self.downloadProgressPublisher.send((tag, progress))
            }
            if let book = self.bookRegistry.book(forIdentifier: tag) {
                self.announceDownloadProgress(for: book, progress: progress)
            }
            self.broadcastUpdate()
        }
    }

    func adept(_ adept: NYPLADEPT, didCancelDownloadWithTag tag: String) {
        bookRegistry.setState(.downloadNeeded, for: tag)
        self.broadcastUpdate()
    }

    func didIgnoreFulfillmentWithNoAuthorizationPresent() {
        self.tokenInterceptor.reauthenticator.authenticateIfNeeded(userAccount, usingExistingCredentials: true, authenticationCompletion: nil)
    }
}
#endif

// MARK: - Delegate Conformances

extension MyBooksDownloadCenter: BackgroundDownloadHandlerDelegate {}
extension MyBooksDownloadCenter: TokenRefreshInterceptorDelegate {}
