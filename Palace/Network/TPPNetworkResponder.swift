//
//  TPPNetworkResponder.swift
//  The Palace Project
//
//  Created by Ettore Pasquini on 3/22/20.
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

import Foundation
import PalaceLogging
import PalaceNetwork
import PalaceCatalog
import PalaceAuth

private struct TPPNetworkTaskInfo {
    var progressData: Data
    var startDate: Date
    var completion: ((NYPLResult<Data>) -> Void)

    // ----------------------------------------------------------------------------
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
    private let useFallbackCaching: Bool
    private let credentialsProvider: NYPLBasicAuthCredentialsProvider?

    /// Tracks URLs that have been retried after a 401 to prevent infinite retry loops.
    /// Key is the URL absoluteString, value is the number of retry attempts.
    private var retriedURLs: [String: Int] = [:]
    private let retriedURLsLock = NSLock()
    private let maxRetryAttempts = 1

    private let taskInfoQueue = DispatchQueue(
        label: "com.thepalaceproject.networkResponder.taskInfo"
    )

    // ----------------------------------------------------------------------------
    /// - Parameter shouldEnableFallbackCaching: If set to `true`, the executor
    /// will attempt to cache responses even when these lack a sufficient set of
    /// caching headers. The default is `false`.
    /// - Parameter credentialsProvider: The object providing the credentials
    /// to respond to an authentication challenge.
    init(credentialsProvider: NYPLBasicAuthCredentialsProvider? = nil,
         useFallbackCaching: Bool = false) {
        self.taskInfo = [Int: TPPNetworkTaskInfo]()
        self.useFallbackCaching = useFallbackCaching
        self.credentialsProvider = credentialsProvider
        super.init()
    }

    // MARK: - Retry Tracking

    /// Checks if a URL can be retried (hasn't exceeded max retry attempts)
    func canRetry(url: URL?) -> Bool {
        guard let urlString = url?.absoluteString else { return false }
        retriedURLsLock.lock()
        defer { retriedURLsLock.unlock() }
        let attempts = retriedURLs[urlString] ?? 0
        return attempts < maxRetryAttempts
    }

