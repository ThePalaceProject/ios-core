//
//  TPPNetworkResponder.swift
//  The Palace Project
//
//  Created by Ettore Pasquini on 3/22/20.
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

import Foundation

fileprivate struct TPPNetworkTaskInfo {
  var progressData: Data
  var startDate: Date
  var completion: ((NYPLResult<Data>) -> Void)

  //----------------------------------------------------------------------------
  init(completion: (@escaping (NYPLResult<Data>) -> Void)) {
    self.progressData = Data()
    self.startDate = Date()
    self.completion = completion
  }
}

/// This class responds to URLSession events related to the tasks being
/// issued on the URLSession, keeping a tally of the related completion
/// handlers in a thread-safe way.
class TPPNetworkResponder: NSObject {
  typealias TaskID = Int
  
  private var tokenRefreshAttempts: Int = 0
  private var taskInfo: [TaskID: TPPNetworkTaskInfo]
  private let taskInfoLock: NSLock
  private let useFallbackCaching: Bool
  private let credentialsProvider: NYPLBasicAuthCredentialsProvider?

  //----------------------------------------------------------------------------
  /// - Parameter shouldEnableFallbackCaching: If set to `true`, the executor
  /// will attempt to cache responses even when these lack a sufficient set of
  /// caching headers. The default is `false`.
  /// - Parameter credentialsProvider: The object providing the credentials
  /// to respond to an authentication challenge.
  init(credentialsProvider: NYPLBasicAuthCredentialsProvider? = nil,
       useFallbackCaching: Bool = false) {
    self.taskInfo = [Int: TPPNetworkTaskInfo]()
    self.taskInfoLock = NSLock()
    self.useFallbackCaching = useFallbackCaching
    self.credentialsProvider = credentialsProvider
    super.init()
  }

  //----------------------------------------------------------------------------
  func addCompletion(_ completion: @escaping (NYPLResult<Data>) -> Void,
                     taskID: TaskID) {
    taskInfoLock.lock()
    defer {
      taskInfoLock.unlock()
    }

    taskInfo[taskID] = TPPNetworkTaskInfo(completion: completion)
  }
  
  func updateCompletionId(_ oldId: TaskID, newId: TaskID) {
    taskInfoLock.lock()
    defer {
      taskInfoLock.unlock()
    }
    
    taskInfo[newId] = taskInfo[oldId]
  }
}

// MARK: - URLSessionDelegate
// MARK: - URLSessionDelegate
extension TPPNetworkResponder: URLSessionDelegate {
  func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
    taskInfoLock.lock()
    let pending = taskInfo
    taskInfo.removeAll()
    taskInfoLock.unlock()

    let cancelError = NSError(domain: NSURLErrorDomain,
                              code: NSURLErrorCancelled,
                              userInfo: nil)
    for (_, info) in pending {
      info.completion(.failure(cancelError, nil))
    }

    if let err = error {
      TPPErrorLogger.logError(err, summary: "URLSession invalidated with error")
    } else {
      TPPErrorLogger.logError(withCode: .invalidURLSession,
                              summary: "URLSession invalidated without error")
    }
  }
}

// MARK: - URLSessionDataDelegate
extension TPPNetworkResponder: URLSessionDataDelegate {
  
  //----------------------------------------------------------------------------
  func urlSession(_ session: URLSession,
                  dataTask: URLSessionDataTask,
                  didReceive data: Data) {
    taskInfoLock.lock()
    defer {
      taskInfoLock.unlock()
    }
    
    var currentTaskInfo = taskInfo[dataTask.taskIdentifier]
    currentTaskInfo?.progressData.append(data)
    taskInfo[dataTask.taskIdentifier] = currentTaskInfo
  }
  
  //----------------------------------------------------------------------------
  func urlSession(_ session: URLSession,
                  dataTask: URLSessionDataTask,
                  willCacheResponse proposedResponse: CachedURLResponse,
                  completionHandler: @escaping (CachedURLResponse?) -> Void) {
    
    guard let httpResponse = proposedResponse.response as? HTTPURLResponse else {
      completionHandler(proposedResponse)
      return
    }
    
    if httpResponse.hasSufficientCachingHeaders || !useFallbackCaching {
      completionHandler(proposedResponse)
    } else {
      let newResponse = httpResponse.modifyingCacheHeaders()
      completionHandler(CachedURLResponse(response: newResponse,
                                          data: proposedResponse.data))
    }
  }

