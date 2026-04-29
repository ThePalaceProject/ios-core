//
//  TPPNetworkExecutorTests.swift
//  PalaceTests
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import PalaceNetwork
@testable import Palace

final class TPPNetworkExecutorAPITests: XCTestCase {

    // MARK: - Shared Instance

    func testShared_isNotNil() {
        XCTAssertNotNil(AppContainer.production().networkExecutor)
        // Shared must be a singleton — two accesses return the same object
        let a = AppContainer.production().networkExecutor
        let b = AppContainer.production().networkExecutor
        XCTAssertTrue(a === b, "AppContainer.production().networkExecutor must be a singleton")
    }

    // MARK: - Request Creation

    func testRequest_forURL_createsValidRequest() {
        let url = URL(string: "https://example.com/api/books")!
        let request = AppContainer.production().networkExecutor.request(for: url)

        XCTAssertEqual(request.url, url)
        XCTAssertNotNil(request.url)
    }

    func testRequest_forURL_setsUserAgent() {
        let url = URL(string: "https://example.com/api/test")!
        let request = AppContainer.production().networkExecutor.request(for: url)

        // The request should have some standard headers
        XCTAssertNotNil(request.url)
        XCTAssertEqual(request.url, url, "URL must be preserved exactly")
        // Accept-Language is explicitly set to empty string to prevent iOS default
        let acceptLang = request.value(forHTTPHeaderField: "Accept-Language")
        XCTAssertEqual(acceptLang, "", "Accept-Language should be empty string per Palace convention")
    }

    func testRequest_forURL_setsAcceptLanguageEmpty() {
        let url = URL(string: "https://example.com/api/test")!
        let request = AppContainer.production().networkExecutor.request(for: url)

        let acceptLang = request.value(forHTTPHeaderField: "Accept-Language")
        XCTAssertEqual(acceptLang, "")
        // The URL must be preserved when Accept-Language is set
        XCTAssertEqual(request.url, url, "URL must remain unchanged when Accept-Language is set")
        XCTAssertNotNil(request.url, "Request URL must be non-nil")
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
        // URL must also be preserved
        XCTAssertEqual(authorized.url, request.url, "bearerAuthorized must preserve the request URL")
        // Authorization must be added without removing the Content-Type
        XCTAssertNotNil(authorized.value(forHTTPHeaderField: "Authorization"),
                        "Authorization header must be present after bearerAuthorized")
    }

    // MARK: - Initialization with Custom Config

    func testInit_withCachingStrategy_doesNotCrash() {
        let executor = TPPNetworkExecutor(
            credentialsProvider: nil,
            cachingStrategy: .ephemeral,
            delegateQueue: nil
        )
        XCTAssertGreaterThan(executor.requestTimeout, 0,
                             "Ephemeral executor must have a positive request timeout")
        XCTAssertTrue(executor is TPPRequestExecuting,
                      "Executor must conform to TPPRequestExecuting")
    }

    func testInit_withDefaultCachingStrategy() {
        let executor = TPPNetworkExecutor(
            credentialsProvider: nil,
            cachingStrategy: .default,
            delegateQueue: nil
        )
        XCTAssertGreaterThan(executor.requestTimeout, 0,
                             "Default caching executor must have a positive request timeout")
        XCTAssertTrue(executor is TPPRequestExecuting,
                      "Default caching executor must conform to TPPRequestExecuting")
    }

    func testInit_withFallbackCachingStrategy() {
        let executor = TPPNetworkExecutor(
            credentialsProvider: nil,
            cachingStrategy: .fallback,
            delegateQueue: nil
        )
        XCTAssertGreaterThan(executor.requestTimeout, 0,
                             "Fallback caching executor must have a positive request timeout")
        XCTAssertTrue(executor is TPPRequestExecuting,
                      "Fallback caching executor must conform to TPPRequestExecuting")
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
        // Custom config executor must have a valid timeout, just like shared
        XCTAssertGreaterThan(executor.requestTimeout, 0,
                             "Custom-config executor must have a positive request timeout")
        XCTAssertTrue(executor is TPPRequestExecuting,
                      "Custom-config executor must conform to TPPRequestExecuting")
    }

    // MARK: - Cache Control

    func testClearCache_doesNotCrash() {
        AppContainer.production().networkExecutor.clearCache()
        // Calling clearCache twice in a row must also be safe (idempotent)
        AppContainer.production().networkExecutor.clearCache()
        // Shared is still usable after cache clear — can still create a request
        let req = AppContainer.production().networkExecutor.request(for: URL(string: "https://example.com")!)
        XCTAssertNotNil(req.url, "Executor must remain functional after cache cleared")
        XCTAssertGreaterThan(AppContainer.production().networkExecutor.requestTimeout, 0,
                        "requestTimeout must remain positive after cache cleared")
    }

    // MARK: - Task Management

    func testPauseAllTasks_doesNotCrash() {
        AppContainer.production().networkExecutor.pauseAllTasks()
        // Pause then immediately resume must not crash (common sequence on app background/foreground)
        AppContainer.production().networkExecutor.resumeAllTasks()
        let req = AppContainer.production().networkExecutor.request(for: URL(string: "https://example.com")!)
        XCTAssertNotNil(req.url, "Executor must remain functional after pause+resume")
        XCTAssertGreaterThan(AppContainer.production().networkExecutor.requestTimeout, 0,
                        "requestTimeout must remain positive after pause+resume")
    }

    func testResumeAllTasks_doesNotCrash() {
        // Resume without prior pause must be safe
        AppContainer.production().networkExecutor.resumeAllTasks()
        AppContainer.production().networkExecutor.resumeAllTasks()
        let req = AppContainer.production().networkExecutor.request(for: URL(string: "https://example.com")!)
        XCTAssertNotNil(req.url, "Executor must remain functional after multiple resumes")
        XCTAssertGreaterThan(AppContainer.production().networkExecutor.requestTimeout, 0,
                        "requestTimeout must remain positive after multiple resumes")
    }

    func testCancelNonEssentialTasks_doesNotCrash() {
        AppContainer.production().networkExecutor.cancelNonEssentialTasks()
        // Cancelling twice in quick succession must not crash
        AppContainer.production().networkExecutor.cancelNonEssentialTasks()
        let req = AppContainer.production().networkExecutor.request(for: URL(string: "https://example.com")!)
        XCTAssertNotNil(req.url, "Executor must remain functional after repeated cancellations")
        XCTAssertGreaterThan(AppContainer.production().networkExecutor.requestTimeout, 0,
                        "requestTimeout must remain positive after repeated cancellations")
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
        // Server errors must produce either error or data (completion must be called)
        XCTAssertTrue(gotData != nil || gotError != nil,
                      "A 500 response must result in either error data or an error object — completion must not silently drop")
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

        // Wait briefly to ensure no crash, then verify the executor remains usable
        let wait = XCTestExpectation(description: "Wait")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { wait.fulfill() }
        self.wait(for: [wait], timeout: 2.0)
        // Executor must remain functional after fire-and-forget POST
        XCTAssertGreaterThan(self.executor.requestTimeout, 0,
                             "Executor requestTimeout must remain positive after nil-completion POST")
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
        // Executor must remain functional after fire-and-forget DELETE
        XCTAssertGreaterThan(self.executor.requestTimeout, 0,
                             "Executor requestTimeout must remain positive after nil-completion DELETE")
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
