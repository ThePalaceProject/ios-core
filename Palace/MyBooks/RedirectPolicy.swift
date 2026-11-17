//
//  RedirectPolicy.swift
//  Palace
//
//  The download session's willPerformHTTPRedirection decision, in order:
//  cap the chain at `maxRedirectAttempts` per task, reject HTTPS → non-HTTPS
//  downgrades, otherwise follow. Auth headers are not re-added: URLSession
//  strips Authorization on cross-origin redirects, and bearer-token flows
//  return a JSON document rather than a redirect.
//

import Foundation

/// - Sendable: a value type holding two `@Sendable async` closures and an
///   `Int`; the production closures capture only the `DownloadCoordinator` actor.
struct RedirectPolicy: Sendable {
    static let defaultMaxRedirectAttempts: Int = 10

    private let getRedirectAttempts: @Sendable (Int) async -> Int
    private let incrementRedirectAttempts: @Sendable (Int) async -> Void
    private let maxRedirectAttempts: Int

    init(
        getRedirectAttempts: @escaping @Sendable (Int) async -> Int,
        incrementRedirectAttempts: @escaping @Sendable (Int) async -> Void,
        maxRedirectAttempts: Int = RedirectPolicy.defaultMaxRedirectAttempts
    ) {
        self.getRedirectAttempts = getRedirectAttempts
        self.incrementRedirectAttempts = incrementRedirectAttempts
        self.maxRedirectAttempts = maxRedirectAttempts
    }

    /// Returns the request to follow on redirect, or `nil` to deny it.
    /// Increments the per-task redirect counter on every accepted request.
    func decide(
        taskIdentifier: Int,
        originalScheme: String?,
        newRequest: URLRequest
    ) async -> URLRequest? {
        let attempts = await getRedirectAttempts(taskIdentifier)
        if attempts >= maxRedirectAttempts {
            return nil
        }

        await incrementRedirectAttempts(taskIdentifier)

        if originalScheme == "https" && newRequest.url?.scheme != "https" {
            return nil
        }

        return newRequest
    }
}