    /// Marks a URL as having been retried
    func markRetried(url: URL?) {
        guard let urlString = url?.absoluteString else { return }
        retriedURLsLock.lock()
        defer { retriedURLsLock.unlock() }
        retriedURLs[urlString] = (retriedURLs[urlString] ?? 0) + 1
        Log.debug(#file, "Marked URL as retried (\(retriedURLs[urlString] ?? 0)/\(maxRetryAttempts)): \(urlString)")
    }

    /// Clears retry tracking for a URL (called after successful completion)
    func clearRetry(url: URL?) {
        guard let urlString = url?.absoluteString else { return }
        retriedURLsLock.lock()
        defer { retriedURLsLock.unlock() }
        retriedURLs.removeValue(forKey: urlString)
    }

    /// Clears all retry tracking (useful for session reset)
    func clearAllRetries() {
        retriedURLsLock.lock()
        defer { retriedURLsLock.unlock() }
        retriedURLs.removeAll()
        tokenRefreshAttempts = 0
    }

    // ----------------------------------------------------------------------------
    func addCompletion(_ completion: @escaping (NYPLResult<Data>) -> Void,
                       taskID: TaskID) {
        taskInfoQueue.sync {
            self.taskInfo[taskID] = TPPNetworkTaskInfo(completion: completion)
        }
    }

    func updateCompletionId(_ oldId: TaskID, newId: TaskID) {
        taskInfoQueue.sync {
            // MOVE semantics, not copy. Token-refresh retry flow:
            //  1. addCompletion(handler, taskID: oldId)        ← original task
            //  2. token refresh succeeds, drain queue          ← retry kicks in
            //  3. updateCompletionId(oldId, newId)             ← retry-task mapping
            //  4. oldTask.cancel()                              ← URLSession fires
            //                                                    completion at oldId
            //                                                    if we leave it
            //  5. newTask.resume() → completes                  ← responder fires
            //                                                    completion at newId
            // If step 3 only COPIED, both step 4 and step 5 deliver via the
            // same completion handler → XCTestExpectation API violation in
            // TokenRefreshAndRetryQueueTests.testRefresh_Success_ReleasesSingleFlightSlot
            // (caught at PR #956's CI). Production callers see the completion
            // fire twice — second call is a cancelled-error overwriting the
            // genuine retry result. Move the mapping to fix.
            if let info = self.taskInfo.removeValue(forKey: oldId) {
                self.taskInfo[newId] = info
            }
        }
    }
}

// MARK: - URLSessionDelegate
// MARK: - URLSessionDelegate
extension TPPNetworkResponder: URLSessionDelegate {
    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        taskInfoQueue.async {
            let pending = self.taskInfo
            self.taskInfo.removeAll()

            let cancelError = NSError(domain: NSURLErrorDomain,
                                      code: NSURLErrorCancelled,
                                      userInfo: nil)
            for (_, info) in pending {
                info.completion(.failure(cancelError, nil))
            }

            // Only log if there's an actual error during invalidation
            // Normal invalidation (e.g., deinit) without error is expected and shouldn't be reported
            if let err = error {
                Log.error(#file, "URLSession invalidated with error: \(err.localizedDescription), pending tasks: \(pending.count)")
                TPPErrorLogger.logError(
                    err,
                    summary: "URLSession invalidated with error",
                    metadata: [
                        "pending_tasks": pending.count,
                        "error_domain": (err as NSError).domain,
                        "error_code": (err as NSError).code
                    ]
                )
            } else if !pending.isEmpty {
                // Only log if there were pending tasks when invalidated (potential issue)
                Log.warn(#file, "URLSession invalidated with \(pending.count) pending tasks (no error)")
            } else {
                // Normal shutdown - don't log
                Log.debug(#file, "URLSession invalidated normally (no error, no pending tasks)")
            }
        }
    }
}

// MARK: - URLSessionDataDelegate
extension TPPNetworkResponder: URLSessionDataDelegate {

    // ----------------------------------------------------------------------------
    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive data: Data) {
        taskInfoQueue.async { [ weak self] in
            var info = self?.taskInfo[dataTask.taskIdentifier]
            info?.progressData.append(data)
            if let updated = info {
                self?.taskInfo[dataTask.taskIdentifier] = updated
            }
        }
    }

    // ----------------------------------------------------------------------------
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

    // ----------------------------------------------------------------------------

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError networkError: Error?) {
        let taskID = task.taskIdentifier
        var logMetadata: [String: Any] = [
            "currentRequest": task.currentRequest?.loggableString ?? "N/A",
            "taskID": taskID
        ]

        // Check for 401 BEFORE removing taskInfo, so completion can be preserved for retry
        // Use URL-based retry tracking instead of associated objects (which don't work on structs)
        let requestURL = task.originalRequest?.url
        if let http = task.response as? HTTPURLResponse,
           http.statusCode == 401,
           canRetry(url: requestURL),
           handleExpiredTokenIfNeeded(for: http, with: task) {
            // Mark this URL as retried to prevent infinite loops
            markRetried(url: requestURL)
            // Don't remove taskInfo - it will be transferred to the retry task via updateCompletionId
            Log.debug(#file, "Task \(taskID) got 401, triggering token refresh and retry (completion preserved)")
            return
        } else if let http = task.response as? HTTPURLResponse,
                  http.statusCode == 401,
                  !canRetry(url: requestURL) {
            // Already retried this URL - don't retry again
            Log.warn(#file, "Task \(taskID) got 401 but max retries reached for URL - failing request")
        }

        var maybeInfo: TPPNetworkTaskInfo?
        taskInfoQueue.sync {
            maybeInfo = self.taskInfo.removeValue(forKey: task.taskIdentifier)
        }

        guard let info = maybeInfo else {
            // This can happen legitimately in several scenarios:
            // 1. URLSession internal tasks (preconnect, preflight, etc.) that we never registered
            // 2. Cancelled tasks where session became invalid and cleared all taskInfo
            // 3. Tasks created by the system for HTTP/2 multiplexing
            // 4. Rapid task creation/completion race conditions (very rare)
            //
            // Only log at debug level to avoid noise in crash reporting.
            // If this becomes a real issue, the user will see failed network requests.
            Log.debug(#file, "Task \(taskID) completed but no taskInfo found - likely an internal URLSession task")
            return
        }

        if let nsErr = networkError as NSError?,
           nsErr.domain == NSURLErrorDomain,
           nsErr.code == NSURLErrorCancelled {
            Log.info(#file, "Task \(taskID) cancelled: \(nsErr.localizedDescription)")
            // Must still call completion to avoid leaving continuations unresumed
            info.completion(.failure(nsErr, task.response))
            return
        }

        let elapsed = Date().timeIntervalSince(info.startDate)
        logMetadata["elapsedTime"] = elapsed
        Log.info(#file, "Task \(taskID) completed (\(logMetadata)[\"currentRequest\"] ?? \"nil\")), elapsed: \(elapsed)s")

        let result: NYPLResult<Data>
        if let http = task.response as? HTTPURLResponse {
            // Use URL-based retry tracking instead of broken hasRetried flag
            let isFailedRetry = !canRetry(url: requestURL)

            if !http.isSuccess() {
                let err: TPPUserFriendlyError
                let data = info.progressData

                if !data.isEmpty {
                    err = task.parseAndLogError(
                        fromProblemDocumentData: data,
                        networkError: networkError,
                        logMetadata: logMetadata,
                        isFailedRetry: isFailedRetry
                    )
                } else {
                    err = NSError(
                        domain: "Api call with failure HTTP status",
                        code: TPPErrorCode.responseFail.rawValue,
                        userInfo: logMetadata
                    )

                    // Only log non-retry failures or failed retries
                    if !isFailedRetry || http.statusCode == 401 {
                        Log.warn(#file, "Request failed with status \(http.statusCode), isRetry: \(isFailedRetry)")
                    }
                }

                result = .failure(err, task.response)
                // Request failed permanently - clear retry tracking so future requests can try again
                clearRetry(url: requestURL)
            } else if let netErr = networkError {
                let ue = netErr as TPPUserFriendlyError
                result = .failure(ue, task.response)
                TPPErrorLogger.logNetworkError(netErr,
                                               summary: "Network task completed with error",
                                               request: task.originalRequest,
                                               response: task.response,
                                               metadata: logMetadata)
            } else {
                // Success! Clear retry tracking for this URL
                clearRetry(url: requestURL)
                result = .success(info.progressData, task.response)

                // Self-heal: a 2xx from an authenticated request means the
                // server accepted our credentials. If our local state is
                // `.credentialsStale` we should reconcile to `.loggedIn` —
                // otherwise a transient /patrons/me/ 401 from a prior session
                // can persist across launches and prompt the user to re-sign-in
                // even though their bearer token is still valid (the SAML
                // two-surface case: IdP cookie expires but bearer stays good).
                // Only heal on requests that actually carried an Authorization
                // header, so we don't false-heal off /authentication_document
                // or other unauthenticated discovery calls.
                let sentAuthHeader = (task.originalRequest?.value(forHTTPHeaderField: "Authorization") != nil)
                    || (task.currentRequest?.value(forHTTPHeaderField: "Authorization") != nil)
                if sentAuthHeader {
                    let user = AppContainer.production().accountsManager.currentUserAccount
                    if user.authState == .credentialsStale {
                        Log.info(#file, "Authenticated request \(taskID) returned \(http.statusCode) — server accepted credentials, reconciling authState credentialsStale → loggedIn")
                        user.setAuthState(.loggedIn)
                    }
                }
            }
        } else {
            let err = NSError(domain: "Api call with failure HTTP status",
                              code: TPPErrorCode.invalidOrNoHTTPResponse.rawValue,
                              userInfo: logMetadata)
            result = .failure(err, task.response)
        }

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
                let snap = AppContainer.production().accountsManager.currentUserAccount.credentialSnapshot()
                if (snap.authDefinition?.isToken ?? false) && tokenRefreshAttempts < 2 {
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

private func handleExpiredTokenIfNeeded(for response: HTTPURLResponse,
                                       with task: URLSessionTask,
                                       networkExecutor: TPPNetworkExecutor = AppContainer.production().networkExecutor) -> Bool {
    // Skip DELETE requests - intentionally don't refresh tokens for deletes
    // This prevents refresh loops when revoking/returning items
    if task.originalRequest?.httpMethod == "DELETE" {
        return false
    }

    // Use atomic snapshot to prevent TOCTOU races during account switches.
    // Previously this used TPPUserAccount.sharedAccount() which resolves to
    // whatever account is current at call time — if the user switched accounts
    // between sending the request and receiving the 401, the wrong account's
    // credentials would be checked/marked stale.
    let accountsManager = AppContainer.production().accountsManager
    let accountId = accountsManager.currentAccountId
    let snapshot = accountsManager.currentUserAccount.credentialSnapshot()

    guard snapshot.hasCredentials else {
        return false
    }

    let authDef = snapshot.authDefinition

    if response.statusCode == 401 {
        // A 401 from a cross-domain redirect (e.g., to biblioboard.com) does NOT
        // mean our Palace credentials are expired - it's a third-party auth issue
        let originalURL = task.originalRequest?.url
        guard response.indicatesAuthenticationNeedsRefresh(with: nil, originalRequestURL: originalURL) else {
            Log.info(#file, "401 from cross-domain redirect - not marking credentials stale")
            return false
        }

        if authDef?.reauthStrategy == .browser {
            // SAML/OIDC have TWO auth surfaces: the bearer token (used for
            // /borrow, /fulfillment, /loans/) and the IdP session cookie
            // (used only for /patrons/me/). The IdP cookie expires faster
            // than the bearer in Gorgon and many institutional deployments,
            // so /patrons/me/ keeps 401-ing as a background poll while the
            // user can still borrow and read fine.
            //
            // The previous behavior was to mark credentials stale here on
            // ANY browser-auth 401 (including /patrons/me/), which left
            // authState=credentialsStale persisted across app launches. The
            // moment the user touched a book detail view, ensureAuthAndExecute
            // saw the stale state and prompted re-auth — even though the
            // user's bearer token was still good and nothing was broken.
            // HelpSpot 17716 follow-up, hotfix-branch device test 2026-05-01.
            //
            // Narrow the rule: only mark stale on browser-auth 401s from
            // ACTION endpoints (borrow, fulfillment, loans). A 401 from the
            // user-profile endpoint is non-actionable noise — let it pass.
            // The borrow/download path's `handleBorrowAuthErrorIfNeeded`
            // marks stale itself when an actual borrow fails, and that is
            // the right time to surface the modal.
            let isUserProfilePoll = originalURL.flatMap { url -> Bool in
                let path = url.path
                return path.contains("/patrons/me") || path.hasSuffix("/patrons/me/")
            } ?? false

            if isUserProfilePoll {
                Log.info(#file, "Browser-auth 401 from /patrons/me/ poll — IdP cookie expired but bearer still likely valid; not marking credentials stale (user-action paths will mark stale only on a real borrow/fulfillment failure)")
                return false
            }

            // Mark credentials as stale - preserves Adobe DRM activation
            accountsManager.userAccount(for: accountId ?? "").markCredentialsStale()
            Log.info(#file, "Server returned 401 for browser-based auth on action endpoint - credentials marked stale; user-action paths will surface re-auth on next interaction")
            return false
        }

        // Non-browser auth (basic, token, oauth): a 401 here is unambiguous —
        // the credential we sent is no longer accepted. Mark stale and fall
        // through to the token-refresh path below.
        accountsManager.userAccount(for: accountId ?? "").markCredentialsStale()

        let canRefreshToken = (authDef?.isToken == true || authDef?.isOauth == true) &&
            authDef?.tokenURL != nil &&
            snapshot.barcode != nil &&
            snapshot.pin != nil

        if canRefreshToken {
            Log.info(#file, "Server returned 401 - triggering token refresh (server authority)")
            networkExecutor.refreshTokenAndResume(task: task, accountId: accountId)
            return true
        }
    }
    return false
}

// ------------------------------------------------------------------------------
// MARK: - URLSessionTask extensions

extension URLSessionTask {
    // ----------------------------------------------------------------------------
    fileprivate func parseAndLogError(fromProblemDocumentData responseData: Data,
                                      networkError: Error?,
                                      logMetadata: [String: Any],
                                      isFailedRetry: Bool = false) -> TPPUserFriendlyError {
        let parseError: Error?
        let code: TPPErrorCode
        let returnedError: TPPUserFriendlyError
        var logMetadata = logMetadata
        logMetadata["isFailedRetry"] = isFailedRetry

        do {
            let problemDoc = try TPPProblemDocument.fromData(responseData)
            returnedError = error(fromProblemDocument: problemDoc)
            parseError = nil
            code = TPPErrorCode.problemDocAvailable
            logMetadata["problemDocument"] = problemDoc.dictionaryValue
            logMetadata["problemDocType"] = problemDoc.type ?? "unknown"

            // Check response status code (could be in HTTPURLResponse or problem document)
            let httpStatusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            let problemDocStatus = problemDoc.status ?? httpStatusCode

            // Don't log first-attempt 401s to Crashlytics - they may be retried with token refresh
            // or trigger re-auth flow (for SAML). Either way, not a crashworthy error yet.
            if !isFailedRetry && (httpStatusCode == 401 || problemDocStatus == 401) {
                Log.debug(#file, "Problem document with 401 - will be handled by auth flow (not logging to Crashlytics)")
                return returnedError
            }

            // For failed retries with 401, this is a real auth issue (log it)
            if isFailedRetry && (httpStatusCode == 401 || problemDocStatus == 401) {
                Log.error(#file, "Failed retry with 401 - auth credentials invalid after refresh")
            }
        } catch let caughtParseError {
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

    // ----------------------------------------------------------------------------
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

// ----------------------------------------------------------------------------
// MARK: - URLSessionTaskDelegate
extension TPPNetworkResponder: URLSessionTaskDelegate {
    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let credsProvider = credentialsProvider ?? AppContainer.production().accountsManager.currentUserAccount
        let authChallenger = TPPBasicAuth(credentialsProvider: credsProvider)
        authChallenger.handleChallenge(challenge, completion: completionHandler)
    }

    func refreshToken(userAccount: TPPUserAccount = AppContainer.production().accountsManager.currentUserAccount) async throws {
        guard let tokenURL = userAccount.authDefinition?.tokenURL,
              let username = userAccount.username,
              let password = userAccount.pin
        else { return }

        let tokenRequest = TokenRequest(url: tokenURL, username: username, password: password)
        let result = await tokenRequest.execute()

        switch result {
        case .success(let tokenResponse):
            userAccount.setAuthToken(tokenResponse.accessToken, barcode: username, pin: password, expirationDate: tokenResponse.expirationDate)
        case .failure(let error):
            throw error
        }
    }
}
