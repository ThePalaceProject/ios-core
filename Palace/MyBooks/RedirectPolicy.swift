//
//  RedirectPolicy.swift
//  Palace
//
//  Encapsulates the URLSession willPerformHTTPRedirection decision lifted
//  out of MyBooksDownloadCenter as part of the Phase 7 decomposition.
//  Three rules, in order:
//    1. Cap the redirect chain at `maxRedirectAttempts` (per task) by
//       consulting the shared DownloadCoordinator counter.
//    2. Reject HTTPS → non-HTTPS downgrades to prevent transport
//       stripping during a multi-hop redirect.
//    3. Otherwise allow the redirect to proceed with the new request.
//
//  Auth headers are not re-added — URLSession already strips Authorization
//  on cross-origin redirects, and bearer-token flows return a JSON
//  document (not a redirect), so the redirect policy never has to decide
//  that question.
//

import Foundation

/// - Sendable invariant (Swift 6 `complete`-mode): a value type whose only
///   stored members are two `@Sendable async` closures and an `Int`, so it is
///   `Sendable` and can be awaited (`decide`) from any actor — including a
///   `@MainActor` caller (tests) — without racing. The production closures
///   capture only the actor-isolated `DownloadCoordinator` (itself `Sendable`);
///   the `@Sendable` annotation is satisfied there with no widening.
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
