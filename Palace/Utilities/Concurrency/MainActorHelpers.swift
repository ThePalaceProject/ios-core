//
//  MainActorHelpers.swift
//  Palace
//
//  Copyright © 2025 The Palace Project. All rights reserved.
//

import Foundation

/// Modern alternatives to legacy DispatchQueue patterns
/// Use these helpers when migrating from GCD to Swift concurrency

// MARK: - Main Thread Execution

/// Runs work on the main actor
/// Replaces: DispatchQueue.main.async { }
@MainActor
@inlinable
func runOnMain(_ work: @escaping @MainActor () -> Void) {
  work()
}

/// Runs work on the main actor asynchronously from a non-isolated context
/// Replaces: DispatchQueue.main.async { }
@inlinable
func runOnMainAsync(_ work: @escaping @MainActor () -> Void) {
  Task { @MainActor in
    work()
  }
}

/// Runs work on the main actor with a delay
/// Replaces: DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { }
@inlinable
func runOnMainAfter(seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) {
  Task { @MainActor in
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    work()
  }
}

// MARK: - Background Execution

/// Runs work on a background task
/// Replaces: DispatchQueue.global().async { }
@inlinable
func runInBackground(priority: TaskPriority = .utility, _ work: @escaping @Sendable () async -> Void) {
  Task.detached(priority: priority) {
    await work()
  }
}

/// Runs work on a background task and returns the result on main actor
/// Replaces: DispatchQueue.global().async { let result = ...; DispatchQueue.main.async { use(result) } }
@inlinable
func runInBackgroundThenMain<T>(
  priority: TaskPriority = .utility,
  backgroundWork: @escaping @Sendable () async -> T,
  mainWork: @escaping @MainActor (T) -> Void
) {
  Task.detached(priority: priority) {
    let result = await backgroundWork()
    await MainActor.run {
      mainWork(result)
    }
  }
}

// MARK: - Task Groups for Parallel Work

/// Runs multiple tasks in parallel and collects results
/// Replaces: DispatchQueue.concurrentPerform or multiple async calls
@inlinable
func runParallel<T>(
  _ work: [@Sendable () async throws -> T]
) async throws -> [T] {
  try await withThrowingTaskGroup(of: (Int, T).self) { group in
    for (index, task) in work.enumerated() {
      group.addTask {
        return (index, try await task())
      }
    }
    
    var results: [(Int, T)] = []
    for try await result in group {
      results.append(result)
    }
    
    // Sort by original index to maintain order
    results.sort { $0.0 < $1.0 }
    return results.map { $0.1 }
  }
}

/// Runs multiple tasks in parallel without collecting results
/// Replaces: Multiple DispatchQueue.async calls for fire-and-forget operations
@inlinable
func runParallelFireAndForget(_ work: [@Sendable () async -> Void]) async {
  await withTaskGroup(of: Void.self) { group in
    for task in work {
      group.addTask {
        await task()
      }
    }
  }
}

// MARK: - Debouncing

/// Actor for debouncing rapid calls
actor Debouncer {
  private var task: Task<Void, Never>?
  private let duration: Duration
  
  init(duration: Duration) {
    self.duration = duration
  }
  
  /// Debounces the given work - only the last call within the duration will execute
  func debounce(_ work: @escaping @Sendable () async -> Void) {
    task?.cancel()
    task = Task {
      try? await Task.sleep(for: duration)
      if !Task.isCancelled {
        await work()
      }
    }
  }
  
  /// Cancels any pending debounced work
  func cancel() {
    task?.cancel()
    task = nil
  }
}

// MARK: - Throttling

/// Actor for throttling rapid calls
actor Throttler {
  private var lastExecutionTime: ContinuousClock.Instant?
  private let interval: Duration
  
  init(interval: Duration) {
    self.interval = interval
  }
  
  /// Throttles the given work - executes immediately if enough time has passed since last execution
  func throttle(_ work: @escaping @Sendable () async -> Void) async {
    let now = ContinuousClock.now
    
    if let lastTime = lastExecutionTime {
      let elapsed = now - lastTime
      if elapsed < interval {
        return // Skip execution
      }
    }
    
    lastExecutionTime = now
    await work()
  }
}

// MARK: - Serial Execution Queue

/// Actor that ensures serial execution of tasks
/// Replaces: Serial DispatchQueue
actor SerialExecutor {
  private var currentTask: Task<Void, Never>?
  
  /// Enqueues work to be executed serially
  func enqueue(_ work: @escaping @Sendable () async -> Void) {
    let previousTask = currentTask
    currentTask = Task {
      await previousTask?.value
      await work()
    }
  }
  
  /// Waits for all enqueued work to complete
  func waitForAll() async {
    await currentTask?.value
  }
  
  /// Cancels all pending work
  func cancelAll() {
    currentTask?.cancel()
    currentTask = nil
  }
}

// MARK: - Once Execution

/// Ensures a block of code runs only once
/// Replaces: dispatch_once
actor OnceExecutor {
  private var hasExecuted = false
  
  /// Executes the given work only once, subsequent calls are ignored
  func executeOnce(_ work: @Sendable () async -> Void) async {
    guard !hasExecuted else { return }
    hasExecuted = true
    await work()
  }
  
  /// Resets the executor to allow execution again
  func reset() {
    hasExecuted = false
  }
}

// MARK: - Barrier Execution

/// Actor for barrier-style synchronized access
/// Replaces: DispatchQueue with barrier flags
actor BarrierExecutor<Value> {
  private var value: Value
  
  init(initialValue: Value) {
    self.value = initialValue
  }
  
  /// Reads the current value
  func read() -> Value {
    return value
  }
  
  /// Updates the value (barrier-style - exclusive access)
  func write(_ newValue: Value) {
    self.value = newValue
  }
  
  /// Updates the value based on current value
  func modify(_ transform: (inout Value) -> Void) {
    transform(&value)
  }
}

// MARK: - Async Completion Handler Adapters

/// Converts a callback-style function to async/await
/// - Parameter work: Function that takes a completion handler
/// - Returns: The result from the completion handler
@inlinable
func withAsyncCallback<T>(
  _ work: (@escaping (T) -> Void) -> Void
) async -> T {
  await withCheckedContinuation { continuation in
    work { result in
      continuation.resume(returning: result)
    }
  }
}

/// Converts a callback-style function with Result to async/await
/// - Parameter work: Function that takes a completion handler with Result
/// - Returns: The unwrapped result
/// - Throws: The error from the Result.failure
@inlinable
func withAsyncThrowingCallback<T>(
  _ work: (@escaping (Result<T, Error>) -> Void) -> Void
) async throws -> T {
  try await withCheckedThrowingContinuation { continuation in
    work { result in
      continuation.resume(with: result)
    }
  }
}

// MARK: - Migration Helpers

extension Task where Success == Never, Failure == Never {
  /// Sleeps for the specified number of seconds
  /// More convenient than nanoseconds conversion
  static func sleep(seconds: TimeInterval) async throws {
    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
  }
}

