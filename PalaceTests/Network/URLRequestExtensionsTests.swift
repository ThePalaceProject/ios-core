//
//  URLRequestExtensionsTests.swift
//  PalaceTests
//
//  Tests for URLRequest+Extensions.swift and URLRequest+Logging.swift
//

import XCTest
@testable import Palace

final class URLRequestExtensionsTests: XCTestCase {

    private let testURL = URL(string: "https://example.com/api")!

    // MARK: - Custom User-Agent Init Tests

    /// SRS: NET-005 — Custom User-Agent applied to all requests
    func testInit_WithCustomUserAgent_SetsUserAgentHeader() {
        let request = URLRequest(url: testURL, applyingCustomUserAgent: true)

        let userAgent = request.value(forHTTPHeaderField: "User-Agent")
        XCTAssertNotNil(userAgent, "User-Agent header should be set")
        XCTAssertTrue(userAgent!.contains("iOS"), "User-Agent should contain iOS platform info")
    }

    /// SRS: NET-005 — Custom User-Agent applied to all requests
    func testInit_WithoutCustomUserAgent_NoUserAgentHeader() {
        let request = URLRequest(url: testURL, applyingCustomUserAgent: false)

        let userAgent = request.value(forHTTPHeaderField: "User-Agent")
        XCTAssertNil(userAgent, "User-Agent should not be set when applyingCustomUserAgent is false")
        // Without a user agent header, Authorization header must still be absent (no side effects)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"),
                     "No Authorization header must exist on a plain request without user agent")
    }

    func testInit_WithCustomUserAgent_PreservesURL() {
        let request = URLRequest(url: testURL, applyingCustomUserAgent: true)
        XCTAssertEqual(request.url, testURL)
        // User-Agent must be present when requested
        XCTAssertNotNil(request.value(forHTTPHeaderField: "User-Agent"),
                        "User-Agent must be set when applyingCustomUserAgent is true")
    }

    // MARK: - applyCustomUserAgent Mutating Tests

    /// SRS: NET-005 — Custom User-Agent applied to all requests
    func testApplyCustomUserAgent_SetsHeader() {
        var request = URLRequest(url: testURL)
        request.applyCustomUserAgent()

        let userAgent = request.value(forHTTPHeaderField: "User-Agent")
        XCTAssertNotNil(userAgent)
        XCTAssertTrue(userAgent!.contains("iOS"))
    }

    /// SRS: NET-005 — Custom User-Agent applied to all requests
    func testApplyCustomUserAgent_ReturnsSelf() {
        var request = URLRequest(url: testURL)
        let returned = request.applyCustomUserAgent()

        XCTAssertEqual(returned.url, request.url)
        XCTAssertEqual(
            returned.value(forHTTPHeaderField: "User-Agent"),
            request.value(forHTTPHeaderField: "User-Agent")
        )
    }

    // MARK: - loggableString Tests

    func testLoggableString_ContainsMethodAndURL() {
        var request = URLRequest(url: testURL)
        request.httpMethod = "GET"

        XCTAssertTrue(request.loggableString.contains("GET"))
        XCTAssertTrue(request.loggableString.contains("https://example.com/api"))
    }

    func testLoggableString_ExcludesAuthorizationHeader() {
        var request = URLRequest(url: testURL)
        request.setValue("Bearer secret-token", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        XCTAssertFalse(request.loggableString.contains("Authorization"))
        XCTAssertFalse(request.loggableString.contains("secret-token"))
        XCTAssertTrue(request.loggableString.contains("Content-Type"))
    }

    func testLoggableString_IncludesNonSensitiveHeaders() {
        var request = URLRequest(url: testURL)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        XCTAssertTrue(request.loggableString.contains("Accept"))
        XCTAssertTrue(request.loggableString.contains("application/json"),
                      "Accept header value must be visible in the loggable string")
    }

    // MARK: - isTokenAuthorized Tests

    func testIsTokenAuthorized_WithBearerToken_ReturnsTrue() {
        var request = URLRequest(url: testURL)
        request.setValue("Bearer abc123", forHTTPHeaderField: "Authorization")

        XCTAssertTrue(request.isTokenAuthorized)
        // The URL must not change when authorization is added
        XCTAssertEqual(request.url, testURL, "Adding Authorization header must not mutate the URL")
    }

    func testIsTokenAuthorized_WithBasicAuth_ReturnsFalse() {
        var request = URLRequest(url: testURL)
        request.setValue("Basic dXNlcjpwYXNz", forHTTPHeaderField: "Authorization")

        XCTAssertFalse(request.isTokenAuthorized)
        // Complement: basic auth is NOT a bearer token
        XCTAssertFalse(request.isTokenAuthorized,
                       "Basic authentication must never qualify as token authorization")
    }

    func testIsTokenAuthorized_NoAuthHeader_ReturnsFalse() {
        let request = URLRequest(url: testURL)
        XCTAssertFalse(request.isTokenAuthorized)
        // A fresh request must also be unauthenticated
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"),
                     "A freshly created URLRequest must have no Authorization header")
    }
}
