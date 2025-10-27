//
//  TPPNetworkExecutor+Async.swift
//  Palace
//
//  Created for Swift Concurrency Modernization
//  Copyright © 2025 The Palace Project. All rights reserved.
//

import Foundation

/// Modern async/await extensions for TPPNetworkExecutor
extension TPPNetworkExecutor {
  
  // MARK: - Async GET Methods
  
  /// Performs an async GET request
  /// - Parameters:
  ///   - url: The URL to fetch
  ///   - useToken: Whether to use authentication token if available
  /// - Returns: The fetched data
  /// - Throws: PalaceError on failure
  func get(_ url: URL, useToken: Bool = true) async throws -> Data {
    return try await withCheckedThrowingContinuation { continuation in
      GET(url, useTokenIfAvailable: useToken) { result in
        switch result {
        case .success(let data, _):
          continuation.resume(returning: data)
        case .failure(let error, _):
          let palaceError = PalaceError.from(error)
          continuation.resume(throwing: palaceError)
        }
      }
    }
  }
  
  /// Performs an async GET request with cache policy
  /// - Parameters:
  ///   - url: The URL to fetch
  ///   - cachePolicy: The cache policy to use
  ///   - useToken: Whether to use authentication token if available
  /// - Returns: The fetched data and response
  /// - Throws: PalaceError on failure
  func get(
    _ url: URL,
    cachePolicy: NSURLRequest.CachePolicy,
    useToken: Bool = true
  ) async throws -> (Data, URLResponse?) {
    return try await withCheckedThrowingContinuation { continuation in
      GET(url, cachePolicy: cachePolicy, useTokenIfAvailable: useToken) { data, response, error in
        if let error = error {
          let palaceError = PalaceError.from(error)
          continuation.resume(throwing: palaceError)
        } else if let data = data {
          continuation.resume(returning: (data, response))
        } else {
          continuation.resume(throwing: PalaceError.network(.invalidResponse))
        }
      }
    }
  }
  
  // MARK: - Async POST Methods
  
  /// Performs an async POST request
  /// - Parameters:
  ///   - url: The URL to post to
  ///   - parameters: Optional JSON parameters
  /// - Returns: The response data
  /// - Throws: PalaceError on failure
  func post(_ url: URL, parameters: [String: Any]? = nil) async throws -> Data {
    return try await withCheckedThrowingContinuation { continuation in
      POST(url, parameters: parameters) { result in
        switch result {
        case .success(let data, _):
          continuation.resume(returning: data)
        case .failure(let error, _):
          let palaceError = PalaceError.from(error)
          continuation.resume(throwing: palaceError)
        }
      }
    }
  }
  
  // MARK: - Async PUT Methods
  
  /// Performs an async PUT request
  /// - Parameters:
  ///   - url: The URL to put to
  ///   - parameters: Optional JSON parameters
  /// - Returns: The response data
  /// - Throws: PalaceError on failure
  func put(_ url: URL, parameters: [String: Any]? = nil) async throws -> Data {
    return try await withCheckedThrowingContinuation { continuation in
      PUT(url, parameters: parameters) { result in
        switch result {
        case .success(let data, _):
          continuation.resume(returning: data)
        case .failure(let error, _):
          let palaceError = PalaceError.from(error)
          continuation.resume(throwing: palaceError)
        }
      }
    }
  }
  
  // MARK: - Async DELETE Methods
  
  /// Performs an async DELETE request
  /// - Parameter url: The URL to delete
  /// - Returns: The response data
  /// - Throws: PalaceError on failure
  func delete(_ url: URL) async throws -> Data {
    return try await withCheckedThrowingContinuation { continuation in
      DELETE(url) { result in
        switch result {
        case .success(let data, _):
          continuation.resume(returning: data)
        case .failure(let error, _):
          let palaceError = PalaceError.from(error)
          continuation.resume(throwing: palaceError)
        }
      }
    }
  }
  
  // MARK: - Async Download Methods
  
