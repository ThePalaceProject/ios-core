//
//  AsyncBridge+Timeout.swift
//  Palace
//
//  Created for Swift Concurrency Modernization
//  Copyright © 2025 The Palace Project. All rights reserved.
//

import Foundation

// MARK: - Safe Async→Sync Bridge with Timeout

/// Safely bridge async code to sync context with timeout protection
/// 
/// Usage:
/// ```swift
/// @objc func legacyMethod() -> String? {
///     return syncBridge(timeout: 5.0, operation: "legacyMethod") {
///         await asyncMethod()
///     }
/// }
/// ```
///
/// - Parameters:
///   - timeout: Maximum time to wait (default: 10 seconds)
///   - operation: Name of operation for logging
///   - work: Async closure to execute
/// - Returns: Result of async work, or nil on timeout
func syncBridge<T>(
  timeout: TimeInterval = 10.0,
  operation: String = #function,
  work: @escaping () async -> T
) -> T? {
  let semaphore = DispatchSemaphore(value: 0)
  var result: T?
  
  Task.detached {
    result = await work()
    semaphore.signal()
  }
  
  let deadline = DispatchTime.now() + .milliseconds(Int(timeout * 1000))
  if semaphore.wait(timeout: deadline) == .timedOut {
    Log.error(#file, "⚠️ TIMEOUT: syncBridge timed out for \(operation) after \(timeout)s")
    TPPErrorLogger.logError(
      withCode: .downloadFail,
      summary: "Async→Sync bridge timeout",
      metadata: [
        "operation": operation,
        "timeout": timeout,
        "function": "syncBridge"
      ]
    )
    return nil
  }
  
  return result
}

/// Safely bridge throwing async code to sync context with timeout protection
func syncBridgeThrowing<T>(
  timeout: TimeInterval = 10.0,
  operation: String = #function,
  work: @escaping () async throws -> T
) throws -> T? {
  let semaphore = DispatchSemaphore(value: 0)
  var result: Result<T, Error>?
  
  Task.detached {
    do {
      let value = try await work()
      result = .success(value)
    } catch {
      result = .failure(error)
    }
    semaphore.signal()
  }
  
  let deadline = DispatchTime.now() + .milliseconds(Int(timeout * 1000))
  if semaphore.wait(timeout: deadline) == .timedOut {
    Log.error(#file, "⚠️ TIMEOUT: syncBridgeThrowing timed out for \(operation) after \(timeout)s")
    TPPErrorLogger.logError(
      withCode: .downloadFail,
      summary: "Async→Sync bridge timeout (throwing)",
      metadata: [
        "operation": operation,
        "timeout": timeout,
        "function": "syncBridgeThrowing"
      ]
    )
    return nil
  }
  
  guard let result = result else {
    return nil
  }
  
  switch result {
  case .success(let value):
    return value
  case .failure(let error):
    throw error
  }
}

// MARK: - Timeout-Safe Actor Access

// MARK: - Actor Monitoring Wrapper

/// Execute actor work with automatic health monitoring
func withActorMonitoring<T>(
  _ operation: String,
  actorType: String,
  work: () async throws -> T
) async rethrows -> T {
  let id = await ActorHealthMonitor.shared.startOperation(name: operation, actorType: actorType)
  defer {
    Task {
      await ActorHealthMonitor.shared.completeOperation(id: id)
    }
  }
  return try await work()
}

