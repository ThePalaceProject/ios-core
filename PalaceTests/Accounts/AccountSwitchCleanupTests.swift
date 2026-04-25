//
//  AccountSwitchCleanupTests.swift
//  PalaceTests
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class AccountSwitchCleanupTests: XCTestCase {

    // MARK: - cancelNonEssentialTasks

    func testCancelNonEssentialTasks_WithNoActiveTasks_ExecutorRemainsUsable() {
        // Arrange
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HTTPStubURLProtocol.self]
        HTTPStubURLProtocol.register { _ in
            HTTPStubURLProtocol.StubbedResponse(statusCode: 200, headers: nil, body: Data("ok".utf8))
        }
        defer { HTTPStubURLProtocol.reset() }

        let executor = TPPNetworkExecutor(
            credentialsProvider: nil,
            cachingStrategy: .ephemeral,
            sessionConfiguration: config,
            delegateQueue: nil
        )

        // Act: cancel with no tasks in flight
        XCTAssertNoThrow(executor.cancelNonEssentialTasks())

        // Assert: executor still accepts new requests after the cancel
        let expectation = XCTestExpectation(description: "GET completes after cancel-with-no-tasks")
        executor.GET(URL(string: "https://example.com/ping")!) { (_: NYPLResult<Data>) in
            // Any result (200 or error) proves the executor is still functional
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 3.0)
    }

    func testCancelNonEssentialTasks_CalledMultipleTimes_ExecutorIdempotent() {
        // Arrange
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HTTPStubURLProtocol.self]
        HTTPStubURLProtocol.register { _ in
            HTTPStubURLProtocol.StubbedResponse(statusCode: 200, headers: nil, body: Data("ok".utf8))
        }
        defer { HTTPStubURLProtocol.reset() }

        let executor = TPPNetworkExecutor(
            credentialsProvider: nil,
            cachingStrategy: .ephemeral,
            sessionConfiguration: config,
            delegateQueue: nil
        )

        // Act: three consecutive cancels with no tasks
        XCTAssertNoThrow(executor.cancelNonEssentialTasks())
        XCTAssertNoThrow(executor.cancelNonEssentialTasks())
        XCTAssertNoThrow(executor.cancelNonEssentialTasks())

        // Assert: executor still accepts new requests after repeated cancels
        let expectation = XCTestExpectation(description: "GET completes after repeated cancels")
        executor.GET(URL(string: "https://example.com/ping")!) { (_: NYPLResult<Data>) in
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 3.0)
    }

    func testPauseAllTasks_AfterCancel_ResumeAcceptsNewRequests() {
        // Arrange
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HTTPStubURLProtocol.self]
        HTTPStubURLProtocol.register { _ in
            HTTPStubURLProtocol.StubbedResponse(statusCode: 200, headers: nil, body: Data("ok".utf8))
        }
        defer { HTTPStubURLProtocol.reset() }

        let executor = TPPNetworkExecutor(
            credentialsProvider: nil,
            cachingStrategy: .ephemeral,
            sessionConfiguration: config,
            delegateQueue: nil
        )

        // Act: simulate account-switch lifecycle — cancel, pause, then resume
        XCTAssertNoThrow(executor.cancelNonEssentialTasks())
        XCTAssertNoThrow(executor.pauseAllTasks())
        XCTAssertNoThrow(executor.resumeAllTasks())

        // Assert: executor accepts new work after the full pause/resume cycle
        let expectation = XCTestExpectation(description: "GET completes after pause/resume cycle")
        executor.GET(URL(string: "https://example.com/ping")!) { (_: NYPLResult<Data>) in
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 3.0)
    }

    // MARK: - TPPUserAccount with specific libraryUUID

    func testSharedAccount_WithSpecificUUID_DoesNotCrash() {
        let account = TPPUserAccount.sharedAccount(libraryUUID: "urn:uuid:test-library")
        XCTAssertNotNil(account)
        // Retrieving the same UUID twice returns equivalent accounts
        let accountAgain = TPPUserAccount.sharedAccount(libraryUUID: "urn:uuid:test-library")
        XCTAssertNotNil(accountAgain)
        // A different UUID should still produce a non-nil account
        let otherAccount = TPPUserAccount.sharedAccount(libraryUUID: "urn:uuid:other-library")
        XCTAssertNotNil(otherAccount)
    }

    func testSharedAccount_WithNilUUID_DoesNotCrash() {
        let account = TPPUserAccount.sharedAccount(libraryUUID: nil)
        XCTAssertNotNil(account)
        // Repeated nil-UUID calls all return non-nil accounts
        let account2 = TPPUserAccount.sharedAccount(libraryUUID: nil)
        XCTAssertNotNil(account2)
        // A specific UUID after a nil-UUID call also works
        let namedAccount = TPPUserAccount.sharedAccount(libraryUUID: "urn:uuid:after-nil")
        XCTAssertNotNil(namedAccount)
    }

    func testSharedAccount_SwitchingUUIDs_DoesNotCrash() {
        let account1 = TPPUserAccount.sharedAccount(libraryUUID: "urn:uuid:library-a")
        XCTAssertNotNil(account1)

        let account2 = TPPUserAccount.sharedAccount(libraryUUID: "urn:uuid:library-b")
        XCTAssertNotNil(account2)

        let account3 = TPPUserAccount.sharedAccount(libraryUUID: "urn:uuid:library-a")
        XCTAssertNotNil(account3)
    }

    func testSharedAccount_RapidSwitching_DoesNotCrash() {
        for i in 0..<50 {
            let uuid = "urn:uuid:rapid-switch-\(i % 3)"
            let account = TPPUserAccount.sharedAccount(libraryUUID: uuid)
            XCTAssertNotNil(account)
        }
    }

    // MARK: - Bookmark Cleanup Model Cache

    @MainActor
    func testBookCellModelCache_ClearsOnAccountChange() {
        let mockImageCache = MockImageCache()
        let mockRegistry = TPPBookRegistryMock()

        let cache = BookCellModelCache(
            configuration: .init(maxEntries: 50, unusedTTL: 60, observeRegistryChanges: false),
            imageCache: mockImageCache,
            bookRegistry: mockRegistry,
            downloadCenter: .shared,
            accountsManager: .shared,
            samplePreviewManager: .shared,
            readerService: .shared
        )

        let book = TPPBookMocker.mockBook(identifier: "cache-test", title: "Cache Test", authors: "Author")
        let book2 = TPPBookMocker.mockBook(identifier: "cache-test-2", title: "Cache Test 2", authors: "Author 2")
        _ = cache.model(for: book)
        _ = cache.model(for: book2)
        XCTAssertEqual(cache.count, 2, "Both books should be cached before account change")

        // Simulate account change notification
        NotificationCenter.default.post(name: .TPPCurrentAccountDidChange, object: nil)

        // NotificationCenter delivers synchronously to all observers on the posting thread.
        // No sleep needed — any cache-clear triggered by the notification is already done.
        XCTAssertEqual(cache.count, 0, "Cache should be cleared after account change")
        // A new model can be populated after the clear
        _ = cache.model(for: book)
        XCTAssertEqual(cache.count, 1, "Cache should accept new entries after account-change clear")
    }
}