  /// Performs an async download
  /// - Parameter url: The URL to download from
  /// - Returns: The downloaded data and response
  /// - Throws: PalaceError on failure
  func download(_ url: URL) async throws -> (Data, URLResponse?) {
    return try await withCheckedThrowingContinuation { continuation in
      let _ = download(url) { data, response, error in
        if let error = error {
          let palaceError = PalaceError.from(error)
          continuation.resume(throwing: palaceError)
        } else if let data = data {
          continuation.resume(returning: (data, response))
        } else {
          continuation.resume(throwing: PalaceError.download(.networkFailure))
        }
      }
    }
  }
  
  // MARK: - Request Execution
  
  /// Executes a URLRequest asynchronously
  /// - Parameters:
  ///   - request: The request to execute
  ///   - enableTokenRefresh: Whether to enable automatic token refresh
  /// - Returns: The response data
  /// - Throws: PalaceError on failure
  func execute(_ request: URLRequest, enableTokenRefresh: Bool = true) async throws -> Data {
    return try await withCheckedThrowingContinuation { continuation in
      executeRequest(request, enableTokenRefresh: enableTokenRefresh) { result in
        switch result {
        case .success(let data, _):
          continuation.resume(returning: data)
        case .failure(let error, _):
          let palaceError = PalaceError.from(error)
          continuation.resume(throwing: palaceError)
        }
      }
    }
  }
  
  /// Executes a URLRequest with bearer authorization asynchronously
  /// - Parameter request: The request to execute
  /// - Returns: The response data and response
  /// - Throws: PalaceError on failure
  func executeWithBearer(_ request: URLRequest) async throws -> (Data, URLResponse?) {
    return try await withCheckedThrowingContinuation { continuation in
      let _ = addBearerAndExecute(request) { data, response, error in
        if let error = error {
          let palaceError = PalaceError.from(error)
          continuation.resume(throwing: palaceError)
        } else if let data = data {
          continuation.resume(returning: (data, response))
        } else {
          continuation.resume(throwing: PalaceError.network(.invalidResponse))
        }
      }
    }
  }
}

// MARK: - Cancellable Request Support

/// Wrapper for cancellable async network requests
actor CancellableNetworkRequest {
  private var task: URLSessionDataTask?
  
  func setTask(_ task: URLSessionDataTask) {
    self.task = task
  }
  
  func cancel() {
    task?.cancel()
    task = nil
  }
}

extension TPPNetworkExecutor {
  /// Performs a cancellable GET request
  /// - Parameters:
  ///   - url: The URL to fetch
  ///   - useToken: Whether to use authentication token
  /// - Returns: Tuple of data and a cancellation handle
  func getCancellable(
    _ url: URL,
    useToken: Bool = true
  ) async throws -> Data {
    return try await withTaskCancellationHandler {
      try await get(url, useToken: useToken)
    } onCancel: {
      // Task cancellation will be handled by URLSession
      Log.info(#file, "Network request cancelled: \(url)")
    }
  }
}

// MARK: - Retry Logic

extension TPPNetworkExecutor {
  /// Performs a GET request with automatic retry
  /// - Parameters:
  ///   - url: The URL to fetch
  ///   - maxRetries: Maximum number of retry attempts
  ///   - useToken: Whether to use authentication token
  /// - Returns: The fetched data
  /// - Throws: PalaceError after all retries fail
  func getWithRetry(
    _ url: URL,
    maxRetries: Int = 3,
    useToken: Bool = true
  ) async throws -> Data {
    var lastError: Error?
    
    for attempt in 0..<maxRetries {
      do {
        return try await get(url, useToken: useToken)
      } catch let error as PalaceError {
        lastError = error
        
        // Don't retry on certain errors
        if case .network(let networkError) = error {
          switch networkError {
          case .unauthorized, .forbidden, .notFound, .cancelled:
            throw error
          default:
            break
          }
        }
        
        // Exponential backoff
        if attempt < maxRetries - 1 {
          let delay = min(pow(2.0, Double(attempt)), 10.0) // Max 10 seconds
          try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
          Log.info(#file, "Retrying network request (attempt \(attempt + 2)/\(maxRetries)): \(url)")
        }
      }
    }
    
    throw lastError ?? PalaceError.network(.unknown)
  }
}

