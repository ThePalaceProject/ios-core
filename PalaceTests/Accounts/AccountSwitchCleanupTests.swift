//
//  AccountSwitchCleanupTests.swift
//  PalaceTests
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

@MainActor
final class AccountSwitchCleanupTests: XCTestCase {

    override func tearDown() {
        super.tearDown()
    }

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

    // MARK: - TPPUserAccount with isolated factory-minted libraryUUIDs

    func testFactoryAccount_WithSpecificUUID_BindsUUIDAndIsIsolated() {
        // Two factory calls with the same explicit UUID yield two SEPARATE
        // instances bound to the same UUID — the factory deliberately
        // bypasses AccountsManager's per-library cache so cross-test
        // pollution can't leak via shared in-memory state.
        let firstUUID = "test-uuid-cleanup-fixture-\(UUID().uuidString)"
        let account = TPPUserAccountTestFactory.makeIsolated(libraryUUID: firstUUID)
        XCTAssertEqual(account.libraryUUID, firstUUID)
        let accountAgain = TPPUserAccountTestFactory.makeIsolated(libraryUUID: firstUUID)
        XCTAssertEqual(accountAgain.libraryUUID, firstUUID)
        XCTAssertFalse(account === accountAgain,
                       "Factory must NOT cache — two calls under the same UUID return distinct instances so tests cannot share residue")
        let otherAccount = TPPUserAccountTestFactory.makeIsolated()
        XCTAssertNotEqual(otherAccount.libraryUUID, firstUUID,
                          "Default makeIsolated() must mint a distinct UUID — never collide with an explicit caller-provided one")
    }

    func testFactoryAccount_DefaultMintIsNamespaced() {
        let account = TPPUserAccountTestFactory.makeIsolated()
        XCTAssertTrue(account.libraryUUID?.hasPrefix("test-uuid-") ?? false,
                      "Default makeIsolated() must namespace UUIDs under 'test-uuid-' so keychain keys can't collide with production")
        let account2 = TPPUserAccountTestFactory.makeIsolated()
        XCTAssertNotEqual(account.libraryUUID, account2.libraryUUID,
                          "Each default call must mint a fresh UUID")
        let namedAccount = TPPUserAccountTestFactory.makeIsolated(libraryUUID: "test-uuid-after-default")
        XCTAssertEqual(namedAccount.libraryUUID, "test-uuid-after-default",
                       "Explicit UUID must override the default mint")
    }

    func testFactoryAccount_DistinctUUIDsRemainIsolated() {
        let account1 = TPPUserAccountTestFactory.makeIsolated(libraryUUID: "test-uuid-library-a")
        XCTAssertEqual(account1.libraryUUID, "test-uuid-library-a")

        let account2 = TPPUserAccountTestFactory.makeIsolated(libraryUUID: "test-uuid-library-b")
        XCTAssertEqual(account2.libraryUUID, "test-uuid-library-b")

        let account3 = TPPUserAccountTestFactory.makeIsolated(libraryUUID: "test-uuid-library-a")
        XCTAssertEqual(account3.libraryUUID, "test-uuid-library-a")
        XCTAssertFalse(account1 === account3,
                       "Re-binding the same UUID via the factory must NOT return the prior instance — bypass of AccountsManager cache is the entire point of the factory")
    }

    func testFactoryAccount_RapidMintingDoesNotCrash() {
        for i in 0..<50 {
            let uuid = "test-uuid-rapid-switch-\(i % 3)"
            let account = TPPUserAccountTestFactory.makeIsolated(libraryUUID: uuid)
            XCTAssertEqual(account.libraryUUID, uuid,
                           "Factory must remain stable under repeated calls — every iteration sees its bound UUID")
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
            downloadCenter: AppContainer.production().downloadCenter,
            accountsManager: AppContainer.production().accountsManager,
            samplePreviewManager: AppContainer.production().samplePreviewManager,
            readerService: AppContainer.production().readerService
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
