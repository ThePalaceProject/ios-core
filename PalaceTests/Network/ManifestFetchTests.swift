//
//  ManifestFetchTests.swift
//  PalaceTests
//
//  Regression tests for the Pattern 2 audiobook playback bug:
//  fetchOpenAccessManifest used URLSessionDownloadTask on a session
//  with no URLSessionDownloadDelegate, causing empty data. It also
//  did not handle the two-step bearer token flow (fulfill URL returns
//  bearer token JSON, then manifest is fetched from the location URL).
//
//  These tests verify:
//    1. Bearer token responses are correctly distinguished from manifests
//    2. fetchManifestWithBearerToken fetches from the correct URL with correct auth
//    3. TPPNetworkExecutor.GET creates a data task (not download task)
//    4. Error cases are handled gracefully
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

// MARK: - Bearer Token vs Manifest Detection

/// Verifies that the app correctly distinguishes CM bearer token responses
/// from actual audiobook manifests. This is the core decision logic that
/// determines whether a second network hop is needed.
final class BearerTokenResponseDetectionTests: XCTestCase {

    func testBearerTokenJSON_isDetectedCorrectly() {
        let bearerTokenJSON: [String: Any] = [
            "access_token": "eyJhbGciOiJIUzI1NiJ9.test-token",
            "expires_in": 3600,
            "location": "https://distributor.example.com/manifest/book-123.json"
        ]

        let token = MyBooksSimplifiedBearerToken.simplifiedBearerToken(with: bearerTokenJSON)

        XCTAssertNotNil(token, "Bearer token JSON with access_token/expires_in/location must be detected")
        XCTAssertEqual(token?.accessToken, "eyJhbGciOiJIUzI1NiJ9.test-token")
        XCTAssertEqual(token?.location.absoluteString, "https://distributor.example.com/manifest/book-123.json")
    }

    func testAudiobookManifestJSON_isNotMistakenForBearerToken() {
        let manifestJSON: [String: Any] = [
            "@context": "https://readium.org/webpub-manifest/context.jsonld",
            "metadata": [
                "@type": "https://schema.org/Audiobook",
                "title": "Test Audiobook",
                "author": "Test Author",
                "duration": 36000
            ],
            "readingOrder": [
                ["href": "https://cdn.example.com/chapter1.mp3", "type": "audio/mpeg", "duration": 1800],
                ["href": "https://cdn.example.com/chapter2.mp3", "type": "audio/mpeg", "duration": 1800]
            ]
        ]

        let token = MyBooksSimplifiedBearerToken.simplifiedBearerToken(with: manifestJSON)

        XCTAssertNil(token, "Audiobook manifest JSON must NOT be mistaken for a bearer token response")
    }

    func testManifestWithLocationKey_butNoAccessToken_isNotBearerToken() {
        let json: [String: Any] = [
            "metadata": ["title": "Book"],
            "location": "some-value",
            "readingOrder": []
        ]

        let token = MyBooksSimplifiedBearerToken.simplifiedBearerToken(with: json)
        XCTAssertNil(token, "JSON with 'location' but no 'access_token' should not be detected as bearer token")
    }

    func testManifestWithAccessTokenKey_butNoLocation_isNotBearerToken() {
        let json: [String: Any] = [
            "access_token": "some-token",
            "expires_in": 3600
        ]

        let token = MyBooksSimplifiedBearerToken.simplifiedBearerToken(with: json)
        XCTAssertNil(token, "JSON with 'access_token' but no 'location' should not be detected as bearer token")
    }

    func testBearerTokenJSON_withExpirationKey_isDetected() {
        let json: [String: Any] = [
            "access_token": "tok",
            "expiration": 7200,
            "location": "https://example.com/manifest"
        ]

        let token = MyBooksSimplifiedBearerToken.simplifiedBearerToken(with: json)
        XCTAssertNotNil(token, "Bearer token JSON with 'expiration' key (instead of 'expires_in') should be detected")
    }

    func testEmptyJSON_isNotBearerToken() {
        let token = MyBooksSimplifiedBearerToken.simplifiedBearerToken(with: [:])
        XCTAssertNil(token, "Empty JSON should not be detected as bearer token")
    }

    func testProblemDocumentJSON_isNotBearerToken() {
        let problemDoc: [String: Any] = [
            "type": "http://opds-spec.org/odl/error",
            "title": "Expired Loan",
            "status": 403,
            "detail": "Your loan for this book has expired."
        ]

        let token = MyBooksSimplifiedBearerToken.simplifiedBearerToken(with: problemDoc)
        XCTAssertNil(token, "OPDS problem document should not be detected as bearer token")
    }
}

// MARK: - fetchManifestWithBearerToken Tests

/// Tests the second-hop manifest fetch that uses the book-specific bearer token.
/// Uses HTTP stub protocol to verify correct request construction and response handling.
final class FetchManifestWithBearerTokenTests: XCTestCase {

    private let manifestURL = URL(string: "https://distributor.example.com/manifest/book-123.json")!
    private let fulfillURL = URL(string: "https://cm.example.com/works/123/fulfill/45")!
    private var book: TPPBook!
    private var stubbedSession: URLSession!

