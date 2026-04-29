//
//  TPPCachingContractTests.swift
//  PalaceNetworkTests
//
//  Contract tests for TPPCaching + the HTTPURLResponse caching-headers
//  helpers. The hasSufficientCachingHeaders matrix matters — it gates
//  whether a response gets stored in URLCache, and a regression here
//  would silently disable caching across the app.
//

import XCTest
@testable import PalaceNetwork

final class TPPCachingContractTests: XCTestCase {

    // MARK: - makeURLSessionConfiguration

    func testMakeConfiguration_FallbackStrategy_HasNonNilURLCache() {
        let config = TPPCaching.makeURLSessionConfiguration(caching: .fallback,
                                                            requestTimeout: 30.0)
        XCTAssertNotNil(config.urlCache,
                        "Fallback strategy must produce a configuration with a urlCache attached, otherwise caching is silently disabled")
    }

    func testMakeConfiguration_DefaultStrategy_HasNonNilURLCache() {
        let config = TPPCaching.makeURLSessionConfiguration(caching: .default,
                                                            requestTimeout: 30.0)
        XCTAssertNotNil(config.urlCache,
                        ".default strategy must also have a urlCache (only .ephemeral skips it)")
    }

    func testMakeConfiguration_EphemeralStrategy_DiffersFromDefault() {
        let ephemeral = TPPCaching.makeURLSessionConfiguration(caching: .ephemeral,
                                                               requestTimeout: 30.0)
        let standard = TPPCaching.makeURLSessionConfiguration(caching: .default,
                                                              requestTimeout: 30.0)
        // The two strategies must produce structurally different configs:
        // .default sets httpMaximumConnectionsPerHost to 8 (per TPPCaching),
        // .ephemeral inherits the system default (typically 6 for ephemeral).
        XCTAssertNotEqual(ephemeral.httpMaximumConnectionsPerHost,
                          standard.httpMaximumConnectionsPerHost,
                          ".ephemeral and .default must produce structurally distinct configs")
        XCTAssertEqual(standard.httpMaximumConnectionsPerHost, 8,
                       ".default sets httpMaximumConnectionsPerHost to 8 (per TPPCaching)")
    }

    func testMakeConfiguration_RequestTimeoutPropagates() {
        let config = TPPCaching.makeURLSessionConfiguration(caching: .default,
                                                            requestTimeout: 17.0)
        XCTAssertEqual(config.timeoutIntervalForRequest, 17.0,
                       "Request timeout must propagate from arg to config")
        XCTAssertEqual(config.timeoutIntervalForResource, 34.0,
                       "Resource timeout must be 2x request timeout per documented contract")
    }

    func testMakeConfiguration_DefaultStrategy_HasMaxConnectionsPerHost8() {
        let config = TPPCaching.makeURLSessionConfiguration(caching: .default,
                                                            requestTimeout: 30.0)
        XCTAssertEqual(config.httpMaximumConnectionsPerHost, 8,
                       "httpMaximumConnectionsPerHost is documented as 8; lowering it silently throttles parallelism")
    }

    // MARK: - hasSufficientCachingHeaders matrix

    func testHasSufficientCachingHeaders_CacheControlPlusExpires_ReturnsTrue() {
        let response = makeResponse(headers: [
            "Cache-Control": "public, max-age=3600",
            "Expires": "Wed, 25 Mar 2020 01:23:45 GMT"
        ])
        XCTAssertTrue(response.hasSufficientCachingHeaders,
                      "Cache-Control + Expires is a documented sufficient pair")
    }

    func testHasSufficientCachingHeaders_CacheControlPlusLastModified_ReturnsTrue() {
        let response = makeResponse(headers: [
            "Cache-Control": "public, max-age=3600",
            "Last-Modified": "Wed, 25 Mar 2020 01:23:45 GMT"
        ])
        XCTAssertTrue(response.hasSufficientCachingHeaders)
    }

    func testHasSufficientCachingHeaders_ExpiresPlusLastModified_ReturnsTrue() {
        let response = makeResponse(headers: [
            "Expires": "Wed, 25 Mar 2020 01:23:45 GMT",
            "Last-Modified": "Wed, 24 Mar 2020 01:23:45 GMT"
        ])
        XCTAssertTrue(response.hasSufficientCachingHeaders)
    }

    func testHasSufficientCachingHeaders_ExpiresPlusETag_ReturnsTrue() {
        let response = makeResponse(headers: [
            "Expires": "Wed, 25 Mar 2020 01:23:45 GMT",
            "ETag": "\"abc123\""
        ])
        XCTAssertTrue(response.hasSufficientCachingHeaders)
    }

    func testHasSufficientCachingHeaders_LastModifiedPlusETag_ReturnsTrue() {
        let response = makeResponse(headers: [
            "Last-Modified": "Wed, 25 Mar 2020 01:23:45 GMT",
            "ETag": "\"abc123\""
        ])
        XCTAssertTrue(response.hasSufficientCachingHeaders)
    }

    func testHasSufficientCachingHeaders_CacheControlAlone_ReturnsFalse() {
        let response = makeResponse(headers: [
            "Cache-Control": "public, max-age=3600"
        ])
        XCTAssertFalse(response.hasSufficientCachingHeaders,
                       "Cache-Control alone is insufficient per the documented matrix")
    }

    func testHasSufficientCachingHeaders_NoHeaders_ReturnsFalse() {
        let response = makeResponse(headers: [:])
        XCTAssertFalse(response.hasSufficientCachingHeaders)
    }

    // MARK: - cacheControlMaxAge parsing

    func testCacheControlMaxAge_ParsesEqualsSeparator() {
        let response = makeResponse(headers: ["Cache-Control": "public, max-age=600"])
        XCTAssertEqual(response.cacheControlMaxAge, 600.0)
    }

    func testCacheControlMaxAge_NoCacheControl_ReturnsNil() {
        let response = makeResponse(headers: [:])
        XCTAssertNil(response.cacheControlMaxAge)
    }

    // MARK: - Helpers

    private func makeResponse(headers: [String: String]) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://example.com")!,
                        statusCode: 200,
                        httpVersion: "HTTP/1.1",
                        headerFields: headers)!
    }
}
