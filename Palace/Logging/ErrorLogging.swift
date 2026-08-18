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
/// instance methods. The default implementation (`DefaultErrorLogger`) simply
/// forwards to those static methods.
///
/// Note this is NOT held by `AppContainer` — that was the original intent and
/// the doc said so, but no such wiring was ever added (verified: zero
/// `ErrorLogging` references there). Consumers today are static-class APIs
/// that cannot take constructor injection, so each holds its own shared
/// instance behind a test seam; see `TPPAnnotations.errorLoggerOverride`. If a
/// container-held instance is ever added, prefer it and retire the seams.
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
///
/// `Sendable` because it holds no state — every method forwards straight to a
/// static. That lets callers hold a single shared instance instead of either
/// allocating one per report or reaching for `nonisolated(unsafe)`; the
/// compiler checks the claim rather than us asserting it.
final class DefaultErrorLogger: ErrorLogging, Sendable {

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
