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

@objc class TPPNetworkExecutor: NSObject {
    private let urlSession: URLSession
    private let refreshQueue = DispatchQueue(label: "com.palace.token-refresh-queue", qos: .userInitiated)
    private var isRefreshing = false
    private var retryQueue: [URLSessionTask] = []
    private let retryQueueLock = NSLock()
    private var activeTasks: [URLSessionTask] = []
    private let activeTasksLock = NSLock()

    private let responder: TPPNetworkResponder

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
            addTaskToActiveTasks(task)
        }
    }

    private func addTaskToActiveTasks(_ task: URLSessionTask) {
        activeTasksLock.lock()
        activeTasks.append(task)
        activeTasksLock.unlock()
    }

    private func removeTaskFromActiveTasks(_ task: URLSessionTask) {
        activeTasksLock.lock()
        if let index = activeTasks.firstIndex(of: task) {
            activeTasks.remove(at: index)
        }
        activeTasksLock.unlock()
    }

    @objc func pauseAllTasks() {
        activeTasksLock.lock()
        activeTasks.forEach { task in
            if let url = task.originalRequest?.url,
               url.absoluteString.contains("audiobook") ||
                url.absoluteString.contains(".mp3") ||
                url.absoluteString.contains(".m4a") ||
                url.absoluteString.contains("audio") ||
                url.absoluteString.contains("readium") ||
                url.absoluteString.contains("lcp") {
                Log.info(#file, "Preserving audiobook network task: \(url.absoluteString)")
                return
            }
            task.suspend()
        }
        activeTasksLock.unlock()
    }

    @objc func resumeAllTasks() {
        activeTasksLock.lock()
        activeTasks.forEach { $0.resume() }
        activeTasksLock.unlock()
    }

    /// Cancels all active tasks that are not related to audiobook streaming.
    /// Called during account switches to prevent requests from completing with
    /// the wrong account's credentials.
    @objc func cancelNonEssentialTasks() {
        activeTasksLock.lock()
        let tasksToCancel = activeTasks.filter { task in
            guard let url = task.originalRequest?.url?.absoluteString else { return true }
            let isAudiobook = url.contains("audiobook") ||
                url.contains(".mp3") ||
                url.contains(".m4a") ||
                url.contains("audio") ||
                url.contains("readium") ||
                url.contains("lcp")
            return !isAudiobook
        }
        tasksToCancel.forEach { $0.cancel() }
        activeTasks.removeAll { tasksToCancel.contains($0) }
        activeTasksLock.unlock()
        Log.info(#file, "Cancelled \(tasksToCancel.count) non-essential tasks during account switch")
    }
}

extension TPPNetworkExecutor: TPPRequestExecuting {
    @discardableResult
    func executeRequest(_ req: URLRequest, enableTokenRefresh: Bool, completion: @escaping (_: NYPLResult<Data>) -> Void) -> URLSessionDataTask? {
        let accountId = AccountsManager.shared.currentAccountId
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
        let account = TPPUserAccount.sharedAccount(libraryUUID: accountId ?? AccountsManager.shared.currentAccountId)

        if let authDef = account.authDefinition, authDef.isSaml,
           let cookies = account.cookies, !cookies.isEmpty {
            let shared = HTTPCookieStorage.shared
            for cookie in cookies { shared.setCookie(cookie) }
        }

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
        let capturedAccountId = accountId ?? AccountsManager.shared.currentAccountId
        refreshQueue.async { [weak self] in
            guard let self = self else {
                let error = NSError(domain: TPPErrorLogger.clientDomain, code: TPPErrorCode.invalidCredentials.rawValue, userInfo: [NSLocalizedDescriptionKey: "Network executor deallocated"])
                completion?(NYPLResult.failure(error, nil))
                return
            }

            if self.isRefreshing {
                Log.debug(#file, "Token refresh already in progress, queueing task for retry")
                if let task {
                    self.retryQueueLock.lock()
                    self.retryQueue.append(task)
                    if let completion {
                        self.responder.addCompletion(completion, taskID: task.taskIdentifier)
                    }
                    self.retryQueueLock.unlock()
                } else {
                    let error = NSError(domain: TPPErrorLogger.clientDomain, code: TPPErrorCode.invalidCredentials.rawValue, userInfo: [NSLocalizedDescriptionKey: "Token refresh in progress"])
                    completion?(NYPLResult.failure(error, nil))
                }
                return
            }

            self.isRefreshing = true

            let account = TPPUserAccount.sharedAccount(libraryUUID: capturedAccountId)
            guard let username = account.username,
                  let password = account.pin,
                  let tokenURL = account.authDefinition?.tokenURL else {
                Log.error(#file, "Cannot refresh token: missing credentials or tokenURL for account \(capturedAccountId ?? "nil")")
                self.isRefreshing = false
                let error = NSError(domain: TPPErrorLogger.clientDomain, code: TPPErrorCode.invalidCredentials.rawValue, userInfo: [NSLocalizedDescriptionKey: "Unauthorized HTTP"])
                completion?(NYPLResult.failure(error, nil))
                return
            }

            let authDef = account.authDefinition
            let authType = authDef?.authType.rawValue ?? "unknown"
            let credentialType: String
            switch account.credentials {
            case .token(let authToken, let barcode, let pin, let expirationDate):
                let hasBarcode = barcode != nil && !barcode!.isEmpty
                let hasPin = pin != nil && !pin!.isEmpty
                let hasToken = !authToken.isEmpty
                let tokenExpired = expirationDate.map { $0 < Date() } ?? false
                credentialType = "token(hasBarcode=\(hasBarcode), hasPin=\(hasPin), hasToken=\(hasToken), tokenExpired=\(tokenExpired))"
            case .barcodeAndPin(let barcode, _):
                credentialType = "barcodeAndPin(barcodeLen=\(barcode.count))"
            case .cookies:
                credentialType = "cookies"
            case .none:
                credentialType = "nil"
            }
            let isOAuth = authDef?.isOauth == true
            let isToken = authDef?.isToken == true
            let isBasic = authDef?.isBasic == true
            Log.info(#file, "Refreshing token for auth type: \(authType), account: \(capturedAccountId ?? "current")")
            Log.info(#file, "  Auth flags: isBasic=\(isBasic), isToken=\(isToken), isOAuth=\(isOAuth)")
            Log.info(#file, "  Credential type: \(credentialType)")
            Log.info(#file, "  Using username(len=\(username.count)) + password(len=\(password.count)) for Basic Auth")
            if isOAuth && !isToken {
                Log.warn(#file, "  ⚠️ POTENTIAL MISMATCH: OAuth auth type but attempting Basic Auth token refresh")
            }

            if let task {
                self.retryQueueLock.lock()
                self.retryQueue.append(task)
                if let completion {
                    self.responder.addCompletion(completion, taskID: task.taskIdentifier)
                }
                self.retryQueueLock.unlock()
            }

            self.executeTokenRefresh(username: username, password: password, tokenURL: tokenURL, accountId: capturedAccountId) { result in
                defer { self.isRefreshing = false }

                switch result {
                case .success(let tokenResponse):
                    Log.info(#file, "Token refresh successful for account \(capturedAccountId ?? "current"), expires in \(tokenResponse.expiresIn)s")

                    var newTasks = [URLSessionTask]()

                    self.retryQueueLock.lock()
                    let retryCount = self.retryQueue.count
                    self.retryQueue.forEach { oldTask in
                        guard let originalRequest = oldTask.originalRequest,
                              let originalURL = originalRequest.url else {
                            return
                        }

                        let mutableRequest = self.request(for: originalURL)
                        // Note: Retry tracking is now handled by URL-based tracking in TPPNetworkResponder
                        let newTask = self.urlSession.dataTask(with: mutableRequest)
                        self.responder.updateCompletionId(oldTask.taskIdentifier, newId: newTask.taskIdentifier)
                        newTasks.append(newTask)

                        oldTask.cancel()
                    }

                    self.retryQueue.removeAll()
                    self.retryQueueLock.unlock()

                    Log.info(#file, "Retrying \(retryCount) failed request(s) with new token")
                    newTasks.forEach { $0.resume() }

                    // For proactive refresh (task was nil), call completion to let caller proceed
                    // The completion handler will trigger the original request with the new token
                    if task == nil {
                        completion?(NYPLResult.success(Data(), nil))
                    }

                case .failure(let error):
                    Log.error(#file, "Failed to refresh token with error: \(error.localizedDescription)")

                    self.retryQueueLock.lock()
                    let failedTasks = self.retryQueue
                    self.retryQueue.removeAll()
                    self.retryQueueLock.unlock()

                    failedTasks.forEach { $0.cancel() }

                    if let nsError = error as? NSError, nsError.code == 401 {
                        Log.info(#file, "Token refresh failed due to invalid credentials - marking credentials stale for account \(capturedAccountId ?? "current")")
                        DispatchQueue.main.async {
                            TPPUserAccount.sharedAccount(libraryUUID: capturedAccountId).markCredentialsStale()
                            if capturedAccountId == nil || capturedAccountId == AccountsManager.shared.currentAccountId {
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

    private func retryFailedRequests() {
        retryQueueLock.lock()
        while !retryQueue.isEmpty {
            let task = retryQueue.removeFirst()
            retryQueueLock.unlock()
            guard let request = task.originalRequest else {
                retryQueueLock.lock()
                continue
            }
            self.executeRequest(request, enableTokenRefresh: true) { _ in
                Log.info(#file, "Task Successfully resumed after token refresh")
            }
            retryQueueLock.lock()
        }
        retryQueueLock.unlock()
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

extension TPPNetworkExecutor {
    func GET(_ reqURL: URL, useTokenIfAvailable: Bool = true) async throws -> (Data, URLResponse?) {
        return try await withCheckedThrowingContinuation { continuation in
            var didResume = false

            GET(reqURL, useTokenIfAvailable: useTokenIfAvailable) { result in
                guard !didResume else {
                    return
                }
                didResume = true

                switch result {
                case let .success(data, response):
                    continuation.resume(returning: (data, response))
                case let .failure(error, _):
                    continuation.resume(throwing: error)
                }
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + 10.0) {
                guard !didResume else { return }
                didResume = true
                let timeoutError = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: nil)
                continuation.resume(throwing: timeoutError)
            }
        }
    }
}
