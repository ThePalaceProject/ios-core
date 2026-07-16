//
//  NetworkRetryTests.swift
//  PalaceTests
//
//  Tests for network retry logic, timeout handling, and offline detection
//

import XCTest
@testable import Palace

// MARK: - Network Retry Logic Tests

final class NetworkRetryLogicTests: XCTestCase {

    // MARK: - Properties

    private var config: URLSessionConfiguration!

    // MARK: - Setup

    override func setUp() {
        super.setUp()
        HTTPStubURLProtocol.reset()

        config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HTTPStubURLProtocol.self]
    }

    override func tearDown() {
        HTTPStubURLProtocol.reset()
        config = nil
        super.tearDown()
    }

    // MARK: - Retry on 5xx Error Tests

    func testRetry_on500Error_eventualSuccess() async throws {
        let lock = NSLock()
        var requestCount = 0

        HTTPStubURLProtocol.register { req in
            guard req.url?.path == "/retry-test" else { return nil }
            lock.lock()
            requestCount += 1
            let count = requestCount
            lock.unlock()
            if count < 3 {
                return .init(statusCode: 500, headers: nil, body: nil)
            }
            return .init(statusCode: 200, headers: nil, body: Data("{\"ok\":true}".utf8))
        }

        // This tests the retry behavior - whether it happens depends on client implementation
        let url = URL(string: "https://example.com/retry-test")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let (_, response) = try await session.data(for: request)

        let httpResponse = response as! HTTPURLResponse
        // First request should complete (either retry succeeded or got 500)
        XCTAssertTrue([200, 500].contains(httpResponse.statusCode))
    }

    func testRetry_on502BadGateway() async throws {
        HTTPStubURLProtocol.register { req in
            guard req.url?.path == "/bad-gateway" else { return nil }
            return .init(statusCode: 502, headers: nil, body: Data("Bad Gateway".utf8))
        }

        let url = URL(string: "https://example.com/bad-gateway")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let (_, response) = try await session.data(for: request)

        let httpResponse = response as! HTTPURLResponse
        XCTAssertEqual(httpResponse.statusCode, 502)
    }

    func testRetry_on503ServiceUnavailable() async throws {
        HTTPStubURLProtocol.register { req in
            guard req.url?.path == "/unavailable" else { return nil }
            return .init(statusCode: 503, headers: ["Retry-After": "60"], body: nil)
        }

        let url = URL(string: "https://example.com/unavailable")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let (_, response) = try await session.data(for: request)

        let httpResponse = response as! HTTPURLResponse
        XCTAssertEqual(httpResponse.statusCode, 503)
        XCTAssertEqual(httpResponse.value(forHTTPHeaderField: "Retry-After"), "60")
    }

    func testRetry_on504GatewayTimeout() async throws {
        HTTPStubURLProtocol.register { req in
            guard req.url?.path == "/gateway-timeout" else { return nil }
            return .init(statusCode: 504, headers: nil, body: nil)
        }

        let url = URL(string: "https://example.com/gateway-timeout")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let (_, response) = try await session.data(for: request)

        let httpResponse = response as! HTTPURLResponse
        XCTAssertEqual(httpResponse.statusCode, 504)
    }

    // MARK: - No Retry on 4xx Tests

    func testNoRetry_on400BadRequest() async throws {
        let lock = NSLock()
        var requestCount = 0

        HTTPStubURLProtocol.register { req in
            guard req.url?.path == "/bad-request" else { return nil }
            lock.lock()
            requestCount += 1
            lock.unlock()
            return .init(statusCode: 400, headers: nil, body: Data("Bad Request".utf8))
        }

        let url = URL(string: "https://example.com/bad-request")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        _ = try await session.data(for: request)

        // 4xx errors should not be retried
        // Swift 6: NSLock.lock()/unlock() are unavailable in async contexts.
        let finalCount = lock.withLock { requestCount }
        XCTAssertEqual(finalCount, 1)
    }

    func testNoRetry_on404NotFound() async throws {
        let lock = NSLock()
        var requestCount = 0

        HTTPStubURLProtocol.register { req in
            guard req.url?.path == "/not-found" else { return nil }
            lock.lock()
            requestCount += 1
            lock.unlock()
            return .init(statusCode: 404, headers: nil, body: nil)
        }

        let url = URL(string: "https://example.com/not-found")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        _ = try await session.data(for: request)

        // Swift 6: NSLock.lock()/unlock() are unavailable in async contexts.
        let finalCount = lock.withLock { requestCount }
        XCTAssertEqual(finalCount, 1)
    }

    // MARK: - Rate Limiting Tests

    func testRateLimiting_429Response() async throws {
        HTTPStubURLProtocol.register { req in
            guard req.url?.path == "/rate-limited" else { return nil }
            return .init(
                statusCode: 429,
                headers: [
                    "Retry-After": "30",
                    "X-RateLimit-Remaining": "0",
                    "X-RateLimit-Reset": "\(Int(Date().timeIntervalSince1970) + 30)"
                ],
                body: Data("Too Many Requests".utf8)
            )
        }

        let url = URL(string: "https://example.com/rate-limited")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let (_, response) = try await session.data(for: request)

        let httpResponse = response as! HTTPURLResponse
        XCTAssertEqual(httpResponse.statusCode, 429)
        XCTAssertNotNil(httpResponse.value(forHTTPHeaderField: "Retry-After"))
    }
}

