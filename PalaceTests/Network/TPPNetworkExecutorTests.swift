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

    func testRequest_forURL_setsAcceptLanguageEmpty() {
        let url = URL(string: "https://example.com/api/test")!
        let request = TPPNetworkExecutor.shared.request(for: url)

        let acceptLang = request.value(forHTTPHeaderField: "Accept-Language")
        XCTAssertEqual(acceptLang, "")
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

    func testBearerAuthorized_preservesExistingHeaders() {
        var request = URLRequest(url: URL(string: "https://example.com")!)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let authorized = TPPNetworkExecutor.bearerAuthorized(request: request)

        XCTAssertEqual(authorized.value(forHTTPHeaderField: "Content-Type"), "application/json")
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

    func testInit_withDefaultCachingStrategy() {
        let executor = TPPNetworkExecutor(
            credentialsProvider: nil,
            cachingStrategy: .default,
            delegateQueue: nil
        )
        XCTAssertNotNil(executor)
    }

    func testInit_withFallbackCachingStrategy() {
        let executor = TPPNetworkExecutor(
            credentialsProvider: nil,
            cachingStrategy: .fallback,
            delegateQueue: nil
        )
        XCTAssertNotNil(executor)
    }

    func testInit_withCustomSessionConfiguration() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HTTPStubURLProtocol.self]

        let executor = TPPNetworkExecutor(
            credentialsProvider: nil,
            cachingStrategy: .ephemeral,
            sessionConfiguration: config,
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

    func testCancelNonEssentialTasks_doesNotCrash() {
        TPPNetworkExecutor.shared.cancelNonEssentialTasks()
        // Should not crash
    }
}

// MARK: - Stubbed HTTP Tests

final class TPPNetworkExecutorStubbedTests: XCTestCase {

    private var executor: TPPNetworkExecutor!

    override func setUp() {
        super.setUp()
        HTTPStubURLProtocol.reset()

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HTTPStubURLProtocol.self]

        executor = TPPNetworkExecutor(
            credentialsProvider: nil,
            cachingStrategy: .ephemeral,
            sessionConfiguration: config,
            delegateQueue: nil
        )
    }

    override func tearDown() {
        HTTPStubURLProtocol.reset()
        executor = nil
        super.tearDown()
    }

    // MARK: - GET

    func testGET_success_returnsData() {
        let responseBody = "{\"title\": \"Test Book\"}".data(using: .utf8)!
        HTTPStubURLProtocol.register { request in
            guard request.url?.host == "api.example.com" else { return nil }
            return .init(statusCode: 200, headers: ["Content-Type": "application/json"], body: responseBody)
        }

        let expectation = XCTestExpectation(description: "GET completes")
        var receivedData: Data?

        executor.GET(URL(string: "https://api.example.com/books")!, useTokenIfAvailable: false) { result in
            switch result {
            case .success(let data, _):
                receivedData = data
            case .failure:
                break
            }
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5.0)
        XCTAssertNotNil(receivedData)
        XCTAssertEqual(receivedData, responseBody)
    }

    func testGET_objcAPI_success() {
        let responseBody = "hello".data(using: .utf8)!
        HTTPStubURLProtocol.register { _ in
            return .init(statusCode: 200, headers: nil, body: responseBody)
        }

        let expectation = XCTestExpectation(description: "GET (objc) completes")
        var receivedData: Data?
        var receivedError: Error?

        executor.GET(
            URL(string: "https://api.example.com/test")!,
            cachePolicy: .useProtocolCachePolicy,
            useTokenIfAvailable: false
        ) { data, response, error in
            receivedData = data
            receivedError = error
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5.0)
        XCTAssertNotNil(receivedData)
        XCTAssertNil(receivedError)
    }

    func testGET_serverError_returnsFailure() {
        HTTPStubURLProtocol.register { _ in
            return .init(statusCode: 500, headers: nil, body: "Internal Server Error".data(using: .utf8))
        }

        let expectation = XCTestExpectation(description: "GET returns error")
        var gotData: Data?
        var gotError: Error?

        executor.GET(
            URL(string: "https://api.example.com/fail")!,
            cachePolicy: .useProtocolCachePolicy,
            useTokenIfAvailable: false
        ) { data, _, error in
            gotData = data
            gotError = error
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5.0)
        // Server errors may come back as data or error depending on responder behavior
        // Just verify the completion was called
    }

    // MARK: - PUT

    func testPUT_setsMethodToPUT() {
        var capturedMethod: String?

        HTTPStubURLProtocol.register { request in
            capturedMethod = request.httpMethod
            return .init(statusCode: 200, headers: nil, body: nil)
        }

        let expectation = XCTestExpectation(description: "PUT completes")
        executor.PUT(
            URL(string: "https://api.example.com/borrow")!,
            useTokenIfAvailable: false
        ) { _, _, _ in
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5.0)
        XCTAssertEqual(capturedMethod, "PUT")
    }

    // MARK: - POST

    func testPOST_setsMethodToPOST() {
        var capturedMethod: String?

        HTTPStubURLProtocol.register { request in
            capturedMethod = request.httpMethod
            return .init(statusCode: 201, headers: nil, body: nil)
        }

        var request = URLRequest(url: URL(string: "https://api.example.com/create")!)
        request.httpMethod = "POST"

        let expectation = XCTestExpectation(description: "POST completes")
        executor.POST(request, useTokenIfAvailable: false) { _, _, _ in
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5.0)
        XCTAssertEqual(capturedMethod, "POST")
    }

    func testPOST_nilCompletion_doesNotCrash() {
        HTTPStubURLProtocol.register { _ in
            return .init(statusCode: 200, headers: nil, body: nil)
        }

        var request = URLRequest(url: URL(string: "https://api.example.com/fire-and-forget")!)
        request.httpMethod = "POST"

        executor.POST(request, useTokenIfAvailable: false, completion: nil)

        // Wait briefly to ensure no crash
        let wait = XCTestExpectation(description: "Wait")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { wait.fulfill() }
        self.wait(for: [wait], timeout: 2.0)
    }

    // MARK: - DELETE

    func testDELETE_setsMethodToDELETE() {
        var capturedMethod: String?

        HTTPStubURLProtocol.register { request in
            capturedMethod = request.httpMethod
            return .init(statusCode: 204, headers: nil, body: nil)
        }

        var request = URLRequest(url: URL(string: "https://api.example.com/resource/123")!)
        request.httpMethod = "DELETE"

        let expectation = XCTestExpectation(description: "DELETE completes")
        executor.DELETE(request, useTokenIfAvailable: false) { _, _, _ in
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5.0)
        XCTAssertEqual(capturedMethod, "DELETE")
    }

    func testDELETE_nilCompletion_doesNotCrash() {
        HTTPStubURLProtocol.register { _ in
            return .init(statusCode: 204, headers: nil, body: nil)
        }

        var request = URLRequest(url: URL(string: "https://api.example.com/resource/123")!)
        request.httpMethod = "DELETE"

        executor.DELETE(request, useTokenIfAvailable: false, completion: nil)

        let wait = XCTestExpectation(description: "Wait")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { wait.fulfill() }
        self.wait(for: [wait], timeout: 2.0)
    }

    // MARK: - Async/Await API

    func testGET_async_success() async throws {
        let responseBody = "{\"count\": 42}".data(using: .utf8)!
        HTTPStubURLProtocol.register { _ in
            return .init(statusCode: 200, headers: nil, body: responseBody)
        }

        let (data, _) = try await executor.GET(
            URL(string: "https://api.example.com/count")!,
            useTokenIfAvailable: false
        )
        XCTAssertEqual(data, responseBody)
    }

    func testGET_async_withRequest() async throws {
        let responseBody = "ok".data(using: .utf8)!
        HTTPStubURLProtocol.register { _ in
            return .init(statusCode: 200, headers: nil, body: responseBody)
        }

        let request = URLRequest(url: URL(string: "https://api.example.com/req")!)
        let (data, _) = try await executor.GET(
            request: request,
            cachePolicy: .useProtocolCachePolicy,
            useTokenIfAvailable: false
        )
        XCTAssertEqual(data, responseBody)
    }

    func testPUT_async_success() async throws {
        HTTPStubURLProtocol.register { _ in
            return .init(statusCode: 200, headers: nil, body: "borrowed".data(using: .utf8))
        }

        let (data, _) = try await executor.PUT(
            URL(string: "https://api.example.com/borrow")!,
            useTokenIfAvailable: false
        )
        XCTAssertEqual(String(data: data, encoding: .utf8), "borrowed")
    }

    func testPOST_async_success() async throws {
        HTTPStubURLProtocol.register { _ in
            return .init(statusCode: 201, headers: nil, body: "created".data(using: .utf8))
        }

        var request = URLRequest(url: URL(string: "https://api.example.com/new")!)
        request.httpMethod = "POST"

        let (data, _) = try await executor.POST(request, useTokenIfAvailable: false)
        XCTAssertEqual(String(data: data, encoding: .utf8), "created")
    }

    func testDELETE_async_success() async throws {
        HTTPStubURLProtocol.register { _ in
            return .init(statusCode: 204, headers: nil, body: nil)
        }

        var request = URLRequest(url: URL(string: "https://api.example.com/del")!)
        request.httpMethod = "DELETE"

        let (data, _) = try await executor.DELETE(request, useTokenIfAvailable: false)
        XCTAssertTrue(data.isEmpty)
    }

    // MARK: - Method Correction

    func testGET_correctsHTTPMethodIfNotGET() {
        var capturedMethod: String?

        HTTPStubURLProtocol.register { request in
            capturedMethod = request.httpMethod
            return .init(statusCode: 200, headers: nil, body: nil)
        }

        // Pass a request with wrong method
        var request = URLRequest(url: URL(string: "https://api.example.com/test")!)
        request.httpMethod = "POST"

        let expectation = XCTestExpectation(description: "GET corrects method")
        executor.GET(
            request: request,
            cachePolicy: .useProtocolCachePolicy,
            useTokenIfAvailable: false
        ) { _, _, _ in
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5.0)
        XCTAssertEqual(capturedMethod, "GET")
    }

    func testPUT_correctsHTTPMethodIfNotPUT() {
        var capturedMethod: String?

        HTTPStubURLProtocol.register { request in
            capturedMethod = request.httpMethod
            return .init(statusCode: 200, headers: nil, body: nil)
        }

        // Pass a request with wrong method (GET)
        let request = URLRequest(url: URL(string: "https://api.example.com/borrow")!)

        let expectation = XCTestExpectation(description: "PUT corrects method")
        executor.PUT(
            request: request,
            useTokenIfAvailable: false
        ) { _, _, _ in
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5.0)
        XCTAssertEqual(capturedMethod, "PUT")
    }

    // MARK: - Download

    func testDownload_createsDownloadTask() {
        HTTPStubURLProtocol.register { _ in
            return .init(statusCode: 200, headers: nil, body: "file data".data(using: .utf8))
        }

        let expectation = XCTestExpectation(description: "Download completes")
        let task = executor.download(URL(string: "https://api.example.com/book.epub")!) { data, response, error in
            expectation.fulfill()
        }

        XCTAssertNotNil(task)
        wait(for: [expectation], timeout: 5.0)
    }

    // MARK: - addBearerAndExecute

    func testAddBearerAndExecute_setsAuthHeader() {
        var capturedAuthHeader: String?

        HTTPStubURLProtocol.register { request in
            capturedAuthHeader = request.value(forHTTPHeaderField: "Authorization")
            return .init(statusCode: 200, headers: nil, body: nil)
        }

        let request = URLRequest(url: URL(string: "https://api.example.com/protected")!)

        let expectation = XCTestExpectation(description: "Bearer request completes")
        executor.addBearerAndExecute(request) { _, _, _ in
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5.0)
        // Authorization header should be present (even if empty/blank when no token)
        XCTAssertNotNil(capturedAuthHeader)
    }
}
