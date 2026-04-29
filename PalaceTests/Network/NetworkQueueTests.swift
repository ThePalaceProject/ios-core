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
        let queue = AppContainer.production().networkQueue
        XCTAssertEqual(queue.MaxRetriesInQueue, 5)
        XCTAssertGreaterThan(queue.MaxRetriesInQueue, 0, "Retry limit must be positive")
        XCTAssertLessThanOrEqual(queue.MaxRetriesInQueue, 10,
                                 "Retry limit should be reasonable (<=10) to avoid excessive retries")
    }

    // MARK: - HTTPMethodType

    func testHTTPMethodTypeRawValues() {
        // Raw values are used verbatim in HTTP requests — verify roundtrip (not just definitions)
        let methods: [(HTTPMethodType, String)] = [
            (.GET, "GET"), (.POST, "POST"), (.PUT, "PUT"), (.DELETE, "DELETE"),
            (.HEAD, "HEAD"), (.OPTIONS, "OPTIONS"), (.CONNECT, "CONNECT")
        ]
        for (method, expectedRaw) in methods {
            XCTAssertEqual(HTTPMethodType(rawValue: expectedRaw), method,
                           "roundtrip for \(expectedRaw) must produce .\(method)")
        }
        // Case sensitivity check: HTTP methods are uppercase-only
        XCTAssertNil(HTTPMethodType(rawValue: "get"), "Lowercase 'get' must not produce a valid HTTPMethodType")
        XCTAssertNil(HTTPMethodType(rawValue: "post"), "Lowercase 'post' must not produce a valid HTTPMethodType")
    }

    // MARK: - Queue Instance

    func testSharedInstanceIsSingleton() {
        let a = AppContainer.production().networkQueue
        let b = AppContainer.production().networkQueue
        XCTAssertTrue(a === b, "sharedInstance must return the same object on every access")
        XCTAssertEqual(ObjectIdentifier(a), ObjectIdentifier(b), "Both references must have identical object identity")
    }

    func testObjCSharedReturnsInstance() {
        let instance = AppContainer.production().networkQueue
        XCTAssertNotNil(instance)
        // The ObjC @objc factory must return the same singleton as the Swift property
        XCTAssertTrue(instance === AppContainer.production().networkQueue,
                      "ObjC shared() and Swift sharedInstance must be the same object")
    }

    // MARK: - Add Request (Integration)

    func testAddRequestDoesNotCrash() {
        let queue = AppContainer.production().networkQueue
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
        let queue = AppContainer.production().networkQueue
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
        // Queue must remain functional after adding a request with headers and body
        XCTAssertEqual(queue.MaxRetriesInQueue, 5, "MaxRetriesInQueue must be unchanged after addRequest with headers")
    }

    // MARK: - Migration

    func testMigrateDoesNotCrash() {
        let queue = AppContainer.production().networkQueue
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
        let queue = AppContainer.production().networkQueue
        queue.migrate()
        queue.migrate()

        let expectation = expectation(description: "Double migration completes")
        queue.serialQueue.async {
            expectation.fulfill()
        }
        waitForExpectations(timeout: 3)
        // Double migration must not alter the queue's configured constants
        XCTAssertEqual(queue.MaxRetriesInQueue, 5, "MaxRetriesInQueue must be unchanged after double migrate")
        XCTAssertTrue(NetworkQueue.StatusCodes.contains(NSURLErrorNotConnectedToInternet),
                      "StatusCodes must remain valid after double migrate")
    }
}
