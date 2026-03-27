//
//  MainActorHelpersTests.swift
//  PalaceTests
//
//  Tests for MainActorHelpers.swift concurrency utilities
//

import XCTest
@testable import Palace

final class MainActorHelpersTests: XCTestCase {

    // MARK: - runParallel Tests

    /// SRS: CONC-001 — Parallel execution preserves result ordering
    func testRunParallel_MultipleItems_ReturnsInOriginalOrder() async throws {
        let work: [@Sendable () async throws -> Int] = [
            { try await Task.sleep(nanoseconds: 50_000_000); return 1 },
            { return 2 },
            { try await Task.sleep(nanoseconds: 10_000_000); return 3 }
        ]

        let results = try await runParallel(work)
        XCTAssertEqual(results, [1, 2, 3], "Results should be in original submission order")
    }

    func testRunParallel_EmptyArray_ReturnsEmptyArray() async throws {
        let work: [@Sendable () async throws -> Int] = []
        let results = try await runParallel(work)
        XCTAssertTrue(results.isEmpty)
    }

    func testRunParallel_SingleItem_ReturnsSingleResult() async throws {
        let work: [@Sendable () async throws -> String] = [
            { "hello" }
        ]
        let results = try await runParallel(work)
        XCTAssertEqual(results, ["hello"])
    }

    func testRunParallel_ThrowingTask_PropagatesError() async {
        struct TestError: Error {}
        let work: [@Sendable () async throws -> Int] = [
            { 1 },
            { throw TestError() },
            { 3 }
        ]

        do {
            _ = try await runParallel(work)
            XCTFail("Should have thrown an error")
        } catch {
            XCTAssertTrue(error is TestError)
        }
    }

    // MARK: - runParallelFireAndForget Tests

    func testRunParallelFireAndForget_ExecutesAllTasks() async {
        let counter = Counter()

        let work: [@Sendable () async -> Void] = [
            { await counter.increment() },
            { await counter.increment() },
            { await counter.increment() }
        ]

        await runParallelFireAndForget(work)
        let count = await counter.value
        XCTAssertEqual(count, 3, "All three tasks should have executed")
    }

    func testRunParallelFireAndForget_EmptyArray_CompletesImmediately() async {
        let work: [@Sendable () async -> Void] = []
        await runParallelFireAndForget(work)
        // If we reach here, the empty array completed successfully
    }

    // MARK: - Debouncer Tests

    func testDebouncer_OnlExecutesLastCall() async throws {
        let counter = Counter()
        let debouncer = Debouncer(duration: .milliseconds(50))

        for i in 1...5 {
            await debouncer.debounce {
                await counter.set(i)
            }
        }

        // Wait for debounce duration to pass
        try await Task.sleep(nanoseconds: 150_000_000)
        let finalValue = await counter.value
        XCTAssertEqual(finalValue, 5, "Only the last debounced call should execute")
    }

    func testDebouncer_Cancel_PreventsExecution() async throws {
        let counter = Counter()
        let debouncer = Debouncer(duration: .milliseconds(50))

        await debouncer.debounce {
            await counter.increment()
        }
        await debouncer.cancel()

        try await Task.sleep(nanoseconds: 100_000_000)
        let count = await counter.value
        XCTAssertEqual(count, 0, "Cancelled debounce should not execute")
    }

    // MARK: - Throttler Tests

    func testThrottler_FirstCall_ExecutesImmediately() async {
        let counter = Counter()
        let throttler = Throttler(interval: .seconds(1))

        await throttler.throttle {
            await counter.increment()
        }

        let count = await counter.value
        XCTAssertEqual(count, 1, "First throttled call should execute immediately")
    }

    func testThrottler_RapidCalls_SkipsSubsequent() async {
        let counter = Counter()
        let throttler = Throttler(interval: .milliseconds(200))

        // First call should execute
        await throttler.throttle { await counter.increment() }
        // Second call within interval should be skipped
        await throttler.throttle { await counter.increment() }
        // Third call within interval should be skipped
        await throttler.throttle { await counter.increment() }

        let count = await counter.value
        XCTAssertEqual(count, 1, "Only the first call should execute within the throttle interval")
    }

