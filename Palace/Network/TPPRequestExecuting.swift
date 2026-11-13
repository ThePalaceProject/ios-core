//
//  TPPRequestExecuting.swift
//  The Palace Project
//
//  Created by Ettore Pasquini on 3/24/21.
//  Copyright © 2021 NYPL Labs. All rights reserved.
//

import Foundation

let TPPDefaultRequestTimeout: TimeInterval = 30.0

/// `Sendable` states what every conformer already guarantees rather than
/// imposing anything new: `TPPNetworkExecutor` is declared `@unchecked
/// Sendable`, and so is each test double. Saying it here is what makes
/// `execute` reachable from an isolated context — without it, awaiting a
/// request from a `@MainActor` caller means sending the executor across
/// isolation, which the compiler refuses.
protocol TPPRequestExecuting: Sendable {
    /// Perform a request and return its result.
    ///
    /// - Parameters:
    ///   - req: the request to perform.
    ///   - enableTokenRefresh: refresh a near-expiry token before dispatching.
    ///   - accountId: the library this request was BUILT for; `nil` means the
    ///     currently selected one. PP-4986: a 401 retry rebuilds the request
    ///     from the account stamped on its task, so a caller that built for
    ///     another library — Settings sign-in and sign-out via
    ///     `TPPSignInBusinessLogic`, `NotificationService.deleteToken(for:)` —
    ///     must name it, or the retry authenticates as the wrong library.
    ///
    /// This replaced two completion-handler requirements. A completion typed
    /// `(NYPLResult<Data>) -> Void` cannot say where it runs: the executor's
    /// sessions use `delegateQueue: nil`, so every completion arrives off the
    /// main actor, while a closure formed in a `@MainActor` context inherits
    /// that isolation and type-checks anyway. That mismatch is the PP-5299
    /// crash class, and at a completion call site the only remedies were a hop
    /// the author had to remember or an `@unchecked Sendable` carrier. A
    /// continuation resumes on the awaiting caller's actor, so the hazard is
    /// unrepresentable here rather than merely avoided.
    ///
    /// Returns `NYPLResult` rather than throwing because the failure case
    /// carries the `URLResponse`, and sign-in reads problem documents off
    /// error responses.
    func execute(_ req: URLRequest,
                 enableTokenRefresh: Bool,
                 accountId: String?) async -> NYPLResult<Data>

    var requestTimeout: TimeInterval {get}

    static var defaultRequestTimeout: TimeInterval {get}
}

extension TPPRequestExecuting {
    var requestTimeout: TimeInterval {
        return Self.defaultRequestTimeout
    }

    static var defaultRequestTimeout: TimeInterval {
        return TPPDefaultRequestTimeout
    }
}

// MARK: - TokenRefreshing seam (§10.2)
//
// `TPPSignInBusinessLogic.getBearerToken` historically accepted a concrete
// `TPPNetworkExecutor`. The `TokenRefreshing` protocol abstracts the single
// method it actually invokes (`executeTokenRefresh`) so that pure
// in-memory unit-test mocks can stand in for the real executor without
// having to spin up a `URLSessionConfiguration` + `HTTPStubURLProtocol`
// stack. Production callers still pass a real `TPPNetworkExecutor` (which
// gains conformance for free via an empty extension).
import PalaceAuth

protocol TokenRefreshing: AnyObject {
    /// Perform a bearer-token refresh against the supplied `tokenURL` using
    /// username/password basic-auth credentials. On success, the
    /// `TokenResponse` is reported to `completion`; on failure the underlying
    /// error is forwarded.
    func executeTokenRefresh(username: String,
                             password: String,
                             tokenURL: URL,
                             accountId: String?,
                             completion: @escaping (Result<TokenResponse, Error>) -> Void)
}
