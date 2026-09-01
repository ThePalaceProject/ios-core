//
//  TPPRequestExecuting.swift
//  The Palace Project
//
//  Created by Ettore Pasquini on 3/24/21.
//  Copyright © 2021 NYPL Labs. All rights reserved.
//

import Foundation

let TPPDefaultRequestTimeout: TimeInterval = 30.0

protocol TPPRequestExecuting {
    /// Execute a given request.
    /// - Parameters:
    ///   - req: The request to perform.
    ///   - completion: Always called when the resource is either fetched from
    /// the network or from the cache.
    /// - Returns: The task issueing the given request.
    @discardableResult
    func executeRequest(_ req: URLRequest,
                        enableTokenRefresh: Bool,
                        completion: @escaping (_: NYPLResult<Data>) -> Void) -> URLSessionDataTask?

    /// Dispatch a request that was built for a SPECIFIC library rather than the
    /// currently selected one.
    ///
    /// PP-4986: the retry queue rebuilds a 401'd request using the account
    /// stamped on its task, and the default `executeRequest` stamps
    /// `currentAccountId` — because that is what it resolves. Callers that build
    /// for another library (Settings sign-in/sign-out via
    /// `TPPSignInBusinessLogic`, `NotificationService.deleteToken(for:)` — see the note below —) must
    /// say so here, or a retry authenticates as the wrong library.
    ///
    /// Additive rather than a signature change: conformers and mocks that do not
    /// implement it inherit the default below, which delegates and behaves
    /// exactly as before.
    @discardableResult
    func executeRequest(_ req: URLRequest,
                        enableTokenRefresh: Bool,
                        accountId: String?,
                        completion: @escaping (_: NYPLResult<Data>) -> Void) -> URLSessionDataTask?

    var requestTimeout: TimeInterval {get}

    static var defaultRequestTimeout: TimeInterval {get}
}

extension TPPRequestExecuting {
    /// Default: ignore the account and behave exactly as the two-argument form.
    /// A conformer that cannot honour per-request accounts is no worse than it
    /// was; only `TPPNetworkExecutor` overrides this.
    @discardableResult
    func executeRequest(_ req: URLRequest,
                        enableTokenRefresh: Bool,
                        accountId: String?,
                        completion: @escaping (_: NYPLResult<Data>) -> Void) -> URLSessionDataTask? {
        executeRequest(req, enableTokenRefresh: enableTokenRefresh, completion: completion)
    }

    var requestTimeout: TimeInterval {
        return Self.defaultRequestTimeout
    }

    static var defaultRequestTimeout: TimeInterval {
        return TPPDefaultRequestTimeout
    }

    @discardableResult
    func executeRequest(_ req: URLRequest,
                        useTokenIfAvailable: Bool = true,
                        completion: @escaping (_: NYPLResult<Data>) -> Void) -> URLSessionDataTask {
        URLSessionDataTask()
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
