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
    activeTasks.forEach { $0.suspend() }
    activeTasksLock.unlock()
  }
  
  @objc func resumeAllTasks() {
    activeTasksLock.lock()
    activeTasks.forEach { $0.resume() }
    activeTasksLock.unlock()
  }
}

extension TPPNetworkExecutor: TPPRequestExecuting {
  @discardableResult
  func executeRequest(_ req: URLRequest, enableTokenRefresh: Bool, completion: @escaping (_: NYPLResult<Data>) -> Void) -> URLSessionDataTask? {
    let userAccount = TPPUserAccount.sharedAccount()
    
    if let authDefinition = userAccount.authDefinition, authDefinition.isSaml {
      return performDataTask(with: req, completion: completion)
    }
    
    if userAccount.isTokenRefreshRequired() && enableTokenRefresh {
      let task = urlSession.dataTask(with: req)
      refreshTokenAndResume(task: task, completion: completion)
      return task
    }
    
    if req.hasRetried && userAccount.isTokenRefreshRequired() {
      let error = createErrorForRetryFailure()
      completion(NYPLResult.failure(error, nil))
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
    var urlRequest = URLRequest(url: url,
                                cachePolicy: urlSession.configuration.requestCachePolicy)
    urlRequest.applyCustomUserAgent()
    if let authToken = TPPUserAccount.sharedAccount().authToken, useTokenIfAvailable {
      let headers = [
        "Authorization": "Bearer \(authToken)",
        "Content-Type": "application/json"
      ]
      headers.forEach { urlRequest.setValue($0.value, forHTTPHeaderField: $0.key) }
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
    let headers: [String: String]
    if let authToken = TPPUserAccount.sharedAccount().authToken, !authToken.isEmpty {
      headers = [
        "Authorization": "Bearer \(authToken)",
        "Content-Type": "application/json"
      ]
    } else {
      headers = [
        "Authorization": "",
        "Content-Type": "application/json"
      ]
    }

    var request = request
    for (headerKey, headerValue) in headers {
      request.setValue(headerValue, forHTTPHeaderField: headerKey)
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
    if (request.httpMethod != "GET") {
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
    if (request.httpMethod != "PUT") {
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
    if (request.httpMethod != "POST") {
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
    if (request.httpMethod != "DELETE") {
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
  
  func refreshTokenAndResume(task: URLSessionTask?, completion: ((_ result: NYPLResult<Data>) -> Void)? = nil) {
    refreshQueue.async { [weak self] in
      guard let self = self else { return }
      guard !self.isRefreshing else { return }
      
      self.isRefreshing = true
      
      guard let username = TPPUserAccount.sharedAccount().username,
            let password = TPPUserAccount.sharedAccount().pin else {
        Log.info(#file, "Failed to refresh token due to missing credentials!")
        self.isRefreshing = false
        let error = NSError(domain: TPPErrorLogger.clientDomain, code: TPPErrorCode.invalidCredentials.rawValue, userInfo: [NSLocalizedDescriptionKey: "Unauthorized HTTP"])
        completion?(NYPLResult.failure(error, nil))
        return
      }
      
      if let task {
        self.retryQueueLock.lock()
        self.retryQueue.append(task)
        if let completion {
          responder.addCompletion(completion, taskID: task.taskIdentifier)
        }
        self.retryQueueLock.unlock()
      }
      
      self.executeTokenRefresh(username: username, password: password) { result in
        defer { self.isRefreshing = false }
        
        switch result {
        case .success:
          var newTasks = [URLSessionTask]()
          
          self.retryQueueLock.lock()
          self.retryQueue.forEach { oldTask in
            guard let originalRequest = oldTask.originalRequest,
                  let originalURL = originalRequest.url else {
              return
            }
            
            var mutableRequest = self.request(for: originalURL)
            mutableRequest.hasRetried = true
            let newTask = self.urlSession.dataTask(with: mutableRequest)
            self.responder.updateCompletionId(oldTask.taskIdentifier, newId: newTask.taskIdentifier)
            newTasks.append(newTask)
            
            oldTask.cancel()
          }
          
          self.retryQueue.removeAll()
          self.retryQueueLock.unlock()
          
          newTasks.forEach { $0.resume() }
          
        case .failure(let error):
          Log.info(#file, "Failed to refresh token with error: \(error)")
          let error = NSError(domain: TPPErrorLogger.clientDomain, code: TPPErrorCode.invalidCredentials.rawValue, userInfo: [NSLocalizedDescriptionKey: "\(error.localizedDescription)"])
          completion?(NYPLResult.failure(error, nil))
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

  
  func executeTokenRefresh(username: String, password: String, completion: @escaping (Result<TokenResponse, Error>) -> Void) {
    guard let tokenURL = TPPUserAccount.sharedAccount().authDefinition?.tokenURL else {
      Log.error(#file, "Unable to refresh token, missing credentials")
      completion(.failure(NSError(domain: "Unable to refresh token, missing credentials", code: 401)))
      return
    }
    
    Task {
      let tokenRequest = TokenRequest(url: tokenURL, username: username, password: password)
      let result = await tokenRequest.execute()
      
      switch result {
      case .success(let tokenResponse):
        TPPUserAccount.sharedAccount().setAuthToken(
          tokenResponse.accessToken,
          barcode: username,
          pin: password,
          expirationDate: tokenResponse.expirationDate
        )
        completion(.success(tokenResponse))
      case .failure(let error):
        completion(.failure(error))
      }
    }
  }
}

private extension URLRequest {
  struct AssociatedKeys {
    static var hasRetriedKey = "hasRetriedKey"
  }
  
  var hasRetried: Bool {
    get {
      return objc_getAssociatedObject(self, &AssociatedKeys.hasRetriedKey) as? Bool ?? false
    }
    set {
      objc_setAssociatedObject(self, &AssociatedKeys.hasRetriedKey, newValue, .OBJC_ASSOCIATION_RETAIN)
    }
  }
}

extension TPPNetworkExecutor {
  func GET(_ reqURL: URL, useTokenIfAvailable: Bool = true) async throws -> (Data, URLResponse?) {
    return try await withCheckedThrowingContinuation { continuation in
      GET(reqURL, useTokenIfAvailable: useTokenIfAvailable) { result in
        switch result {
        case let .success(data, response):
          continuation.resume(returning: (data, response))
        case let .failure(error, response):
          continuation.resume(throwing: error)
        }
      }
    }
  }
}
