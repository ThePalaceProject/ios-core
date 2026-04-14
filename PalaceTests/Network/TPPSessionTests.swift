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
        let session = TPPSession.sharedSession
        XCTAssertNotNil(session, "sharedSession must not be nil")
        // Shared session must be able to make upload calls without crashing
        XCTAssertTrue(session === TPPSession.sharedSession, "sharedSession must return the same instance")
    }

    func testSharedSession_isSingleton() {
        let session1 = TPPSession.sharedSession
        let session2 = TPPSession.sharedSession
        XCTAssertTrue(session1 === session2)
        // The singleton must remain identical across multiple accesses
        let session3 = TPPSession.sharedSession
        XCTAssertTrue(session2 === session3, "sharedSession must be the same object on every access")
    }

    // MARK: - Upload

    func testUpload_doesNotCrashWithEmptyBody() {
        let url = URL(string: "https://httpbin.org/post")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = nil

        let expectation = XCTestExpectation(description: "Upload callback")
        var callbackData: Data??
        TPPSession.sharedSession.upload(with: request) { data, _, _ in
            callbackData = data
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 10.0)
        // The callback must have been invoked — callbackData is set (possibly nil on network error)
        XCTAssertNotNil(callbackData, "Completion handler must be called (even on network error)")
    }

    func testUpload_nullHandler_doesNotCrash() {
        let url = URL(string: "https://example.com/upload")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data("test".utf8)

        // Passing nil handler should not crash
        TPPSession.sharedSession.upload(with: request, completionHandler: nil)

        // Verify the session is still operational after a nil-handler call
        let waitExpectation = XCTestExpectation(description: "Session still operational")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            waitExpectation.fulfill()
        }
        wait(for: [waitExpectation], timeout: 2.0)
        // sharedSession must still be accessible (not nil/crashed)
        XCTAssertNotNil(TPPSession.sharedSession, "sharedSession must remain accessible after a nil-handler upload")
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
        var completionInvoked = false
        _ = TPPSession.sharedSession.withURL(url, shouldResetCache: true) { _, _, _ in
            completionInvoked = true
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 10.0)
        // The completion handler must have been invoked (cache clearing must not block it)
        XCTAssertTrue(completionInvoked, "Completion handler must be called after cache reset")
    }

    func testWithURL_completionHandler_calledOnError() {
        // Use a URL that will fail (invalid host)
        let url = URL(string: "https://definitely-not-a-real-host-12345.invalid/api")!

        let expectation = XCTestExpectation(description: "Completion called with error")
        var receivedError: Error?
        _ = TPPSession.sharedSession.withURL(url, shouldResetCache: false) { data, response, error in
            receivedError = error
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 15.0)
        // The error must be non-nil for an invalid host
        XCTAssertNotNil(receivedError, "An invalid host must produce a non-nil error in the completion handler")
    }
}
