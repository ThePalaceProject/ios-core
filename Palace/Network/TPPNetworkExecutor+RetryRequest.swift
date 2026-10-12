//
//  TPPNetworkExecutor+RetryRequest.swift
//  Palace
//
//  Building and failing the request resent after a token refresh.
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
        var retry = original
        retry.setValue(snapshot.authToken.map { "Bearer \($0)" }, forHTTPHeaderField: "Authorization")
        return retry
    }

    /// Fails a queued retry that `retryRequest` could not rebuild. Delivered on
    /// the session's delegate queue, where the responder delivers every other
    /// task completion.
    fileprivate func failUnresendableRetry(_ oldTask: URLSessionTask, url retryURL: URL?) {
        let host = retryURL?.host ?? "unknown-host"
        Log.error(#file, "Token-refresh retry not sent: stream body consumed (host: \(host))")
        let responder = self.responder
        transport.urlSession.delegateQueue.addOperation {
            let message = "The request body could not be resent after a token refresh"
            let error = NSError(domain: TPPErrorLogger.clientDomain,
                                code: TPPErrorCode.responseFail.rawValue,
                                userInfo: [NSLocalizedDescriptionKey: message])
            responder.failRetry(taskID: oldTask.taskIdentifier, url: retryURL, error: error)
            oldTask.cancel()
        }
    }
}
