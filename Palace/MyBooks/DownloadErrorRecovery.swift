//
//  DownloadErrorRecovery.swift
//  Palace
//
//  Created for Swift Concurrency Modernization
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
        let nsError = error as NSError
        
        // Don't retry on certain errors
        switch nsError.domain {
        case NSURLErrorDomain:
          switch nsError.code {
          case NSURLErrorCancelled,
               NSURLErrorBadURL,
               NSURLErrorUnsupportedURL:
            return false
          default:
            return true
          }
        default:
          return true
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

// MARK: - Network Condition Aware Downloads

actor NetworkConditionMonitor {
  static let shared = NetworkConditionMonitor()
  
  private init() {}
  
  /// Checks if network conditions are suitable for downloading
  func isNetworkSuitableForDownload() -> Bool {
    guard Reachability.shared.isConnectedToNetwork() else {
      return false
    }
    
    // Check if on WiFi (preferred for large downloads)
    let (isConnected, connectionType, _) = Reachability.shared.getDetailedConnectivityStatus()
    guard isConnected else { return false }
    let isWiFi = (connectionType == "WiFi")
    
    // Check if on low power mode
    let isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    
    // WiFi is always suitable
    if isWiFi {
      return true
    }
    
    // Cellular is OK if not in low power mode
    if !isLowPowerMode {
      return true
    }
    
    // In low power mode on cellular, not suitable
    return false
  }
  
  /// Waits for suitable network conditions
  /// - Parameter timeout: Maximum time to wait
  /// - Returns: True if conditions became suitable, false if timeout
  func waitForSuitableConditions(timeout: TimeInterval = 60) async -> Bool {
    let startTime = Date()
    
    while !isNetworkSuitableForDownload() {
      if Date().timeIntervalSince(startTime) > timeout {
        return false
      }
      
      // Wait 5 seconds before checking again
      try? await Task.sleep(nanoseconds: 5_000_000_000)
      
      if Task.isCancelled {
        return false
      }
    }
    
    return true
  }
}

// MARK: - Disk Space Checker

actor DiskSpaceChecker {
  static let shared = DiskSpaceChecker()
  
  private let minimumRequiredSpaceMB: Int64 = 100 // 100MB minimum
  
  private init() {}
  
  /// Checks if there's enough disk space for a download
  /// - Parameter estimatedSizeMB: Estimated download size in MB (0 if unknown)
  /// - Returns: True if sufficient space available
  func hasSufficientSpace(forDownloadSize estimatedSizeMB: Int64 = 0) -> Bool {
    guard let availableSpace = availableDiskSpace() else {
      return true // Assume space available if we can't check
    }
    
    let availableSpaceMB = availableSpace / (1024 * 1024)
    let requiredSpace = max(minimumRequiredSpaceMB, estimatedSizeMB * 2) // 2x for safety
    
    if availableSpaceMB < requiredSpace {
      Log.warn(#file, "Insufficient disk space: \(availableSpaceMB)MB available, need \(requiredSpace)MB")
      return false
    }
    
    return true
  }
  
  /// Gets available disk space
  private func availableDiskSpace() -> Int64? {
    let fileURL = URL(fileURLWithPath: NSHomeDirectory() as String)
    do {
      let values = try fileURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
      return values.volumeAvailableCapacityForImportantUsage
    } catch {
      return nil
    }
  }
  
  /// Estimates download size from book metadata
  func estimateDownloadSize(for book: TPPBook) -> Int64 {
    // Try to get size from acquisition metadata if available
    // Most OPDS feeds don't include size, so we use defaults
    
    // Default estimates by book type
    switch book.defaultBookContentType {
    case .audiobook:
      return 200 // 200MB default for audiobooks
    case .epub:
      return 20 // 20MB default for ebooks
    case .pdf:
      return 30 // 30MB default for PDFs
    default:
      return 50 // 50MB default for unknown
    }
  }
}

