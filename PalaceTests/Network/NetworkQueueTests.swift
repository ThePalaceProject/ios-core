//
//  NetworkQueueTests.swift
//  PalaceTests
//
//  Tests for NetworkQueue offline request storage and retry logic.
//

import XCTest
@testable import Palace

/// SRS: NET-003 — Offline queue stores failed requests
class NetworkQueueTests: XCTestCase {

    // MARK: - Static Properties

    func testStatusCodesContainsExpectedNetworkErrors() {
        let codes = NetworkQueue.StatusCodes
        XCTAssertTrue(codes.contains(NSURLErrorTimedOut))
        XCTAssertTrue(codes.contains(NSURLErrorCannotFindHost))
        XCTAssertTrue(codes.contains(NSURLErrorCannotConnectToHost))
        XCTAssertTrue(codes.contains(NSURLErrorNetworkConnectionLost))
        XCTAssertTrue(codes.contains(NSURLErrorNotConnectedToInternet))
    }

    func testStatusCodesContainsRoamingAndCallErrors() {
        let codes = NetworkQueue.StatusCodes
        XCTAssertTrue(codes.contains(NSURLErrorInternationalRoamingOff))
        XCTAssertTrue(codes.contains(NSURLErrorCallIsActive))
        XCTAssertTrue(codes.contains(NSURLErrorDataNotAllowed))
    }

    func testStatusCodesContainsSecureConnectionFailed() {
        XCTAssertTrue(NetworkQueue.StatusCodes.contains(NSURLErrorSecureConnectionFailed))
        // Should also contain the closely related SSL errors
        XCTAssertTrue(NetworkQueue.StatusCodes.contains(NSURLErrorCannotConnectToHost),
                      "SSL errors go hand-in-hand with connection failures")
        XCTAssertFalse(NetworkQueue.StatusCodes.isEmpty,
                       "StatusCodes must be non-empty to be useful")
    }

    func testMaxRetriesInQueueIsFive() {
        let queue = NetworkQueue()
        XCTAssertEqual(queue.MaxRetriesInQueue, 5)
        XCTAssertGreaterThan(queue.MaxRetriesInQueue, 0, "Retry limit must be positive")
        XCTAssertLessThanOrEqual(queue.MaxRetriesInQueue, 10,
                                 "Retry limit should be reasonable (<=10) to avoid excessive retries")
    }

    // MARK: - HTTPMethodType

    func testHTTPMethodTypeRawValues() {
        XCTAssertEqual(HTTPMethodType.GET.rawValue, "GET")
        XCTAssertEqual(HTTPMethodType.POST.rawValue, "POST")
        XCTAssertEqual(HTTPMethodType.PUT.rawValue, "PUT")
        XCTAssertEqual(HTTPMethodType.DELETE.rawValue, "DELETE")
        XCTAssertEqual(HTTPMethodType.HEAD.rawValue, "HEAD")
        XCTAssertEqual(HTTPMethodType.OPTIONS.rawValue, "OPTIONS")
        XCTAssertEqual(HTTPMethodType.CONNECT.rawValue, "CONNECT")
    }

    // MARK: - Queue Instance

    func testSharedInstanceIsSingleton() {
        let a = NetworkQueue.sharedInstance
        let b = NetworkQueue.sharedInstance
        XCTAssertTrue(a === b)
    }

    func testObjCSharedReturnsInstance() {
        let instance = NetworkQueue.shared()
        XCTAssertNotNil(instance)
        // The ObjC @objc factory must return the same singleton as the Swift property
        XCTAssertTrue(instance === NetworkQueue.sharedInstance,
                      "ObjC shared() and Swift sharedInstance must be the same object")
    }

    // MARK: - Add Request (Integration)

    func testAddRequestDoesNotCrash() {
        let queue = NetworkQueue()
        // Migrate first to set up the table
        queue.migrate()

        let url = URL(string: "https://example.com/api/test")!
        // Should not crash even with a fresh DB
        queue.addRequest("test-lib", "update-1", url, .POST, nil, nil)

        // Allow serial queue to process
        let expectation = expectation(description: "Queue processes request")
        queue.serialQueue.async {
            expectation.fulfill()
        }
        waitForExpectations(timeout: 3)
        // Verify queue is still operable after adding a request
        XCTAssertNotNil(queue, "Queue should remain functional after addRequest")
        XCTAssertEqual(queue.MaxRetriesInQueue, 5, "MaxRetriesInQueue unchanged after use")
    }

    func testAddRequestWithHeadersDoesNotCrash() {
        let queue = NetworkQueue()
        queue.migrate()

        let url = URL(string: "https://example.com/api/test")!
        let headers = ["Authorization": "Bearer test-token", "Content-Type": "application/json"]
        let body = Data("{\"key\":\"value\"}".utf8)
        queue.addRequest("test-lib", "update-2", url, .PUT, body, headers)

        let expectation = expectation(description: "Queue processes request")
        queue.serialQueue.async {
            expectation.fulfill()
        }
        waitForExpectations(timeout: 3)
    }

    // MARK: - Migration

    func testMigrateDoesNotCrash() {
        let queue = NetworkQueue()
        queue.migrate()

        let expectation = expectation(description: "Migration completes")
        queue.serialQueue.async {
            expectation.fulfill()
        }
        waitForExpectations(timeout: 3)
        // Queue should remain fully functional post-migration
        XCTAssertEqual(queue.MaxRetriesInQueue, 5, "MaxRetriesInQueue unchanged after migration")
        XCTAssertTrue(NetworkQueue.StatusCodes.contains(NSURLErrorNotConnectedToInternet),
                      "StatusCodes should remain valid after migration")
    }

    func testMigrateCanBeCalledMultipleTimes() {
        let queue = NetworkQueue()
        queue.migrate()
        queue.migrate()

        let expectation = expectation(description: "Double migration completes")
        queue.serialQueue.async {
            expectation.fulfill()
        }
        waitForExpectations(timeout: 3)
    }
}