  //----------------------------------------------------------------------------

  func urlSession(_ session: URLSession,
                  task: URLSessionTask,
                  didCompleteWithError networkError: Error?) {
    let taskID = task.taskIdentifier
    var logMetadata: [String: Any] = [
      "currentRequest": task.currentRequest?.loggableString ?? "N/A",
      "taskID": taskID
    ]

    // 1) Remove & grab the TPPNetworkTaskInfo under lock
    taskInfoLock.lock()
    let maybeInfo = taskInfo.removeValue(forKey: taskID)
    taskInfoLock.unlock()

    guard let info = maybeInfo else {
      TPPErrorLogger.logNetworkError(
        nil,
        code: .noTaskInfoAvailable,
        summary: "No taskInfo for task \(taskID)",
        request: task.originalRequest,
        response: task.response,
        metadata: logMetadata
      )
      return
    }

    if let nsErr = networkError as NSError?,
       nsErr.domain == NSURLErrorDomain,
       nsErr.code == NSURLErrorCancelled {
      Log.info(#file, "Task \(taskID) cancelled: \(nsErr.localizedDescription)")
      return
    }

    let elapsed = Date().timeIntervalSince(info.startDate)
    logMetadata["elapsedTime"] = elapsed
    Log.info(#file, "Task \(taskID) completed (\(logMetadata)[\"currentRequest\"] ?? \"nil\")), elapsed: \(elapsed)s")

    let result: NYPLResult<Data> = .success(info.progressData, task.response)
    info.completion(result)
  }
  
  private func logTaskCompletion(taskID: Int, startDate: Date, metadata: inout [String: Any]) {
    let elapsed = Date().timeIntervalSince(startDate)
    metadata["elapsedTime"] = elapsed
    Log.info(#file, "Task \(taskID) completed (\(metadata["currentRequest"] ?? "nil")), elapsed time: \(elapsed) sec")
  }

  
  private func handleNoTaskInfo(for task: URLSessionTask, with networkError: Error?, logMetadata: inout [String: Any]) {
    logMetadata["NYPLNetworkResponder context"] = "No task info available for task \(task.taskIdentifier). Completion closure could not be called."
    TPPErrorLogger.logNetworkError(
      networkError,
      code: .noTaskInfoAvailable,
      summary: "Network layer error: task info unavailable",
      request: task.originalRequest,
      response: task.response,
      metadata: logMetadata)
  }
  
  private func handleHTTPResponse(_ httpResponse: HTTPURLResponse, for task: URLSessionTask, currentTaskInfo: TPPNetworkTaskInfo, logMetadata: inout [String: Any]) -> Bool {
    guard httpResponse.isSuccess() else {
      logMetadata["response"] = httpResponse
      var err: NSError = NSError()
      var code: TPPErrorCode = .responseFail
      var summary: String = Strings.Error.connectionFailed
      logMetadata[NSLocalizedDescriptionKey] = Strings.Error.unknownRequestError
      
      if httpResponse.statusCode == 401 {
        if (TPPUserAccount.sharedAccount().authDefinition?.isToken ?? false) && tokenRefreshAttempts < 2 {
          tokenRefreshAttempts += 1
          return handleExpiredTokenIfNeeded(for: httpResponse, with: task)
        }
        
        logMetadata[NSLocalizedDescriptionKey] = Strings.Error.invalidCredentialsErrorMessage
        code = TPPErrorCode.invalidCredentials
        summary = Strings.Error.invalidCredentialsErrorMessage
      }
      
      err = NSError(domain: "Api call with failure HTTP status",
                    code: code.rawValue,
                    userInfo: logMetadata)
      
      currentTaskInfo.completion(.failure(err, task.response))
      TPPErrorLogger.logNetworkError(code: code,
                                     summary: summary,
                                     request: task.originalRequest,
                                     metadata: logMetadata)
      return false
    }
    
    return true
  }

  
  private func handleProblemDocument(for task: URLSessionTask, with responseData: Data, currentTaskInfo: TPPNetworkTaskInfo, networkError: Error?, logMetadata: [String: Any]) {
    let errorWithProblemDoc = task.parseAndLogError(fromProblemDocumentData: responseData,
                                                    networkError: networkError,
                                                    logMetadata: logMetadata)
    currentTaskInfo.completion(.failure(errorWithProblemDoc, task.response))
  }
  
  private func handleNetworkError(_ networkError: Error, for task: URLSessionTask, currentTaskInfo: TPPNetworkTaskInfo, logMetadata: [String: Any]) {
    currentTaskInfo.completion(.failure(networkError as TPPUserFriendlyError, task.response))
    TPPErrorLogger.logNetworkError(
      networkError,
      summary: "Network task completed with error",
      request: task.originalRequest,
      response: task.response,
      metadata: logMetadata)
  }
}


private func handleExpiredTokenIfNeeded(for response: HTTPURLResponse, with task: URLSessionTask) -> Bool {
  if response.statusCode == 401 && TPPUserAccount.sharedAccount().hasCredentials() {
    TPPNetworkExecutor.shared.refreshTokenAndResume(task: task)
    return true
  }
  return false
}

//------------------------------------------------------------------------------
// MARK: - URLSessionTask extensions

extension URLSessionTask {
  //----------------------------------------------------------------------------
  fileprivate func parseAndLogError(fromProblemDocumentData responseData: Data,
                                    networkError: Error?,
                                    logMetadata: [String: Any]) -> TPPUserFriendlyError {
    let parseError: Error?
    let code: TPPErrorCode
    let returnedError: TPPUserFriendlyError
    var logMetadata = logMetadata

    do {
      let problemDoc = try TPPProblemDocument.fromData(responseData)
      returnedError = error(fromProblemDocument: problemDoc)
      parseError = nil
      code = TPPErrorCode.problemDocAvailable
      logMetadata["problemDocument"] = problemDoc.dictionaryValue
    } catch (let caughtParseError) {
      parseError = caughtParseError
      code = TPPErrorCode.parseProblemDocFail
      let responseString = String(data: responseData, encoding: .utf8) ?? "N/A"
      logMetadata["problemDocument (parse failed)"] = responseString
      if let networkError = networkError as TPPUserFriendlyError? {
        returnedError = networkError
      } else {
        returnedError = caughtParseError as TPPUserFriendlyError
      }
    }

    if let networkError = networkError {
      logMetadata["urlSessionError"] = networkError
    }

    TPPErrorLogger.logNetworkError(parseError,
                                    code: code,
                                    summary: "Network request failed: Problem Document available",
                                    request: originalRequest,
                                    response: response,
                                    metadata: logMetadata)

    return returnedError
  }

  //----------------------------------------------------------------------------
  fileprivate func error(fromProblemDocument problemDoc: TPPProblemDocument) -> NSError {
    var userInfo = [String: Any]()
    if let currentRequest = currentRequest {
      userInfo["taskCurrentRequest"] = currentRequest
    }
    if let originalRequest = originalRequest {
      userInfo["taskOriginalRequest"] = originalRequest
    }
    if let response = response {
      userInfo["response"] = response
    }

    let err = NSError.makeFromProblemDocument(
      problemDoc,
      domain: "Api call failure: problem document available",
      code: TPPErrorCode.apiCall.rawValue,
      userInfo: userInfo)

    return err
  }
}

//----------------------------------------------------------------------------
// MARK: - URLSessionTaskDelegate
extension TPPNetworkResponder: URLSessionTaskDelegate {
  func urlSession(_ session: URLSession,
                  task: URLSessionTask,
                  didReceive challenge: URLAuthenticationChallenge,
                  completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void)
  {
    let credsProvider = credentialsProvider ?? TPPUserAccount.sharedAccount()
    let authChallenger = TPPBasicAuth(credentialsProvider: credsProvider)
    authChallenger.handleChallenge(challenge, completion: completionHandler)
  }
  
  func refreshToken() async throws {
    guard let tokenURL = TPPUserAccount.sharedAccount().authDefinition?.tokenURL,
          let username = TPPUserAccount.sharedAccount().username,
          let password = TPPUserAccount.sharedAccount().pin
    else { return }
    
    let tokenRequest = TokenRequest(url: tokenURL, username: username, password: password)
    let result = await tokenRequest.execute()
    
    switch result {
    case .success(let tokenResponse):
      TPPUserAccount.sharedAccount().setAuthToken(tokenResponse.accessToken, barcode: username, pin: password, expirationDate: tokenResponse.expirationDate)
    case .failure(let error):
      throw error
    }
  }
}
