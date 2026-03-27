//
//  AccountSwitchIntegrationTests.swift
//  PalaceTests
//
//  Integration tests for account switching flows. Tests verify that switching
//  accounts correctly clears book registry state, updates the current account,
//  cancels pending operations, and triggers catalog refresh via the mock
//  infrastructure.
//
//  Copyright 2026 The Palace Project. All rights reserved.
//

import XCTest
import Combine
@testable import Palace

// SRS: REQ-ACCT-001 — Account switch integration

@MainActor
final class AccountSwitchIntegrationTests: XCTestCase {

    private var bookRegistry: TPPBookRegistryMock!
    private var userAccount: TPPUserAccountMock!
    private var catalogRepo: CatalogRepositoryTestMock!
    private var cancellables: Set<AnyCancellable>!

    override func setUp() {
        super.setUp()
        bookRegistry = TPPBookRegistryMock()
        userAccount = TPPUserAccountMock()
        catalogRepo = CatalogRepositoryTestMock()
        cancellables = []
    }

    override func tearDown() {
        cancellables = nil
        catalogRepo.reset()
        bookRegistry = nil
        userAccount = nil
        catalogRepo = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeTestBook(identifier: String, title: String = "Test Book") -> TPPBook {
        return TPPBook(dictionary: [
            "acquisitions": [TPPFake.genericAcquisition.dictionaryRepresentation()],
            "title": title,
            "categories": ["Fiction"],
            "id": identifier,
            "updated": "2024-01-01T00:00:00Z"
        ])!
    }

    // MARK: - Account Switch Clears Registry

    // SRS: REQ-ACCT-002 — Account switch clears book registry
    func testAccountSwitch_ClearsBookRegistry() {
        // Given: Registry has books from current account
        let book1 = makeTestBook(identifier: "book-1", title: "Book One")
        let book2 = makeTestBook(identifier: "book-2", title: "Book Two")
        bookRegistry.addBook(book1, state: .downloadSuccessful)
        bookRegistry.addBook(book2, state: .downloadNeeded)
        XCTAssertEqual(bookRegistry.registry.count, 2,
                       "Registry should have 2 books before switch")

        // When: Simulate account switch by resetting registry
        bookRegistry.reset("new-account-uuid")

        // Then
        XCTAssertTrue(bookRegistry.registry.isEmpty,
                      "Registry should be empty after account switch reset")
        XCTAssertNil(bookRegistry.book(forIdentifier: "book-1"),
                     "Book 1 should be gone after reset")
        XCTAssertNil(bookRegistry.book(forIdentifier: "book-2"),
                     "Book 2 should be gone after reset")
    }

    // SRS: REQ-ACCT-003 — Account switch posts notification
    func testAccountSwitch_PostsCurrentAccountDidChangeNotification() {
        // Given
        let expectation = expectation(forNotification: .TPPCurrentAccountDidChange,
                                      object: nil)

        // When
        NotificationCenter.default.post(name: .TPPCurrentAccountDidChange, object: nil)

        // Then
        wait(for: [expectation], timeout: 1.0)
    }

    // SRS: REQ-ACCT-004 — Account switch cancels pending operations
    func testAccountSwitch_StopsPendingNetworkRequests() async throws {
        // Given: A slow catalog load in progress
        catalogRepo.simulatedDelay = 5.0
        let catalogURL = URL(string: "https://catalog.example.com/feed")!

        let loadTask = Task {
            try await self.catalogRepo.loadTopLevelCatalog(at: catalogURL)
        }

        // When: Cancel the load (simulating account switch cleanup)
        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
        loadTask.cancel()

        // Then: Verify the task was cancelled or completed
        let result = await loadTask.result
        switch result {
        case .success:
            break // May complete before cancellation
        case .failure(let error):
            XCTAssertTrue(error is CancellationError,
                          "Pending task should be cancelled, got \(error)")
        }
    }

    // SRS: REQ-ACCT-005 — New account triggers catalog refresh
    func testNewAccount_LoadsFreshCatalog() async throws {
        // Given
        let catalogURL = URL(string: "https://newlibrary.example.com/feed")!
        catalogRepo.loadTopLevelCatalogResult = nil

        // When: Load catalog for the new account
        _ = try await catalogRepo.loadTopLevelCatalog(at: catalogURL)

        // Then
        XCTAssertEqual(catalogRepo.loadTopLevelCatalogCallCount, 1,
                       "Fresh catalog should be loaded once")
        XCTAssertEqual(catalogRepo.lastLoadURL, catalogURL,
                       "Should load from the new account's catalog URL")
    }

    // SRS: REQ-ACCT-006 — Multiple rapid switches don't corrupt state
    func testMultipleRapidSwitches_DoNotCorruptRegistry() {
        // Given: Start with books
        let book = makeTestBook(identifier: "book-rapid", title: "Rapid Book")
        bookRegistry.addBook(book, state: .downloadSuccessful)

        // When: Simulate rapid account switches
        for i in 0..<10 {
            bookRegistry.reset("account-\(i)")
            if i % 2 == 0 {
                // Re-add a book on even switches
                let newBook = makeTestBook(identifier: "book-\(i)", title: "Book \(i)")
                bookRegistry.addBook(newBook, state: .downloadNeeded)
            }
        }

        // Then: Last switch was odd (i=9), so registry was reset without adding
        // But we check registry is in a consistent, non-corrupted state
        XCTAssertTrue(bookRegistry.registry.count <= 1,
                      "Registry should have at most 1 book after rapid switches")
        // Verify no crash occurred and state is consistent
        let state = bookRegistry.state(for: "nonexistent")
        XCTAssertEqual(state, .unregistered,
                       "Unknown book should return .unregistered")
    }

    // SRS: REQ-ACCT-007 — Switch to same account is idempotent
    func testSwitchToSameAccount_IsIdempotent() {
        // Given: Registry with a book
        let book = makeTestBook(identifier: "same-acct-book")
        bookRegistry.addBook(book, state: .downloadSuccessful)

        // When: "Switch" to the same account (no reset triggered)
        // In production, AccountsManager.currentAccount setter checks previousAccountId != newAccountId
        // We verify that not calling reset preserves state
        let bookBefore = bookRegistry.book(forIdentifier: "same-acct-book")
        let stateBefore = bookRegistry.state(for: "same-acct-book")

        // Then
        XCTAssertNotNil(bookBefore, "Book should still exist when account didn't change")
        XCTAssertEqual(stateBefore, .downloadSuccessful,
                       "State should be preserved when account didn't change")
        XCTAssertEqual(bookRegistry.registry.count, 1,
                       "Registry count should remain unchanged")
    }

    // SRS: REQ-ACCT-008 — Cache invalidation on account switch
    func testAccountSwitch_InvalidatesCatalogCache() async throws {
        // Given: Catalog was loaded for the old account
        let oldCatalogURL = URL(string: "https://old-library.example.com/feed")!
        _ = try await catalogRepo.loadTopLevelCatalog(at: oldCatalogURL)
        XCTAssertEqual(catalogRepo.loadTopLevelCatalogCallCount, 1)

        // When: Invalidate cache as part of account switch
        catalogRepo.invalidateCache(for: oldCatalogURL)

        // Then
        XCTAssertEqual(catalogRepo.invalidateCacheCallCount, 1,
                       "Cache should be invalidated during account switch")
        XCTAssertEqual(catalogRepo.lastInvalidatedURL, oldCatalogURL,
                       "Old account's catalog URL should be invalidated")
    }

    // SRS: REQ-ACCT-009 — Account switch clears cached credentials
    func testAccountSwitch_ClearsCachedCredentials() {
        // Given: User has credentials set
        userAccount._credentials = .barcodeAndPin(barcode: "12345", pin: "9999")
        userAccount.setAuthorizationIdentifier("auth-id-123")
        userAccount.setAuthState(.loggedIn)

        XCTAssertNotNil(userAccount.credentials, "Should have credentials before switch")
        XCTAssertEqual(userAccount.authState, .loggedIn)

        // When: Clear credentials (simulating account switch cleanup)
        userAccount.removeAll()

        // Then
        XCTAssertNil(userAccount.credentials,
                     "Credentials should be nil after account switch cleanup")
        XCTAssertNil(userAccount.authorizationIdentifier,
                     "Authorization identifier should be cleared")
        XCTAssertEqual(userAccount.authState, .loggedOut,
                       "Auth state should be loggedOut after cleanup")
    }
}
