//
//  URLRequestNYPLAdditionsTests.swift
//  PalaceTests
//
//  Unit tests for NSURLRequest+NYPLURLRequestAdditions.swift:
//  problem document POST and multipart form POST.
//

import XCTest
@testable import Palace

final class URLRequestNYPLAdditionsTests: XCTestCase {

    private let testURL = URL(string: "https://example.com/api/report")!

    // MARK: - postRequest(withProblemDocument:url:)

    func testPostProblemDocument_producesCompliantProblemJSONRequest() {
        let problemDoc: NSDictionary = ["type": "about:blank", "title": "Error", "status": 400]

        let request = NSURLRequest.postRequest(withProblemDocument: problemDoc, url: testURL)

        XCTAssertEqual(request.httpMethod, "POST",
                       "problem document must be POSTed")
        XCTAssertEqual(request.url, testURL,
                       "request URL must match the caller's URL verbatim")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"),
                       "application/problem+json",
                       "content-type must conform to RFC 7807 (application/problem+json)")
    }

    func testPostProblemDocument_setsBody() {
        let problemDoc: NSDictionary = [
            "type": "http://example.com/error",
            "title": "Not Found",
            "status": 404,
            "detail": "The requested resource was not found"
        ]

        let request = NSURLRequest.postRequest(withProblemDocument: problemDoc, url: testURL)

        XCTAssertNotNil(request.httpBody)
        if let bodyData = request.httpBody {
            let decoded = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any]
            XCTAssertNotNil(decoded)
            XCTAssertEqual(decoded?["title"] as? String, "Not Found")
            XCTAssertEqual(decoded?["status"] as? Int, 404)
        }
    }

    func testPostProblemDocument_setsContentLength() {
        let problemDoc: NSDictionary = ["type": "about:blank", "title": "Error"]

        let request = NSURLRequest.postRequest(withProblemDocument: problemDoc, url: testURL)

        let contentLength = request.value(forHTTPHeaderField: "Content-Length")
        XCTAssertNotNil(contentLength)
        if let length = Int(contentLength ?? ""), let body = request.httpBody {
            XCTAssertEqual(length, body.count)
        }
    }

    func testPostProblemDocument_usesTransportDefaultsForReporting() {
        // Reports must bypass the cache (fresh network pass), not share cookies
        // (error reports are diagnostic, not a user session), and time out in
        // 30 seconds so a stalled endpoint can't wedge the caller.
        let problemDoc: NSDictionary = ["type": "about:blank"]

        let request = NSURLRequest.postRequest(withProblemDocument: problemDoc, url: testURL)

        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertEqual(request.timeoutInterval, 30)
    }

    // MARK: - postRequest(withParams:imageOrNil:url:)

    func testPostParams_producesMultipartFormPOSTRequest() {
        let params: NSDictionary = ["key": "value"]

        let request = NSURLRequest.postRequest(withParams: params, imageOrNil: nil, url: testURL)

        XCTAssertEqual(request.httpMethod, "POST",
                       "multipart params must be POSTed")
        XCTAssertEqual(request.url, testURL,
                       "request URL must match the caller's URL verbatim")
        let contentType = request.value(forHTTPHeaderField: "Content-Type") ?? ""
        XCTAssertTrue(contentType.contains("multipart/form-data"),
                      "content-type must be multipart/form-data, got: '\(contentType)'")
        XCTAssertTrue(contentType.contains("boundary="),
                      "multipart content-type must declare a boundary, got: '\(contentType)'")
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData,
                       "multipart POST must bypass the cache (fresh upload, not replay)")
    }

    func testPostParams_bodyContainsParams() {
        let params: NSDictionary = ["username": "testuser", "message": "hello"]

        let request = NSURLRequest.postRequest(withParams: params, imageOrNil: nil, url: testURL)

        XCTAssertNotNil(request.httpBody)
        if let bodyString = String(data: request.httpBody! as Data, encoding: .utf8) {
            XCTAssertTrue(bodyString.contains("username"))
            XCTAssertTrue(bodyString.contains("testuser"))
            XCTAssertTrue(bodyString.contains("message"))
            XCTAssertTrue(bodyString.contains("hello"))
        }
    }

    func testPostParams_withImage_bodyContainsImageData() {
        let params: NSDictionary = ["title": "photo"]

        // Create a small test image
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10))
        let testImage = renderer.image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        }

        let request = NSURLRequest.postRequest(withParams: params, imageOrNil: testImage, url: testURL)

        XCTAssertNotNil(request.httpBody)
        let bodyData = request.httpBody! as Data
        // With image, body should be larger
        XCTAssertGreaterThan(bodyData.count, 100, "Body should contain image data")

        if let bodyString = String(data: bodyData, encoding: .utf8) {
            XCTAssertTrue(bodyString.contains("image.jpg"))
            XCTAssertTrue(bodyString.contains("image/jpeg"))
        }
    }

    func testPostParams_withNilImage_bodyLacksImageSection() {
        let params: NSDictionary = ["key": "value"]

        let request = NSURLRequest.postRequest(withParams: params, imageOrNil: nil, url: testURL)

        if let bodyString = String(data: request.httpBody! as Data, encoding: .utf8) {
            XCTAssertFalse(bodyString.contains("image.jpg"))
            XCTAssertFalse(bodyString.contains("image/jpeg"))
        }
    }

    func testPostParams_setsContentLength() {
        let params: NSDictionary = ["key": "value"]

        let request = NSURLRequest.postRequest(withParams: params, imageOrNil: nil, url: testURL)

        let contentLength = request.value(forHTTPHeaderField: "Content-Length")
        XCTAssertNotNil(contentLength)
        if let length = Int(contentLength ?? ""), let body = request.httpBody {
            XCTAssertEqual(length, body.count)
        }
    }

    func testPostParams_emptyParams_doesNotCrash() {
        let params: NSDictionary = [:]

        let request = NSURLRequest.postRequest(withParams: params, imageOrNil: nil, url: testURL)

        XCTAssertNotNil(request.httpBody)
        XCTAssertEqual(request.httpMethod, "POST")
    }

    // MARK: - Multipart Boundary

    func testPostParams_boundaryConsistencyBetweenHeaderAndBody() {
        let params: NSDictionary = ["field": "value"]

        let request = NSURLRequest.postRequest(withParams: params, imageOrNil: nil, url: testURL)

        let contentType = request.value(forHTTPHeaderField: "Content-Type") ?? ""
        // Extract boundary from Content-Type header
        let boundaryPrefix = "boundary="
        guard let range = contentType.range(of: boundaryPrefix) else {
            XCTFail("Content-Type should contain boundary")
            return
        }
        let boundary = String(contentType[range.upperBound...])

        // Verify the body contains this boundary
        if let bodyString = String(data: request.httpBody! as Data, encoding: .utf8) {
            XCTAssertTrue(bodyString.contains(boundary), "Body should use the same boundary as header")
        }
    }
}