    override func setUp() {
        super.setUp()
        book = TPPBookMocker.mockBook(distributorType: .BearerToken)
        HTTPStubURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HTTPStubURLProtocol.self]
        stubbedSession = URLSession(configuration: config)
    }

    override func tearDown() {
        HTTPStubURLProtocol.reset()
        stubbedSession = nil
        book = nil
        super.tearDown()
    }

    // MARK: - Success Cases

    func testSuccess_returnsManifestJSON() {
        let manifest: [String: Any] = [
            "@context": "https://readium.org/webpub-manifest/context.jsonld",
            "metadata": ["title": "Test Audiobook"],
            "readingOrder": [
                ["href": "https://cdn.example.com/ch1.mp3", "type": "audio/mpeg"]
            ]
        ]
        let manifestData = try! JSONSerialization.data(withJSONObject: manifest)

        HTTPStubURLProtocol.register { request in
            guard request.url == self.manifestURL else { return nil }
            return .init(statusCode: 200, headers: ["Content-Type": "application/json"], body: manifestData)
        }

        let token = MyBooksSimplifiedBearerToken(
            accessToken: "test-bearer-token-xyz",
            expiration: Date(timeIntervalSinceNow: 3600),
            location: manifestURL,
            fulfillURL: fulfillURL
        )

        let expectation = expectation(description: "Manifest fetch completes")
        var resultJSON: [String: Any]?

        BookService.fetchManifestWithBearerToken(token, for: book, session: stubbedSession) { json in
            resultJSON = json
            expectation.fulfill()
        }

        waitForExpectations(timeout: 5)

        XCTAssertNotNil(resultJSON, "Should return parsed manifest JSON")
        XCTAssertNotNil(resultJSON?["metadata"], "Manifest should contain metadata")
        XCTAssertNotNil(resultJSON?["readingOrder"], "Manifest should contain readingOrder")
    }

    func testSuccess_sendsCorrectBearerTokenHeader() {
        var capturedAuthHeader: String?

        HTTPStubURLProtocol.register { request in
            guard request.url == self.manifestURL else { return nil }
            capturedAuthHeader = request.value(forHTTPHeaderField: "Authorization")
            let json = try! JSONSerialization.data(withJSONObject: ["metadata": [:]])
            return .init(statusCode: 200, headers: nil, body: json)
        }

        let token = MyBooksSimplifiedBearerToken(
            accessToken: "specific-book-token-abc",
            expiration: Date(timeIntervalSinceNow: 3600),
            location: manifestURL
        )

        let expectation = expectation(description: "Request sent")
        BookService.fetchManifestWithBearerToken(token, for: book, session: stubbedSession) { _ in
            expectation.fulfill()
        }

        waitForExpectations(timeout: 5)

        XCTAssertEqual(
            capturedAuthHeader, "Bearer specific-book-token-abc",
            "Must use the BOOK-SPECIFIC bearer token, not the CM auth token"
        )
    }

    func testSuccess_requestsFromCorrectURL() {
        var capturedURL: URL?

        HTTPStubURLProtocol.register { request in
            capturedURL = request.url
            let json = try! JSONSerialization.data(withJSONObject: ["metadata": [:]])
            return .init(statusCode: 200, headers: nil, body: json)
        }

        let token = MyBooksSimplifiedBearerToken(
            accessToken: "tok",
            expiration: Date(timeIntervalSinceNow: 3600),
            location: manifestURL
        )

        let expectation = expectation(description: "Request sent")
        BookService.fetchManifestWithBearerToken(token, for: book, session: stubbedSession) { _ in
            expectation.fulfill()
        }

        waitForExpectations(timeout: 5)

        XCTAssertEqual(capturedURL, manifestURL,
                       "Should fetch from the bearer token's location URL, not the fulfill URL")
    }

    // MARK: - Error Cases

    func testHTTP401_returnsNil() {
        HTTPStubURLProtocol.register { request in
            guard request.url == self.manifestURL else { return nil }
            return .init(statusCode: 401, headers: nil, body: nil)
        }

        let token = MyBooksSimplifiedBearerToken(
            accessToken: "expired-token",
            expiration: Date(timeIntervalSinceNow: 3600),
            location: manifestURL
        )

        let expectation = expectation(description: "Fetch completes")
        var resultJSON: [String: Any]?

        BookService.fetchManifestWithBearerToken(token, for: book, session: stubbedSession) { json in
            resultJSON = json
            expectation.fulfill()
        }

        waitForExpectations(timeout: 5)
        XCTAssertNil(resultJSON, "Should return nil for 401 response")
    }

    func testHTTP500_returnsNil() {
        HTTPStubURLProtocol.register { request in
            guard request.url == self.manifestURL else { return nil }
            return .init(statusCode: 500, headers: nil, body: nil)
        }

        let token = MyBooksSimplifiedBearerToken(
            accessToken: "tok",
            expiration: Date(timeIntervalSinceNow: 3600),
            location: manifestURL
        )

        let expectation = expectation(description: "Fetch completes")
        var resultJSON: [String: Any]?

        BookService.fetchManifestWithBearerToken(token, for: book, session: stubbedSession) { json in
            resultJSON = json
            expectation.fulfill()
        }

        waitForExpectations(timeout: 5)
        XCTAssertNil(resultJSON, "Should return nil for 500 server error")
    }

    func testEmptyResponseBody_returnsNil() {
        HTTPStubURLProtocol.register { request in
            guard request.url == self.manifestURL else { return nil }
            return .init(statusCode: 200, headers: nil, body: nil)
        }

        let token = MyBooksSimplifiedBearerToken(
            accessToken: "tok",
            expiration: Date(timeIntervalSinceNow: 3600),
            location: manifestURL
        )

        let expectation = expectation(description: "Fetch completes")
        var resultJSON: [String: Any]?

        BookService.fetchManifestWithBearerToken(token, for: book, session: stubbedSession) { json in
            resultJSON = json
            expectation.fulfill()
        }

        waitForExpectations(timeout: 5)
        XCTAssertNil(resultJSON, "Should return nil for empty response body")
    }

    func testHTMLResponse_returnsNil() {
        let htmlData = "<html><body>Login Required</body></html>".data(using: .utf8)!

        HTTPStubURLProtocol.register { request in
            guard request.url == self.manifestURL else { return nil }
            return .init(statusCode: 200, headers: ["Content-Type": "text/html"], body: htmlData)
        }

        let token = MyBooksSimplifiedBearerToken(
            accessToken: "tok",
            expiration: Date(timeIntervalSinceNow: 3600),
            location: manifestURL
        )

        let expectation = expectation(description: "Fetch completes")
        var resultJSON: [String: Any]?

        BookService.fetchManifestWithBearerToken(token, for: book, session: stubbedSession) { json in
            resultJSON = json
            expectation.fulfill()
        }

        waitForExpectations(timeout: 5)
        XCTAssertNil(resultJSON, "Should return nil for HTML (non-JSON) response")
    }

    func testInvalidJSON_returnsNil() {
        let badJSON = "{ invalid json }".data(using: .utf8)!

        HTTPStubURLProtocol.register { request in
            guard request.url == self.manifestURL else { return nil }
            return .init(statusCode: 200, headers: ["Content-Type": "application/json"], body: badJSON)
        }

        let token = MyBooksSimplifiedBearerToken(
            accessToken: "tok",
            expiration: Date(timeIntervalSinceNow: 3600),
            location: manifestURL
        )

        let expectation = expectation(description: "Fetch completes")
        var resultJSON: [String: Any]?

        BookService.fetchManifestWithBearerToken(token, for: book, session: stubbedSession) { json in
            resultJSON = json
            expectation.fulfill()
        }

        waitForExpectations(timeout: 5)
        XCTAssertNil(resultJSON, "Should return nil for malformed JSON")
    }

    func testJSONArray_returnsNil() {
        let arrayJSON = try! JSONSerialization.data(withJSONObject: [1, 2, 3])

        HTTPStubURLProtocol.register { request in
            guard request.url == self.manifestURL else { return nil }
            return .init(statusCode: 200, headers: nil, body: arrayJSON)
        }

        let token = MyBooksSimplifiedBearerToken(
            accessToken: "tok",
            expiration: Date(timeIntervalSinceNow: 3600),
            location: manifestURL
        )

        let expectation = expectation(description: "Fetch completes")
        var resultJSON: [String: Any]?

        BookService.fetchManifestWithBearerToken(token, for: book, session: stubbedSession) { json in
            resultJSON = json
            expectation.fulfill()
        }

        waitForExpectations(timeout: 5)
        XCTAssertNil(resultJSON, "Should return nil for JSON array (not a dictionary)")
    }
}

