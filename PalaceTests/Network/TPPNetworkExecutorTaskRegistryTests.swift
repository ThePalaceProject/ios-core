//
//  TPPNetworkExecutorTaskRegistryTests.swift
//  PalaceTests
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import PalaceNetwork
@testable import Palace

/// The transport's active-tasks store must release a data task once its
/// completion is delivered. Holding it until the next account switch retains
/// every request and response for the whole session. Each test waits on the
/// completions themselves, which the executor delivers after releasing the task.
@MainActor
final class TPPNetworkExecutorTaskRegistryTests: XCTestCase {

    private let apiURL = URL(string: "https://api.example.com/feed")!
    private let audiobookURL = URL(string: "https://api.example.com/audiobook/manifest.json")!

    override func setUp() async throws {
        try await super.setUp()
        ScriptedURLProtocol.reset()
    }

    override func tearDown() async throws {
        ScriptedURLProtocol.release(apiURL, status: 503, body: nil)
        ScriptedURLProtocol.release(audiobookURL, status: 503, body: nil)
        ScriptedURLProtocol.reset()
        try await super.tearDown()
    }

    /// Successful requests, awaited one after another, leave nothing held.
    func testExecute_afterSuccessfulRequestsComplete_holdsNoTasks() async {
        let fixture = URLSessionNetworkClientFixture(tokenExpiresIn: 3600)
        ScriptedURLProtocol.route(apiURL, .respond(status: 200, headers: nil, body: Data("ok".utf8)))

        for _ in 0..<5 {
            let result = await fixture.executor.execute(URLRequest(url: apiURL),
                                                        enableTokenRefresh: true, accountId: nil)
            guard case .success = result else { return XCTFail("expected success, got \(result)") }
        }

        XCTAssertEqual(fixture.executor.registeredTaskCount, 5, "every request registers its task")
        XCTAssertEqual(fixture.executor.heldTaskCount, 0, "a completed task must be released")
    }

    /// Error responses go down the responder's failure branch; they must be
    /// released as well.
    func testExecute_afterErrorResponsesComplete_holdsNoTasks() async {
        let fixture = URLSessionNetworkClientFixture(tokenExpiresIn: 3600)
        ScriptedURLProtocol.route(apiURL, .respond(status: 500, headers: nil, body: nil))

        for _ in 0..<3 {
            let result = await fixture.executor.execute(URLRequest(url: apiURL),
                                                        enableTokenRefresh: true, accountId: nil)
            guard case .failure = result else { return XCTFail("expected failure, got \(result)") }
        }

        XCTAssertEqual(fixture.executor.registeredTaskCount, 3)
        XCTAssertEqual(fixture.executor.heldTaskCount, 0)
    }

    /// Concurrent requests complete on URLSession's delegate queue while
    /// others are still being added, so additions and removals interleave.
    func testExecute_concurrentRequests_holdNoTasksOnceAllComplete() async {
        let fixture = URLSessionNetworkClientFixture(tokenExpiresIn: 3600)
        ScriptedURLProtocol.route(apiURL, .respond(status: 200, headers: nil, body: Data("ok".utf8)))
        let executor = fixture.executor
        let url = apiURL

        let successes = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    if case .success = await executor.execute(URLRequest(url: url),
                                                              enableTokenRefresh: true, accountId: nil) {
                        return true
                    }
                    return false
                }
            }
            var count = 0
            for await succeeded in group where succeeded { count += 1 }
            return count
        }

        XCTAssertEqual(successes, 20)
        XCTAssertEqual(executor.registeredTaskCount, 20)
        XCTAssertEqual(executor.heldTaskCount, 0)
    }

    /// A request still on the wire stays held, so an account switch can still
    /// reach it; it is released when its response arrives.
    func testExecuteRequest_inFlight_isHeldUntilItsCompletion() async {
        let fixture = URLSessionNetworkClientFixture(tokenExpiresIn: 3600)
        ScriptedURLProtocol.route(apiURL, .hold)
        let started = expectation(description: "request reached the server")
        ScriptedURLProtocol.expectStart(of: apiURL, started)
        let completed = expectation(description: "completion delivered")
        let heldAtCompletion = LockIsolated<Int?>(nil)
        let executor = fixture.executor

        executor.executeRequest(URLRequest(url: apiURL), enableTokenRefresh: false, accountId: nil) { _ in
            heldAtCompletion.value = executor.heldTaskCount
            completed.fulfill()
        }
        await fulfillment(of: [started], timeout: 5) // STARVE-001-OK: fulfilled by the URLProtocol when the request starts
        XCTAssertEqual(executor.heldTaskCount, 1, "an in-flight task must stay reachable by cancelNonEssential")

        ScriptedURLProtocol.release(apiURL, status: 200, body: Data("ok".utf8))
        await fulfillment(of: [completed], timeout: 5) // STARVE-001-OK: fulfilled by the responder's completion

        XCTAssertEqual(heldAtCompletion.value, 0, "the task is released before its completion runs")
        XCTAssertEqual(executor.heldTaskCount, 0)
    }

    /// An account switch cancels the non-audiobook request and keeps the
    /// audiobook one; the cancelled task's completion must not disturb the
    /// survivor, which is released when it finishes.
    func testCancelNonEssential_cancelsOtherRequestsAndReleasesAudiobookOneOnCompletion() async {
        let fixture = URLSessionNetworkClientFixture(tokenExpiresIn: 3600)
        ScriptedURLProtocol.route(apiURL, .hold)
        ScriptedURLProtocol.route(audiobookURL, .hold)
        let apiStarted = expectation(description: "API request started")
        let audioStarted = expectation(description: "audiobook request started")
        ScriptedURLProtocol.expectStart(of: apiURL, apiStarted)
        ScriptedURLProtocol.expectStart(of: audiobookURL, audioStarted)
        let apiCompleted = expectation(description: "API completion")
        let audioCompleted = expectation(description: "audiobook completion")
        let apiErrorCode = LockIsolated<Int?>(nil)
        let audioSucceeded = LockIsolated(false)
        let executor = fixture.executor

        executor.executeRequest(URLRequest(url: apiURL), enableTokenRefresh: false, accountId: nil) { result in
            if case let .failure(error, _) = result { apiErrorCode.value = (error as NSError).code }
            apiCompleted.fulfill()
        }
        executor.executeRequest(URLRequest(url: audiobookURL), enableTokenRefresh: false, accountId: nil) { result in
            if case .success = result { audioSucceeded.value = true }
            audioCompleted.fulfill()
        }
        await fulfillment(of: [apiStarted, audioStarted], timeout: 5) // STARVE-001-OK: fulfilled by the URLProtocol when each request starts

        executor.cancelNonEssentialTasks()
        await fulfillment(of: [apiCompleted], timeout: 5) // STARVE-001-OK: fulfilled by the responder's cancelled completion

        XCTAssertEqual(apiErrorCode.value, NSURLErrorCancelled)
        XCTAssertEqual(executor.heldTaskCount, 1, "the audiobook request must survive the account switch")

        ScriptedURLProtocol.release(audiobookURL, status: 200, body: Data("ok".utf8))
        await fulfillment(of: [audioCompleted], timeout: 5) // STARVE-001-OK: fulfilled by the responder's completion

        XCTAssertTrue(audioSucceeded.value)
        XCTAssertEqual(executor.heldTaskCount, 0)
    }
}
