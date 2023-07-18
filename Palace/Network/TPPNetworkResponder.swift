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

  private var taskInfo: [TaskID: TPPNetworkTaskInfo]

  /// Protects access to `taskInfo` to ensure thread-safety.
  private let taskInfoLock: NSRecursiveLock

  /// Whether the fallback caching system should be active or not.
  private let useFallbackCaching: Bool

  /// The object providing the credentials to respond to an authentication
  /// challenge. If `nil`, the shared `NYPLUserAccount` singleton will be used.
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
    self.taskInfoLock = NSRecursiveLock()
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
}

// MARK: - URLSessionDelegate
extension TPPNetworkResponder: URLSessionDelegate {
  //----------------------------------------------------------------------------
  func urlSession(_ session: URLSession, didBecomeInvalidWithError err: Error?) {
    if let err = err {
      TPPErrorLogger.logError(err, summary: "URLSession became invalid")
    } else {
      TPPErrorLogger.logError(withCode: .invalidURLSession,
                               summary: "URLSessionDelegate: session became invalid")
    }

    taskInfoLock.lock()
    defer {
      taskInfoLock.unlock()
    }

    taskInfo.removeAll()
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
      "taskID": taskID,
    ]

    taskInfoLock.lock()
    guard let currentTaskInfo = taskInfo.removeValue(forKey: taskID) else {
      taskInfoLock.unlock()
      logMetadata["NYPLNetworkResponder context"] = "No task info available for task \(taskID). Completion closure could not be called."
      TPPErrorLogger.logNetworkError(
        networkError,
        code: .noTaskInfoAvailable,
        summary: "Network layer error: task info unavailable",
        request: task.originalRequest,
        response: task.response,
        metadata: logMetadata)
      return
    }
    taskInfoLock.unlock()

    let responseData = currentTaskInfo.progressData
    let elapsed = Date().timeIntervalSince(currentTaskInfo.startDate)
    logMetadata["elapsedTime"] = elapsed
    Log.info(#file, "Task \(taskID) completed, elapsed time: \(elapsed) sec")

    // attempt parsing of Problem Document
    if task.response?.isProblemDocument() ?? false {
      let errorWithProblemDoc = task.parseAndLogError(fromProblemDocumentData: responseData,
                                                      networkError: networkError,
                                                      logMetadata: logMetadata)
      currentTaskInfo.completion(.failure(errorWithProblemDoc, task.response))
      return
    }

    // no problem document, but if we have an error it's still a failure
    if let networkError = networkError {
      currentTaskInfo.completion(.failure(networkError as TPPUserFriendlyError, task.response))

      // logging the error after the completion call so that the error report
      // will include any eventual logging done in the completion handler.
      TPPErrorLogger.logNetworkError(
        networkError,
        summary: "Network task completed with error",
        request: task.originalRequest,
        response: task.response,
        metadata: logMetadata)
      return
    }

    // no problem document nor error, but response could still be a failure
    if let httpResponse = task.response as? HTTPURLResponse {
      guard httpResponse.isSuccess() else {
        logMetadata["response"] = httpResponse
        logMetadata[NSLocalizedDescriptionKey] = Strings.Error.unknownRequestError
        let err = NSError(domain: "Api call with failure HTTP status",
                          code: TPPErrorCode.responseFail.rawValue,
                          userInfo: logMetadata)
        currentTaskInfo.completion(.failure(err, task.response))
        TPPErrorLogger.logNetworkError(code: TPPErrorCode.responseFail,
                                        summary: "Network request failed: server error response",
                                        request: task.originalRequest,
                                        metadata: logMetadata)
        return
      }
    }

    currentTaskInfo.completion(.success(responseData, task.response))
  }
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
//  func urlSession(_ session: URLSession,
//                  task: URLSessionTask,
//                  didReceive challenge: URLAuthenticationChallenge,
//                  completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void)
//  {
//    let credsProvider = credentialsProvider ?? TPPUserAccount.sharedAccount()
//    let authChallenger = TPPBasicAuth(credentialsProvider: credsProvider)
//    authChallenger.handleChallenge(challenge, completion: completionHandler)
//  }
    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void)
    {
      let credsProvider = credentialsProvider ?? TPPUserAccount.sharedAccount()
      let authChallenger = TPPBasicAuth(credentialsProvider: credsProvider)
      authChallenger.handleChallenge(challenge) { [weak self] (disposition, credential) in
        if disposition == .rejectProtectionSpace {
          completionHandler(disposition, credential)
        } else {
          if let dataTask = task as? URLSessionDataTask,
             let response = dataTask.response as? HTTPURLResponse,
             response.statusCode == 401 && disposition == .cancelAuthenticationChallenge {
            // Perform token refresh and retry the request
            Task { [weak self] in
              guard let self = self else { return }
              do {
                try await self.refreshToken()
                // Retry the authentication challenge with the updated credentials
                authChallenger.handleChallenge(challenge, completion: completionHandler)
              } catch {
                completionHandler(.rejectProtectionSpace, nil)
              }
            }
          } else {
            completionHandler(disposition, credential)
          }
        }
      }
    }
  
    private func refreshToken() async throws {
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
