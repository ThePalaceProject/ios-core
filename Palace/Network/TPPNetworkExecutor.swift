//
//  TPPNetworkExecutor.swift
//  The Palace Project
//
//  Created by Ettore Pasquini on 3/19/20.
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

import Foundation

/// Use this enum to express either-or semantics in a result.
enum NYPLResult<SuccessInfo> {
  case success(SuccessInfo, URLResponse?)
  case failure(TPPUserFriendlyError, URLResponse?)
}

/// A class that is capable of executing network requests in a thread-safe way.
/// This class implements caching according to server response caching headers,
/// but can also be configured to have a fallback mechanism to cache responses
/// that lack a sufficient set of caching headers. This fallback cache attempts
/// to use the value found in the `max-age` directive of the `Cache-Control`
/// header if present, otherwise defaults to 3 hours.
///
/// The cache lives on both memory and disk.
@objc class TPPNetworkExecutor: NSObject {
  private let urlSession: URLSession
  private let refreshQueue = DispatchQueue(label: "com.palace.token-refresh-queue", qos: .userInitiated)
  private var isRefreshing = false
  private var retryQueue: [URLSessionTask] = []

  /// The delegate of the URLSession.
  private let responder: TPPNetworkResponder

  /// Designated initializer.
  /// - Parameter credentialsProvider: The object responsible with providing cretdentials
  /// - Parameter cachingStrategy: The strategy to cache responses with.
  /// - Parameter delegateQueue: The queue where callbacks will be called.
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

  /// A shared generic executor with enabled fallback caching.
  @objc static let shared = TPPNetworkExecutor(cachingStrategy: .fallback)

  /// Performs a GET request using the specified URL
  /// - Parameters:
  ///   - reqURL: URL of the resource to GET.
  ///   - completion: Always called when the resource is either fetched from
  /// the network or from the cache.
  func GET(_ reqURL: URL,
           useTokenIfAvailable: Bool = true,
           completion: @escaping (_ result: NYPLResult<Data>) -> Void) {
    let req = request(for: reqURL, useTokenIfAvailable: useTokenIfAvailable)
    executeRequest(req, completion: completion)
  }
}

extension TPPNetworkExecutor: TPPRequestExecuting {
  /// Executes a given request.
  /// - Parameters:
  ///   - req: The request to perform.
  ///   - completion: Always called when the resource is either fetched from
  /// the network or from the cache.
  /// - Returns: The task issueing the given request.
  @discardableResult
  func executeRequest(_ req: URLRequest, completion: @escaping (_: NYPLResult<Data>) -> Void) -> URLSessionDataTask {
    let userAccount = TPPUserAccount.sharedAccount()
    
    if let authDefinition = userAccount.authDefinition, authDefinition.isSaml {
      return performDataTask(with: req, completion: completion)
    }
    
    if userAccount.isTokenRefreshRequired() {
      handleTokenRefresh(for: req, completion: completion)
      return URLSessionDataTask()
    }
    
    if req.hasRetried && userAccount.isTokenRefreshRequired() {
      let error = createErrorForRetryFailure()
      completion(NYPLResult.failure(error, nil))
      return URLSessionDataTask()
    }
    
    return performDataTask(with: req, completion: completion)
  }

  private func createErrorForRetryFailure() -> NSError {
    return NSError(
      domain: TPPErrorLogger.clientDomain,
      code: TPPErrorCode.invalidCredentials.rawValue,
      userInfo: [NSLocalizedDescriptionKey: "Unauthorized HTTP after token refresh attempt"]
    )
  }

  private func handleTokenRefresh(for req: URLRequest, completion: @escaping (_: NYPLResult<Data>) -> Void) {
    refreshTokenAndResume(task: nil) { [weak self] newToken in
      guard let strongSelf = self else { return }
      
      if let token = newToken {
        var updatedRequest = req
        updatedRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        updatedRequest.hasRetried = true
        strongSelf.executeRequest(updatedRequest, completion: completion)
      } else {
        let error = NSError(domain: TPPErrorLogger.clientDomain, code: TPPErrorCode.invalidCredentials.rawValue, userInfo: [NSLocalizedDescriptionKey: "Unauthorized HTTP"])
        completion(NYPLResult.failure(error, nil))
      }
    }
  }

