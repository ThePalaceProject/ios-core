//
//  DownloadErrorRecovery.swift
//  Palace
//
//  Copyright © 2025 The Palace Project. All rights reserved.
//

import Foundation

/// Provides error recovery strategies for download failures
actor DownloadErrorRecovery {

    // MARK: - Retry Policy

    struct RetryPolicy {
        let maxAttempts: Int
        let baseDelay: TimeInterval
        let maxDelay: TimeInterval
        /// Overall timeout for all retry attempts combined (prevents indefinite freezing)
        let overallTimeout: TimeInterval
        let shouldRetry: (Error) -> Bool

        static let `default` = RetryPolicy(
            maxAttempts: 3,
            baseDelay: 2.0,
            maxDelay: 30.0,
            overallTimeout: 45.0,  // Max 45 seconds for entire borrow operation
            shouldRetry: { error in
                // Check for PalaceError types first (structured errors)
                if let palaceError = error as? PalaceError {
                    switch palaceError {
                    // RETRY token expiry - token refresh mechanism will handle it
                    case .authentication(.tokenExpired):
                        return true
                    // Don't retry other authentication errors (invalid credentials, etc.)
                    case .authentication:
                        return false
                    // Don't retry parsing errors (server sent invalid data)
                    case .parsing:
                        return false
                    // Don't retry book registry policy errors
                    case .bookRegistry(.invalidState), .bookRegistry(.alreadyBorrowed):
                        return false
                    // Retry network errors
                    case .network(.serverError), .network(.timeout), .network(.noConnection):
                        return true
                    // Don't retry other network errors (404, 403, etc.)
                    case .network:
                        return false
                    // Don't retry download errors that are client-side or policy-based
                    case .download(.insufficientSpace),
                         .download(.fileSystemError),
                         .download(.cannotFulfill),
                         .download(.invalidLicense),
                         .download(.cancelled):
                        return false
                    // Retry download network failures
                    case .download(.networkFailure):
                        return true
                    default:
                        return false
                    }
                }

                // Fallback to NSError domain checks
                let nsError = error as NSError
                switch nsError.domain {
                case NSURLErrorDomain:
                    switch nsError.code {
                    case NSURLErrorCancelled,
                         NSURLErrorBadURL,
                         NSURLErrorUnsupportedURL,
                         NSURLErrorUserAuthenticationRequired,
                         NSURLErrorNoPermissionsToReadFile,
                         NSURLErrorFileDoesNotExist:
                        return false
                    default:
                        return true
                    }
                default:
                    // Unknown errors - don't retry to avoid infinite loops
                    return false
                }
            }
        )

        static let aggressive = RetryPolicy(
            maxAttempts: 5,
            baseDelay: 1.0,
            maxDelay: 60.0,
            overallTimeout: 120.0,
            shouldRetry: { _ in true }
        )

        static let conservative = RetryPolicy(
            maxAttempts: 2,
            baseDelay: 5.0,
            maxDelay: 15.0,
            overallTimeout: 30.0,
            shouldRetry: { error in
                let nsError = error as NSError
                return nsError.domain == NSURLErrorDomain &&
                    (nsError.code == NSURLErrorTimedOut ||
                        nsError.code == NSURLErrorNotConnectedToInternet)
            }
        )

        /// Retry policy for borrow operations — tolerant of slow servers (hold notifications
        /// can fire before the loan is fully ready on the CM side).
        static let borrowOperation = RetryPolicy(
            maxAttempts: 3,
            baseDelay: 2.0,
            maxDelay: 10.0,
            overallTimeout: 25.0,
            shouldRetry: { error in
                if let palaceError = error as? PalaceError {
                    switch palaceError {
                    case .network(.timeout), .network(.noConnection):
                        return true
                    case .bookRegistry(.bookNotFound):
                        return true  // Book may not be ready yet on slow servers
                    default:
                        return false
                    }
                }

                let nsError = error as NSError
                return nsError.domain == NSURLErrorDomain &&
                    (nsError.code == NSURLErrorTimedOut ||
                        nsError.code == NSURLErrorNotConnectedToInternet)
            }
        )
    }

    // MARK: - User-Facing Retry Classification

    /// Determines whether an error should be presented to the user with a "Retry" option.
    /// This is separate from the automatic retry logic: it classifies errors that are likely
    /// transient and worth retrying manually (e.g., network issues, server errors, parsing
    /// errors from potentially malformed server responses).
    static func isRetryableForUser(_ error: Error) -> Bool {
        if let palaceError = error as? PalaceError {
            switch palaceError {
            // Network errors that are transient
            case .network(.serverError),
                 .network(.timeout),
                 .network(.noConnection),
                 .network(.rateLimited),
                 .network(.invalidResponse),
                 .network(.unknown):
                return true

            // Parsing errors are often transient (server glitch, malformed response)
            case .parsing(.opdsFeedInvalid),
                 .parsing(.invalidJSON),
                 .parsing(.invalidXML),
                 .parsing(.missingRequiredField),
                 .parsing(.invalidFormat),
                 .parsing(.encodingError):
                return true

            // Download failures that could resolve on retry
            case .download(.networkFailure),
                 .download(.maxRetriesExceeded):
                return true

            // Book registry sync failure
            case .bookRegistry(.syncFailed):
                return true

            // Auth network error (not invalid credentials)
            case .authentication(.networkError):
                return true

            // Audiobook streaming issues
            case .audiobook(.streamingError):
                return true

            // Everything else is NOT retryable by the user
            // (invalid credentials, DRM limits, storage, unsupported formats, etc.)
            default:
                return false
            }
        }

        // Fallback: check NSError domain
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorCancelled,
                 NSURLErrorBadURL,
                 NSURLErrorUnsupportedURL,
                 NSURLErrorUserAuthenticationRequired,
                 NSURLErrorNoPermissionsToReadFile,
                 NSURLErrorFileDoesNotExist:
                return false
            default:
                // Most URL errors are transient (timeout, no connection, etc.)
                return true
            }
        }

        // Unknown errors - not retryable
        return false
    }

    // MARK: - Retry Execution

    /// Executes an operation with automatic retry and overall timeout
    /// - Parameters:
    ///   - policy: The retry policy to use
    ///   - operation: The operation to execute
    /// - Returns: The result of the operation
    /// - Throws: The last error after all retries are exhausted or timeout
    func executeWithRetry<T>(
        policy: RetryPolicy = .default,
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        let startTime = Date()
        var lastError: Error?

        for attempt in 0..<policy.maxAttempts {
            // Check overall timeout before each attempt
            let elapsed = Date().timeIntervalSince(startTime)
            if elapsed >= policy.overallTimeout {
                Log.warn(#file, "Operation timed out after \(String(format: "%.1f", elapsed))s (overall timeout: \(policy.overallTimeout)s)")
                throw PalaceError.network(.timeout)
            }

            do {
                return try await operation()
            } catch {
                lastError = error

                // Check if we should retry this error
                guard policy.shouldRetry(error) else {
                    Log.error(#file, "Download error is non-retryable: \(error.localizedDescription)")
                    throw error
                }

                // If this isn't the last attempt, wait before retry
                if attempt < policy.maxAttempts - 1 {
                    let delay = calculateBackoffDelay(
                        attempt: attempt,
                        baseDelay: policy.baseDelay,
                        maxDelay: policy.maxDelay
                    )

                    // Check if delay would exceed overall timeout
                    let remainingTime = policy.overallTimeout - Date().timeIntervalSince(startTime)
                    if delay >= remainingTime {
                        Log.warn(#file, "Skipping retry - delay (\(String(format: "%.1f", delay))s) would exceed remaining time (\(String(format: "%.1f", remainingTime))s)")
                        break
                    }

                    Log.info(#file, "Download failed (attempt \(attempt + 1)/\(policy.maxAttempts)), retrying in \(String(format: "%.1f", delay))s: \(error.localizedDescription)")

                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

                    // Check for cancellation
                    if Task.isCancelled {
                        throw CancellationError()
                    }
                }
            }
        }

        // All retries failed
        if let lastError = lastError {
            Log.error(#file, "Download failed after \(policy.maxAttempts) attempts: \(lastError.localizedDescription)")
            throw PalaceError.download(.maxRetriesExceeded)
        }

        throw PalaceError.download(.networkFailure)
    }

    // MARK: - Backoff Calculation

    private func calculateBackoffDelay(attempt: Int, baseDelay: TimeInterval, maxDelay: TimeInterval) -> TimeInterval {
        // Exponential backoff with jitter
        let exponentialDelay = baseDelay * pow(2.0, Double(attempt))
        let jitter = Double.random(in: 0...0.3) * exponentialDelay
        let totalDelay = min(exponentialDelay + jitter, maxDelay)
        return totalDelay
    }
}
