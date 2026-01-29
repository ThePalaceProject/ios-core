//
//  XCTestCase+Async.swift
//  PalaceTests
//
//  Extension on XCTestCase providing helpers for async/await testing
//  and Combine publisher observation.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import Combine
@testable import Palace

// MARK: - Async Testing Helpers

extension XCTestCase {

  // MARK: - Publisher Observation

  /// Waits for a @Published property to emit a value matching the predicate.
  /// - Parameters:
  ///   - publisher: The publisher to observe
  ///   - timeout: Maximum time to wait (default: 2 seconds)
  ///   - description: Description for the expectation
  ///   - predicate: Closure that returns true when the expected value is received
  /// - Returns: The value that matched the predicate
  /// - Throws: XCTestError if timeout occurs before predicate is satisfied
  @MainActor
  func awaitPublisher<P: Publisher>(
    _ publisher: P,
    timeout: TimeInterval = 2.0,
    description: String = "Publisher expectation",
    where predicate: @escaping (P.Output) -> Bool
  ) async throws -> P.Output where P.Failure == Never {
    var cancellable: AnyCancellable?
    var receivedValue: P.Output?

    return try await withCheckedThrowingContinuation { continuation in
      let expectation = self.expectation(description: description)

      cancellable = publisher
        .first(where: predicate)
        .sink { value in
          receivedValue = value
          expectation.fulfill()
        }

      // Use XCTest's wait mechanism
      wait(for: [expectation], timeout: timeout)

      if let value = receivedValue {
        continuation.resume(returning: value)
      } else {
        continuation.resume(throwing: XCTestError(.timeoutWhileWaiting))
      }

      cancellable?.cancel()
    }
  }

  /// Waits for a @Published property to change from its current value.
  /// - Parameters:
  ///   - keyPath: KeyPath to the @Published property
  ///   - object: The object containing the property
  ///   - timeout: Maximum time to wait
  /// - Returns: The new value after the change
  @MainActor
  func awaitPropertyChange<T: ObservableObject, Value: Equatable>(
    _ keyPath: KeyPath<T, Value>,
    on object: T,
    timeout: TimeInterval = 2.0
  ) async throws -> Value {
    let initialValue = object[keyPath: keyPath]
    var cancellable: AnyCancellable?
    var newValue: Value?

    return try await withCheckedThrowingContinuation { continuation in
      let expectation = self.expectation(description: "Property change")

      cancellable = object.objectWillChange.sink { _ in
        DispatchQueue.main.async {
          let currentValue = object[keyPath: keyPath]
          if currentValue != initialValue {
            newValue = currentValue
            expectation.fulfill()
          }
        }
      }

      wait(for: [expectation], timeout: timeout)

      if let value = newValue {
        continuation.resume(returning: value)
      } else {
        continuation.resume(throwing: XCTestError(.timeoutWhileWaiting))
      }

      cancellable?.cancel()
    }
  }

  // MARK: - Collecting Publisher Values