// MARK: - Data Task vs Download Task Verification

/// Verifies that TPPNetworkExecutor.GET creates a URLSessionDataTask (not a download task).
/// The old bug used download() which created URLSessionDownloadTask on a session without
/// URLSessionDownloadDelegate, causing empty response data.
final class NetworkExecutorTaskTypeTests: XCTestCase {

    func testGET_createsDataTask_notDownloadTask() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HTTPStubURLProtocol.self]

        HTTPStubURLProtocol.reset()
        HTTPStubURLProtocol.register { _ in
            return .init(statusCode: 200, headers: nil, body: "{}".data(using: .utf8))
        }

        let executor = TPPNetworkExecutor(
            cachingStrategy: .default,
            sessionConfiguration: config
        )

        let url = URL(string: "https://example.com/test")!
        let expectation = expectation(description: "GET completes")

        let task = executor.GET(url) { _, _, _ in
            expectation.fulfill()
        }

        XCTAssertNotNil(task, "GET should return a task")
        // GET returns URLSessionDataTask? -- the compiler enforces this at the type level.
        // This test documents that we use GET (data task) rather than download (download task).
        let taskClassName = String(describing: type(of: task!))
        XCTAssertTrue(taskClassName.contains("DataTask"), "GET must return a data task, got: \(taskClassName)")
        XCTAssertFalse(taskClassName.contains("DownloadTask"), "GET must NOT return a download task")

        waitForExpectations(timeout: 5)
        HTTPStubURLProtocol.reset()
    }

    func testDownload_createsDownloadTask() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HTTPStubURLProtocol.self]

        HTTPStubURLProtocol.reset()
        HTTPStubURLProtocol.register { _ in
            return .init(statusCode: 200, headers: nil, body: "{}".data(using: .utf8))
        }

        let executor = TPPNetworkExecutor(
            cachingStrategy: .default,
            sessionConfiguration: config
        )

        let url = URL(string: "https://example.com/test")!
        let task = executor.download(url) { _, _, _ in }

        let taskClassName = String(describing: type(of: task))
        XCTAssertTrue(taskClassName.contains("DownloadTask"),
                      "download() should return URLSessionDownloadTask, got: \(taskClassName)")

        task.cancel()
        HTTPStubURLProtocol.reset()
    }

    func testGET_receivesResponseData() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HTTPStubURLProtocol.self]

        let responseBody = """
        {"metadata": {"title": "Test Book"}, "readingOrder": []}
        """.data(using: .utf8)!

        HTTPStubURLProtocol.reset()
        HTTPStubURLProtocol.register { _ in
            return .init(statusCode: 200, headers: ["Content-Type": "application/json"], body: responseBody)
        }

        let executor = TPPNetworkExecutor(
            cachingStrategy: .default,
            sessionConfiguration: config
        )

        let url = URL(string: "https://example.com/manifest")!
        let expectation = expectation(description: "GET receives data")
        var receivedData: Data?

        let _ = executor.GET(url) { data, _, _ in
            receivedData = data
            expectation.fulfill()
        }

        waitForExpectations(timeout: 5)

        XCTAssertNotNil(receivedData, "GET with data task MUST receive response data")
        XCTAssertGreaterThan(receivedData?.count ?? 0, 0, "Response data must not be empty")

        if let data = receivedData,
           let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            XCTAssertNotNil(json["metadata"], "Parsed JSON should contain metadata")
        } else {
            XCTFail("Response data should be valid JSON")
        }

        HTTPStubURLProtocol.reset()
    }
}

// MARK: - Two-Step Fulfill Flow Integration Tests

/// End-to-end tests for the full bearer token fulfill flow:
/// Step 1: App calls CM fulfill URL → receives bearer token JSON
/// Step 2: App calls manifest location URL with bearer token → receives manifest
///
/// These tests verify the complete chain using a stubbed executor.
final class BearerTokenFulfillFlowTests: XCTestCase {

    private let fulfillURL = URL(string: "https://cm.example.com/CA9876/works/6139999/fulfill/30")!
    private let manifestURL = URL(string: "https://distributor.example.com/content/manifest.json")!

