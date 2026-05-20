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
