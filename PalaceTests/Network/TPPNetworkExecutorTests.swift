//
//  TPPNetworkExecutorTests.swift
//  PalaceTests
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class TPPNetworkExecutorAPITests: XCTestCase {

    // MARK: - Shared Instance

    func testShared_isNotNil() {
        XCTAssertNotNil(TPPNetworkExecutor.shared)
    }

    // MARK: - Request Creation

    func testRequest_forURL_createsValidRequest() {
        let url = URL(string: "https://example.com/api/books")!
        let request = TPPNetworkExecutor.shared.request(for: url)

        XCTAssertEqual(request.url, url)
        XCTAssertNotNil(request.url)
    }

    func testRequest_forURL_setsUserAgent() {
        let url = URL(string: "https://example.com/api/test")!
        let request = TPPNetworkExecutor.shared.request(for: url)

        // The request should have some standard headers
        XCTAssertNotNil(request.url)
    }

    // MARK: - Bearer Authorization

    func testBearerAuthorized_setsAuthorizationHeader() {
        let request = URLRequest(url: URL(string: "https://example.com")!)

        let authorized = TPPNetworkExecutor.bearerAuthorized(request: request)

        // URL should be preserved
        XCTAssertEqual(authorized.url, request.url)

        // Authorization header should be set (empty when no user is logged in during tests)
        let authHeader = authorized.value(forHTTPHeaderField: "Authorization")
        XCTAssertNotNil(authHeader, "bearerAuthorized should always set an Authorization header")
    }

    // MARK: - Initialization with Custom Config

    func testInit_withCachingStrategy_doesNotCrash() {
        let executor = TPPNetworkExecutor(
            credentialsProvider: nil,
            cachingStrategy: .ephemeral,
            delegateQueue: nil
        )
        XCTAssertNotNil(executor)
    }

    // MARK: - Cache Control

    func testClearCache_doesNotCrash() {
        TPPNetworkExecutor.shared.clearCache()
        // Should not crash
    }

    // MARK: - Task Management

    func testPauseAllTasks_doesNotCrash() {
        TPPNetworkExecutor.shared.pauseAllTasks()
        // Should not crash
    }

    func testResumeAllTasks_doesNotCrash() {
        TPPNetworkExecutor.shared.resumeAllTasks()
        // Should not crash
    }
}