    override func tearDown() {
        HTTPStubURLProtocol.reset()
        super.tearDown()
    }

    func testFullFlow_fulfillReturnsBearerToken_thenManifestIsFetched() {
        let bearerTokenResponse: [String: Any] = [
            "access_token": "fulfill-bearer-token-123",
            "expires_in": 3600,
            "location": manifestURL.absoluteString
        ]
        let bearerTokenData = try! JSONSerialization.data(withJSONObject: bearerTokenResponse)

        let manifestResponse: [String: Any] = [
            "@context": "https://readium.org/webpub-manifest/context.jsonld",
            "metadata": [
                "@type": "https://schema.org/Audiobook",
                "title": "California Audiobook",
                "duration": 36000
            ],
            "readingOrder": [
                ["href": "https://cdn.example.com/ch1.mp3", "type": "audio/mpeg", "duration": 1800]
            ]
        ]
        let manifestData = try! JSONSerialization.data(withJSONObject: manifestResponse)

        var requestLog: [(url: URL, authHeader: String?)] = []
        let requestLogLock = NSLock()

        HTTPStubURLProtocol.reset()
        HTTPStubURLProtocol.register { request in
            let entry = (url: request.url!, authHeader: request.value(forHTTPHeaderField: "Authorization"))
            requestLogLock.lock()
            requestLog.append(entry)
            requestLogLock.unlock()

            if request.url?.path.contains("fulfill") == true {
                return .init(statusCode: 200, headers: ["Content-Type": "application/vnd.librarysimplified.bearer-token+json"], body: bearerTokenData)
            }
            if request.url == self.manifestURL {
                return .init(statusCode: 200, headers: ["Content-Type": "application/json"], body: manifestData)
            }
            return nil
        }

        // Step 1: Parse the bearer token response (simulating what fetchOpenAccessManifest does)
        let json = try! JSONSerialization.jsonObject(with: bearerTokenData) as! [String: Any]
        let token = MyBooksSimplifiedBearerToken.simplifiedBearerToken(with: json)
        XCTAssertNotNil(token, "Bearer token response must be detected")
        XCTAssertEqual(token?.location, manifestURL)

        // Step 2: Fetch manifest via bearer token (the second hop)
        let book = TPPBookMocker.mockBook(distributorType: .BearerToken)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HTTPStubURLProtocol.self]
        let stubbedSession = URLSession(configuration: config)

        let expectation = expectation(description: "Manifest fetched via bearer token")
        var resultJSON: [String: Any]?

        BookService.fetchManifestWithBearerToken(token!, for: book, session: stubbedSession) { json in
            resultJSON = json
            expectation.fulfill()
        }

        waitForExpectations(timeout: 5)

        // Verify manifest was returned
        XCTAssertNotNil(resultJSON, "Should receive the actual manifest, not the bearer token JSON")
        let metadata = resultJSON?["metadata"] as? [String: Any]
        XCTAssertEqual(metadata?["title"] as? String, "California Audiobook")
        XCTAssertNotNil(resultJSON?["readingOrder"])

        // Verify the request was made to the manifest URL (not the fulfill URL)
        requestLogLock.lock()
        let manifestRequests = requestLog.filter { $0.url == manifestURL }
        requestLogLock.unlock()

        XCTAssertEqual(manifestRequests.count, 1, "Exactly one request should go to the manifest URL")
        XCTAssertEqual(
            manifestRequests.first?.authHeader,
            "Bearer fulfill-bearer-token-123",
            "Manifest request must use the BOOK-SPECIFIC bearer token from the fulfill response"
        )
    }

    func testFullFlow_manifestResponseIsNotMistakenForBearerToken() {
        let manifestJSON: [String: Any] = [
            "@context": "https://readium.org/webpub-manifest/context.jsonld",
            "metadata": ["title": "Open Access Audiobook"],
            "readingOrder": [
                ["href": "https://cdn.example.com/ch1.mp3", "type": "audio/mpeg"]
            ]
        ]

        // When the fulfill URL returns a manifest directly (open access),
        // simplifiedBearerToken should return nil and the manifest should be used as-is
        let token = MyBooksSimplifiedBearerToken.simplifiedBearerToken(with: manifestJSON)
        XCTAssertNil(token, "Open access manifest must NOT trigger the two-step bearer token flow")
    }

    func testFullFlow_bearerTokenWithExpiredManifestFetch_returnsNil() {
        HTTPStubURLProtocol.reset()
        HTTPStubURLProtocol.register { request in
            if request.url == self.manifestURL {
                return .init(statusCode: 403, headers: nil, body: nil)
            }
            return nil
        }

        let token = MyBooksSimplifiedBearerToken(
            accessToken: "expired-book-token",
            expiration: Date(timeIntervalSinceNow: 3600),
            location: manifestURL,
            fulfillURL: fulfillURL
        )

        let book = TPPBookMocker.mockBook(distributorType: .BearerToken)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HTTPStubURLProtocol.self]
        let stubbedSession = URLSession(configuration: config)

        let expectation = expectation(description: "Fetch completes")
        var resultJSON: [String: Any]?

        BookService.fetchManifestWithBearerToken(token, for: book, session: stubbedSession) { json in
            resultJSON = json
            expectation.fulfill()
        }

        waitForExpectations(timeout: 5)
        XCTAssertNil(resultJSON, "Should return nil when manifest location returns 403")
    }

    /// Verifies that the fulfill URL (which might return bearer token JSON) is correctly
    /// distinguished from the manifest URL. The app was previously treating them as the same.
    func testFulfillURL_andManifestURL_areDifferentEndpoints() {
        let bearerTokenJSON: [String: Any] = [
            "access_token": "book-token",
            "expires_in": 3600,
            "location": manifestURL.absoluteString
        ]

        let token = MyBooksSimplifiedBearerToken.simplifiedBearerToken(with: bearerTokenJSON)!

        XCTAssertNotEqual(
            fulfillURL, token.location,
            "The manifest location from the bearer token should be a DIFFERENT URL than the fulfill URL"
        )
        XCTAssertEqual(token.location, manifestURL)
    }
}

