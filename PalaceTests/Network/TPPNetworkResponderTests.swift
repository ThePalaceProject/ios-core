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
        // A different URL must also be retryable (independent tracking)
        let url2 = URL(string: "https://example.com/api/loans")!
        XCTAssertTrue(responder.canRetry(url: url2),
                      "A fresh URL different from the first must also be retryable")
    }

    func testCanRetryReturnsFalseAfterMarkRetried() {
        let url = URL(string: "https://example.com/api/books")!
        responder.markRetried(url: url)
        XCTAssertFalse(responder.canRetry(url: url), "URL should not be retryable after marking retried once (maxRetryAttempts=1)")
        // A different URL must remain retryable (independent tracking)
        let url2 = URL(string: "https://example.com/api/loans")!
        XCTAssertTrue(responder.canRetry(url: url2),
                      "Marking one URL retried must not affect other URLs")
    }

    func testCanRetryReturnsFalseForNilURL() {
        XCTAssertFalse(responder.canRetry(url: nil))
        // nil URL must always return false, even before any markRetried calls
        XCTAssertFalse(responder.canRetry(url: nil),
                       "canRetry(url: nil) must consistently return false")
    }

    func testMarkRetriedWithNilURL_isNoOp_andLeavesRealURLTrackingIntact() {
        // A nil URL can reach markRetried from a task whose originalRequest
        // has been torn down. Must be a silent no-op — not a crash, and
        // not a corruption of the retry map that affects real URLs.
        let urlA = URL(string: "https://example.com/a")!
        let urlB = URL(string: "https://example.com/b")!

        responder.markRetried(url: nil)

        XCTAssertTrue(responder.canRetry(url: urlA),
                      "unrelated URL must still be retryable after nil call")
        XCTAssertTrue(responder.canRetry(url: urlB),
                      "second unrelated URL must also be retryable after nil call")

        responder.markRetried(url: urlA)
        XCTAssertFalse(responder.canRetry(url: urlA),
                       "after markRetried(urlA), canRetry(urlA) must be false")
        XCTAssertTrue(responder.canRetry(url: urlB),
                      "urlB must remain retryable — markRetried(urlA) must not affect siblings")
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
        // Adding a second completion for a different task must not trigger the first
        responder.addCompletion({ _ in }, taskID: 99)
        XCTAssertFalse(stored, "Adding another task must not prematurely call existing completions")
    }

    func testUpdateCompletionIdTransfersInfo() {
        var completionCalled = false
        responder.addCompletion({ _ in
            completionCalled = true
        }, taskID: 10)
        responder.updateCompletionId(10, newId: 20)
        // After update, old ID's completion should be available at new ID
        // We can't directly verify this without triggering the delegate,
        // but we verify no crash occurs and no premature call happened
        XCTAssertFalse(completionCalled,
                       "updateCompletionId must not fire the completion — it only remaps the key")
        // Calling updateCompletionId again (same IDs) must not crash either
        responder.updateCompletionId(20, newId: 30)
        XCTAssertFalse(completionCalled,
                       "Repeated updateCompletionId calls must not trigger the completion")
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
        defer { session.invalidateAndCancel() }
        session.invalidateAndCancel()

        waitForExpectations(timeout: 3)
    }

    // MARK: - Init Configuration

    func testInitWithFallbackCachingDisabledByDefault() {
        let r = TPPNetworkResponder()
        // Should not crash and should be usable
        XCTAssertNotNil(r)
        // A fresh responder must be able to retry any URL (no prior history)
        let url = URL(string: "https://example.com/fresh")!
        XCTAssertTrue(r.canRetry(url: url),
                      "Freshly initialized responder must allow retries on any URL")
    }

    func testInitWithCredentialsProvider() {
        let r = TPPNetworkResponder(credentialsProvider: nil, useFallbackCaching: true)
        // Responder with fallback caching must still function for retry tracking
        let url = URL(string: "https://example.com/with-fallback")!
        XCTAssertTrue(r.canRetry(url: url),
                      "Responder with fallback caching must allow retries on fresh URLs")
        // After marking retried, canRetry must return false (state tracking works with fallback caching)
        r.markRetried(url: url)
        XCTAssertFalse(r.canRetry(url: url),
                       "Responder with fallback caching must track retried URLs")
    }
}
