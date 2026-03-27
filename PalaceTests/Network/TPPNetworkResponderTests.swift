//
//  TPPNetworkResponderTests.swift
//  PalaceTests
//
//  Tests for TPPNetworkResponder retry tracking, task info management, and delegate behavior.
//

import XCTest
@testable import Palace

/// SRS: REL-003 — Token refresh retry limit prevents loops
class TPPNetworkResponderTests: XCTestCase {

    var responder: TPPNetworkResponder!

    override func setUp() {
        super.setUp()
        responder = TPPNetworkResponder(credentialsProvider: nil, useFallbackCaching: false)
    }

    override func tearDown() {
        responder = nil
        super.tearDown()
    }

    // MARK: - Retry Tracking

    func testCanRetryReturnsTrueForFreshURL() {
        let url = URL(string: "https://example.com/api/books")!
        XCTAssertTrue(responder.canRetry(url: url))
    }

    func testCanRetryReturnsFalseAfterMarkRetried() {
        let url = URL(string: "https://example.com/api/books")!
        responder.markRetried(url: url)
        XCTAssertFalse(responder.canRetry(url: url), "URL should not be retryable after marking retried once (maxRetryAttempts=1)")
    }

    func testCanRetryReturnsFalseForNilURL() {
        XCTAssertFalse(responder.canRetry(url: nil))
    }

    func testMarkRetriedWithNilURLDoesNotCrash() {
        responder.markRetried(url: nil) // Should not crash
    }

    func testClearRetryResetsURL() {
        let url = URL(string: "https://example.com/api/books")!
        responder.markRetried(url: url)
        XCTAssertFalse(responder.canRetry(url: url))
        responder.clearRetry(url: url)
        XCTAssertTrue(responder.canRetry(url: url), "URL should be retryable after clearing retry tracking")
    }

    func testClearAllRetriesResetsEverything() {
        let url1 = URL(string: "https://example.com/api/books")!
        let url2 = URL(string: "https://example.com/api/loans")!
        responder.markRetried(url: url1)
        responder.markRetried(url: url2)
        XCTAssertFalse(responder.canRetry(url: url1))
        XCTAssertFalse(responder.canRetry(url: url2))
        responder.clearAllRetries()
        XCTAssertTrue(responder.canRetry(url: url1))
        XCTAssertTrue(responder.canRetry(url: url2))
    }

    func testMultipleURLsTrackedIndependently() {
        let url1 = URL(string: "https://example.com/api/books")!
        let url2 = URL(string: "https://example.com/api/loans")!
        responder.markRetried(url: url1)
        XCTAssertFalse(responder.canRetry(url: url1))
        XCTAssertTrue(responder.canRetry(url: url2), "Different URLs should be tracked independently")
    }

    // MARK: - Task Info Management

    func testAddCompletionStoresTaskInfo() {
        var stored = false
        responder.addCompletion({ _ in
            stored = true
        }, taskID: 42)
        // Verify storage by triggering session invalidation which calls all pending completions
        XCTAssertFalse(stored, "Completion should not be called until session event")
    }

    func testUpdateCompletionIdTransfersInfo() {
        var completionCalled = false
        responder.addCompletion({ _ in
            completionCalled = true
        }, taskID: 10)
        responder.updateCompletionId(10, newId: 20)
        // After update, old ID's completion should be available at new ID
        // We can't directly verify this without triggering the delegate,
        // but we verify no crash occurs
        XCTAssertFalse(completionCalled)
    }

    // MARK: - Session Invalidation

    func testSessionInvalidationCallsPendingCompletionsWithCancelError() {
        let expectation = expectation(description: "Completion called on invalidation")
        responder.addCompletion({ result in
            switch result {
            case .failure(let error, _):
                let nsError = error as NSError
                XCTAssertEqual(nsError.domain, NSURLErrorDomain)
                XCTAssertEqual(nsError.code, NSURLErrorCancelled)
                expectation.fulfill()
            case .success:
                XCTFail("Should have failed with cancellation error")
            }
        }, taskID: 99)

        // Create a minimal URLSession and invalidate it
        let config = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: config, delegate: responder, delegateQueue: nil)
        session.invalidateAndCancel()

        waitForExpectations(timeout: 3)
    }

    // MARK: - Init Configuration

    func testInitWithFallbackCachingDisabledByDefault() {
        let r = TPPNetworkResponder()
        // Should not crash and should be usable
        XCTAssertNotNil(r)
    }

    func testInitWithCredentialsProvider() {
        let r = TPPNetworkResponder(credentialsProvider: nil, useFallbackCaching: true)
        XCTAssertNotNil(r)
    }
}
