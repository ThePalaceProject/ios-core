//
//  ErrorLogging.swift
//  Palace
//
//  Created for dependency injection support.
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation

/// Protocol for error logging, enabling dependency injection for testing.
///
/// This protocol extracts the consumer-facing interface from `TPPErrorLogger`,
/// allowing tests to inject mock implementations that capture logged errors
/// instead of sending them to Crashlytics.
///
/// Because `TPPErrorLogger` uses class (static) methods, this protocol uses
/// instance methods. The `AppContainer` holds a concrete instance conforming
/// to this protocol. The default implementation (`DefaultErrorLogger`) simply
/// forwards to the existing static methods on `TPPErrorLogger`.
protocol ErrorLogging: AnyObject {

    /// Reports an error with an optional originating error and metadata.
    func logError(_ error: Error?, summary: String, metadata: [String: Any]?)

    /// Reports an error with a code and metadata (no originating error).
    func logError(withCode code: TPPErrorCode, summary: String, metadata: [String: Any]?)

    /// Logs a network error with request/response context.
    func logNetworkError(_ originalError: Error?,
                         code: TPPErrorCode,
                         summary: String?,
                         request: URLRequest?,
                         response: URLResponse?,
                         metadata: [String: Any]?)
}

// MARK: - Default Implementation

/// Default implementation that forwards to `TPPErrorLogger`'s static methods.
final class DefaultErrorLogger: ErrorLogging {

    func logError(_ error: Error?, summary: String, metadata: [String: Any]?) {
        TPPErrorLogger.logError(error, summary: summary, metadata: metadata)
    }

    func logError(withCode code: TPPErrorCode, summary: String, metadata: [String: Any]?) {
        TPPErrorLogger.logError(withCode: code, summary: summary, metadata: metadata)
    }

    func logNetworkError(_ originalError: Error?,
                         code: TPPErrorCode,
                         summary: String?,
                         request: URLRequest?,
                         response: URLResponse?,
                         metadata: [String: Any]?) {
        TPPErrorLogger.logNetworkError(originalError,
                                       code: code,
                                       summary: summary,
                                       request: request,
                                       response: response,
                                       metadata: metadata)
    }
}