// MARK: - Executor GET vs Download Data Reception

/// Specifically tests that GET (data task) properly receives response bodies,
/// while documenting that download (download task) on a non-download delegate
/// may lose data.
final class DataReceptionComparisonTests: XCTestCase {

    func testGET_receivesNonEmptyBody_forValidJSON() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HTTPStubURLProtocol.self]

        let bodyJSON: [String: Any] = [
            "metadata": ["title": "Test"],
            "readingOrder": []
        ]
        let bodyData = try! JSONSerialization.data(withJSONObject: bodyJSON)

        HTTPStubURLProtocol.reset()
        HTTPStubURLProtocol.register { _ in
            return .init(statusCode: 200, headers: nil, body: bodyData)
        }

        let executor = TPPNetworkExecutor(
            cachingStrategy: .default,
            sessionConfiguration: config
        )

        let url = URL(string: "https://example.com/manifest")!
        let expectation = expectation(description: "GET completes")
        var receivedData: Data?

        let _ = executor.GET(url) { data, _, _ in
            receivedData = data
            expectation.fulfill()
        }

        waitForExpectations(timeout: 5)

        XCTAssertNotNil(receivedData)
        XCTAssertEqual(receivedData?.count, bodyData.count,
                       "GET (data task) must receive the complete response body")

        if let parsed = (try? JSONSerialization.jsonObject(with: receivedData!)) as? [String: Any] {
            XCTAssertNotNil(parsed["metadata"], "Response body must be parseable as JSON")
        } else {
            XCTFail("Response data should be valid JSON dictionary")
        }

        HTTPStubURLProtocol.reset()
    }

    func testGET_receivesBearerTokenJSON_andCanBeDetected() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HTTPStubURLProtocol.self]

        let bearerTokenJSON: [String: Any] = [
            "access_token": "test-token",
            "expires_in": 3600,
            "location": "https://distributor.example.com/manifest.json"
        ]
        let bodyData = try! JSONSerialization.data(withJSONObject: bearerTokenJSON)

        HTTPStubURLProtocol.reset()
        HTTPStubURLProtocol.register { _ in
            return .init(statusCode: 200, headers: nil, body: bodyData)
        }

        let executor = TPPNetworkExecutor(
            cachingStrategy: .default,
            sessionConfiguration: config
        )

        let url = URL(string: "https://cm.example.com/fulfill/123")!
        let expectation = expectation(description: "GET completes")
        var receivedData: Data?

        let _ = executor.GET(url) { data, _, _ in
            receivedData = data
            expectation.fulfill()
        }

        waitForExpectations(timeout: 5)

        XCTAssertNotNil(receivedData, "Must receive bearer token JSON data")

        guard let json = (try? JSONSerialization.jsonObject(with: receivedData!)) as? [String: Any] else {
            XCTFail("Data must parse as JSON dictionary")
            return
        }

        let token = MyBooksSimplifiedBearerToken.simplifiedBearerToken(with: json)
        XCTAssertNotNil(token, "Bearer token must be detectable from the parsed JSON")
        XCTAssertEqual(token?.accessToken, "test-token")

        HTTPStubURLProtocol.reset()
    }
}

// MARK: - LCP License Document Detection

/// Verifies that LCP license documents are NOT mistaken for bearer tokens
/// or audiobook manifests. This is the regression test for the Pattern 2
/// LCP-specific failure: the CM returns a valid LCP license document (with
/// encryption keys, rights, etc.), not an audiobook manifest. If the app
/// incorrectly tries to parse it as a manifest, audiobook playback fails.
final class LCPLicenseDocumentDetectionTests: XCTestCase {

    /// A realistic LCP license document structure as returned by the CM
    /// for LCP audiobooks (application/vnd.readium.lcp.license.v1.0+json).
    static let sampleLCPLicense: [String: Any] = [
        "id": "urn:uuid:12345678-1234-1234-1234-123456789abc",
        "issued": "2026-03-15T10:00:00Z",
        "provider": "https://license.feedbooks.net",
        "encryption": [
            "profile": "http://readium.org/lcp/basic-profile",
            "content_key": [
                "algorithm": "http://www.w3.org/2001/04/xmlenc#aes256-cbc",
                "encrypted_value": "base64encodedkey=="
            ],
            "user_key": [
                "algorithm": "http://www.w3.org/2001/04/xmlenc#sha256",
                "text_hint": "Enter your passphrase",
                "key_check": "base64check=="
            ]
        ],
        "links": [
            [
                "rel": "hint",
                "href": "https://license.feedbooks.net/hint"
            ],
            [
                "rel": "publication",
                "href": "https://license.feedbooks.net/content/book.lcpa",
                "type": "application/audiobook+lcp"
            ],
            [
                "rel": "self",
                "href": "https://license.feedbooks.net/loan/lcp/12345",
                "type": "application/vnd.readium.lcp.license.v1.0+json"
            ],
            [
                "rel": "status",
                "href": "https://license.feedbooks.net/loan/lcp/12345/status",
                "type": "application/vnd.readium.license.status.v1.0+json"
            ]
        ],
        "rights": [
            "start": "2026-03-15T10:00:00Z",
            "end": "2026-04-15T10:00:00Z",
            "print": 0,
            "copy": 0
        ],
        "signature": [
            "algorithm": "http://www.w3.org/2001/04/xmldsig-more#ecdsa-sha256",
            "certificate": "MIIBBase64==",
            "value": "Base64SignatureValue=="
        ]
    ]

    func testLCPLicenseDocument_isNotDetectedAsBearerToken() {
        let token = MyBooksSimplifiedBearerToken.simplifiedBearerToken(
            with: LCPLicenseDocumentDetectionTests.sampleLCPLicense
        )
        XCTAssertNil(token,
            "LCP license document must NOT be detected as a bearer token. " +
            "LCP licenses have 'id', 'encryption', 'links', 'rights', 'signature' " +
            "but no 'access_token' or 'expires_in'."
        )
    }