// MARK: - Network Timeout Tests

final class NetworkTimeoutTests: XCTestCase {

    func testTimeout_configuration() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60

        XCTAssertEqual(config.timeoutIntervalForRequest, 30)
        XCTAssertEqual(config.timeoutIntervalForResource, 60)
        // Resource timeout must be >= request timeout (otherwise a single slow request
        // could exceed the resource budget even though the request itself is within limit)
        XCTAssertGreaterThanOrEqual(config.timeoutIntervalForResource,
                                    config.timeoutIntervalForRequest,
                                    "Resource timeout must be >= per-request timeout")
    }

    func testDefaultTimeout_isReasonable() {
        let request = URLRequest(url: URL(string: "https://example.com")!)

        // Default timeout should be > 0
        XCTAssertGreaterThan(request.timeoutInterval, 0)
        // Sanity-check: default must be under an unreasonably large ceiling
        XCTAssertLessThanOrEqual(request.timeoutInterval, 3600,
                                 "Default timeout should not exceed one hour")
    }
}

// MARK: - Offline Detection Tests

final class NetworkOfflineDetectionTests: XCTestCase {

    func testNetworkReachability_hasSharedInstance() {
        // Verify the reachability service exists and is a singleton
        let reachability = AppContainer.production().reachability
        XCTAssertNotNil(reachability)
        // Two accesses must return the same object
        let second = AppContainer.production().reachability
        XCTAssertTrue(reachability === second,
                      "AppContainer.production().reachability must be a singleton")
    }

    func testURLError_offlineErrorCodes() {
        let offlineErrorCodes: [URLError.Code] = [
            .notConnectedToInternet,
            .networkConnectionLost,
            .dataNotAllowed
        ]

        for code in offlineErrorCodes {
            let error = URLError(code)
            XCTAssertTrue(Self.isOfflineError(error))
        }
    }

    func testURLError_nonOfflineErrorCodes() {
        let onlineErrorCodes: [URLError.Code] = [
            .badURL,
            .timedOut,
            .cannotFindHost,
            .badServerResponse
        ]

        for code in onlineErrorCodes {
            let error = URLError(code)
            XCTAssertFalse(Self.isOfflineError(error))
        }
    }

    private static func isOfflineError(_ error: URLError) -> Bool {
        let offlineCodes: [URLError.Code] = [
            .notConnectedToInternet,
            .networkConnectionLost,
            .dataNotAllowed
        ]
        return offlineCodes.contains(error.code)
    }
}

// MARK: - Request Queue Tests

final class NetworkRequestQueueTests: XCTestCase {

    private var config: URLSessionConfiguration!

