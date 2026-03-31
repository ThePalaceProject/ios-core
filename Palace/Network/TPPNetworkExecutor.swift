//
//  TPPNetworkExecutor.swift
//  The Palace Project
//
//  Created by Ettore Pasquini on 3/19/20.
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

import Foundation

enum NYPLResult<SuccessInfo> {
    case success(SuccessInfo, URLResponse?)
    case failure(TPPUserFriendlyError, URLResponse?)
}

/// Actor that serializes access to the token refresh state and retry queue.
private actor TokenRefreshCoordinator {
    var isRefreshing = false
    var retryQueue: [URLSessionTask] = []

    func setRefreshing(_ value: Bool) {
        isRefreshing = value
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

/// Actor that serializes access to the active tasks list.
private actor ActiveTasksCoordinator {
    var tasks: [URLSessionTask] = []

    func add(_ task: URLSessionTask) {
        tasks.append(task)
    }

    func remove(_ task: URLSessionTask) {
        if let index = tasks.firstIndex(of: task) {
            tasks.remove(at: index)
        }
    }

    func pauseNonAudioTasks() {
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
        tasks.forEach { $0.resume() }
    }

    func cancelNonEssential() -> Int {
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
    private let urlSession: URLSession
    private let tokenCoordinator = TokenRefreshCoordinator()
    private let activeTasksCoordinator = ActiveTasksCoordinator()

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

    @objc static let shared = TPPNetworkExecutor(cachingStrategy: .fallback)

    func GET(_ reqURL: URL,
             useTokenIfAvailable: Bool = true,
             completion: @escaping (_ result: NYPLResult<Data>) -> Void) {
        let req = request(for: reqURL, useTokenIfAvailable: useTokenIfAvailable)
        let task = executeRequest(req, enableTokenRefresh: useTokenIfAvailable, completion: completion)

        if let task = task {
            Task { await activeTasksCoordinator.add(task) }
        }
    }

    @objc func pauseAllTasks() {
        Task { await activeTasksCoordinator.pauseNonAudioTasks() }
    }

    @objc func resumeAllTasks() {
        Task { await activeTasksCoordinator.resumeAll() }
    }

    /// Cancels all active tasks that are not related to audiobook streaming.
    /// Called during account switches to prevent requests from completing with
    /// the wrong account's credentials.
    @objc func cancelNonEssentialTasks() {
        Task {
            let count = await activeTasksCoordinator.cancelNonEssential()
            Log.info(#file, "Cancelled \(count) non-essential tasks during account switch")
        }
    }
}

extension TPPNetworkExecutor: TPPRequestExecuting {
    @discardableResult
    func executeRequest(_ req: URLRequest, enableTokenRefresh: Bool, completion: @escaping (_: NYPLResult<Data>) -> Void) -> URLSessionDataTask? {
        let accountId = accountsManager.currentAccountId
        let userAccount = TPPUserAccount.sharedAccount(libraryUUID: accountId)

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
        urlRequest.applyCustomUserAgent()
        let account = TPPUserAccount.sharedAccount(libraryUUID: accountId ?? accountsManager.currentAccountId)
        if let authToken = account.authToken, useTokenIfAvailable {
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
        let userAccount = TPPUserAccount.sharedAccount()

        if let authToken = userAccount.authToken, !authToken.isEmpty {
            let tokenPrefix = String(authToken.prefix(8))
            Log.debug(#file, "Adding Bearer token (prefix: \(tokenPrefix)...) to request for \(request.url?.host ?? "unknown")")
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        } else {
            Log.warn(#file, "No auth token available for request to \(request.url?.host ?? "unknown") - hasCredentials: \(userAccount.hasCredentials())")
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

            let alreadyRefreshing = await self.tokenCoordinator.isRefreshing

            if alreadyRefreshing {
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

            await self.tokenCoordinator.setRefreshing(true)

            let account = TPPUserAccount.sharedAccount(libraryUUID: capturedAccountId)
            guard let username = account.username,
                  let password = account.pin,
                  let tokenURL = account.authDefinition?.tokenURL else {
                Log.error(#file, "Cannot refresh token: missing credentials or tokenURL for account \(capturedAccountId ?? "nil")")
                await self.tokenCoordinator.setRefreshing(false)
                let error = NSError(domain: TPPErrorLogger.clientDomain, code: TPPErrorCode.invalidCredentials.rawValue, userInfo: [NSLocalizedDescriptionKey: "Unauthorized HTTP"])
                completion?(NYPLResult.failure(error, nil))
                return
            }

            let authType = account.authDefinition?.authType.rawValue ?? "unknown"
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
                                TPPUserAccount.sharedAccount(libraryUUID: capturedAccountId).markCredentialsStale()
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
        let session = self.urlSession
        Task {
            let tokenRequest = TokenRequest(url: tokenURL, username: username, password: password)
            let result = await tokenRequest.execute(session: session)

            switch result {
            case .success(let tokenResponse):
                TPPUserAccount.sharedAccount().atomicUpdate(for: accountId) { account in
                    account.setAuthToken(
                        tokenResponse.accessToken,
                        barcode: username,
                        pin: password,
                        expirationDate: tokenResponse.expirationDate
                    )
                    account.markLoggedIn()
                }
                completion(.success(tokenResponse))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }
}

// MARK: - Async/Await API

extension TPPNetworkExecutor {

    /// Async version of GET that bridges to the completion-handler API.
    /// Timeout is handled by the URLSession configuration, not by a manual timer.
    func GET(_ reqURL: URL, useTokenIfAvailable: Bool = true) async throws -> (Data, URLResponse?) {
        return try await withCheckedThrowingContinuation { continuation in
            GET(reqURL, useTokenIfAvailable: useTokenIfAvailable) { result in
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
            GET(request: request, cachePolicy: cachePolicy, useTokenIfAvailable: useTokenIfAvailable) { data, response, error in
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
            PUT(reqURL, useTokenIfAvailable: useTokenIfAvailable) { data, response, error in
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
            POST(request, useTokenIfAvailable: useTokenIfAvailable) { data, response, error in
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
            DELETE(request, useTokenIfAvailable: useTokenIfAvailable) { data, response, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (data ?? Data(), response))
                }
            }
        }
    }
}