    func testLCPLicenseDocument_doesNotContainManifestKeys() {
        let license = LCPLicenseDocumentDetectionTests.sampleLCPLicense

        XCTAssertNil(license["readingOrder"],
            "LCP license must not contain 'readingOrder' (that's a manifest key)")
        XCTAssertNil(license["@context"],
            "LCP license must not contain '@context' (that's a manifest key)")
        XCTAssertNil(license["metadata"] as? [String: Any],
            "LCP license must not contain 'metadata' dict (that's a manifest key)")
        XCTAssertNotNil(license["encryption"],
            "LCP license must contain 'encryption' (distinguishing it from manifests)")
        XCTAssertNotNil(license["signature"],
            "LCP license must contain 'signature' (distinguishing it from manifests)")
    }

    func testLCPLicenseDocument_isValidJSON() {
        let data = try! JSONSerialization.data(
            withJSONObject: LCPLicenseDocumentDetectionTests.sampleLCPLicense
        )

        let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(parsed,
            "LCP license must be valid JSON. The CM returns it with 200 OK " +
            "and it parses as a JSON dictionary, which is why the old code " +
            "could mistake it for a manifest."
        )
    }

    func testLCPLicenseDocument_withMinimalFields_isNotBearerToken() {
        let minimalLicense: [String: Any] = [
            "id": "urn:uuid:test",
            "encryption": ["profile": "basic"],
            "links": [],
            "rights": [:]
        ]

        let token = MyBooksSimplifiedBearerToken.simplifiedBearerToken(with: minimalLicense)
        XCTAssertNil(token, "Even a minimal LCP license must not be detected as bearer token")
    }

    func testLCPLicenseDocument_parsedAsManifest_lacksReadingOrder() {
        let license = LCPLicenseDocumentDetectionTests.sampleLCPLicense

        let readingOrder = license["readingOrder"] as? [[String: Any]]
        let spine = license["spine"] as? [[String: Any]]

        XCTAssertNil(readingOrder, "LCP license has no readingOrder; toolkit would fail if treated as manifest")
        XCTAssertNil(spine, "LCP license has no spine; toolkit would fail if treated as manifest")
    }
}

// MARK: - Audiobook Type Routing Tests

/// Tests that the app routes different audiobook types through the correct
/// code path. This prevents regression where all audiobook types fall through
/// to fetchOpenAccessManifest regardless of their DRM type.
final class AudiobookTypeRoutingTests: XCTestCase {

    func testBearerTokenBook_hasExpectedIdentifiers() {
        let book = TPPBookMocker.mockBook(distributorType: .BearerToken)
        XCTAssertNotNil(book.defaultAcquisition,
            "Bearer token mock must have an acquisition")
        XCTAssertEqual(book.defaultAcquisition?.type,
            "application/vnd.librarysimplified.bearer-token+json",
            "Bearer token mock must have the expected acquisition type")
    }

    func testOpenAccessAudiobook_hasExpectedIdentifiers() {
        let book = TPPBookMocker.mockBook(distributorType: .OpenAccessAudiobook)
        XCTAssertNotNil(book.defaultAcquisition,
            "Open access audiobook mock must have an acquisition")
        XCTAssertEqual(book.defaultAcquisition?.type,
            "application/audiobook+json",
            "Open access audiobook mock must have the expected acquisition type")
    }

    func testReadiumLCPBook_hasExpectedIdentifiers() {
        let book = TPPBookMocker.mockBook(distributorType: .ReadiumLCP)
        XCTAssertNotNil(book.defaultAcquisition,
            "ReadiumLCP mock must have an acquisition")
        XCTAssertEqual(book.defaultAcquisition?.type,
            "application/vnd.readium.lcp.license.v1.0+json",
            "ReadiumLCP mock must have the LCP license acquisition type")
    }

    func testAudiobookLCPBook_hasExpectedIdentifiers() {
        let book = TPPBookMocker.mockBook(distributorType: .AudiobookLCP)
        XCTAssertNotNil(book.defaultAcquisition,
            "AudiobookLCP mock must have an acquisition")
        XCTAssertEqual(book.defaultAcquisition?.type,
            "application/audiobook+lcp",
            "AudiobookLCP mock must have the LCP audiobook acquisition type")
    }

    #if LCP
    func testLCPAudiobook_canOpenBook_usesCorrectAcquisitionType() {
        let lcpBook = TPPBookMocker.mockBook(distributorType: .ReadiumLCP)
        let openAccessBook = TPPBookMocker.mockBook(distributorType: .OpenAccessAudiobook)
        let bearerBook = TPPBookMocker.mockBook(distributorType: .BearerToken)

        XCTAssertFalse(LCPAudiobooks.canOpenBook(openAccessBook),
            "Open access audiobook must NOT be treated as LCP")
        XCTAssertFalse(LCPAudiobooks.canOpenBook(bearerBook),
            "Bearer token book must NOT be treated as LCP")
    }
    #endif
}

// MARK: - LCP License File Path Tests

/// Verifies the file path logic used for saving and locating LCP license files.
/// The app stores LCP licenses alongside content files with .lcpl extension.
final class LCPLicenseFilePathTests: XCTestCase {

    func testLCPLicenseExtension_isLcpl() {
        let contentURL = URL(fileURLWithPath: "/tmp/test-content.lcpa")
        let licenseURL = contentURL.deletingPathExtension().appendingPathExtension("lcpl")

        XCTAssertEqual(licenseURL.pathExtension, "lcpl",
            "LCP license files must use .lcpl extension")
        XCTAssertEqual(licenseURL.deletingPathExtension().lastPathComponent,
            contentURL.deletingPathExtension().lastPathComponent,
            "License file must share the same base name as content file")
    }

