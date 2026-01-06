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
    let shouldRetry: (Error) -> Bool
    
    static let `default` = RetryPolicy(
      maxAttempts: 3,
      baseDelay: 2.0,
      maxDelay: 30.0,
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
      shouldRetry: { _ in true }
    )
    
    static let conservative = RetryPolicy(
      maxAttempts: 2,
      baseDelay: 5.0,
      maxDelay: 15.0,
      shouldRetry: { error in
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain &&
          (nsError.code == NSURLErrorTimedOut ||
           nsError.code == NSURLErrorNotConnectedToInternet)
      }
    )
  }
  
  // MARK: - Retry Execution
  
  /// Executes an operation with automatic retry
  /// - Parameters:
  ///   - policy: The retry policy to use
  ///   - operation: The operation to execute
  /// - Returns: The result of the operation
  /// - Throws: The last error after all retries are exhausted
  func executeWithRetry<T>(
    policy: RetryPolicy = .default,
    operation: @Sendable () async throws -> T
  ) async throws -> T {
    var lastError: Error?
    
    for attempt in 0..<policy.maxAttempts {
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

