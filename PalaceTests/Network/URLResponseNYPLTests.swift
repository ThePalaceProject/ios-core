//
//  URLResponseNYPLTests.swift
//  PalaceTests
//
//  Tests for URLResponse+NYPL.swift (isProblemDocument, isSuccess)
//

import XCTest
@testable import Palace

final class URLResponseNYPLTests: XCTestCase {

    private let testURL = URL(string: "https://example.com/api")!

    // MARK: - isProblemDocument Tests

    func testIsProblemDocument_WithProblemJsonMime_ReturnsTrue() {
        let response = URLResponse(
            url: testURL,
            mimeType: "application/problem+json",
            expectedContentLength: 0,
            textEncodingName: nil
        )
        XCTAssertTrue(response.isProblemDocument())
    }

    func testIsProblemDocument_WithApiProblemJsonMime_ReturnsTrue() {
        let response = URLResponse(
            url: testURL,
            mimeType: "application/api-problem+json",
            expectedContentLength: 0,
            textEncodingName: nil
        )
        XCTAssertTrue(response.isProblemDocument())
        // Verify both problem MIME types are treated the same way
        let standardProblem = URLResponse(
            url: testURL, mimeType: "application/problem+json",
            expectedContentLength: 0, textEncodingName: nil
        )
        XCTAssertEqual(response.isProblemDocument(), standardProblem.isProblemDocument(),
                       "Both problem+json and api-problem+json must be detected as problem documents")
    }

    func testIsProblemDocument_WithRegularJsonMime_ReturnsFalse() {
        let response = URLResponse(
            url: testURL,
            mimeType: "application/json",
            expectedContentLength: 0,
            textEncodingName: nil
        )
        XCTAssertFalse(response.isProblemDocument())
        // Regular JSON must not be mistaken for a problem document
        XCTAssertNotEqual(response.mimeType, "application/problem+json",
                          "application/json is not the same MIME as application/problem+json")
    }

    func testIsProblemDocument_WithNilMime_ReturnsFalse() {
        let response = URLResponse(
            url: testURL,
            mimeType: nil,
            expectedContentLength: 0,
            textEncodingName: nil
        )
        XCTAssertFalse(response.isProblemDocument())
        XCTAssertNil(response.mimeType, "Sanity check: response must have nil mimeType")
        // Calling again must be idempotent — no state mutation
        XCTAssertFalse(response.isProblemDocument(),
                       "Repeated calls with nil MIME must consistently return false")
    }

    func testIsProblemDocument_WithHtmlMime_ReturnsFalse() {
        let response = URLResponse(
            url: testURL,
            mimeType: "text/html",
            expectedContentLength: 0,
            textEncodingName: nil
        )
        XCTAssertFalse(response.isProblemDocument())
        // HTML error pages (e.g. 503 maintenance pages) must NOT be treated as OPDS problem docs
        XCTAssertFalse(response.mimeType?.contains("problem") ?? false,
                       "text/html must not contain 'problem' in its MIME type")
    }

    // MARK: - HTTPURLResponse isSuccess Tests

    func testIsSuccess_200_ReturnsTrue() {
        let response = HTTPURLResponse(
            url: testURL, statusCode: 200, httpVersion: nil, headerFields: nil
        )!
        XCTAssertTrue(response.isSuccess())
    }

    func testIsSuccess_201Created_ReturnsTrue() {
        let response = HTTPURLResponse(
            url: testURL, statusCode: 201, httpVersion: nil, headerFields: nil
        )!
        XCTAssertTrue(response.isSuccess())
        // 201 is a 2xx status — must match the broader success range
        XCTAssertEqual(response.statusCode / 100, 2,
                       "201 must be in the 2xx success range")
    }

    func testIsSuccess_204NoContent_ReturnsTrue() {
        let response = HTTPURLResponse(
            url: testURL, statusCode: 204, httpVersion: nil, headerFields: nil
        )!
        XCTAssertTrue(response.isSuccess())
        // 204 is commonly used for DELETE and PUT responses — must be treated as success
        XCTAssertEqual(response.statusCode, 204,
                       "Status code must be exactly 204 No Content")
        XCTAssertEqual(response.statusCode / 100, 2,
                       "204 must be in the 2xx success range")
    }

    func testIsSuccess_299_ReturnsTrue() {
        let response = HTTPURLResponse(
            url: testURL, statusCode: 299, httpVersion: nil, headerFields: nil
        )!
        XCTAssertTrue(response.isSuccess())
        // 299 is the upper boundary of the 2xx range — must still be success
        let nextCode = HTTPURLResponse(url: testURL, statusCode: 300, httpVersion: nil, headerFields: nil)!
        XCTAssertFalse(nextCode.isSuccess(),
                       "300 (one above 299) must NOT be success — boundary must be enforced")
    }

    func testIsSuccess_300Redirect_ReturnsFalse() {
        let response = HTTPURLResponse(
            url: testURL, statusCode: 300, httpVersion: nil, headerFields: nil
        )!
        XCTAssertFalse(response.isSuccess())
    }

    func testIsSuccess_400BadRequest_ReturnsFalse() {
        let response = HTTPURLResponse(
            url: testURL, statusCode: 400, httpVersion: nil, headerFields: nil
        )!
        XCTAssertFalse(response.isSuccess())
        // 400 is the start of 4xx client errors — must not be treated as success
        XCTAssertEqual(response.statusCode / 100, 4,
                       "400 must be in the 4xx client error range")
        // 399 (just below 400) should be a failure boundary too
        let belowSuccess = HTTPURLResponse(url: testURL, statusCode: 399, httpVersion: nil, headerFields: nil)!
        XCTAssertFalse(belowSuccess.isSuccess(),
                       "399 (3xx redirect) must also not be success")
    }

    func testIsSuccess_401Unauthorized_ReturnsFalse() {
        let response = HTTPURLResponse(
            url: testURL, statusCode: 401, httpVersion: nil, headerFields: nil
        )!
        XCTAssertFalse(response.isSuccess())
        // 401 is distinct from 403 — both must be failures
        let forbidden = HTTPURLResponse(url: testURL, statusCode: 403, httpVersion: nil, headerFields: nil)!
        XCTAssertFalse(forbidden.isSuccess(),
                       "403 Forbidden must also not be success")
        XCTAssertNotEqual(response.statusCode, forbidden.statusCode,
                          "401 and 403 must be distinct status codes")
    }

    func testIsSuccess_500ServerError_ReturnsFalse() {
        let response = HTTPURLResponse(
            url: testURL, statusCode: 500, httpVersion: nil, headerFields: nil
        )!
        XCTAssertFalse(response.isSuccess())
        // 5xx errors are server failures — clearly not success
        XCTAssertEqual(response.statusCode / 100, 5,
                       "500 must be in the 5xx server error range")
        // 503 Service Unavailable is equally a failure
        let serviceUnavailable = HTTPURLResponse(url: testURL, statusCode: 503, httpVersion: nil, headerFields: nil)!
        XCTAssertFalse(serviceUnavailable.isSuccess(),
                       "503 Service Unavailable must also not be success")
    }

    func testIsSuccess_199_ReturnsFalse() {
        let response = HTTPURLResponse(
            url: testURL, statusCode: 199, httpVersion: nil, headerFields: nil
        )!
        XCTAssertFalse(response.isSuccess())
        // 199 is the upper boundary of 1xx informational — must not be success
        let lowerBound = HTTPURLResponse(url: testURL, statusCode: 200, httpVersion: nil, headerFields: nil)!
        XCTAssertTrue(lowerBound.isSuccess(),
                      "200 (one above 199) must be the start of the success range")
    }
}
