//
//  TPPNetworkExecutor.swift
//  The Palace Project
//
//  Created by Ettore Pasquini on 3/19/20.
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

import Foundation
import PalaceLogging

enum NYPLResult<SuccessInfo> {
    case success(SuccessInfo, URLResponse?)
    case failure(TPPUserFriendlyError, URLResponse?)
}

/// Actor that serializes access to the token refresh state and retry queue.
private actor TokenRefreshCoordinator {
    var isRefreshing = false
    var retryQueue: [URLSessionTask] = []
    /// Count of underlying token-refresh attempts that actually took the
    /// single-flight slot (i.e. transitioned `isRefreshing` from false to true).
    /// Read-only; test-observable via `TPPNetworkExecutor.refreshAttemptCount`.
    private(set) var refreshAttemptCount: Int = 0

    func setRefreshing(_ value: Bool) {
        if value && !isRefreshing {
            refreshAttemptCount += 1
        }
        isRefreshing = value
    }

    /// Atomically attempts to claim the single-flight refresh slot.
    /// Returns `true` if the caller now owns the in-flight refresh, `false`
    /// if another caller already holds it. This collapses the previous
    /// check-then-act pattern into a single actor-hop so two concurrent
    /// 401s can never both proceed past the guard.
    func tryClaimRefreshSlot() -> Bool {
        guard !isRefreshing else { return false }
        isRefreshing = true
        refreshAttemptCount += 1
        return true
    }

    func resetRefreshAttemptCount() {
        refreshAttemptCount = 0
    }

    func appendToRetryQueue(_ task: URLSessionTask) {
        retryQueue.append(task)
    }

    func drainRetryQueue() -> [URLSessionTask] {
        let tasks = retryQueue
        retryQueue.removeAll()
        return tasks
    }
}

/// Lock-protected store for the active tasks list.
///
/// Intentionally NOT an actor: the `@objc` methods that drive this
/// (`pauseAllTasks`, `resumeAllTasks`, `cancelNonEssentialTasks`) are
/// invoked from synchronous call sites — most importantly during account
/// switches, where we *must* finish cancelling before the caller proceeds,
/// otherwise in-flight requests can complete against the wrong account's
/// credentials. A fire-and-forget `Task { await actor.… }` would silently
/// break that invariant.
private final class ActiveTasksStore {
    private var tasks: [URLSessionTask] = []
    private let lock = NSLock()

    func add(_ task: URLSessionTask) {
        lock.lock(); defer { lock.unlock() }
        tasks.append(task)
    }

    func remove(_ task: URLSessionTask) {
        lock.lock(); defer { lock.unlock() }
        if let index = tasks.firstIndex(of: task) {
            tasks.remove(at: index)
        }
    }

    func pauseNonAudioTasks() {
        lock.lock(); defer { lock.unlock() }
        for task in tasks {
            if let url = task.originalRequest?.url,
               Self.isAudiobookRelated(url: url) {
                Log.info(#function, "Preserving audiobook network task: \(url.absoluteString)")
                continue
            }
            task.suspend()
        }
    }

    func resumeAll() {
        lock.lock(); defer { lock.unlock() }
        tasks.forEach { $0.resume() }
    }

    @discardableResult
    func cancelNonEssential() -> Int {
        lock.lock(); defer { lock.unlock() }
        let toCancel = tasks.filter { task in
            guard let url = task.originalRequest?.url else { return true }
            return !Self.isAudiobookRelated(url: url)
        }
        toCancel.forEach { $0.cancel() }
        tasks.removeAll { toCancel.contains($0) }
        return toCancel.count
    }

    private static func isAudiobookRelated(url: URL) -> Bool {
        let s = url.absoluteString
        return s.contains("audiobook") ||
            s.contains(".mp3") ||
            s.contains(".m4a") ||
            s.contains("audio") ||
            s.contains("readium") ||
            s.contains("lcp")
    }
}

@objc class TPPNetworkExecutor: NSObject {
    #if DEBUG
    private var urlSession: URLSession
    #else
    private let urlSession: URLSession
    #endif
    private let tokenCoordinator = TokenRefreshCoordinator()
    private let activeTasksStore = ActiveTasksStore()

