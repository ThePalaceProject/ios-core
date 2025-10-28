//
//  CircuitBreaker.swift
//  Palace
//
//  Created for Swift Concurrency Modernization
//  Copyright © 2025 The Palace Project. All rights reserved.
//

import Foundation

/// Circuit breaker pattern for preventing cascading failures in network operations
/// Implements the classic circuit breaker pattern to fail fast when a service is unavailable
actor CircuitBreaker {
  
  enum State {
    case closed      // Normal operation
    case open        // Failing fast, not attempting requests
    case halfOpen    // Testing if service recovered
  }
  
  private(set) var state: State = .closed
  private var failureCount = 0
  private var lastFailureTime: Date?
  private var successCount = 0
  
  private let failureThreshold: Int
  private let timeout: TimeInterval
  private let halfOpenRetryCount: Int
  
  /// Initializes a circuit breaker
  /// - Parameters:
  ///   - failureThreshold: Number of failures before opening circuit (default: 5)
  ///   - timeout: Time to wait before attempting to close circuit (default: 30s)
  ///   - halfOpenRetryCount: Number of successes needed in half-open state (default: 2)
  init(failureThreshold: Int = 5, timeout: TimeInterval = 30.0, halfOpenRetryCount: Int = 2) {
    self.failureThreshold = failureThreshold
    self.timeout = timeout
    self.halfOpenRetryCount = halfOpenRetryCount
  }
  
  /// Executes an operation through the circuit breaker
  /// - Parameter operation: The operation to execute
  /// - Returns: The result of the operation
  /// - Throws: Error if operation fails or circuit is open
  func execute<T>(_ operation: () async throws -> T) async throws -> T {
    // Check current state
    switch state {
    case .open:
      // Check if timeout has elapsed
      if let lastFailure = lastFailureTime,
         Date().timeIntervalSince(lastFailure) >= timeout {
        state = .halfOpen
        successCount = 0
        Log.info(#file, "Circuit breaker entering half-open state")
      } else {
        throw PalaceError.network(.serverError)
      }
      
    case .halfOpen:
      // In half-open state, try the operation
      break
      
    case .closed:
      // Normal operation
      break
    }
    
    do {
      let result = try await operation()
      await recordSuccess()
      return result
    } catch {
      await recordFailure()
      throw error
    }
  }
  
  /// Records a successful operation
  private func recordSuccess() {
    switch state {
    case .halfOpen:
      successCount += 1
      if successCount >= halfOpenRetryCount {
        state = .closed
        failureCount = 0
        successCount = 0
        Log.info(#file, "Circuit breaker closed after successful recovery")
      }
      
    case .closed:
      // Reset failure count on success
      if failureCount > 0 {
        failureCount = max(0, failureCount - 1)
      }
      
    case .open:
      // Shouldn't happen, but reset if it does
      state = .closed
      failureCount = 0
    }
  }
  
  /// Records a failed operation
  private func recordFailure() {
    lastFailureTime = Date()
    
    switch state {
    case .closed:
      failureCount += 1
      if failureCount >= failureThreshold {
        state = .open
        Log.warn(#file, "Circuit breaker opened after \(failureCount) failures")
      }
      
    case .halfOpen:
      // Failure in half-open, return to open
      state = .open
      failureCount = failureThreshold
      Log.warn(#file, "Circuit breaker reopened after failure in half-open state")
      
    case .open:
      // Already open, just update failure time
      break
    }
  }
  
  /// Manually resets the circuit breaker
  func reset() {
    state = .closed
    failureCount = 0
    successCount = 0
    lastFailureTime = nil
    Log.info(#file, "Circuit breaker manually reset")
  }
  
  /// Gets current circuit breaker metrics
  func metrics() -> (state: State, failureCount: Int, lastFailureTime: Date?) {
    return (state, failureCount, lastFailureTime)
  }
}

// MARK: - Circuit Breaker Manager

/// Manages circuit breakers for different services
actor CircuitBreakerManager {
  static let shared = CircuitBreakerManager()
  
  private var breakers: [String: CircuitBreaker] = [:]
  
  private init() {}
  
  /// Gets or creates a circuit breaker for a service
  /// - Parameter serviceKey: Unique identifier for the service (e.g., "opds-feed", "loans-api")
  /// - Returns: Circuit breaker for the service
  func breaker(for serviceKey: String) -> CircuitBreaker {
    if let existing = breakers[serviceKey] {
      return existing
    }
    
    let newBreaker = CircuitBreaker()
    breakers[serviceKey] = newBreaker
    return newBreaker
  }
  
  /// Executes an operation through a service-specific circuit breaker
  /// - Parameters:
  ///   - serviceKey: The service identifier
  ///   - operation: The operation to execute
  /// - Returns: Result of the operation
  /// - Throws: Error if operation fails or circuit is open
  func execute<T>(
    service serviceKey: String,
    operation: () async throws -> T
  ) async throws -> T {
    let breaker = breaker(for: serviceKey)
    return try await breaker.execute(operation)
  }
  
  /// Resets a specific service's circuit breaker
  func reset(service serviceKey: String) async {
    await breakers[serviceKey]?.reset()
  }
  
  /// Resets all circuit breakers
  func resetAll() async {
    for breaker in breakers.values {
      await breaker.reset()
    }
  }
  
  /// Gets metrics for all services
  func allMetrics() async -> [String: (state: CircuitBreaker.State, failures: Int)] {
    var metrics: [String: (state: CircuitBreaker.State, failures: Int)] = [:]
    
    for (key, breaker) in breakers {
      let (state, count, _) = await breaker.metrics()
      metrics[key] = (state, count)
    }
    
    return metrics
  }
}

// MARK: - Network Executor Integration

extension TPPNetworkExecutor {
  /// Performs a GET request with circuit breaker protection
  /// - Parameters:
  ///   - url: The URL to fetch
  ///   - serviceKey: Circuit breaker service identifier (defaults to host)
  ///   - useToken: Whether to use authentication token
  /// - Returns: The fetched data
  /// - Throws: PalaceError on failure or if circuit is open
  func getWithCircuitBreaker(
    _ url: URL,
    serviceKey: String? = nil,
    useToken: Bool = true
  ) async throws -> Data {
    let service = serviceKey ?? url.host ?? "default"
    
    return try await CircuitBreakerManager.shared.execute(service: service) {
      try await self.get(url, useToken: useToken)
    }
  }
}

// MARK: - OPDS Service Integration

extension OPDSFeedService {
  /// Fetches an OPDS feed with circuit breaker protection
  /// - Parameters:
  ///   - url: The feed URL
  ///   - resetCache: Whether to reset cache
  ///   - useToken: Whether to use authentication token
  /// - Returns: The parsed feed
  /// - Throws: PalaceError if fetch fails or circuit is open
  func fetchFeedWithCircuitBreaker(
    from url: URL,
    resetCache: Bool = false,
    useToken: Bool = true
  ) async throws -> TPPOPDSFeed {
    let serviceKey = "opds-\(url.host ?? "unknown")"
    
    return try await CircuitBreakerManager.shared.execute(service: serviceKey) {
      try await self.fetchFeed(from: url, resetCache: resetCache, useToken: useToken)
    }
  }
}

