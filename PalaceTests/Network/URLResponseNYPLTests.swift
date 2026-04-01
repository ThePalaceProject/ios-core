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
    }

    func testIsProblemDocument_WithRegularJsonMime_ReturnsFalse() {
        let response = URLResponse(
            url: testURL,
            mimeType: "application/json",
            expectedContentLength: 0,
            textEncodingName: nil
        )
        XCTAssertFalse(response.isProblemDocument())
    }

    func testIsProblemDocument_WithNilMime_ReturnsFalse() {
        let response = URLResponse(
            url: testURL,
            mimeType: nil,
            expectedContentLength: 0,
            textEncodingName: nil
        )
        XCTAssertFalse(response.isProblemDocument())
    }

    func testIsProblemDocument_WithHtmlMime_ReturnsFalse() {
        let response = URLResponse(
            url: testURL,
            mimeType: "text/html",
            expectedContentLength: 0,
            textEncodingName: nil
        )
        XCTAssertFalse(response.isProblemDocument())
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
    }

    func testIsSuccess_204NoContent_ReturnsTrue() {
        let response = HTTPURLResponse(
            url: testURL, statusCode: 204, httpVersion: nil, headerFields: nil
        )!
        XCTAssertTrue(response.isSuccess())
    }

    func testIsSuccess_299_ReturnsTrue() {
        let response = HTTPURLResponse(
            url: testURL, statusCode: 299, httpVersion: nil, headerFields: nil
        )!
        XCTAssertTrue(response.isSuccess())
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
    }

    func testIsSuccess_401Unauthorized_ReturnsFalse() {
        let response = HTTPURLResponse(
            url: testURL, statusCode: 401, httpVersion: nil, headerFields: nil
        )!
        XCTAssertFalse(response.isSuccess())
    }

    func testIsSuccess_500ServerError_ReturnsFalse() {
        let response = HTTPURLResponse(
            url: testURL, statusCode: 500, httpVersion: nil, headerFields: nil
        )!
        XCTAssertFalse(response.isSuccess())
    }

    func testIsSuccess_199_ReturnsFalse() {
        let response = HTTPURLResponse(
            url: testURL, statusCode: 199, httpVersion: nil, headerFields: nil
        )!
        XCTAssertFalse(response.isSuccess())
    }
}