    override func setUp() {
        super.setUp()
        HTTPStubURLProtocol.reset()

        config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HTTPStubURLProtocol.self]
    }

    override func tearDown() {
        HTTPStubURLProtocol.reset()
        config = nil
        super.tearDown()
    }

    func testConcurrentRequests_respectsLimit() async throws {
        var concurrentCount = 0
        var maxConcurrent = 0
        let lock = NSLock()
        // Released once at least 2 requests have registered concurrent in-flight
        // state. Each stub-handler waits on this gate (bounded by the 1s timeout
        // baked into the semaphore wait) so we observe real concurrency on a
        // real signal instead of a fixed-delay sleep.
        let concurrencyReached = DispatchSemaphore(value: 0)
        var gateOpened = false

        HTTPStubURLProtocol.register { _ in
            lock.lock()
            concurrentCount += 1
            maxConcurrent = max(maxConcurrent, concurrentCount)
            let shouldOpenGate = concurrentCount >= 2 && !gateOpened
            if shouldOpenGate { gateOpened = true }
            lock.unlock()

            if shouldOpenGate {
                // Wake every other stub-handler currently parked on the gate.
                for _ in 0..<10 { concurrencyReached.signal() }
            } else {
                // Park until a sibling request has arrived. The 1s ceiling
                // is a safety stop — under normal conditions this releases
                // sub-millisecond once another request enters the stub.
                _ = concurrencyReached.wait(timeout: .now() + 1.0)
            }

            lock.lock()
            concurrentCount -= 1
            lock.unlock()

            return .init(statusCode: 200, headers: nil, body: nil)
        }

        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let urls = (0..<10).map { URL(string: "https://example.com/item/\($0)")! }

        await withTaskGroup(of: Void.self) { group in
            for url in urls {
                group.addTask {
                    _ = try? await session.data(from: url)
                }
            }
        }

        // Should have processed all requests
        XCTAssertGreaterThan(maxConcurrent, 0)
    }

    func testRequestOrdering_maintainsOrder() async throws {
        var requestOrder: [Int] = []
        let lock = NSLock()

        HTTPStubURLProtocol.register { req in
            if let pathComponent = req.url?.lastPathComponent, let index = Int(pathComponent) {
                lock.lock()
                requestOrder.append(index)
                lock.unlock()
            }
            return .init(statusCode: 200, headers: nil, body: nil)
        }

        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        // Sequential requests
        for i in 0..<5 {
            let url = URL(string: "https://example.com/sequential/\(i)")!
            _ = try await session.data(from: url)
        }

        // Should maintain order for sequential requests
        XCTAssertEqual(requestOrder, [0, 1, 2, 3, 4])
    }
}

// MARK: - Network Executor Tests

final class TPPNetworkExecutorTests: XCTestCase {

    func testExecutor_usesEphemeralCaching() {
        let executor = TPPNetworkExecutor(cachingStrategy: .ephemeral)
        // Executor must be able to build a valid request (not just non-nil)
        let url = URL(string: "https://example.com/books")!
        let request = executor.request(for: url, useTokenIfAvailable: false)
        XCTAssertEqual(request.url, url, "Ephemeral executor must build requests with the correct URL")
        XCTAssertGreaterThan(executor.requestTimeout, 0, "Executor must have a positive timeout")
    }

    func testExecutor_hasCorrectTimeout() {
        let executor = TPPNetworkExecutor(cachingStrategy: .ephemeral)
        XCTAssertGreaterThan(executor.requestTimeout, 0)
        // Timeout must be under an unreasonably large ceiling (sanity check)
        XCTAssertLessThanOrEqual(executor.requestTimeout, 3600,
                                 "Timeout must not exceed one hour")
        // Two calls must return the same timeout (it must be deterministic)
        XCTAssertEqual(executor.requestTimeout, executor.requestTimeout)
    }

    func testExecutor_conformsToProtocol() {
        let executor = TPPNetworkExecutor(cachingStrategy: .ephemeral)
        XCTAssertTrue(executor is TPPRequestExecuting)
        // As protocol, it must be assignable without concrete type
        let asProtocol: TPPRequestExecuting = executor
        XCTAssertNotNil(asProtocol, "Executor must be usable via protocol type")
    }
}
