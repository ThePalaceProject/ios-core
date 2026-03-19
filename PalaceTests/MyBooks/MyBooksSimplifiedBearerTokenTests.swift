//
//  MyBooksSimplifiedBearerTokenTests.swift
//  PalaceTests
//
//  Tests for MyBooksSimplifiedBearerToken: parsing, expiry, fulfill URL storage,
//  and token refresh from a CM fulfill URL.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class MyBooksSimplifiedBearerTokenTests: XCTestCase {

    override func setUp() {
        super.setUp()
        HTTPStubURLProtocol.reset()
    }

    override func tearDown() {
        HTTPStubURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Parsing

    func testParsing_validDictionary_createsToken() {
        let dict: [String: Any] = [
            "access_token": "abc123",
            "expires_in": 3600,
            "location": "https://distributor.example.com/content/book.mp3"
        ]

        let token = MyBooksSimplifiedBearerToken.simplifiedBearerToken(with: dict)

        XCTAssertNotNil(token)
        XCTAssertEqual(token?.accessToken, "abc123")
        XCTAssertEqual(token?.location.absoluteString, "https://distributor.example.com/content/book.mp3")
        XCTAssertNil(token?.fulfillURL, "fulfillURL should not be set by the parser")
    }

    func testParsing_acceptsExpirationKey() {
        let dict: [String: Any] = [
            "access_token": "tok",
            "expiration": 7200,
            "location": "https://example.com/book"
        ]

        let token = MyBooksSimplifiedBearerToken.simplifiedBearerToken(with: dict)

        XCTAssertNotNil(token, "Should accept 'expiration' as an alternative to 'expires_in'")
    }

    func testParsing_missingAccessToken_returnsNil() {
        let dict: [String: Any] = [
            "expires_in": 3600,
            "location": "https://example.com/book"
        ]

        XCTAssertNil(MyBooksSimplifiedBearerToken.simplifiedBearerToken(with: dict))
    }

    func testParsing_missingLocation_returnsNil() {
        let dict: [String: Any] = [
            "access_token": "tok",
            "expires_in": 3600
        ]

        XCTAssertNil(MyBooksSimplifiedBearerToken.simplifiedBearerToken(with: dict))
    }

    func testParsing_missingExpiration_returnsNil() {
        let dict: [String: Any] = [
            "access_token": "tok",
            "location": "https://example.com/book"
        ]

        XCTAssertNil(MyBooksSimplifiedBearerToken.simplifiedBearerToken(with: dict))
    }

    func testParsing_invalidLocationURL_returnsNil() {
        let dict: [String: Any] = [
            "access_token": "tok",
            "expires_in": 3600,
            "location": ""
        ]

        XCTAssertNil(MyBooksSimplifiedBearerToken.simplifiedBearerToken(with: dict))
    }

    func testParsing_zeroExpiration_usesDistantFuture() {
        let dict: [String: Any] = [
            "access_token": "tok",
            "expires_in": 0,
            "location": "https://example.com/book"
        ]

        let token = MyBooksSimplifiedBearerToken.simplifiedBearerToken(with: dict)

        XCTAssertNotNil(token)
        XCTAssertGreaterThan(
            token!.expiration.timeIntervalSinceNow,
            86400 * 365,
            "Zero expiration should result in distant future"
        )
    }

    func testParsing_negativeExpiration_usesDistantFuture() {
        let dict: [String: Any] = [
            "access_token": "tok",
            "expires_in": -1,
            "location": "https://example.com/book"
        ]

        let token = MyBooksSimplifiedBearerToken.simplifiedBearerToken(with: dict)

        XCTAssertNotNil(token)
        XCTAssertGreaterThan(
            token!.expiration.timeIntervalSinceNow,
            86400 * 365,
            "Negative expiration should result in distant future"
        )
    }

    // MARK: - isExpired

    func testIsExpired_futureExpiration_returnsFalse() {
        let token = MyBooksSimplifiedBearerToken(
            accessToken: "tok",
            expiration: Date(timeIntervalSinceNow: 3600),
            location: URL(string: "https://example.com")!
        )

        XCTAssertFalse(token.isExpired)
    }

    func testIsExpired_pastExpiration_returnsTrue() {
        let token = MyBooksSimplifiedBearerToken(
            accessToken: "tok",
            expiration: Date(timeIntervalSinceNow: -1),
            location: URL(string: "https://example.com")!
        )

        XCTAssertTrue(token.isExpired)
    }

    func testIsExpired_exactlyNow_returnsTrue() {
        let token = MyBooksSimplifiedBearerToken(
            accessToken: "tok",
            expiration: Date(),
            location: URL(string: "https://example.com")!
        )

        XCTAssertTrue(token.isExpired, "Token expiring at exactly now should be considered expired")
    }

    // MARK: - fulfillURL

    func testFulfillURL_defaultsToNil() {
        let token = MyBooksSimplifiedBearerToken(
            accessToken: "tok",
            expiration: Date(),
            location: URL(string: "https://example.com")!
        )

        XCTAssertNil(token.fulfillURL)
    }

    func testFulfillURL_canBeSetViaInit() {
        let url = URL(string: "https://cm.example.com/fulfill/123")!
        let token = MyBooksSimplifiedBearerToken(
            accessToken: "tok",
            expiration: Date(),
            location: URL(string: "https://example.com")!,
            fulfillURL: url
        )

        XCTAssertEqual(token.fulfillURL, url)
    }

    func testFulfillURL_canBeSetAfterInit() {
        let token = MyBooksSimplifiedBearerToken(
            accessToken: "tok",
            expiration: Date(),
            location: URL(string: "https://example.com")!
        )

        let url = URL(string: "https://cm.example.com/fulfill/456")!
        token.fulfillURL = url

        XCTAssertEqual(token.fulfillURL, url)
    }

    // MARK: - Token Refresh (network stubbed)

    func testRefreshToken_success_returnsNewToken() {
        let fulfillURL = URL(string: "https://cm.example.com/fulfill/book-123")!

        let tokenJSON: [String: Any] = [
            "access_token": "new-token-xyz",
            "expires_in": 1800,
            "location": "https://distributor.example.com/content/book.mp3"
        ]
        let responseData = try! JSONSerialization.data(withJSONObject: tokenJSON)

        URLProtocol.registerClass(HTTPStubURLProtocol.self)
        HTTPStubURLProtocol.reset()
        HTTPStubURLProtocol.register { request in
            guard request.url == fulfillURL else { return nil }
            return .init(statusCode: 200, headers: nil, body: responseData)
        }

        let expectation = expectation(description: "Token refresh completes")

        MyBooksSimplifiedBearerToken.refreshToken(from: fulfillURL) { token in
            XCTAssertNotNil(token)
            XCTAssertEqual(token?.accessToken, "new-token-xyz")
            XCTAssertEqual(token?.fulfillURL, fulfillURL, "Refreshed token should retain the fulfill URL")
            XCTAssertEqual(token?.location.absoluteString, "https://distributor.example.com/content/book.mp3")
            XCTAssertFalse(token?.isExpired ?? true)
            expectation.fulfill()
        }

        waitForExpectations(timeout: 5)
        HTTPStubURLProtocol.reset()
        URLProtocol.unregisterClass(HTTPStubURLProtocol.self)
    }

    func testRefreshToken_serverError_returnsNil() {
        let fulfillURL = URL(string: "https://cm.example.com/fulfill/book-456")!

        URLProtocol.registerClass(HTTPStubURLProtocol.self)
        HTTPStubURLProtocol.reset()
        HTTPStubURLProtocol.register { request in
            guard request.url == fulfillURL else { return nil }
            return .init(statusCode: 500, headers: nil, body: nil)
        }

        let expectation = expectation(description: "Token refresh fails gracefully")

        MyBooksSimplifiedBearerToken.refreshToken(from: fulfillURL) { token in
            XCTAssertNil(token)
            expectation.fulfill()
        }

        waitForExpectations(timeout: 5)
        HTTPStubURLProtocol.reset()
        URLProtocol.unregisterClass(HTTPStubURLProtocol.self)
    }

    func testRefreshToken_invalidJSON_returnsNil() {
        let fulfillURL = URL(string: "https://cm.example.com/fulfill/book-789")!
        let invalidData = "not json".data(using: .utf8)!

        URLProtocol.registerClass(HTTPStubURLProtocol.self)
        HTTPStubURLProtocol.reset()
        HTTPStubURLProtocol.register { request in
            guard request.url == fulfillURL else { return nil }
            return .init(statusCode: 200, headers: nil, body: invalidData)
        }

        let expectation = expectation(description: "Token refresh fails on bad JSON")

        MyBooksSimplifiedBearerToken.refreshToken(from: fulfillURL) { token in
            XCTAssertNil(token)
            expectation.fulfill()
        }

        waitForExpectations(timeout: 5)
        HTTPStubURLProtocol.reset()
        URLProtocol.unregisterClass(HTTPStubURLProtocol.self)
    }
}
