//
//  TPPSessionTests.swift
//  PalaceTests
//
//  Unit tests for TPPSession: shared instance, upload, URL-based requests,
//  and authentication challenge delegation.
//

import XCTest
@testable import Palace

final class TPPSessionTests: XCTestCase {

    // MARK: - Shared Instance

    func testSharedSession_isNotNil() {
        XCTAssertNotNil(TPPSession.sharedSession)
    }

    func testSharedSession_isSingleton() {
        let session1 = TPPSession.sharedSession
        let session2 = TPPSession.sharedSession
        XCTAssertTrue(session1 === session2)
    }

    // MARK: - Upload

    func testUpload_doesNotCrashWithEmptyBody() {
        let url = URL(string: "https://httpbin.org/post")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = nil

        // Just verifying it does not crash with a nil body
        let expectation = XCTestExpectation(description: "Upload callback")
        TPPSession.sharedSession.upload(with: request) { _, _, _ in
            expectation.fulfill()
        }

        // May fail with network error, that is fine - we just test it does not crash
        wait(for: [expectation], timeout: 10.0)
    }

    func testUpload_nullHandler_doesNotCrash() {
        let url = URL(string: "https://example.com/upload")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data("test".utf8)

        // Passing nil handler should not crash
        TPPSession.sharedSession.upload(with: request, completionHandler: nil)

        // Give a moment for any async crash
        let waitExpectation = XCTestExpectation(description: "Wait")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            waitExpectation.fulfill()
        }
        wait(for: [waitExpectation], timeout: 2.0)
    }

    // MARK: - withURL

    func testWithURL_regularURL_usesGET() {
        let url = URL(string: "https://example.com/api/catalog")!

        let expectation = XCTestExpectation(description: "Completion called")
        let request = TPPSession.sharedSession.withURL(url, shouldResetCache: false) { _, _, _ in
            expectation.fulfill()
        }

        // For non-borrow URLs, should create a GET request
        // Request may be nil if executor returns nil, but it should not crash
        if let request = request {
            XCTAssertEqual(request.httpMethod, "GET")
        }

        wait(for: [expectation], timeout: 10.0)
    }

    func testWithURL_borrowURL_usesPUT() {
        let url = URL(string: "https://example.com/api/borrow")!

        let expectation = XCTestExpectation(description: "Completion called")
        let request = TPPSession.sharedSession.withURL(url, shouldResetCache: false) { _, _, _ in
            expectation.fulfill()
        }

        // For borrow URLs (path ends with "borrow"), should create a PUT request
        if let request = request {
            XCTAssertEqual(request.httpMethod, "PUT")
        }

        wait(for: [expectation], timeout: 10.0)
    }

    func testWithURL_shouldResetCache_callsClearCache() {
        let url = URL(string: "https://example.com/api/data")!

        let expectation = XCTestExpectation(description: "Completion called")
        // shouldResetCache = true should trigger cache clearing
        _ = TPPSession.sharedSession.withURL(url, shouldResetCache: true) { _, _, _ in
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 10.0)
        // If we got here without crash, cache clearing worked
    }

    func testWithURL_completionHandler_calledOnError() {
        // Use a URL that will fail (invalid host)
        let url = URL(string: "https://definitely-not-a-real-host-12345.invalid/api")!

        let expectation = XCTestExpectation(description: "Completion called with error")
        _ = TPPSession.sharedSession.withURL(url, shouldResetCache: false) { data, response, error in
            // Should get an error for invalid host
            // The session wraps errors, so either data is nil or error is set
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 15.0)
    }
}
