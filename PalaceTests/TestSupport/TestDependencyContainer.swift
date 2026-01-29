//
//  TestDependencyContainer.swift
//  PalaceTests
//
//  Centralized dependency injection container for testing.
//  Provides mock implementations of common dependencies to enable
//  isolated unit testing without singleton state leakage.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
import Combine
@testable import Palace

// MARK: - DependencyProviding Protocol

/// Protocol defining the common dependencies used throughout the app.
/// This allows swapping between production and test implementations.
protocol DependencyProviding: AnyObject {

  /// The book registry for managing book state and metadata
  var bookRegistry: TPPBookRegistryProvider { get }

  /// The network executor for making HTTP requests
  var networkExecutor: TPPRequestExecuting { get }

  /// The clock for getting the current time
  var clock: ClockProviding { get }

  /// The image cache for storing book cover images
  var imageCache: ImageCacheType { get }

  /// Resets all dependencies to their initial state
  func reset()
}

// MARK: - ProductionDependencyContainer

/// Production implementation that returns real singleton instances.
/// Use this in the main app target.
final class ProductionDependencyContainer: DependencyProviding {

  static let shared = ProductionDependencyContainer()

  private init() {}

  var bookRegistry: TPPBookRegistryProvider {
    TPPBookRegistry.shared
  }

  var networkExecutor: TPPRequestExecuting {
    TPPNetworkExecutor.shared
  }

  var clock: ClockProviding {
    SystemClock()
  }

  var imageCache: ImageCacheType {
    ImageCache.shared
  }

  func reset() {
    // Production container does not support reset
    // This is intentional - production state should be managed explicitly
  }
}

// MARK: - TestDependencyContainer

/// Test implementation with mutable mock properties.
/// Use this in unit tests to inject controlled dependencies.
@MainActor
final class TestDependencyContainer: DependencyProviding {

  // MARK: - Singleton for Test Access

  /// Shared instance for tests. Reset between tests using reset().
  nonisolated(unsafe) static let shared = TestDependencyContainer()

  // MARK: - Mutable Mock Properties

  /// Mock book registry - replace with custom mock as needed
  var mockBookRegistry: TPPBookRegistryMock

  /// Mock network executor - replace with custom mock as needed
  var mockNetworkExecutor: TPPRequestExecutorMock

  /// Mock clock - replace with MockClock for time-dependent testing
  var mockClock: MockClock

  /// Mock image cache
  var mockImageCache: MockImageCache

  // MARK: - DependencyProviding Conformance

  var bookRegistry: TPPBookRegistryProvider {
    mockBookRegistry
  }

  nonisolated var networkExecutor: TPPRequestExecuting {
    MainActor.assumeIsolated {
      mockNetworkExecutor
    }
  }

  var clock: ClockProviding {
    mockClock
  }

  var imageCache: ImageCacheType {
    mockImageCache
  }

  // MARK: - Initialization

  init() {
    self.mockBookRegistry = TPPBookRegistryMock()
    self.mockNetworkExecutor = TPPRequestExecutorMock()
    self.mockClock = MockClock()
    self.mockImageCache = MockImageCache()
  }

  // MARK: - Reset

  /// Resets all mock dependencies to fresh instances.
  /// Call this in setUp() or tearDown() to ensure test isolation.
  func reset() {
    mockBookRegistry = TPPBookRegistryMock()
    mockNetworkExecutor = TPPRequestExecutorMock()
    mockClock = MockClock()
    mockImageCache = MockImageCache()
    mockImageCache.resetHistory()

    // Reset any HTTP stubs
    HTTPStubURLProtocol.reset()
  }

  /// Resets only the clock to a fresh instance
  func resetClock() {
    mockClock = MockClock()
  }

  /// Resets only the book registry to a fresh instance
  func resetBookRegistry() {
    mockBookRegistry = TPPBookRegistryMock()
  }

  /// Resets only the network executor to a fresh instance
  func resetNetworkExecutor() {
    mockNetworkExecutor = TPPRequestExecutorMock()
  }
}

// MARK: - Test Helper Extensions

extension TestDependencyContainer {

  /// Convenience method to add a book to the mock registry
  func addBook(_ book: TPPBook, state: TPPBookState = .downloadSuccessful) {
    mockBookRegistry.addBook(book, state: state)
  }

  /// Convenience method to set the current time for time-dependent tests
  func setCurrentTime(_ date: Date) {
    mockClock.now = date
  }

  /// Convenience method to advance time by a given interval
  func advanceTime(by interval: TimeInterval) {
    mockClock.advance(by: interval)
  }

  /// Creates a URLSession configured with HTTPStubURLProtocol for network stubbing
  func createStubbedURLSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [HTTPStubURLProtocol.self]
    return URLSession(configuration: config)
  }
}