  private func performDataTask(with request: URLRequest,
                               completion: @escaping (_: NYPLResult<Data>) -> Void) -> URLSessionDataTask {
    let task = urlSession.dataTask(with: request)
    responder.addCompletion(completion, taskID: task.taskIdentifier)
    Log.info(#file, "Task \(task.taskIdentifier): starting request \(request.loggableString)")
    task.resume()
    return task
  }
}

extension TPPNetworkExecutor {
  @objc func request(for url: URL, useTokenIfAvailable: Bool = true) -> URLRequest {

    var urlRequest = URLRequest(url: url,
                                cachePolicy: urlSession.configuration.requestCachePolicy)

    if let authToken = TPPUserAccount.sharedAccount().authToken, useTokenIfAvailable {
      let headers = [
        "Authorization" : "Bearer \(authToken)",
        "Content-Type" : "application/json"
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

// Objective-C compatibility
extension TPPNetworkExecutor {
  @objc class func bearerAuthorized(request: URLRequest) -> URLRequest {
    let headers: [String: String]
    if let authToken = TPPUserAccount.sharedAccount().authToken, !authToken.isEmpty {
      headers = [
        "Authorization" : "Bearer \(authToken)",
        "Content-Type" : "application/json"]
    } else {
      headers = [
        "Authorization" : "",
        "Content-Type" : "application/json"]
    }

    var request = request
    for (headerKey, headerValue) in headers {
      request.setValue(headerValue, forHTTPHeaderField: headerKey)
    }
    return request
  }

  /// Performs a GET request using the specified URL
  /// - Parameters:
  ///   - reqURL: URL of the resource to GET.
  ///   - completion: Always called when the resource is either fetched from
  /// the network or from the cache.
  @objc func download(_ reqURL: URL,
                      completion: @escaping (_ result: Data?, _ response: URLResponse?,  _ error: Error?) -> Void) -> URLSessionDownloadTask {
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

  /// Performs a GET request using the specified URL, if oauth token is available, it is added to the request
  /// - Parameters:
  ///   - reqURL: URL of the resource to GET.
  ///   - completion: Always called when the resource is either fetched from
  /// the network or from the cache.
  @objc func addBearerAndExecute(_ request: URLRequest,
                     completion: @escaping (_ result: Data?, _ response: URLResponse?,  _ error: Error?) -> Void) -> URLSessionDataTask? {
    let req = TPPNetworkExecutor.bearerAuthorized(request: request)
    let completionWrapper: (_ result: NYPLResult<Data>) -> Void = { result in
      switch result {
      case let .success(data, response): completion(data, response, nil)
      case let .failure(error, response): completion(nil, response, error)
      }
    }
    return executeRequest(req, completion: completionWrapper)
  }
  
  // Performs a GET request using the specified URL
  /// - Parameters:
  ///   - reqURL: URL of the resource to GET.
  ///   - completion: Always called when the resource is either fetched from
  /// the network or from the cache.
  @objc func GET(_ reqURL: URL,
                 cachePolicy: NSURLRequest.CachePolicy = .useProtocolCachePolicy,
                 useTokenIfAvailable: Bool = true,
                 completion: @escaping (_ result: Data?, _ response: URLResponse?,  _ error: Error?) -> Void) -> URLSessionDataTask? {
    GET(request: request(for: reqURL), cachePolicy: cachePolicy, useTokenIfAvailable: useTokenIfAvailable, completion: completion)
  }
  
  /// Performs a GET request using the specified URLRequest
  /// - Parameters:
  ///   - request: URLRequest of the resource to GET.
  ///   - completion: Always called when the resource is either fetched from
  /// the network or from the cache.
  @objc func GET(request: URLRequest,
                 cachePolicy: NSURLRequest.CachePolicy = .useProtocolCachePolicy,
                 useTokenIfAvailable: Bool,
                 completion: @escaping (_ result: Data?, _ response: URLResponse?,  _ error: Error?) -> Void) -> URLSessionDataTask? {
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
    return executeRequest(updatedReq, completion: completionWrapper)
  }

  /// Performs a PUT request using the specified URL
  /// - Parameters:
  ///   - reqURL: URL of the resource to PUT.
  ///   - completion: Always called when the resource is either fetched from
  /// the network or from the cache.
  @objc func PUT(_ reqURL: URL,
                 completion: @escaping (_ result: Data?, _ response: URLResponse?,  _ error: Error?) -> Void) -> URLSessionDataTask? {
    PUT(request: request(for: reqURL), completion: completion)
  }

  /// Performs a PUT request using the specified URLRequest
  /// - Parameters:
  ///   - request: URLRequest of the resource to PUT.
  ///   - completion: Always called when the resource is either fetched from
  /// the network or from the cache.
  @objc func PUT(request: URLRequest,
                 completion: @escaping (_ result: Data?, _ response: URLResponse?,  _ error: Error?) -> Void) -> URLSessionDataTask? {
    if (request.httpMethod != "PUT") {
      var newRequest = request
      newRequest.httpMethod = "PUT"
      return PUT(request: newRequest, completion: completion)
    }

    let completionWrapper: (_ result: NYPLResult<Data>) -> Void = { result in
      switch result {
      case let .success(data, response): completion(data, response, nil)
      case let .failure(error, response): completion(nil, response, error)
      }
    }
    return executeRequest(request, completion: completionWrapper)
  }
    
  /// Performs a POST request using the specified request
  /// - Parameters:
  ///   - request: Request to be posted..
  ///   - completion: Always called when the api call either returns or times out
  @discardableResult
  @objc
  func POST(_ request: URLRequest,
            completion: ((_ result: Data?, _ response: URLResponse?,  _ error: Error?) -> Void)?) -> URLSessionDataTask? {
    
    if (request.httpMethod != "POST") {
      var newRequest = request
      newRequest.httpMethod = "POST"
      return POST(newRequest, completion: completion)
    }
    
    let completionWrapper: (_ result: NYPLResult<Data>) -> Void = { result in
      switch result {
      case let .success(data, response): completion?(data, response, nil)
      case let .failure(error, response): completion?(nil, response, error)
      }
    }
    
    return executeRequest(request, completion: completionWrapper)
  }
  
  /// Performs a DELETE request using the specified request
  /// - Parameters:
  ///   - request: Request to be deleted..
  ///   - completion: Always called when the api call either returns or times out
  @discardableResult
  @objc
  func DELETE(_ request: URLRequest,
            completion: ((_ result: Data?, _ response: URLResponse?,  _ error: Error?) -> Void)?) -> URLSessionDataTask? {
    
    if (request.httpMethod != "DELETE") {
      var newRequest = request
      newRequest.httpMethod = "DELETE"
      return DELETE(newRequest, completion: completion)
    }
    
    let completionWrapper: (_ result: NYPLResult<Data>) -> Void = { result in
      switch result {
      case let .success(data, response): completion?(data, response, nil)
      case let .failure(error, response): completion?(nil, response, error)
      }
    }
    
    return executeRequest(request, completion: completionWrapper)
  }
  
  func refreshTokenAndResume(task: URLSessionTask?, completion: ((String?) -> Void)? = nil) {
    refreshQueue.async { [weak self] in
      guard let self = self else { return }
      guard !self.isRefreshing else {
        completion?(nil)
        return
      }
      
      self.isRefreshing = true
      
      guard let username = TPPUserAccount.sharedAccount().username,
            let password = TPPUserAccount.sharedAccount().pin else {
        Log.info(#file, "Failed to refresh token due to missing credentials!")
        self.isRefreshing = false
        completion?(nil)
        return
      }
      
      if let task = task {
        self.retryQueue.append(task)
      }
      
      self.executeTokenRefresh(username: username, password: password) { result in
        defer { self.isRefreshing = false }
        
        switch result {
        case .success(let token):
          var newTasks = [URLSessionTask]()
          
          self.retryQueue.forEach { oldTask in
            guard let originalRequest = oldTask.originalRequest,
                  let url = originalRequest.url else {
              return
            }
            
            let mutableRequest = self.request(for: url)
            let newTask = self.urlSession.dataTask(with: mutableRequest)
            
            self.responder.updateCompletionId(oldTask.taskIdentifier, newId: newTask.taskIdentifier)
            newTasks.append(newTask)
            
            oldTask.cancel()
          }
          
          newTasks.forEach { $0.resume() }
          self.retryQueue.removeAll()
          
          completion?(token.accessToken)
          
        case .failure(let error):
          Log.info(#file, "Failed to refresh token with error: \(error)")
          completion?(nil)
        }
      }
    }
  }


  private func retryFailedRequests() {
    while !retryQueue.isEmpty {
      let task = retryQueue.removeFirst()
      guard let request = task.originalRequest else { continue }
      self.executeRequest(request) { _ in
        Log.info(#file, "Task Successfully resumed after token refresh")
      }
    }
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