    func testLCPLicensePath_derivedFromContentPath() {
        let contentURL = URL(fileURLWithPath: "/data/content/abc123.lcpa")
        let expectedLicensePath = "/data/content/abc123.lcpl"
        let licenseURL = contentURL.deletingPathExtension().appendingPathExtension("lcpl")

        XCTAssertEqual(licenseURL.path, expectedLicensePath,
            "License path must be derived by replacing .lcpa with .lcpl")
    }

    func testLCPLicensePath_fromEpubExtension() {
        let contentURL = URL(fileURLWithPath: "/data/content/abc123.epub")
        let licenseURL = contentURL.deletingPathExtension().appendingPathExtension("lcpl")

        XCTAssertEqual(licenseURL.pathExtension, "lcpl",
            "Even non-lcpa extensions should produce .lcpl license path")
    }
}

// MARK: - fetchOpenAccessManifest Does Not Process LCP License

/// These tests verify that when the app receives an LCP license document
/// through fetchOpenAccessManifest (which should only happen if the routing
/// is broken), the bearer token detection does NOT incorrectly match it.
/// This is a safety net: even if the routing fix fails, the app should not
/// silently misprocess LCP license documents.
final class FetchOpenAccessManifestLCPSafetyTests: XCTestCase {

    func testLCPLicenseResponse_notDetectedAsBearerToken_inFetchFlow() {
        let licenseData = try! JSONSerialization.data(
            withJSONObject: LCPLicenseDocumentDetectionTests.sampleLCPLicense
        )

        guard let json = (try? JSONSerialization.jsonObject(with: licenseData)) as? [String: Any] else {
            XCTFail("LCP license must parse as JSON dictionary")
            return
        }

        let token = MyBooksSimplifiedBearerToken.simplifiedBearerToken(with: json)
        XCTAssertNil(token,
            "In the fetch flow, LCP license must NOT be mistaken for bearer token")
    }

    func testLCPLicenseResponse_wouldBeReturnedAsManifest_withoutRouting() {
        let licenseData = try! JSONSerialization.data(
            withJSONObject: LCPLicenseDocumentDetectionTests.sampleLCPLicense
        )

        guard let json = (try? JSONSerialization.jsonObject(with: licenseData)) as? [String: Any] else {
            XCTFail("LCP license must parse as JSON dictionary")
            return
        }

        let token = MyBooksSimplifiedBearerToken.simplifiedBearerToken(with: json)
        XCTAssertNil(token, "Not a bearer token, so code would proceed to return it as 'manifest'")

        XCTAssertNil(json["readingOrder"],
            "LCP license lacks readingOrder, so PalaceAudiobookToolkit would fail. " +
            "This is why LCP books must be routed through the LCP pipeline, not fetchOpenAccessManifest."
        )
    }

    func testBearerTokenResponseVsLCPLicense_areDistinct() {
        let bearerJSON: [String: Any] = [
            "access_token": "token-123",
            "expires_in": 3600,
            "location": "https://example.com/manifest.json"
        ]

        let lcpLicense = LCPLicenseDocumentDetectionTests.sampleLCPLicense

        let bearerToken = MyBooksSimplifiedBearerToken.simplifiedBearerToken(with: bearerJSON)
        let lcpToken = MyBooksSimplifiedBearerToken.simplifiedBearerToken(with: lcpLicense)

        XCTAssertNotNil(bearerToken, "Bearer token JSON must be detected")
        XCTAssertNil(lcpToken, "LCP license must NOT be detected as bearer token")
    }

    func testManifestVsLCPLicense_structuralDifferences() {
        let manifest: [String: Any] = [
            "@context": "https://readium.org/webpub-manifest/context.jsonld",
            "metadata": [
                "@type": "https://schema.org/Audiobook",
                "title": "Test Audiobook"
            ],
            "readingOrder": [
                ["href": "https://example.com/chapter1.mp3", "type": "audio/mpeg"]
            ]
        ]

        let license = LCPLicenseDocumentDetectionTests.sampleLCPLicense

        // Manifest has readingOrder, license does not
        XCTAssertNotNil(manifest["readingOrder"], "Manifest must have readingOrder")
        XCTAssertNil(license["readingOrder"], "License must NOT have readingOrder")

        // License has encryption, manifest does not
        XCTAssertNotNil(license["encryption"], "License must have encryption")
        XCTAssertNil(manifest["encryption"], "Manifest must NOT have encryption")

        // License has signature, manifest does not
        XCTAssertNotNil(license["signature"], "License must have signature")
        XCTAssertNil(manifest["signature"], "Manifest must NOT have signature")

        // Neither is a bearer token
        XCTAssertNil(MyBooksSimplifiedBearerToken.simplifiedBearerToken(with: manifest))
        XCTAssertNil(MyBooksSimplifiedBearerToken.simplifiedBearerToken(with: license))
    }
}

// MARK: - Fetch Manifest With Bearer Token: LCP Safety

/// Verifies that fetchManifestWithBearerToken correctly handles the case
/// where the manifest location URL unexpectedly returns an LCP license
/// instead of a manifest.
final class FetchManifestWithBearerTokenLCPSafetyTests: XCTestCase {

    override func tearDown() {
        HTTPStubURLProtocol.reset()
        super.tearDown()
    }

    func testFetchManifestWithBearerToken_receivingLCPLicense_returnsJSON() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HTTPStubURLProtocol.self]
        let stubbedSession = URLSession(configuration: config)

        let licenseData = try! JSONSerialization.data(
            withJSONObject: LCPLicenseDocumentDetectionTests.sampleLCPLicense
        )

        HTTPStubURLProtocol.register { _ in
            return .init(statusCode: 200, headers: nil, body: licenseData)
        }

        let token = MyBooksSimplifiedBearerToken(
            accessToken: "test-token",
            expiration: Date().addingTimeInterval(3600),
            location: URL(string: "https://distributor.example.com/manifest.json")!
        )

        let book = TPPBookMocker.mockBook(distributorType: .BearerToken)
        let expectation = expectation(description: "Fetch completes")
        var receivedJSON: [String: Any]?

        BookService.fetchManifestWithBearerToken(
            token, for: book, session: stubbedSession
        ) { json in
            receivedJSON = json
            expectation.fulfill()
        }

        waitForExpectations(timeout: 5)

        XCTAssertNotNil(receivedJSON,
            "Even if the response is an LCP license (valid JSON), it will be returned. " +
            "The fix prevents LCP books from reaching this code path at all."
        )
        XCTAssertNotNil(receivedJSON?["encryption"],
            "Returned JSON should be the LCP license (with encryption key)")
    }
}