    func testThrottler_AfterInterval_ExecutesAgain() async throws {
        let counter = Counter()
        let throttler = Throttler(interval: .milliseconds(50))

        await throttler.throttle { await counter.increment() }
        try await Task.sleep(nanoseconds: 100_000_000)
        await throttler.throttle { await counter.increment() }

        let count = await counter.value
        XCTAssertEqual(count, 2, "Should execute again after interval passes")
    }

    // MARK: - SerialExecutor Tests

    func testSerialExecutor_ExecutesInOrder() async {
        let results = OrderedResults()
        let executor = SerialExecutor()

        await executor.enqueue { await results.append(1) }
        await executor.enqueue { await results.append(2) }
        await executor.enqueue { await results.append(3) }

        await executor.waitForAll()

        let values = await results.values
        XCTAssertEqual(values, [1, 2, 3], "Tasks should execute in serial order")
    }

    func testSerialExecutor_WaitForAll_WaitsForCompletion() async {
        let counter = Counter()
        let executor = SerialExecutor()

        await executor.enqueue {
            try? await Task.sleep(nanoseconds: 50_000_000)
            await counter.increment()
        }

        await executor.waitForAll()
        let count = await counter.value
        XCTAssertEqual(count, 1)
    }

    // MARK: - OnceExecutor Tests

    func testOnceExecutor_ExecutesOnlyOnce() async {
        let counter = Counter()
        let executor = OnceExecutor()

        await executor.executeOnce { await counter.increment() }
        await executor.executeOnce { await counter.increment() }
        await executor.executeOnce { await counter.increment() }

        let count = await counter.value
        XCTAssertEqual(count, 1, "Should only execute once despite multiple calls")
    }

    func testOnceExecutor_Reset_AllowsReExecution() async {
        let counter = Counter()
        let executor = OnceExecutor()

        await executor.executeOnce { await counter.increment() }
        await executor.reset()
        await executor.executeOnce { await counter.increment() }

        let count = await counter.value
        XCTAssertEqual(count, 2, "Should execute again after reset")
    }

    // MARK: - BarrierExecutor Tests

    func testBarrierExecutor_ReadInitialValue() async {
        let barrier = BarrierExecutor(initialValue: 42)
        let value = await barrier.read()
        XCTAssertEqual(value, 42)
    }

    func testBarrierExecutor_Write_UpdatesValue() async {
        let barrier = BarrierExecutor(initialValue: 0)
        await barrier.write(99)
        let value = await barrier.read()
        XCTAssertEqual(value, 99)
    }

    func testBarrierExecutor_Modify_TransformsValue() async {
        let barrier = BarrierExecutor(initialValue: [1, 2, 3])
        await barrier.modify { $0.append(4) }
        let value = await barrier.read()
        XCTAssertEqual(value, [1, 2, 3, 4])
    }

    // MARK: - withAsyncCallback Tests

    func testWithAsyncCallback_ConvertsCallbackToAsync() async {
        let result = await withAsyncCallback { (completion: @escaping (String) -> Void) in
            DispatchQueue.global().async {
                completion("done")
            }
        }
        XCTAssertEqual(result, "done")
    }

    // MARK: - withAsyncThrowingCallback Tests

    func testWithAsyncThrowingCallback_Success_ReturnsValue() async throws {
        let result = try await withAsyncThrowingCallback { (completion: @escaping (Result<Int, Error>) -> Void) in
            completion(.success(42))
        }
        XCTAssertEqual(result, 42)
    }

    func testWithAsyncThrowingCallback_Failure_ThrowsError() async {
        struct TestError: Error {}

        do {
            _ = try await withAsyncThrowingCallback { (completion: @escaping (Result<Int, Error>) -> Void) in
                completion(.failure(TestError()))
            }
            XCTFail("Should have thrown")
        } catch {
            XCTAssertTrue(error is TestError)
        }
    }

    // MARK: - Task.sleep(seconds:) Tests

    func testTaskSleepSeconds_CompletesAfterDuration() async throws {
        let start = ContinuousClock.now
        try await Task.sleep(seconds: 0.05)
        let elapsed = ContinuousClock.now - start

        XCTAssertGreaterThan(elapsed, .milliseconds(40), "Should sleep for at least the requested duration")
    }
}

// MARK: - Test Helpers

private actor Counter {
    private(set) var value = 0

    func increment() { value += 1 }
    func set(_ newValue: Int) { value = newValue }
}

private actor OrderedResults {
    private(set) var values: [Int] = []

    func append(_ value: Int) { values.append(value) }
}