    private let responder: TPPNetworkResponder
    private var _accountsManager: TPPLibraryAccountsProvider?
    private var accountsManager: TPPLibraryAccountsProvider {
        _accountsManager ?? AccountsManager.shared
    }

    @objc init(credentialsProvider: NYPLBasicAuthCredentialsProvider? = nil,
               cachingStrategy: NYPLCachingStrategy,
               delegateQueue: OperationQueue? = nil) {
        self.responder = TPPNetworkResponder(credentialsProvider: credentialsProvider,
                                             useFallbackCaching: cachingStrategy == .fallback)

        let config = TPPCaching.makeURLSessionConfiguration(
            caching: cachingStrategy,
            requestTimeout: TPPNetworkExecutor.defaultRequestTimeout)
        self.urlSession = URLSession(configuration: config,
                                     delegate: self.responder,
                                     delegateQueue: delegateQueue)
        // accountsManager is lazy — accessed on first use, not during init
        // This avoids circular singleton deadlock: TPPNetworkExecutor ↔ AccountsManager
        super.init()
    }

    /// Test-friendly initializer allowing a custom URLSessionConfiguration (e.g., with custom URLProtocol classes)
    @objc init(credentialsProvider: NYPLBasicAuthCredentialsProvider? = nil,
               cachingStrategy: NYPLCachingStrategy,
               sessionConfiguration: URLSessionConfiguration,
               delegateQueue: OperationQueue? = nil) {
        self.responder = TPPNetworkResponder(credentialsProvider: credentialsProvider,
                                             useFallbackCaching: cachingStrategy == .fallback)
        self.urlSession = URLSession(configuration: sessionConfiguration,
                                     delegate: self.responder,
                                     delegateQueue: delegateQueue)
        // accountsManager is lazy — avoids circular init deadlock
        super.init()
    }

    /// DI-friendly initializer for testing
    init(credentialsProvider: NYPLBasicAuthCredentialsProvider? = nil,
         cachingStrategy: NYPLCachingStrategy,
         accountsManager: TPPLibraryAccountsProvider = AccountsManager.shared,
         delegateQueue: OperationQueue? = nil) {
        self.responder = TPPNetworkResponder(credentialsProvider: credentialsProvider,
                                             useFallbackCaching: cachingStrategy == .fallback)
        let config = TPPCaching.makeURLSessionConfiguration(
            caching: cachingStrategy,
            requestTimeout: TPPNetworkExecutor.defaultRequestTimeout)
        self.urlSession = URLSession(configuration: config,
                                     delegate: self.responder,
                                     delegateQueue: delegateQueue)
        self._accountsManager = accountsManager
        super.init()
    }

    deinit {
        urlSession.finishTasksAndInvalidate()
    }

