//
//  TPPNetworkExecutor+RetryRequest.swift
//  Palace
//
//  Building the request sent after a token refresh, and failing a retry
//  that cannot be resent.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
import PalaceLogging

extension TPPNetworkExecutor {
    /// The request to resend for `oldTask` after a token refresh, or nil after
    /// failing `oldTask`'s caller when the request cannot be resent.
    func resendableRetry(of oldTask: URLSessionTask,
                         original: URLRequest,
                         credentials snapshot: TPPUserAccount.CredentialSnapshot) -> URLRequest? {
        guard let retry = Self.retryRequest(from: original, credentials: snapshot) else {
            failUnresendableRetry(oldTask, url: original.url)
            return nil
        }
        return retry
    }

    /// The request resent after a token refresh: the caller's request, method,
    /// body and headers included, with only the bearer replaced by `snapshot`'s
    /// token. The caller takes `snapshot` from the account the request was
    /// dispatched for. Returns nil for a stream body, which the first send has
    /// already consumed.
    fileprivate static func retryRequest(from original: URLRequest,
                                         credentials snapshot: TPPUserAccount.CredentialSnapshot) -> URLRequest? {
        if original.httpBody == nil, original.httpBodyStream != nil {
            return nil
        }
        return replacingBearer(in: original, with: snapshot)
    }

    /// `request` re-authorized with the token `accountId` holds now; nil
    /// resolves the selected library. A proactive refresh runs after its
    /// request was built, so the request still carries the token the refresh
    /// replaced. A request the caller sent without a bearer is returned as is.
    func withCurrentBearer(_ request: URLRequest, accountId: String?) -> URLRequest {
        guard request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true else {
            return request
        }
        let resolvedId = accountId ?? accountsManager.currentAccountId ?? ""
        return Self.replacingBearer(in: request,
                                    with: accountsManager.userAccount(for: resolvedId).credentialSnapshot())
    }

    /// `request` with its bearer set to `snapshot`'s token, or removed when
    /// the snapshot has none. Method, body and other headers are kept.
    private static func replacingBearer(in request: URLRequest,
                                        with snapshot: TPPUserAccount.CredentialSnapshot) -> URLRequest {
        var request = request
        request.setValue(snapshot.authToken.map { "Bearer \($0)" }, forHTTPHeaderField: "Authorization")
        return request
    }

    /// Fails a queued retry that `retryRequest` could not rebuild.
    fileprivate func failUnresendableRetry(_ oldTask: URLSessionTask, url retryURL: URL?) {
        let host = retryURL?.host ?? "unknown-host"
        Log.error(#file, "Token-refresh retry not sent: stream body consumed (host: \(host))")
        let message = "The request body could not be resent after a token refresh"
        failQueuedRetry(oldTask, error: NSError(domain: TPPErrorLogger.clientDomain,
                                                code: TPPErrorCode.responseFail.rawValue,
                                                userInfo: [NSLocalizedDescriptionKey: message]))
    }

    /// Completes the caller of a request that was waiting on a token refresh
    /// and will not be resent, with `error` and the response that started the
    /// refresh. The task has already finished at the URLSession level, so
    /// cancelling it delivers nothing; the responder's stored completion has to
    /// be called directly. Delivered on the session's delegate queue, where the
    /// responder delivers every other task completion.
    func failQueuedRetry(_ oldTask: URLSessionTask, error: NSError) {
        let responder = self.responder
        transport.urlSession.delegateQueue.addOperation {
            responder.failRetry(taskID: oldTask.taskIdentifier, url: oldTask.originalRequest?.url,
                                error: error, response: oldTask.response)
            oldTask.cancel()
        }
    }
}