  /// Collects values from a publisher for a specified duration.
  /// - Parameters:
  ///   - publisher: The publisher to observe
  ///   - duration: How long to collect values
  /// - Returns: Array of all values emitted during the duration
  @MainActor
  func collectPublisherValues<P: Publisher>(
    _ publisher: P,
    for duration: TimeInterval
  ) async -> [P.Output] where P.Failure == Never {
    var values: [P.Output] = []
    var cancellable: AnyCancellable?

    return await withCheckedContinuation { continuation in
      cancellable = publisher.sink { value in
        values.append(value)
      }

      DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
        cancellable?.cancel()
        continuation.resume(returning: values)
      }
    }
  }

  // MARK: - Async Task Helpers

  /// Waits for an async operation to complete within a timeout.
  /// - Parameters:
  ///   - timeout: Maximum time to wait
  ///   - operation: The async operation to perform
  /// - Throws: XCTestError if timeout occurs
  func awaitWithTimeout<T>(
    timeout: TimeInterval = 5.0,
    operation: @escaping () async throws -> T
  ) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
      group.addTask {
        try await operation()
      }

      group.addTask {
        try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
        throw XCTestError(.timeoutWhileWaiting)
      }

      guard let result = try await group.next() else {
        throw XCTestError(.timeoutWhileWaiting)
      }

      group.cancelAll()
      return result
    }
  }

  // MARK: - Expectation Helpers for Published Properties

  /// Creates an expectation that waits for a @Published property to equal a specific value.
  /// - Parameters:
  ///   - publisher: The publisher to observe
  ///   - expectedValue: The value to wait for
  ///   - description: Description for the expectation
  /// - Returns: A tuple containing the expectation and a cancellable that must be retained
  @MainActor
  func expectation<P: Publisher>(
    for publisher: P,
    toEqual expectedValue: P.Output,
    description: String = "Publisher equals expected value"
  ) -> (expectation: XCTestExpectation, cancellable: AnyCancellable) where P.Output: Equatable, P.Failure == Never {
    let expectation = self.expectation(description: description)

    let cancellable = publisher
      .first(where: { $0 == expectedValue })
      .sink { _ in
        expectation.fulfill()
      }

    return (expectation, cancellable)
  }

  /// Creates an expectation that waits for a @Published property to become true.
  /// - Parameters:
  ///   - publisher: The Bool publisher to observe
  ///   - description: Description for the expectation
  /// - Returns: A tuple containing the expectation and a cancellable that must be retained
  @MainActor
  func expectation<P: Publisher>(
    for publisher: P,
    toBecome value: Bool,
    description: String = "Publisher becomes expected bool"
  ) -> (expectation: XCTestExpectation, cancellable: AnyCancellable) where P.Output == Bool, P.Failure == Never {
    let expectation = self.expectation(description: description)

    let cancellable = publisher
      .first(where: { $0 == value })
      .sink { _ in
        expectation.fulfill()
      }

    return (expectation, cancellable)
  }

  // MARK: - Combine Storage

  /// Helper to create a new cancellables set for each test
  func makeCancellables() -> Set<AnyCancellable> {
    Set<AnyCancellable>()
  }
}

// MARK: - Async MainActor Test Helpers

extension XCTestCase {

  /// Runs a test block on the MainActor with proper async handling.
  /// Use this when testing @MainActor-annotated code from a non-MainActor test.
  func runOnMainActor(_ block: @MainActor @escaping () async throws -> Void) async throws {
    try await MainActor.run {
      try await block()
    }
  }

  /// Asserts that an async operation throws an error of a specific type.
  /// - Parameters:
  ///   - expectedError: The type of error expected
  ///   - message: Message to display on failure
  ///   - operation: The async operation that should throw
  func assertThrowsAsync<T, E: Error>(
    _ expectedError: E.Type,
    message: String = "Expected error was not thrown",
    file: StaticString = #file,
    line: UInt = #line,
    operation: () async throws -> T
  ) async {
    do {
      _ = try await operation()
      XCTFail(message, file: file, line: line)
    } catch {
      XCTAssertTrue(error is E, "Expected \(E.self) but got \(type(of: error))", file: file, line: line)
    }
  }

  /// Asserts that an async operation does not throw.
  /// - Parameters:
  ///   - message: Message to display on failure
  ///   - operation: The async operation that should succeed
  /// - Returns: The result of the operation
  @discardableResult
  func assertNoThrowAsync<T>(
    message: String = "Unexpected error thrown",
    file: StaticString = #file,
    line: UInt = #line,
    operation: () async throws -> T
  ) async -> T? {
    do {
      return try await operation()
    } catch {
      XCTFail("\(message): \(error)", file: file, line: line)
      return nil
    }
  }
}

// MARK: - Test Error Types

/// Errors specific to async test utilities
enum AsyncTestError: Error, LocalizedError {
  case timeout(description: String)
  case unexpectedValue(description: String)
  case predicateNeverSatisfied

  var errorDescription: String? {
    switch self {
    case .timeout(let description):
      return "Timeout waiting for: \(description)"
    case .unexpectedValue(let description):
      return "Unexpected value: \(description)"
    case .predicateNeverSatisfied:
      return "Predicate was never satisfied"
    }
  }
}