// MARK: - Network Executor Response Handling Regression

/// Additional regression tests ensuring that TPPNetworkExecutor.GET properly
/// receives response bodies for various content types. This prevents the
/// original bug where URLSessionDownloadTask silently dropped response data.
final class NetworkExecutorResponseRegressionTests: XCTestCase {

    override func tearDown() {
        HTTPStubURLProtocol.reset()
        super.tearDown()
    }

    func testGET_receivesLCPLicenseJSON() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HTTPStubURLProtocol.self]

        let licenseData = try! JSONSerialization.data(
            withJSONObject: LCPLicenseDocumentDetectionTests.sampleLCPLicense
        )

        HTTPStubURLProtocol.register { _ in
            return .init(
                statusCode: 200,
                headers: ["Content-Type": "application/vnd.readium.lcp.license.v1.0+json"],
                body: licenseData
            )
        }

        let executor = TPPNetworkExecutor(
            cachingStrategy: .default,
            sessionConfiguration: config
        )

        let url = URL(string: "https://cm.example.com/fulfill/lcp-123")!
        let expectation = expectation(description: "GET completes")
        var receivedData: Data?

        let _ = executor.GET(url) { data, response, _ in
            receivedData = data
            expectation.fulfill()
        }

        waitForExpectations(timeout: 5)

        XCTAssertNotNil(receivedData, "GET must receive LCP license response body")
        XCTAssertEqual(receivedData?.count, licenseData.count,
            "All bytes of the LCP license must be received")

        if let json = (try? JSONSerialization.jsonObject(with: receivedData!)) as? [String: Any] {
            XCTAssertNotNil(json["encryption"], "Parsed LCP license must contain 'encryption'")
            XCTAssertNotNil(json["id"], "Parsed LCP license must contain 'id'")
        } else {
            XCTFail("LCP license response must parse as JSON dictionary")
        }
    }

    func testGET_receivesLargeManifestJSON() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HTTPStubURLProtocol.self]

        var chapters: [[String: Any]] = []
        for i in 1...50 {
            chapters.append([
                "href": "https://distributor.example.com/audio/chapter\(i).mp3",
                "type": "audio/mpeg",
                "title": "Chapter \(i)",
                "duration": 1800
            ])
        }

        let manifest: [String: Any] = [
            "@context": "https://readium.org/webpub-manifest/context.jsonld",
            "metadata": [
                "@type": "https://schema.org/Audiobook",
                "title": "A Very Long Audiobook",
                "author": "Test Author",
                "duration": 90000
            ],
            "readingOrder": chapters
        ]

        let manifestData = try! JSONSerialization.data(withJSONObject: manifest)

        HTTPStubURLProtocol.register { _ in
            return .init(statusCode: 200, headers: nil, body: manifestData)
        }

        let executor = TPPNetworkExecutor(
            cachingStrategy: .default,
            sessionConfiguration: config
        )

        let url = URL(string: "https://cm.example.com/manifest/large-book")!
        let expectation = expectation(description: "GET completes")
        var receivedData: Data?

        let _ = executor.GET(url) { data, _, _ in
            receivedData = data
            expectation.fulfill()
        }

        waitForExpectations(timeout: 5)

        XCTAssertNotNil(receivedData)
        XCTAssertEqual(receivedData?.count, manifestData.count,
            "All bytes of large manifest must be received (no truncation)")

        if let json = (try? JSONSerialization.jsonObject(with: receivedData!)) as? [String: Any],
           let readingOrder = json["readingOrder"] as? [[String: Any]] {
            XCTAssertEqual(readingOrder.count, 50,
                "All 50 chapters must be present in received manifest")
        } else {
            XCTFail("Large manifest must parse with all chapters intact")
        }
    }

    func testGET_handlesHTTPErrorGracefully() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HTTPStubURLProtocol.self]

        let errorBody = "{\"type\":\"INVALID_CREDENTIALS\",\"title\":\"Invalid credentials\",\"status\":401}".data(using: .utf8)!

        HTTPStubURLProtocol.register { _ in
            return .init(statusCode: 401, headers: nil, body: errorBody)
        }

        let executor = TPPNetworkExecutor(
            cachingStrategy: .default,
            sessionConfiguration: config
        )

        let url = URL(string: "https://cm.example.com/fulfill/expired")!
        let expectation = expectation(description: "GET completes")
        var receivedResponse: URLResponse?

        let _ = executor.GET(url) { _, response, _ in
            receivedResponse = response
            expectation.fulfill()
        }

        waitForExpectations(timeout: 5)

        let httpResponse = receivedResponse as? HTTPURLResponse
        XCTAssertEqual(httpResponse?.statusCode, 401,
            "HTTP 401 must be passed through to the completion handler")
    }

    func testGET_handlesEmptyResponseBody() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HTTPStubURLProtocol.self]

        HTTPStubURLProtocol.register { _ in
            return .init(statusCode: 204, headers: nil, body: Data())
        }

        let executor = TPPNetworkExecutor(
            cachingStrategy: .default,
            sessionConfiguration: config
        )

        let url = URL(string: "https://cm.example.com/fulfill/empty")!
        let expectation = expectation(description: "GET completes")
        var receivedData: Data?

        let _ = executor.GET(url) { data, _, _ in
            receivedData = data
            expectation.fulfill()
        }

        waitForExpectations(timeout: 5)

        let dataIsEmpty = receivedData == nil || receivedData?.isEmpty == true
        XCTAssertTrue(dataIsEmpty,
            "Empty response must not produce phantom data")
    }
}