    #if DEBUG
    /// Recreate the internal URLSession so it picks up any newly registered
    /// URLProtocol classes (e.g., MockBackendURLProtocol). Called by
    /// MockBackendService when activating/deactivating the mock backend.
    func recreateSession() {
        urlSession.finishTasksAndInvalidate()
        let config = TPPCaching.makeURLSessionConfiguration(
            caching: .fallback,
            requestTimeout: TPPNetworkExecutor.defaultRequestTimeout)
        urlSession = URLSession(configuration: config,
                                delegate: responder,
                                delegateQueue: nil)
        Log.info(#file, "TPPNetworkExecutor: session recreated for mock backend")
    }
    #endif

    @objc static let shared = TPPNetworkExecutor(cachingStrategy: .fallback)

    /// Number of underlying token-refresh attempts that have taken the
    /// single-flight slot since process start (or last reset). Concurrent
    /// 401s that coalesce behind an in-flight refresh do NOT increment this.
    /// Exposed for adversarial tests; safe to read from any context.
    var refreshAttemptCount: Int {
        get async { await tokenCoordinator.refreshAttemptCount }
    }

    /// Test-only: resets the refresh-attempt counter to zero. Does not affect
    /// in-flight refresh state.
    func resetRefreshAttemptCount() async {
        await tokenCoordinator.resetRefreshAttemptCount()
    }

    func GET(_ reqURL: URL,
             useTokenIfAvailable: Bool = true,
             completion: @escaping (_ result: NYPLResult<Data>) -> Void) {
        let req = request(for: reqURL, useTokenIfAvailable: useTokenIfAvailable)
        let task = executeRequest(req, enableTokenRefresh: useTokenIfAvailable, completion: completion)

        if let task = task {
            activeTasksStore.add(task)
        }
    }

    @objc func pauseAllTasks() {
        activeTasksStore.pauseNonAudioTasks()
    }

    @objc func resumeAllTasks() {
        activeTasksStore.resumeAll()
    }

    /// Cancels all active tasks that are not related to audiobook streaming.
    /// Called during account switches to prevent requests from completing with
    /// the wrong account's credentials. Synchronous on purpose — see
    /// `ActiveTasksStore` doc-comment.
    @objc func cancelNonEssentialTasks() {
        let count = activeTasksStore.cancelNonEssential()
        Log.info(#file, "Cancelled \(count) non-essential tasks during account switch")
    }
}

extension TPPNetworkExecutor: TPPRequestExecuting {
    @discardableResult
    func executeRequest(_ req: URLRequest, enableTokenRefresh: Bool, completion: @escaping (_: NYPLResult<Data>) -> Void) -> URLSessionDataTask? {
        let accountId = accountsManager.currentAccountId
        let userAccount = accountId.flatMap { AccountsManager.shared.userAccount(for: $0) } ?? AccountsManager.shared.currentUserAccount

        // SAML auth uses cookies, not tokens - proceed directly
        if let authDefinition = userAccount.authDefinition, authDefinition.isSaml {
            return performDataTask(with: req, completion: completion)
        }

        // Proactive token refresh: if token will expire soon, refresh before the request
        if enableTokenRefresh,
           userAccount.authTokenNearExpiry,
           let authDef = userAccount.authDefinition,
           authDef.isToken || authDef.isOauth,
           authDef.tokenURL != nil {
            Log.info(#file, "Token near expiry - proactively refreshing before request")
            refreshTokenAndResume(task: nil, accountId: accountId) { [weak self] _ in
                _ = self?.performDataTask(with: req, completion: completion)
            }
            return nil
        }

        return performDataTask(with: req, completion: completion)
    }

    private func performDataTask(with request: URLRequest,
                                 completion: @escaping (_: NYPLResult<Data>) -> Void) -> URLSessionDataTask {
        let task = urlSession.dataTask(with: request)
        responder.addCompletion(completion, taskID: task.taskIdentifier)
        task.resume()
        return task
    }
}

extension TPPNetworkExecutor {
    private func createErrorForRetryFailure() -> NSError {
        return NSError(
            domain: TPPErrorLogger.clientDomain,
            code: TPPErrorCode.invalidCredentials.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "Unauthorized HTTP after token refresh attempt"]
        )
    }
}

extension TPPNetworkExecutor {
    @objc func request(for url: URL, useTokenIfAvailable: Bool = true) -> URLRequest {
        return request(for: url, useTokenIfAvailable: useTokenIfAvailable, accountId: nil)
    }

    func request(for url: URL, useTokenIfAvailable: Bool = true, accountId: String?) -> URLRequest {
        var urlRequest = URLRequest(url: url,
                                    cachePolicy: urlSession.configuration.requestCachePolicy)
        // Don't optimistically try HTTP/3 (QUIC) on first contact with each host.
        // Some library servers advertise h3 but have broken QUIC — iOS retries
        // twice (~260ms wasted) before falling back to h2. With this flag off,
        // first requests use h2; the session upgrades to h3 automatically on
        // subsequent requests if the server confirms working QUIC via Alt-Svc.
        urlRequest.assumesHTTP3Capable = false
        urlRequest.applyCustomUserAgent()
        // Use per-account instance to prevent TOCTOU races during account switches.
        // Without this, another thread could change libraryUUID between
        // sharedAccount() and the property reads, causing cross-account
        // credential leaks.
        let resolvedId = accountId ?? accountsManager.currentAccountId ?? ""
        let snapshot = AccountsManager.shared.userAccount(for: resolvedId).credentialSnapshot()

        // SAML auth uses cookies, not tokens — make sure they are installed in
        // the shared cookie storage before the request goes out. Removing this
        // block silently regresses SAML sign-in.
        if let authDef = snapshot.authDefinition, authDef.isSaml,
           let cookies = snapshot.cookies, !cookies.isEmpty {
            let shared = HTTPCookieStorage.shared
            for cookie in cookies { shared.setCookie(cookie) }
        }

        if let authToken = snapshot.authToken, useTokenIfAvailable {
            urlRequest.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        }
        urlRequest.setValue("", forHTTPHeaderField: "Accept-Language")
        return urlRequest
    }

    @objc func clearCache() {
        urlSession.configuration.urlCache?.removeAllCachedResponses()
    }
}

extension TPPNetworkExecutor {
    @objc class func bearerAuthorized(request: URLRequest) -> URLRequest {
        var request = request
        let snapshot = AccountsManager.shared.currentUserAccount.credentialSnapshot()

        if let authToken = snapshot.authToken, !authToken.isEmpty {
            let tokenPrefix = String(authToken.prefix(8))
            Log.debug(#file, "Adding Bearer token (prefix: \(tokenPrefix)...) to request for \(request.url?.host ?? "unknown")")
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        } else {
            Log.warn(#file, "No auth token available for request to \(request.url?.host ?? "unknown") - hasCredentials: \(snapshot.hasCredentials)")
            request.setValue("", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    @objc func download(_ reqURL: URL,
                        completion: @escaping (_ result: Data?, _ response: URLResponse?, _ error: Error?) -> Void) -> URLSessionDownloadTask {
        let req = request(for: reqURL)
        let completionWrapper: (_ result: NYPLResult<Data>) -> Void = { result in
            switch result {
            case let .success(data, response): completion(data, response, nil)
            case let .failure(error, response): completion(nil, response, error)
            }
        }

        let task = urlSession.downloadTask(with: req)
        responder.addCompletion(completionWrapper, taskID: task.taskIdentifier)
        task.resume()

        return task
    }

    @objc func addBearerAndExecute(_ request: URLRequest,
                                   completion: @escaping (_ result: Data?, _ response: URLResponse?, _ error: Error?) -> Void) -> URLSessionDataTask? {
        let req = TPPNetworkExecutor.bearerAuthorized(request: request)
        let completionWrapper: (_ result: NYPLResult<Data>) -> Void = { result in
            switch result {
            case let .success(data, response): completion(data, response, nil)
            case let .failure(error, response): completion(nil, response, error)
            }
        }
        return executeRequest(req, enableTokenRefresh: false, completion: completionWrapper)
    }

    @objc func GET(_ reqURL: URL,
                   cachePolicy: NSURLRequest.CachePolicy = .useProtocolCachePolicy,
                   useTokenIfAvailable: Bool = true,
                   completion: @escaping (_ result: Data?, _ response: URLResponse?, _ error: Error?) -> Void) -> URLSessionDataTask? {
        GET(request: request(for: reqURL), cachePolicy: cachePolicy, useTokenIfAvailable: useTokenIfAvailable, completion: completion)
    }

    @objc func GET(request: URLRequest,
                   cachePolicy: NSURLRequest.CachePolicy = .useProtocolCachePolicy,
                   useTokenIfAvailable: Bool,
                   completion: @escaping (_ result: Data?, _ response: URLResponse?, _ error: Error?) -> Void) -> URLSessionDataTask? {
        if request.httpMethod != "GET" {
            var newRequest = request
            newRequest.httpMethod = "GET"
            return GET(request: newRequest, cachePolicy: cachePolicy, useTokenIfAvailable: useTokenIfAvailable, completion: completion)
        }

        var updatedReq = request
        updatedReq.cachePolicy = cachePolicy

        let completionWrapper: (_ result: NYPLResult<Data>) -> Void = { result in
            switch result {
            case let .success(data, response): completion(data, response, nil)
            case let .failure(error, response): completion(nil, response, error)
            }
        }
        return executeRequest(updatedReq, enableTokenRefresh: useTokenIfAvailable, completion: completionWrapper)
    }

    @objc func PUT(_ reqURL: URL,
                   useTokenIfAvailable: Bool,
                   completion: @escaping (_ result: Data?, _ response: URLResponse?, _ error: Error?) -> Void) -> URLSessionDataTask? {
        PUT(request: request(for: reqURL), useTokenIfAvailable: useTokenIfAvailable, completion: completion)
    }

    @objc func PUT(request: URLRequest,
                   useTokenIfAvailable: Bool,
                   completion: @escaping (_ result: Data?, _ response: URLResponse?, _ error: Error?) -> Void) -> URLSessionDataTask? {
        if request.httpMethod != "PUT" {
            var newRequest = request
            newRequest.httpMethod = "PUT"
            return PUT(request: newRequest, useTokenIfAvailable: useTokenIfAvailable, completion: completion)
        }

        let completionWrapper: (_ result: NYPLResult<Data>) -> Void = { result in
            switch result {
            case let .success(data, response): completion(data, response, nil)
            case let .failure(error, response): completion(nil, response, error)
            }
        }
        return executeRequest(request, enableTokenRefresh: useTokenIfAvailable, completion: completionWrapper)
    }

    @discardableResult
    @objc
    func POST(_ request: URLRequest,
              useTokenIfAvailable: Bool,
              completion: ((_ result: Data?, _ response: URLResponse?, _ error: Error?) -> Void)?) -> URLSessionDataTask? {
        if request.httpMethod != "POST" {
            var newRequest = request
            newRequest.httpMethod = "POST"
            return POST(newRequest, useTokenIfAvailable: useTokenIfAvailable, completion: completion)
        }

        let completionWrapper: (_ result: NYPLResult<Data>) -> Void = { result in
            switch result {
            case let .success(data, response): completion?(data, response, nil)
            case let .failure(error, response): completion?(nil, response, error)
            }
        }
        return executeRequest(request, enableTokenRefresh: useTokenIfAvailable, completion: completionWrapper)
    }

    @discardableResult
    @objc
    func DELETE(_ request: URLRequest,
                useTokenIfAvailable: Bool,
                completion: ((_ result: Data?, _ response: URLResponse?, _ error: Error?) -> Void)?) -> URLSessionDataTask? {
        if request.httpMethod != "DELETE" {
            var newRequest = request
            newRequest.httpMethod = "DELETE"
            return DELETE(newRequest, useTokenIfAvailable: useTokenIfAvailable, completion: completion)
        }

        let completionWrapper: (_ result: NYPLResult<Data>) -> Void = { result in
            switch result {
            case let .success(data, response): completion?(data, response, nil)
            case let .failure(error, response): completion?(nil, response, error)
            }
        }
        return executeRequest(request, enableTokenRefresh: false, completion: completionWrapper)
    }

    func refreshTokenAndResume(task: URLSessionTask?, accountId: String? = nil, completion: ((_ result: NYPLResult<Data>) -> Void)? = nil) {
        let capturedAccountId = accountId ?? accountsManager.currentAccountId
        Task { [weak self] in
            guard let self = self else {
                let error = NSError(domain: TPPErrorLogger.clientDomain, code: TPPErrorCode.invalidCredentials.rawValue, userInfo: [NSLocalizedDescriptionKey: "Network executor deallocated"])
                completion?(NYPLResult.failure(error, nil))
                return
            }

            // Atomic check-and-claim: only one caller can take the refresh slot.
            let claimed = await self.tokenCoordinator.tryClaimRefreshSlot()

            if !claimed {
                Log.debug(#file, "Token refresh already in progress, queueing task for retry")
                if let task {
                    await self.tokenCoordinator.appendToRetryQueue(task)
                    if let completion {
                        self.responder.addCompletion(completion, taskID: task.taskIdentifier)
                    }
                } else {
                    let error = NSError(domain: TPPErrorLogger.clientDomain, code: TPPErrorCode.invalidCredentials.rawValue, userInfo: [NSLocalizedDescriptionKey: "Token refresh in progress"])
                    completion?(NYPLResult.failure(error, nil))
                }
                return
            }

            // Use per-account instance to prevent TOCTOU races: without this,
            // another thread could switch libraryUUID between sharedAccount()
            // and the .username/.pin reads, sending Account B's credentials
            // to Account A's token endpoint.
            let snapshot = AccountsManager.shared.userAccount(for: capturedAccountId ?? AccountsManager.shared.currentAccountId ?? "").credentialSnapshot()
            guard let username = snapshot.barcode, !username.isEmpty,
                  let password = snapshot.pin,
                  let tokenURL = snapshot.authDefinition?.tokenURL else {
                Log.error(#file, "Cannot refresh token: missing credentials or tokenURL for account \(capturedAccountId ?? "nil")")
                await self.tokenCoordinator.setRefreshing(false)
                let error = NSError(domain: TPPErrorLogger.clientDomain, code: TPPErrorCode.invalidCredentials.rawValue, userInfo: [NSLocalizedDescriptionKey: "Cannot request token with empty credentials"])
                completion?(NYPLResult.failure(error, nil))
                return
            }

            let authType = snapshot.authDefinition?.authType.rawValue ?? "unknown"
            Log.info(#file, "Refreshing token for auth type: \(authType), account: \(capturedAccountId ?? "current")")

            if let task {
                await self.tokenCoordinator.appendToRetryQueue(task)
                if let completion {
                    self.responder.addCompletion(completion, taskID: task.taskIdentifier)
                }
            }

            self.executeTokenRefresh(username: username, password: password, tokenURL: tokenURL, accountId: capturedAccountId) { [weak self] result in
                guard let self else { return }
                Task {
                    switch result {
                    case .success(let tokenResponse):
                        Log.info(#file, "Token refresh successful for account \(capturedAccountId ?? "current"), expires in \(tokenResponse.expiresIn)s")

                        let queuedTasks = await self.tokenCoordinator.drainRetryQueue()
                        let retryCount = queuedTasks.count
                        var newTasks = [URLSessionTask]()

                        for oldTask in queuedTasks {
                            guard let originalRequest = oldTask.originalRequest,
                                  let originalURL = originalRequest.url else {
                                continue
                            }

                            let mutableRequest = self.request(for: originalURL)
                            let newTask = self.urlSession.dataTask(with: mutableRequest)
                            self.responder.updateCompletionId(oldTask.taskIdentifier, newId: newTask.taskIdentifier)
                            newTasks.append(newTask)
                            oldTask.cancel()
                        }

                        Log.info(#file, "Retrying \(retryCount) failed request(s) with new token")
                        newTasks.forEach { $0.resume() }

                        await self.tokenCoordinator.setRefreshing(false)

                        if task == nil {
                            completion?(NYPLResult.success(Data(), nil))
                        }

                    case .failure(let error):
                        Log.error(#file, "Failed to refresh token with error: \(error.localizedDescription)")

                        let failedTasks = await self.tokenCoordinator.drainRetryQueue()
                        failedTasks.forEach { $0.cancel() }

                        await self.tokenCoordinator.setRefreshing(false)

                        if let nsError = error as? NSError, nsError.code == 401 {
                            Log.info(#file, "Token refresh failed due to invalid credentials - marking credentials stale for account \(capturedAccountId ?? "current")")
                            await MainActor.run {
                                AccountsManager.shared.userAccount(for: capturedAccountId ?? AccountsManager.shared.currentAccountId ?? "").markCredentialsStale()
                                if capturedAccountId == nil || capturedAccountId == self.accountsManager.currentAccountId {
                                    SignInModalPresenter.presentSignInModalForCurrentAccount(completion: nil)
                                }
                            }
                        }

                        let nsError = NSError(domain: TPPErrorLogger.clientDomain,
                                              code: TPPErrorCode.invalidCredentials.rawValue,
                                              userInfo: [NSLocalizedDescriptionKey: "Token refresh failed: \(error.localizedDescription)"])
                        completion?(NYPLResult.failure(nsError, nil))
                    }
                }
            }
        }
    }

    func executeTokenRefresh(username: String, password: String, tokenURL: URL, accountId: String? = nil, completion: @escaping (Result<TokenResponse, Error>) -> Void) {
        guard !username.isEmpty else {
            // Note: empty password is valid for pinless libraries (PP-4045).
            // Only guard against empty username.
            Log.error(#file, "Cannot request token with empty username")
            let error = NSError(domain: TPPErrorLogger.clientDomain, code: TPPErrorCode.invalidCredentials.rawValue,
                                userInfo: [NSLocalizedDescriptionKey: "Cannot request token with empty username"])
            completion(.failure(error))
            return
        }

        let session = self.urlSession
        Task {
            let tokenRequest = TokenRequest(url: tokenURL, username: username, password: password)
            let result = await tokenRequest.execute(session: session)

            switch result {
            case .success(let tokenResponse):
                let targetAccount = AccountsManager.shared.userAccount(for: accountId ?? AccountsManager.shared.currentAccountId ?? "")
                targetAccount.setAuthToken(
                    tokenResponse.accessToken,
                    barcode: username,
                    pin: password,
                    expirationDate: tokenResponse.expirationDate
                )
                targetAccount.markLoggedIn()
                completion(.success(tokenResponse))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }
}

// MARK: - Continuation safety helper

/// Thread-safe one-shot guard for `withCheckedThrowingContinuation` bridges.
/// Calling `tryConsume()` returns `true` exactly once for the lifetime of the
/// instance; subsequent calls return `false`. Use to guarantee a continuation
/// is resumed at most once even if the underlying completion handler is
/// invoked multiple times by a buggy producer.
private final class ContinuationGuard {
    private var consumed = false
    private let lock = NSLock()
    func tryConsume() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if consumed { return false }
        consumed = true
        return true
    }
}

// MARK: - Async/Await API

extension TPPNetworkExecutor {

    /// Async version of GET that bridges to the completion-handler API.
    /// Timeout is handled by the URLSession configuration, not by a manual timer.
    /// The `ContinuationGuard` ensures the continuation is resumed exactly
    /// once even if a future regression in the completion path invokes the
    /// callback twice (e.g. through the token-refresh / retry paths).
    func GET(_ reqURL: URL, useTokenIfAvailable: Bool = true) async throws -> (Data, URLResponse?) {
        return try await withCheckedThrowingContinuation { continuation in
            let guarded = ContinuationGuard()
            GET(reqURL, useTokenIfAvailable: useTokenIfAvailable) { result in
                guard guarded.tryConsume() else { return }
                switch result {
                case let .success(data, response):
                    continuation.resume(returning: (data, response))
                case let .failure(error, _):
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Async version of GET with full request control.
    func GET(request: URLRequest, cachePolicy: NSURLRequest.CachePolicy = .useProtocolCachePolicy, useTokenIfAvailable: Bool) async throws -> (Data, URLResponse?) {
        return try await withCheckedThrowingContinuation { continuation in
            let guarded = ContinuationGuard()
            GET(request: request, cachePolicy: cachePolicy, useTokenIfAvailable: useTokenIfAvailable) { data, response, error in
                guard guarded.tryConsume() else { return }
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (data ?? Data(), response))
                }
            }
        }
    }

    /// Async version of PUT.
    func PUT(_ reqURL: URL, useTokenIfAvailable: Bool) async throws -> (Data, URLResponse?) {
        return try await withCheckedThrowingContinuation { continuation in
            let guarded = ContinuationGuard()
            PUT(reqURL, useTokenIfAvailable: useTokenIfAvailable) { data, response, error in
                guard guarded.tryConsume() else { return }
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (data ?? Data(), response))
                }
            }
        }
    }

    /// Async version of POST.
    func POST(_ request: URLRequest, useTokenIfAvailable: Bool) async throws -> (Data, URLResponse?) {
        return try await withCheckedThrowingContinuation { continuation in
            let guarded = ContinuationGuard()
            POST(request, useTokenIfAvailable: useTokenIfAvailable) { data, response, error in
                guard guarded.tryConsume() else { return }
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (data ?? Data(), response))
                }
            }
        }
    }

    /// Async version of DELETE.
    func DELETE(_ request: URLRequest, useTokenIfAvailable: Bool) async throws -> (Data, URLResponse?) {
        return try await withCheckedThrowingContinuation { continuation in
            let guarded = ContinuationGuard()
            DELETE(request, useTokenIfAvailable: useTokenIfAvailable) { data, response, error in
                guard guarded.tryConsume() else { return }
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (data ?? Data(), response))
                }
            }
        }
    }
}
