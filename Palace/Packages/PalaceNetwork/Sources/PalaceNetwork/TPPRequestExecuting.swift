//
//  TPPRequestExecuting.swift
//  The Palace Project
//
//  Created by Ettore Pasquini on 3/24/21.
//  Copyright © 2021 NYPL Labs. All rights reserved.
//
//  Public protocol describing a request executor. Depends on NYPLResult
//  (same module) and TPPUserFriendlyError (same module). App-target
//  TPPNetworkExecutor adopts this protocol; PalaceTests' mocks implement
//  it for substitution.
//

import Foundation

public let TPPDefaultRequestTimeout: TimeInterval = 30.0

public protocol TPPRequestExecuting {
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

    var requestTimeout: TimeInterval { get }

    static var defaultRequestTimeout: TimeInterval { get }
}

public extension TPPRequestExecuting {
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
