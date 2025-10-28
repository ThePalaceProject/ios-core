//
//  ActorIsolationTests.swift
//  PalaceTests
//
//  Created for Swift Concurrency Modernization
//  Copyright © 2025 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

/// Tests for actor isolation and thread safety
final class ActorIsolationTests: XCTestCase {
  
  // MARK: - CircuitBreaker Tests
  
  func testCircuitBreakerOpensAfterFailures() async throws {
    let breaker = CircuitBreaker(failureThreshold: 3, timeout: 1.0)
    
    // Execute 3 failing operations
    for _ in 0..<3 {
      do {
        try await breaker.execute {
          throw PalaceError.network(.serverError)
        }
        XCTFail("Should have thrown error")
      } catch {
        // Expected
      }
    }
    
    // Circuit should now be open
    let (state, count, _) = await breaker.metrics()
    XCTAssertEqual(state, .open)
    XCTAssertEqual(count, 3)
    
    // Next call should fail fast without executing operation
    var operationExecuted = false
    do {
      try await breaker.execute {
        operationExecuted = true
        return "success"
      }
      XCTFail("Should have thrown error with circuit open")
    } catch {
      XCTAssertFalse(operationExecuted, "Operation should not execute when circuit is open")
    }
  }
  
  func testCircuitBreakerRecovery() async throws {
    let breaker = CircuitBreaker(failureThreshold: 2, timeout: 0.5, halfOpenRetryCount: 2)
    
    // Open the circuit with failures
    for _ in 0..<2 {
      try? await breaker.execute {
        throw PalaceError.network(.timeout)
      }
    }
    
    var (state, _, _) = await breaker.metrics()
    XCTAssertEqual(state, .open)
    
    // Wait for timeout
    try await Task.sleep(nanoseconds: 600_000_000) // 0.6s
    
    // Execute 2 successful operations to close circuit
    for _ in 0..<2 {
      let result = try await breaker.execute {
        return "success"
      }
      XCTAssertEqual(result, "success")
    }
    
    (state, _, _) = await breaker.metrics()
    XCTAssertEqual(state, .closed)
  }
  
  // MARK: - Debouncer Tests
  
  func testDebouncerExecutesOnlyLastCall() async throws {
    let debouncer = Debouncer(duration: .milliseconds(100))
    var executionCount = 0
    var lastValue = 0
    
    // Make multiple rapid calls
    for i in 1...5 {
      await debouncer.debounce {
        executionCount += 1
        lastValue = i
      }
    }
    
    // Wait for debounce
    try await Task.sleep(nanoseconds: 150_000_000) // 150ms
    
    // Should have executed only once with the last value
    XCTAssertEqual(executionCount, 1)
    XCTAssertEqual(lastValue, 5)
  }
  
  // MARK: - Throttler Tests
  
  func testThrottlerLimitsExecutionRate() async throws {
    let throttler = Throttler(interval: .milliseconds(100))
    var executionCount = 0
    
    // Make rapid calls
    for _ in 1...10 {
      await throttler.throttle {
        executionCount += 1
      }
      try await Task.sleep(nanoseconds: 10_000_000) // 10ms between calls
    }
    
    // Should have executed only a few times (once per 100ms)
    XCTAssertLessThan(executionCount, 5)
    XCTAssertGreaterThan(executionCount, 0)
  }
  
  // MARK: - SerialExecutor Tests
  
  func testSerialExecutorMaintainsOrder() async throws {
    let executor = SerialExecutor()
    var results: [Int] = []
    let resultsLock = NSLock()
    
    // Enqueue tasks with delays
    for i in 1...5 {
      await executor.enqueue {
        try? await Task.sleep(nanoseconds: UInt64.random(in: 10_000_000...50_000_000))
        resultsLock.lock()
        results.append(i)
        resultsLock.unlock()
      }
    }
    
    await executor.waitForAll()
    
    // Results should be in order despite random delays
    XCTAssertEqual(results, [1, 2, 3, 4, 5])
  }
  
  // MARK: - OnceExecutor Tests
  
  func testOnceExecutorRunsOnlyOnce() async throws {
    let executor = OnceExecutor()
    var executionCount = 0
    
    // Try to execute multiple times
    for _ in 1...5 {
      await executor.executeOnce {
        executionCount += 1
      }
    }
    
    XCTAssertEqual(executionCount, 1)
  }
  
  // MARK: - SafeDictionary Tests
  
  func testSafeDictionaryConcurrentAccess() async throws {
    let dict = SafeDictionary<String, Int>()
    
    // Concurrent writes
    await withTaskGroup(of: Void.self) { group in
      for i in 0..<100 {
        group.addTask {
          await dict.set("key\(i)", value: i)
        }
      }
    }
    
    let count = await dict.count()
    XCTAssertEqual(count, 100)
    
    // Verify all values
    for i in 0..<100 {
      let value = await dict.get("key\(i)")
      XCTAssertEqual(value, i)
    }
  }
  
  // MARK: - BarrierExecutor Tests
  
  func testBarrierExecutorExclusiveAccess() async throws {
    let executor = BarrierExecutor(initialValue: 0)
    
    // Concurrent modifications
    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<100 {
        group.addTask {
          await executor.modify { value in
            value += 1
          }
        }
      }
    }
    
    let finalValue = await executor.read()
    XCTAssertEqual(finalValue, 100)
  }
}

