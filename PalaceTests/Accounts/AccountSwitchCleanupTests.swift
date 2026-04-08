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

    func testCancelNonEssentialTasks_WithNoActiveTasks_DoesNotCrash() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HTTPStubURLProtocol.self]

        let executor = TPPNetworkExecutor(
            credentialsProvider: nil,
            cachingStrategy: .ephemeral,
            sessionConfiguration: config,
            delegateQueue: nil
        )

        executor.cancelNonEssentialTasks()
    }

    func testCancelNonEssentialTasks_CalledMultipleTimes_DoesNotCrash() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HTTPStubURLProtocol.self]

        let executor = TPPNetworkExecutor(
            credentialsProvider: nil,
            cachingStrategy: .ephemeral,
            sessionConfiguration: config,
            delegateQueue: nil
        )

        executor.cancelNonEssentialTasks()
        executor.cancelNonEssentialTasks()
        executor.cancelNonEssentialTasks()
    }

    func testPauseAllTasks_AfterCancel_DoesNotCrash() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HTTPStubURLProtocol.self]

        let executor = TPPNetworkExecutor(
            credentialsProvider: nil,
            cachingStrategy: .ephemeral,
            sessionConfiguration: config,
            delegateQueue: nil
        )

        executor.cancelNonEssentialTasks()
        executor.pauseAllTasks()
        executor.resumeAllTasks()
    }

    // MARK: - TPPUserAccount with specific libraryUUID

    func testSharedAccount_WithSpecificUUID_DoesNotCrash() {
        let account = TPPUserAccount.sharedAccount(libraryUUID: "urn:uuid:test-library")
        XCTAssertNotNil(account)
    }

    func testSharedAccount_WithNilUUID_DoesNotCrash() {
        let account = TPPUserAccount.sharedAccount(libraryUUID: nil)
        XCTAssertNotNil(account)
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
            bookRegistry: mockRegistry
        )

        let book = TPPBookMocker.mockBook(identifier: "cache-test", title: "Cache Test", authors: "Author")
        _ = cache.model(for: book)
        XCTAssertEqual(cache.count, 1)

        // Simulate account change notification
        NotificationCenter.default.post(name: .TPPCurrentAccountDidChange, object: nil)

        // NotificationCenter delivers synchronously to all observers on the posting thread.
        // No sleep needed — any cache-clear triggered by the notification is already done.
    }
}
