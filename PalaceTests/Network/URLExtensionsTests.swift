//
//  URLExtensionsTests.swift
//  PalaceTests
//
//  Tests for URL+Extensions.swift replacingScheme method
//

import XCTest
@testable import Palace

final class URLExtensionsTests: XCTestCase {

    // MARK: - replacingScheme Tests

    func testReplacingScheme_HttpToHttps_ReplacesScheme() {
        let url = URL(string: "http://example.com/path")!
        let result = url.replacingScheme(with: "https")

        XCTAssertEqual(result.scheme, "https")
        XCTAssertEqual(result.host, "example.com")
        XCTAssertEqual(result.path, "/path")
    }

    func testReplacingScheme_HttpsToHttp_ReplacesScheme() {
        let url = URL(string: "https://example.com/path?q=1")!
        let result = url.replacingScheme(with: "http")

        XCTAssertEqual(result.scheme, "http")
        XCTAssertEqual(result.query, "q=1")
    }

    func testReplacingScheme_ToCustomScheme_Works() {
        let url = URL(string: "https://example.com/book/123")!
        let result = url.replacingScheme(with: "palace")

        XCTAssertEqual(result.scheme, "palace")
        XCTAssertEqual(result.absoluteString, "palace://example.com/book/123")
    }

    func testReplacingScheme_PreservesFragment() {
        let url = URL(string: "https://example.com/page#section")!
        let result = url.replacingScheme(with: "http")

        XCTAssertEqual(result.fragment, "section")
    }

    func testReplacingScheme_PreservesPort() {
        let url = URL(string: "http://localhost:8080/api")!
        let result = url.replacingScheme(with: "https")

        XCTAssertEqual(result.port, 8080)
        XCTAssertEqual(result.scheme, "https")
    }

    func testReplacingScheme_PreservesUserInfo() {
        let url = URL(string: "http://user:pass@example.com/path")!
        let result = url.replacingScheme(with: "https")

        XCTAssertEqual(result.user, "user")
        XCTAssertEqual(result.password, "pass")
    }
}
