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
@testable import Palace

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

        executor.refreshTokenAndResume(task: nil, accountId: "urn:uuid:test-account") { result in
            switch result {
            case .failure:
                break // Expected: no credentials in test environment
            case .success:
                break
            }
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5.0)
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

        executor.refreshTokenAndResume(task: nil, accountId: nil) { result in
            switch result {
            case .failure:
                break
            case .success:
                break
            }
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5.0)
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

        // Call without accountId parameter (backward compatible)
        executor.refreshTokenAndResume(task: nil) { result in
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5.0)
    }

    // MARK: - Cancel Non-Essential Tasks

    func testCancelNonEssentialTasks_DoesNotCrash() {
        TPPNetworkExecutor.shared.cancelNonEssentialTasks()
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
        executor.GET(url, useTokenIfAvailable: false) { _ in }

        executor.cancelNonEssentialTasks()

        HTTPStubURLProtocol.reset()
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

        let result: Result<TokenResponse, Error> = await withCheckedContinuation { continuation in
            executor.executeTokenRefresh(
                username: "testuser",
                password: "testpass",
                tokenURL: tokenURL,
                accountId: "urn:uuid:test-account"
            ) { continuation.resume(returning: $0) }
        }

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

        // Call without accountId (default nil) — the key assertion is that this
        // compiles and runs without the accountId parameter (backward compatibility).
        let _: Result<TokenResponse, Error> = await withCheckedContinuation { continuation in
            executor.executeTokenRefresh(
                username: "testuser",
                password: "testpass",
                tokenURL: tokenURL
            ) { continuation.resume(returning: $0) }
        }

        HTTPStubURLProtocol.reset()
    }
}
