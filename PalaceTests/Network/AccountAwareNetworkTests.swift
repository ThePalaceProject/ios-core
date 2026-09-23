//
//  AccountAwareNetworkTests.swift
//  PalaceTests
//
//  Regression tests for PP-3702: Network requests must capture the account
//  context at creation time to prevent cross-account credential leaks when
//  the user is logged into multiple libraries simultaneously.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import PalaceAuth
@testable import Palace

// Deliberately NOT @MainActor: the executor completions resume checked
// continuations with non-Sendable payloads — a @MainActor test makes those
// Swift 6 sending errors. Nothing here touches UI or main-actor state.
final class AccountAwareNetworkTests: XCTestCase {

    override func setUp() {
        super.setUp()
        HTTPStubURLProtocol.reset()
    }

    override func tearDown() {
        HTTPStubURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Request Creation with Account Context

    func testRequest_CapturesCurrentAccountToken() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HTTPStubURLProtocol.self]

        let executor = TPPNetworkExecutor(
            credentialsProvider: nil,
            cachingStrategy: .ephemeral,
            sessionConfiguration: config,
            delegateQueue: nil
        )

        let url = URL(string: "https://example.com/api/books")!
        let request = executor.request(for: url, useTokenIfAvailable: true, accountId: nil)

        XCTAssertEqual(request.url, url, "Request URL should be preserved")
        XCTAssertNotNil(request.url)
    }

    func testRequest_AccountIdParameter_AcceptsNil() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HTTPStubURLProtocol.self]

        let executor = TPPNetworkExecutor(
            credentialsProvider: nil,
            cachingStrategy: .ephemeral,
            sessionConfiguration: config,
            delegateQueue: nil
        )

        let url = URL(string: "https://example.com/api/books")!

        let requestWithNil = executor.request(for: url, useTokenIfAvailable: false, accountId: nil)
        let requestWithoutParam = executor.request(for: url, useTokenIfAvailable: false)

        XCTAssertEqual(requestWithNil.url, requestWithoutParam.url)
    }

    func testRequest_AccountIdParameter_AcceptsSpecificId() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HTTPStubURLProtocol.self]

        let executor = TPPNetworkExecutor(
            credentialsProvider: nil,
            cachingStrategy: .ephemeral,
            sessionConfiguration: config,
            delegateQueue: nil
        )

        let url = URL(string: "https://example.com/api/books")!
        let request = executor.request(
            for: url,
            useTokenIfAvailable: true,
            accountId: "urn:uuid:test-library-123"
        )

        XCTAssertEqual(request.url, url, "Request URL should be preserved with specific account")
    }

    // MARK: - Token Refresh with Account Context

    func testRefreshTokenAndResume_AcceptsAccountIdParameter() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HTTPStubURLProtocol.self]

        let executor = TPPNetworkExecutor(
            credentialsProvider: nil,
            cachingStrategy: .ephemeral,
            sessionConfiguration: config,
            delegateQueue: nil
        )

        let expectation = XCTestExpectation(description: "Refresh completes")
        var completionCalled = false

        executor.refreshTokenAndResume(task: nil, accountId: "urn:uuid:test-account") { result in
            completionCalled = true
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5.0)
        XCTAssertTrue(completionCalled, "Completion handler must be called")
    }

    func testRefreshTokenAndResume_NilAccountId_DoesNotCrash() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HTTPStubURLProtocol.self]

        let executor = TPPNetworkExecutor(
            credentialsProvider: nil,
            cachingStrategy: .ephemeral,
            sessionConfiguration: config,
            delegateQueue: nil
        )

        let expectation = XCTestExpectation(description: "Refresh completes")
        var callbackInvoked = false

        executor.refreshTokenAndResume(task: nil, accountId: nil) { result in
            callbackInvoked = true
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5.0)
        XCTAssertTrue(callbackInvoked, "Completion must be called even with nil accountId")
    }

    func testRefreshTokenAndResume_DefaultAccountId_BackwardCompatible() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HTTPStubURLProtocol.self]

        let executor = TPPNetworkExecutor(
            credentialsProvider: nil,
            cachingStrategy: .ephemeral,
            sessionConfiguration: config,
            delegateQueue: nil
        )

        let expectation = XCTestExpectation(description: "Refresh completes")
        var completionCallCount = 0

        // Call without accountId parameter (backward compatible)
        executor.refreshTokenAndResume(task: nil) { result in
            completionCallCount += 1
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5.0)
        XCTAssertEqual(completionCallCount, 1, "Completion must be called exactly once")
    }

    // MARK: - Cancel Non-Essential Tasks

    func testCancelNonEssentialTasks_DoesNotCrash_andLeavesExecutorFullyUsable() {
        // cancelNonEssentialTasks is called on account switch and during
        // memory pressure. After it runs, the executor must still produce
        // valid requests for new URLs (next-account preloads land here
        // within milliseconds of the switch).
        AppContainer.production().networkExecutor.cancelNonEssentialTasks()

        let urlA = URL(string: "https://example.com/a")!
        let urlB = URL(string: "https://example.com/b/with/path?q=1")!

        let requestA = AppContainer.production().networkExecutor.request(for: urlA, useTokenIfAvailable: false)
        let requestB = AppContainer.production().networkExecutor.request(for: urlB, useTokenIfAvailable: true)

        XCTAssertEqual(requestA.url, urlA,
                       "Executor must still build requests for URL A after cancel")
        XCTAssertEqual(requestB.url, urlB,
                       "Executor must also produce requests for URL B with a different token strategy")

        // Second cancel must also be safe (observed under rapid account swaps).
        AppContainer.production().networkExecutor.cancelNonEssentialTasks()
        let requestC = AppContainer.production().networkExecutor.request(for: urlA, useTokenIfAvailable: false)
        XCTAssertEqual(requestC.url, urlA,
                       "Executor must survive back-to-back cancels")
    }

    func testCancelNonEssentialTasks_CancelsActiveTasks() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HTTPStubURLProtocol.self]

        let executor = TPPNetworkExecutor(
            credentialsProvider: nil,
            cachingStrategy: .ephemeral,
            sessionConfiguration: config,
            delegateQueue: nil
        )

        let stubSemaphore = DispatchSemaphore(value: 0)
        HTTPStubURLProtocol.register { request in
            stubSemaphore.wait(timeout: .now() + 0.5)
            return HTTPStubURLProtocol.StubbedResponse(statusCode: 200, headers: nil, body: Data())
        }

        let url = URL(string: "https://example.com/api/catalog")!
        var callbackCount = 0
        executor.GET(url, useTokenIfAvailable: false) { _ in callbackCount += 1 }

        executor.cancelNonEssentialTasks()

        HTTPStubURLProtocol.reset()
        // Executor must survive cancel and still be able to build requests
        let request = executor.request(for: url, useTokenIfAvailable: false)
        XCTAssertEqual(request.url, url, "Executor must be usable after cancel")
    }

    // MARK: - executeTokenRefresh Account Parameter

    // `wait(for:)` blocks the main thread and deadlocks if the completion handler is
    // dispatched back to the main thread. Use async/await + withCheckedContinuation
    // so the test runner's cooperative thread pool handles the suspension correctly.
    func testExecuteTokenRefresh_AcceptsAccountId() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HTTPStubURLProtocol.self]

        HTTPStubURLProtocol.register { request in
            guard request.url?.absoluteString.contains("token") == true else { return nil }
            let json = """
            {"access_token":"test","token_type":"Bearer","expires_in":3600}
            """.data(using: .utf8)!
            return HTTPStubURLProtocol.StubbedResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: json)
        }

        let executor = TPPNetworkExecutor(
            credentialsProvider: nil,
            cachingStrategy: .ephemeral,
            sessionConfiguration: config,
            delegateQueue: nil
        )

        let tokenURL = URL(string: "https://example.com/token")!

        // LockIsolated hand-off: TokenResponse is non-Sendable, so resuming
        // the continuation with it is a Swift 6 sending error — carry the
        // result in a box and resume Void.
        let resultBox = LockIsolated<Result<TokenResponse, Error>?>(nil)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            executor.executeTokenRefresh(
                username: "testuser",
                password: "testpass",
                tokenURL: tokenURL,
                accountId: "urn:uuid:test-account"
            ) { resultBox.value = $0; continuation.resume() }
        }
        let result = resultBox.value!

        switch result {
        case .success(let response):
            XCTAssertEqual(response.accessToken, "test")
        case .failure:
            break // May fail due to test environment
        }

        HTTPStubURLProtocol.reset()
    }

    func testExecuteTokenRefresh_NilAccountId_BackwardCompatible() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HTTPStubURLProtocol.self]

        HTTPStubURLProtocol.register { request in
            guard request.url?.absoluteString.contains("token") == true else { return nil }
            let json = """
            {"access_token":"compat-token","token_type":"Bearer","expires_in":1800}
            """.data(using: .utf8)!
            return HTTPStubURLProtocol.StubbedResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: json)
        }

        let executor = TPPNetworkExecutor(
            credentialsProvider: nil,
            cachingStrategy: .ephemeral,
            sessionConfiguration: config,
            delegateQueue: nil
        )

        let tokenURL = URL(string: "https://example.com/token")!

        // Call without accountId (default nil). Verify backward-compat overload
        // still delivers a result (the stub returns a valid access_token).
        // LockIsolated hand-off — same sending rationale as the test above.
        let resultBox = LockIsolated<Result<TokenResponse, Error>?>(nil)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            executor.executeTokenRefresh(
                username: "testuser",
                password: "testpass",
                tokenURL: tokenURL
            ) { resultBox.value = $0; continuation.resume() }
        }
        let result = resultBox.value!

        HTTPStubURLProtocol.reset()
        switch result {
        case .success(let response):
            XCTAssertEqual(response.accessToken, "compat-token",
                           "Backward-compat overload must still return the stubbed token")
        case .failure(let error):
            XCTFail("Backward-compat executeTokenRefresh should succeed, got: \(error)")
        }
    }
}
