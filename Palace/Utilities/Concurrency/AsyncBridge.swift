//
//  AsyncBridge.swift
//  Palace
//
//  Created for Swift Concurrency Modernization
//  Copyright © 2025 The Palace Project. All rights reserved.
//

import Foundation

/// Utilities for bridging between callback-based and async/await code
/// Helps with incremental modernization of legacy APIs

// MARK: - Callback to Async Converters

extension URLSession {
  /// Async wrapper for download tasks
  func download(from url: URL) async throws -> (URL, URLResponse) {
    try await withCheckedThrowingContinuation { continuation in
      let task = downloadTask(with: url) { location, response, error in
        if let error = error {
          continuation.resume(throwing: error)
        } else if let location = location, let response = response {
          continuation.resume(returning: (location, response))
        } else {
          continuation.resume(throwing: PalaceError.download(.networkFailure))
        }
      }
      task.resume()
    }
  }
  
  /// Async wrapper for data tasks
  func data(from url: URL) async throws -> (Data, URLResponse) {
    try await data(from: url, delegate: nil)
  }
}

// MARK: - Main Actor Callback Helpers

/// Wraps a callback to ensure it runs on MainActor
/// Useful for legacy APIs that take completion handlers
@MainActor
func ensureMainThread<T>(_ callback: @escaping (T) -> Void) -> @Sendable (T) -> Void {
  return { value in
    Task { @MainActor in
      callback(value)
    }
  }
}

/// Wraps an optional callback to ensure it runs on MainActor
@MainActor
func ensureMainThreadOptional<T>(_ callback: ((T) -> Void)?) -> (@Sendable (T) -> Void)? {
  guard let callback = callback else { return nil }
  return { value in
    Task { @MainActor in
      callback(value)
    }
  }
}

// MARK: - Completion Handler Patterns

/// Represents a completion result that can be used in async context
enum CompletionResult<Success> {
  case success(Success)
  case failure(Error)
  
  func get() throws -> Success {
    switch self {
    case .success(let value):
      return value
    case .failure(let error):
      throw error
    }
  }
}

/// Converts a Result-based callback to async/await
func asyncResult<T>(
  _ operation: (@escaping (Result<T, Error>) -> Void) -> Void
) async throws -> T {
  try await withCheckedThrowingContinuation { continuation in
    operation { result in
      continuation.resume(with: result)
    }
  }
}

/// Converts a success/error callback to async/await
func asyncCompletion<T>(
  _ operation: (@escaping (T?, Error?) -> Void) -> Void
) async throws -> T {
  try await withCheckedThrowingContinuation { continuation in
    operation { value, error in
      if let error = error {
        continuation.resume(throwing: error)
      } else if let value = value {
        continuation.resume(returning: value)
      } else {
        continuation.resume(throwing: PalaceError.network(.invalidResponse))
      }
    }
  }
}

/// Converts a simple success callback to async/await
func asyncSuccess(
  _ operation: (@escaping (Bool) -> Void) -> Void
) async -> Bool {
  await withCheckedContinuation { continuation in
    operation { success in
      continuation.resume(returning: success)
    }
  }
}

// MARK: - Debouncing for Callbacks

/// Debounces callback-based operations
final class CallbackDebouncer {
  private var workItem: DispatchWorkItem?
  private let queue: DispatchQueue
  private let delay: TimeInterval
  
  init(delay: TimeInterval, queue: DispatchQueue = .main) {
    self.delay = delay
    self.queue = queue
  }
  
  func debounce(_ work: @escaping () -> Void) {
    workItem?.cancel()
    let newWorkItem = DispatchWorkItem(block: work)
    workItem = newWorkItem
    queue.asyncAfter(deadline: .now() + delay, execute: newWorkItem)
  }
  
  func cancel() {
    workItem?.cancel()
    workItem = nil
  }
}

// MARK: - Safe Casting Utilities

extension Optional {
  /// Safely casts to a different type, logging failures
  func `as`<T>(_ type: T.Type, context: String = #file) -> T? {
    guard let self = self else { return nil }
    
    if let casted = self as? T {
      return casted
    }
    
    Log.error(context, "Failed to cast \(Self.self) to \(T.self)")
    return nil
  }
}

// MARK: - Error Recovery Helpers

extension Error {
  /// Checks if error is retryable
  var isRetryable: Bool {
    let nsError = self as NSError
    
    switch nsError.domain {
    case NSURLErrorDomain:
      switch nsError.code {
      case NSURLErrorTimedOut,
           NSURLErrorCannotFindHost,
           NSURLErrorCannotConnectToHost,
           NSURLErrorNetworkConnectionLost,
           NSURLErrorDNSLookupFailed,
           NSURLErrorNotConnectedToInternet:
        return true
      default:
        return false
      }
    default:
      return false
    }
  }
  
  /// Checks if error indicates user action (cancellation, etc)
  var isUserInitiated: Bool {
    let nsError = self as NSError
    return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
  }
}

// MARK: - Thread-Safe Collections

/// Thread-safe dictionary using actor
actor SafeDictionary<Key: Hashable, Value> {
  private var storage: [Key: Value] = [:]
  
  func get(_ key: Key) -> Value? {
    storage[key]
  }
  
  func set(_ key: Key, value: Value) {
    storage[key] = value
  }
  
  func remove(_ key: Key) {
    storage.removeValue(forKey: key)
  }
  
  func removeAll() {
    storage.removeAll()
  }
  
  func keys() -> [Key] {
    Array(storage.keys)
  }
  
  func values() -> [Value] {
    Array(storage.values)
  }
  
  func count() -> Int {
    storage.count
  }
}

