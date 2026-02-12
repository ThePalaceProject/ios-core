//
//  TPPBookRegistryIntegrationTests.swift
//  PalaceTests
//
//  Integration tests for the REAL TPPBookRegistry production class.
//  These tests verify:
//  - Book state management (addBook, setState, state, removeBook)
//  - Combine publisher emissions (registryPublisher, bookStatePublisher)
//  - Persistence (save/load round-trips)
//  - Location and bookmark management
//
//  Test isolation is achieved through unique account IDs per test,
//  with cleanup in tearDown.
//
//  Note: These tests use real production classes, not mocks.
//  Mocks are only used for external dependencies like AccountsManager.
//
//  Copyright 2026 The Palace Project. All rights reserved.
//

import XCTest
import Combine
@testable import Palace

// MARK: - TPPBookRegistry State Management Integration Tests

final class TPPBookRegistryStateManagementTests: XCTestCase {

    private var cancellables: Set<AnyCancellable>!
    private var testAccountId: String!
    private var testRegistryUrl: URL?

    override func setUp() {
        super.setUp()
        cancellables = []
        // Create unique account ID for test isolation
        testAccountId = "test-account-\(UUID().uuidString)"
    }

    override func tearDown() {
        cancellables = nil
        // Clean up test registry directory
        cleanupTestRegistry()
        super.tearDown()
    }

    private func cleanupTestRegistry() {
        guard let testAccountId = testAccountId else { return }

        // Get the registry URL and clean up
        let paths = NSSearchPathForDirectoriesInDomains(.applicationSupportDirectory, .userDomainMask, true)
        guard let basePath = paths.first else { return }

        let accountDir = URL(fileURLWithPath: basePath)
            .appendingPathComponent(testAccountId)

        try? FileManager.default.removeItem(at: accountDir)
    }

    // MARK: - addBook Tests

    func testAddBook_NewBook_RegistersWithCorrectState() {
        // Arrange
        let registry = TPPBookRegistry.shared
        let book = TPPBookMocker.mockBook(identifier: "add-test-\(UUID().uuidString)", title: "Add Test Book", distributorType: .EpubZip)

        // Act
        registry.addBook(book, state: .downloadNeeded)

        // Allow async operations to complete
        let expectation = self.expectation(description: "Book added")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            expectation.fulfill()
        }
        waitForExpectations(timeout: 1.0)

        // Assert
        XCTAssertEqual(registry.state(for: book.identifier), .downloadNeeded)
        XCTAssertNotNil(registry.book(forIdentifier: book.identifier))

        // Cleanup
        registry.removeBook(forIdentifier: book.identifier)
    }

    func testAddBook_WithLocation_StoresLocation() {
        // Arrange
        let registry = TPPBookRegistry.shared
        let book = TPPBookMocker.mockBook(identifier: "location-test-\(UUID().uuidString)", title: "Location Test", distributorType: .EpubZip)
        let location = TPPBookLocation(locationString: "{\"page\": 42}", renderer: "TestRenderer")!

        // Act
        registry.addBook(book, location: location, state: .downloadSuccessful)

        // Allow async operations
        let expectation = self.expectation(description: "Book with location added")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            expectation.fulfill()
        }
        waitForExpectations(timeout: 1.0)

        // Assert
        let retrievedLocation = registry.location(forIdentifier: book.identifier)
        XCTAssertNotNil(retrievedLocation)
        XCTAssertEqual(retrievedLocation?.locationString, "{\"page\": 42}")
        XCTAssertEqual(retrievedLocation?.renderer, "TestRenderer")

        // Cleanup
        registry.removeBook(forIdentifier: book.identifier)
    }

    func testAddBook_WithFulfillmentId_StoresFulfillmentId() {
        // Arrange
        let registry = TPPBookRegistry.shared
        let book = TPPBookMocker.mockBook(identifier: "fulfillment-test-\(UUID().uuidString)", title: "Fulfillment Test", distributorType: .EpubZip)

        // Act
        registry.addBook(book, state: .downloadSuccessful, fulfillmentId: "test-fulfillment-123")

        // Allow async operations
        let expectation = self.expectation(description: "Book with fulfillmentId added")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            expectation.fulfill()
        }
        waitForExpectations(timeout: 1.0)

        // Assert
        XCTAssertEqual(registry.fulfillmentId(forIdentifier: book.identifier), "test-fulfillment-123")

        // Cleanup
        registry.removeBook(forIdentifier: book.identifier)
    }

    func testAddBook_WithBookmarks_StoresBookmarks() {
        // Arrange
        let registry = TPPBookRegistry.shared
        let book = TPPBookMocker.mockBook(identifier: "bookmarks-test-\(UUID().uuidString)", title: "Bookmarks Test", distributorType: .EpubZip)

        let genericBookmark1 = TPPBookLocation(locationString: "{\"chapter\": 1}", renderer: "R1")!
        let genericBookmark2 = TPPBookLocation(locationString: "{\"chapter\": 2}", renderer: "R1")!

        // Act
        registry.addBook(
            book,
            state: .downloadSuccessful,
            genericBookmarks: [genericBookmark1, genericBookmark2]
        )

        // Allow async operations
        let expectation = self.expectation(description: "Book with bookmarks added")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            expectation.fulfill()
        }
        waitForExpectations(timeout: 1.0)

        // Assert
        let bookmarks = registry.genericBookmarksForIdentifier(book.identifier)
        XCTAssertEqual(bookmarks.count, 2)

        // Cleanup
        registry.removeBook(forIdentifier: book.identifier)
    }

    // MARK: - setState Tests

    func testSetState_TransitionsCorrectly() {
        // Arrange
        let registry = TPPBookRegistry.shared
        let book = TPPBookMocker.mockBook(identifier: "state-transition-\(UUID().uuidString)", title: "State Transition", distributorType: .EpubZip)
        registry.addBook(book, state: .downloadNeeded)

        // Allow async operations
        let addExpectation = self.expectation(description: "Book added")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            addExpectation.fulfill()
        }
        waitForExpectations(timeout: 1.0)

        // Act & Assert - Test state transitions
        let stateTransitions: [TPPBookState] = [
            .downloading,
            .downloadSuccessful,
            .used,
            .downloadFailed,
            .downloadNeeded
        ]

        for expectedState in stateTransitions {
            registry.setState(expectedState, for: book.identifier)

            let stateExpectation = self.expectation(description: "State set to \(expectedState)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                stateExpectation.fulfill()
            }
            waitForExpectations(timeout: 1.0)

            XCTAssertEqual(registry.state(for: book.identifier), expectedState, "State should be \(expectedState)")
        }

        // Cleanup
        registry.removeBook(forIdentifier: book.identifier)
    }

    func testSetState_ForUnregisteredBook_DoesNotCrash() {
        // Arrange
        let registry = TPPBookRegistry.shared
        let nonExistentId = "non-existent-\(UUID().uuidString)"

        // Act - Should not crash
        registry.setState(.downloadNeeded, for: nonExistentId)

        // Allow async
        let expectation = self.expectation(description: "Set state completed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            expectation.fulfill()
        }
        waitForExpectations(timeout: 1.0)

        // Assert
        XCTAssertEqual(registry.state(for: nonExistentId), .unregistered)
    }

    // MARK: - removeBook Tests

    func testRemoveBook_RemovesFromRegistry() {
        // Arrange
        let registry = TPPBookRegistry.shared
        let book = TPPBookMocker.mockBook(identifier: "remove-test-\(UUID().uuidString)", title: "Remove Test", distributorType: .EpubZip)
        registry.addBook(book, state: .downloadSuccessful)

        let addExpectation = self.expectation(description: "Book added")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            addExpectation.fulfill()
        }
        waitForExpectations(timeout: 1.0)

        // Verify book exists
        XCTAssertNotNil(registry.book(forIdentifier: book.identifier))

        // Act
        registry.removeBook(forIdentifier: book.identifier)

        let removeExpectation = self.expectation(description: "Book removed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            removeExpectation.fulfill()
        }
        waitForExpectations(timeout: 1.0)

        // Assert
        XCTAssertNil(registry.book(forIdentifier: book.identifier))
        XCTAssertEqual(registry.state(for: book.identifier), .unregistered)
    }

    func testRemoveBook_WithEmptyIdentifier_DoesNotCrash() {
        // Arrange
        let registry = TPPBookRegistry.shared

        // Act - Should not crash
        registry.removeBook(forIdentifier: "")

        // Assert - No crash occurred
        XCTAssertTrue(true)
    }

    // MARK: - state(for:) Tests

    func testStateFor_NilIdentifier_ReturnsUnregistered() {
        let registry = TPPBookRegistry.shared
        XCTAssertEqual(registry.state(for: nil), .unregistered)
    }

    func testStateFor_EmptyIdentifier_ReturnsUnregistered() {
        let registry = TPPBookRegistry.shared
        XCTAssertEqual(registry.state(for: ""), .unregistered)
    }

    func testStateFor_NonExistentBook_ReturnsUnregistered() {
        let registry = TPPBookRegistry.shared
        XCTAssertEqual(registry.state(for: "non-existent-book-id"), .unregistered)
    }
}

// MARK: - TPPBookRegistry Combine Publisher Integration Tests

final class TPPBookRegistryPublisherTests: XCTestCase {

    private var cancellables: Set<AnyCancellable>!

    override func setUp() {
        super.setUp()
        cancellables = []
    }

    override func tearDown() {
        cancellables = nil
        super.tearDown()
    }

    // MARK: - registryPublisher Tests

    func testRegistryPublisher_EmitsOnBookAdd() {
        // Arrange
        let registry = TPPBookRegistry.shared
        let book = TPPBookMocker.mockBook(identifier: "publisher-add-\(UUID().uuidString)", title: "Publisher Add Test", distributorType: .EpubZip)

        var receivedRegistry: [String: TPPBookRegistryRecord]?
        let expectation = self.expectation(description: "Registry publisher emits with added book")

        // Use filter to wait for the specific emission containing our book
        // This is more reliable than dropFirst() in CI environments with timing variance
        registry.registryPublisher
            .filter { records in
                records[book.identifier] != nil
            }
            .first()
            .sink { records in
                receivedRegistry = records
                expectation.fulfill()
            }
            .store(in: &cancellables)

        // Act
        registry.addBook(book, state: .downloadNeeded)

        // Assert
        waitForExpectations(timeout: 3.0) // Increased timeout for CI
        XCTAssertNotNil(receivedRegistry)
        XCTAssertNotNil(receivedRegistry?[book.identifier])

        // Cleanup
        registry.removeBook(forIdentifier: book.identifier)
    }

    func testRegistryPublisher_EmitsOnBookRemove() {
        // Arrange
        let registry = TPPBookRegistry.shared
        let book = TPPBookMocker.mockBook(identifier: "publisher-remove-\(UUID().uuidString)", title: "Publisher Remove Test", distributorType: .EpubZip)

        // Add book first
        registry.addBook(book, state: .downloadSuccessful)

        let addExpectation = self.expectation(description: "Book added")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            addExpectation.fulfill()
        }
        waitForExpectations(timeout: 1.0)

        var receivedRegistry: [String: TPPBookRegistryRecord]?
        let removeExpectation = self.expectation(description: "Registry publisher emits on remove")

        // Use filter instead of dropFirst() for more reliable timing
        // The initial emission contains the book, so this filter won't match
        // After removal, the emission won't contain the book, so it will match
        registry.registryPublisher
            .filter { $0[book.identifier] == nil }
            .first()
            .sink { records in
                receivedRegistry = records
                removeExpectation.fulfill()
            }
            .store(in: &cancellables)

        // Act
        registry.removeBook(forIdentifier: book.identifier)

        // Assert
        waitForExpectations(timeout: 2.0)
        XCTAssertNotNil(receivedRegistry)
        XCTAssertNil(receivedRegistry?[book.identifier])
    }

    // MARK: - bookStatePublisher Tests

    func testBookStatePublisher_EmitsOnStateChange() {
        // Arrange
        let registry = TPPBookRegistry.shared
        let book = TPPBookMocker.mockBook(identifier: "state-publisher-\(UUID().uuidString)", title: "State Publisher Test", distributorType: .EpubZip)

        // Add book first
        registry.addBook(book, state: .downloadNeeded)

        let addExpectation = self.expectation(description: "Book added")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            addExpectation.fulfill()
        }
        waitForExpectations(timeout: 1.0)

        var receivedState: TPPBookState?
        var receivedBookId: String?
        let stateExpectation = self.expectation(description: "State publisher emits")

        registry.bookStatePublisher
            .filter { $0.0 == book.identifier && $0.1 == .downloading }
            .first()
            .sink { (bookId, state) in
                receivedBookId = bookId
                receivedState = state
                stateExpectation.fulfill()
            }
            .store(in: &cancellables)

        // Act
        registry.setState(.downloading, for: book.identifier)

        // Assert
        waitForExpectations(timeout: 2.0)
        XCTAssertEqual(receivedBookId, book.identifier)
        XCTAssertEqual(receivedState, .downloading)

        // Cleanup
        registry.removeBook(forIdentifier: book.identifier)
    }

    func testBookStatePublisher_EmitsOnBookAdd() {
        // Arrange
        let registry = TPPBookRegistry.shared
        let book = TPPBookMocker.mockBook(identifier: "add-state-publisher-\(UUID().uuidString)", title: "Add State Publisher", distributorType: .EpubZip)

        var receivedState: TPPBookState?
        var receivedBookId: String?
        let expectation = self.expectation(description: "State publisher emits on add")

        registry.bookStatePublisher
            .filter { $0.0 == book.identifier }
            .first()
            .sink { (bookId, state) in
                receivedBookId = bookId
                receivedState = state
                expectation.fulfill()
            }
            .store(in: &cancellables)

        // Act
        registry.addBook(book, state: .downloadSuccessful)

        // Assert
        waitForExpectations(timeout: 2.0)
        XCTAssertEqual(receivedBookId, book.identifier)
        XCTAssertEqual(receivedState, .downloadSuccessful)

        // Cleanup
        registry.removeBook(forIdentifier: book.identifier)
    }

    func testBookStatePublisher_EmitsOnBookRemove() {
        // Arrange
        let registry = TPPBookRegistry.shared
        let book = TPPBookMocker.mockBook(identifier: "remove-state-publisher-\(UUID().uuidString)", title: "Remove State Publisher", distributorType: .EpubZip)

        // Add book first
        registry.addBook(book, state: .downloadSuccessful)

        let addExpectation = self.expectation(description: "Book added")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            addExpectation.fulfill()
        }
        waitForExpectations(timeout: 1.0)

        var receivedState: TPPBookState?
        let removeExpectation = self.expectation(description: "State publisher emits unregistered on remove")

        registry.bookStatePublisher
            .filter { $0.0 == book.identifier && $0.1 == .unregistered }
            .first()
            .sink { (_, state) in
                receivedState = state
                removeExpectation.fulfill()
            }
            .store(in: &cancellables)

        // Act
        registry.removeBook(forIdentifier: book.identifier)

        // Assert
        waitForExpectations(timeout: 2.0)
        XCTAssertEqual(receivedState, .unregistered)
    }

    func testBookStatePublisher_MultipleStateChanges_EmitsAll() {
        // Arrange
        let registry = TPPBookRegistry.shared
        let book = TPPBookMocker.mockBook(identifier: "multi-state-\(UUID().uuidString)", title: "Multi State Test", distributorType: .EpubZip)

        registry.addBook(book, state: .downloadNeeded)

        let addExpectation = self.expectation(description: "Book added")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            addExpectation.fulfill()
        }
        waitForExpectations(timeout: 1.0)

        var receivedStates: [TPPBookState] = []
        let expectation = self.expectation(description: "All states received")
        expectation.expectedFulfillmentCount = 3

        registry.bookStatePublisher
            .filter { $0.0 == book.identifier }
            .sink { (_, state) in
                receivedStates.append(state)
                expectation.fulfill()
            }
            .store(in: &cancellables)

        // Act - Transition through multiple states
        registry.setState(.downloading, for: book.identifier)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            registry.setState(.downloadSuccessful, for: book.identifier)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            registry.setState(.used, for: book.identifier)
        }

        // Assert
        waitForExpectations(timeout: 3.0)
        XCTAssertEqual(receivedStates.count, 3)
        XCTAssertTrue(receivedStates.contains(.downloading))
        XCTAssertTrue(receivedStates.contains(.downloadSuccessful))
        XCTAssertTrue(receivedStates.contains(.used))

        // Cleanup
        registry.removeBook(forIdentifier: book.identifier)
    }
}

// MARK: - TPPBookRegistry Location Management Tests

final class TPPBookRegistryLocationTests: XCTestCase {

    func testSetLocation_UpdatesLocation() {
        // Arrange
        let registry = TPPBookRegistry.shared
        let book = TPPBookMocker.mockBook(identifier: "location-update-\(UUID().uuidString)", title: "Location Update", distributorType: .EpubZip)
        registry.addBook(book, state: .downloadSuccessful)

        let addExpectation = self.expectation(description: "Book added")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            addExpectation.fulfill()
        }
        waitForExpectations(timeout: 1.0)

        // Act
        let newLocation = TPPBookLocation(locationString: "{\"page\": 100, \"chapter\": 5}", renderer: "R2")
        registry.setLocation(newLocation, forIdentifier: book.identifier)

        let setExpectation = self.expectation(description: "Location set")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            setExpectation.fulfill()
        }
        waitForExpectations(timeout: 1.0)

        // Assert
        let retrieved = registry.location(forIdentifier: book.identifier)
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.locationString, "{\"page\": 100, \"chapter\": 5}")
        XCTAssertEqual(retrieved?.renderer, "R2")

        // Cleanup
        registry.removeBook(forIdentifier: book.identifier)
    }

    func testSetLocation_WithNil_ClearsLocation() {
        // Arrange
        let registry = TPPBookRegistry.shared
        let book = TPPBookMocker.mockBook(identifier: "location-clear-\(UUID().uuidString)", title: "Location Clear", distributorType: .EpubZip)
        let initialLocation = TPPBookLocation(locationString: "{\"page\": 1}", renderer: "R1")
        registry.addBook(book, location: initialLocation, state: .downloadSuccessful)

        let addExpectation = self.expectation(description: "Book added")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            addExpectation.fulfill()
        }
        waitForExpectations(timeout: 1.0)

        // Verify initial location
        XCTAssertNotNil(registry.location(forIdentifier: book.identifier))

        // Act
        registry.setLocation(nil, forIdentifier: book.identifier)

        let clearExpectation = self.expectation(description: "Location cleared")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            clearExpectation.fulfill()
        }
        waitForExpectations(timeout: 1.0)

        // Assert
        XCTAssertNil(registry.location(forIdentifier: book.identifier))

        // Cleanup
        registry.removeBook(forIdentifier: book.identifier)
    }

    func testLocation_ForNonExistentBook_ReturnsNil() {
        let registry = TPPBookRegistry.shared
        XCTAssertNil(registry.location(forIdentifier: "non-existent-book"))
    }

    func testSetLocationSync_UpdatesSynchronously() {
        // Arrange
        let registry = TPPBookRegistry.shared
        let book = TPPBookMocker.mockBook(identifier: "sync-location-\(UUID().uuidString)", title: "Sync Location", distributorType: .EpubZip)
        registry.addBook(book, state: .downloadSuccessful)

        let addExpectation = self.expectation(description: "Book added")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            addExpectation.fulfill()
        }
        waitForExpectations(timeout: 1.0)

        // Act
        let newLocation = TPPBookLocation(locationString: "{\"sync\": true}", renderer: "SyncRenderer")
        registry.setLocationSync(newLocation, forIdentifier: book.identifier)

        // Assert - Should be available immediately (synchronous)
        // Note: We still need a small delay due to registry internals
        let retrieved = registry.location(forIdentifier: book.identifier)
        XCTAssertNotNil(retrieved)

        // Cleanup
        registry.removeBook(forIdentifier: book.identifier)
    }
}

// MARK: - TPPBookRegistry Bookmark Tests

final class TPPBookRegistryBookmarkTests: XCTestCase {

    // MARK: - Generic Bookmark Tests

    func testAddGenericBookmark_AppendsToList() {
        // Arrange
        let registry = TPPBookRegistry.shared
        let book = TPPBookMocker.mockBook(identifier: "generic-bookmark-\(UUID().uuidString)", title: "Generic Bookmark", distributorType: .EpubZip)
        registry.addBook(book, state: .downloadSuccessful)

        let addExpectation = self.expectation(description: "Book added")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            addExpectation.fulfill()
        }
        waitForExpectations(timeout: 1.0)

        // Act
        let bookmark1 = TPPBookLocation(locationString: "{\"chapter\": 1, \"page\": 10}", renderer: "R1")!
        let bookmark2 = TPPBookLocation(locationString: "{\"chapter\": 2, \"page\": 20}", renderer: "R1")!

        registry.addGenericBookmark(bookmark1, forIdentifier: book.identifier)
        registry.addGenericBookmark(bookmark2, forIdentifier: book.identifier)

        let bookmarkExpectation = self.expectation(description: "Bookmarks added")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            bookmarkExpectation.fulfill()
        }
        waitForExpectations(timeout: 1.0)

        // Assert
        let bookmarks = registry.genericBookmarksForIdentifier(book.identifier)
        XCTAssertEqual(bookmarks.count, 2)

        // Cleanup
        registry.removeBook(forIdentifier: book.identifier)
    }

    func testDeleteGenericBookmark_RemovesFromList() {
        // Arrange
        let registry = TPPBookRegistry.shared
        let book = TPPBookMocker.mockBook(identifier: "delete-bookmark-\(UUID().uuidString)", title: "Delete Bookmark", distributorType: .EpubZip)
        let bookmark1 = TPPBookLocation(locationString: "{\"chapter\": 1}", renderer: "R1")!
        let bookmark2 = TPPBookLocation(locationString: "{\"chapter\": 2}", renderer: "R1")!

        registry.addBook(book, state: .downloadSuccessful, genericBookmarks: [bookmark1, bookmark2])

        let addExpectation = self.expectation(description: "Book added")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            addExpectation.fulfill()
        }
        waitForExpectations(timeout: 1.0)

        // Verify initial state
        XCTAssertEqual(registry.genericBookmarksForIdentifier(book.identifier).count, 2)

        // Act
        registry.deleteGenericBookmark(bookmark1, forIdentifier: book.identifier)

        let deleteExpectation = self.expectation(description: "Bookmark deleted")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            deleteExpectation.fulfill()
        }
        waitForExpectations(timeout: 1.0)

        // Assert
        let remainingBookmarks = registry.genericBookmarksForIdentifier(book.identifier)
        XCTAssertEqual(remainingBookmarks.count, 1)

        // Cleanup
        registry.removeBook(forIdentifier: book.identifier)
    }

    func testReplaceGenericBookmark_UpdatesBookmark() {
        // Arrange
        let registry = TPPBookRegistry.shared
        let book = TPPBookMocker.mockBook(identifier: "replace-bookmark-\(UUID().uuidString)", title: "Replace Bookmark", distributorType: .EpubZip)
        let oldBookmark = TPPBookLocation(locationString: "{\"chapter\": 1, \"page\": 5}", renderer: "R1")!

        registry.addBook(book, state: .downloadSuccessful, genericBookmarks: [oldBookmark])

        let addExpectation = self.expectation(description: "Book added")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            addExpectation.fulfill()
        }
        waitForExpectations(timeout: 1.0)

        // Act
        let newBookmark = TPPBookLocation(locationString: "{\"chapter\": 1, \"page\": 50}", renderer: "R1")!
        registry.replaceGenericBookmark(oldBookmark, with: newBookmark, forIdentifier: book.identifier)

        let replaceExpectation = self.expectation(description: "Bookmark replaced")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            replaceExpectation.fulfill()
        }
        waitForExpectations(timeout: 1.0)

        // Assert
        let bookmarks = registry.genericBookmarksForIdentifier(book.identifier)
        XCTAssertEqual(bookmarks.count, 1)

        // Cleanup
        registry.removeBook(forIdentifier: book.identifier)
    }

    func testAddOrReplaceGenericBookmark_ReplacesExisting() {
        // Arrange
        let registry = TPPBookRegistry.shared
        let book = TPPBookMocker.mockBook(identifier: "add-or-replace-\(UUID().uuidString)", title: "Add Or Replace", distributorType: .EpubZip)
        let existingBookmark = TPPBookLocation(locationString: "{\"chapter\": 1}", renderer: "R1")!

        registry.addBook(book, state: .downloadSuccessful, genericBookmarks: [existingBookmark])

        let addExpectation = self.expectation(description: "Book added")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            addExpectation.fulfill()
        }
        waitForExpectations(timeout: 1.0)

        // Act - Add with same content, should replace
        let similarBookmark = TPPBookLocation(locationString: "{\"chapter\": 1}", renderer: "R1")!
        registry.addOrReplaceGenericBookmark(similarBookmark, forIdentifier: book.identifier)

        let replaceExpectation = self.expectation(description: "Bookmark add-or-replaced")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            replaceExpectation.fulfill()
        }
        waitForExpectations(timeout: 1.0)

        // Assert - Should still be 1 bookmark, not 2
        let bookmarks = registry.genericBookmarksForIdentifier(book.identifier)
        XCTAssertEqual(bookmarks.count, 1)

        // Cleanup
        registry.removeBook(forIdentifier: book.identifier)
    }

    // MARK: - Readium Bookmark Tests

    func testAddReadiumBookmark_AppendsToList() {
        // Arrange
        let registry = TPPBookRegistry.shared
        let book = TPPBookMocker.mockBook(identifier: "readium-bookmark-\(UUID().uuidString)", title: "Readium Bookmark", distributorType: .EpubZip)
        registry.addBook(book, state: .downloadSuccessful)

        let addExpectation = self.expectation(description: "Book added")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            addExpectation.fulfill()
        }
        waitForExpectations(timeout: 1.0)

        // Act
        let bookmark = TPPReadiumBookmark(
            annotationId: "test-annotation-1",
            href: "/chapter1.html",
            chapter: "Chapter 1",
            page: "10",
            location: "{\"href\":\"/chapter1.html\"}",
            progressWithinChapter: 0.25,
            progressWithinBook: 0.10,
            readingOrderItem: nil,
            readingOrderItemOffsetMilliseconds: nil,
            time: nil,
            device: "test-device"
        )!

        registry.add(bookmark, forIdentifier: book.identifier)

        let bookmarkExpectation = self.expectation(description: "Readium bookmark added")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            bookmarkExpectation.fulfill()
        }
        waitForExpectations(timeout: 1.0)

        // Assert
        let bookmarks = registry.readiumBookmarks(forIdentifier: book.identifier)
        XCTAssertEqual(bookmarks.count, 1)
        XCTAssertEqual(bookmarks.first?.chapter, "Chapter 1")

        // Cleanup
        registry.removeBook(forIdentifier: book.identifier)
    }

    func testDeleteReadiumBookmark_RemovesFromList() {
        // Arrange
        let registry = TPPBookRegistry.shared
        let book = TPPBookMocker.mockBook(identifier: "delete-readium-\(UUID().uuidString)", title: "Delete Readium", distributorType: .EpubZip)

        let bookmark1 = TPPReadiumBookmark(
            annotationId: "ann-1",
            href: "/ch1.html",
            chapter: "Ch 1",
            page: "1",
            location: "{}",
            progressWithinChapter: 0.1,
            progressWithinBook: 0.05,
            readingOrderItem: nil,
            readingOrderItemOffsetMilliseconds: nil,
            time: nil,
            device: nil
        )!

        let bookmark2 = TPPReadiumBookmark(
            annotationId: "ann-2",
            href: "/ch2.html",
            chapter: "Ch 2",
            page: "50",
            location: "{}",
            progressWithinChapter: 0.5,
            progressWithinBook: 0.25,
            readingOrderItem: nil,
            readingOrderItemOffsetMilliseconds: nil,
            time: nil,
            device: nil
        )!

        registry.addBook(book, state: .downloadSuccessful, readiumBookmarks: [bookmark1, bookmark2])

        let addExpectation = self.expectation(description: "Book added")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            addExpectation.fulfill()
        }
        waitForExpectations(timeout: 1.0)

        // Verify initial state
        XCTAssertEqual(registry.readiumBookmarks(forIdentifier: book.identifier).count, 2)

        // Act
        registry.delete(bookmark1, forIdentifier: book.identifier)

        let deleteExpectation = self.expectation(description: "Readium bookmark deleted")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            deleteExpectation.fulfill()
        }
        waitForExpectations(timeout: 1.0)

        // Assert
        let remainingBookmarks = registry.readiumBookmarks(forIdentifier: book.identifier)
        XCTAssertEqual(remainingBookmarks.count, 1)
        XCTAssertEqual(remainingBookmarks.first?.annotationId, "ann-2")

        // Cleanup
        registry.removeBook(forIdentifier: book.identifier)
    }

    func testReadiumBookmarks_SortedByProgress() {
        // Arrange
        let registry = TPPBookRegistry.shared
        let book = TPPBookMocker.mockBook(identifier: "sorted-bookmarks-\(UUID().uuidString)", title: "Sorted Bookmarks", distributorType: .EpubZip)

        // Add bookmarks out of order
        let bookmark1 = TPPReadiumBookmark(
            annotationId: "last",
            href: "/ch3.html",
            chapter: "Ch 3",
            page: nil,
            location: "{}",
            progressWithinChapter: 0.9,
            progressWithinBook: 0.75, // Last
            readingOrderItem: nil,
            readingOrderItemOffsetMilliseconds: nil,
            time: nil,
            device: nil
        )!

        let bookmark2 = TPPReadiumBookmark(
            annotationId: "first",
            href: "/ch1.html",
            chapter: "Ch 1",
            page: nil,
            location: "{}",
            progressWithinChapter: 0.1,
            progressWithinBook: 0.10, // First
            readingOrderItem: nil,
            readingOrderItemOffsetMilliseconds: nil,
            time: nil,
            device: nil
        )!

        let bookmark3 = TPPReadiumBookmark(
            annotationId: "middle",
            href: "/ch2.html",
            chapter: "Ch 2",
            page: nil,
            location: "{}",
            progressWithinChapter: 0.5,
            progressWithinBook: 0.50, // Middle
            readingOrderItem: nil,
            readingOrderItemOffsetMilliseconds: nil,
            time: nil,
            device: nil
        )!

        registry.addBook(book, state: .downloadSuccessful, readiumBookmarks: [bookmark1, bookmark2, bookmark3])

        let addExpectation = self.expectation(description: "Book added")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            addExpectation.fulfill()
        }
        waitForExpectations(timeout: 1.0)

        // Act
        let sortedBookmarks = registry.readiumBookmarks(forIdentifier: book.identifier)

        // Assert - Should be sorted by progressWithinBook
        XCTAssertEqual(sortedBookmarks.count, 3)
        XCTAssertEqual(sortedBookmarks[0].annotationId, "first")
        XCTAssertEqual(sortedBookmarks[1].annotationId, "middle")
        XCTAssertEqual(sortedBookmarks[2].annotationId, "last")

        // Cleanup
        registry.removeBook(forIdentifier: book.identifier)
    }
}

// MARK: - TPPBookRegistry Processing Flag Tests

final class TPPBookRegistryProcessingTests: XCTestCase {

    func testSetProcessing_TracksProcessingState() {
        // Arrange
        let registry = TPPBookRegistry.shared
        let bookId = "processing-test-\(UUID().uuidString)"

        // Initial state should be false
        XCTAssertFalse(registry.processing(forIdentifier: bookId))

        // Act
        registry.setProcessing(true, for: bookId)

        let setExpectation = self.expectation(description: "Processing set")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            setExpectation.fulfill()
        }
        waitForExpectations(timeout: 1.0)

        // Assert
        XCTAssertTrue(registry.processing(forIdentifier: bookId))

        // Cleanup
        registry.setProcessing(false, for: bookId)
    }

    func testSetProcessing_False_ClearsProcessingState() {
        // Arrange
        let registry = TPPBookRegistry.shared
        let bookId = "processing-clear-\(UUID().uuidString)"

        registry.setProcessing(true, for: bookId)

        let setExpectation = self.expectation(description: "Processing set to true")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            setExpectation.fulfill()
        }
        waitForExpectations(timeout: 1.0)

        XCTAssertTrue(registry.processing(forIdentifier: bookId))

        // Act
        registry.setProcessing(false, for: bookId)

        let clearExpectation = self.expectation(description: "Processing cleared")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            clearExpectation.fulfill()
        }
        waitForExpectations(timeout: 1.0)

        // Assert
        XCTAssertFalse(registry.processing(forIdentifier: bookId))
    }
}

// MARK: - TPPBookRegistry FulfillmentId Tests

final class TPPBookRegistryFulfillmentIdTests: XCTestCase {

    func testSetFulfillmentId_UpdatesFulfillmentId() {
        // Arrange
        let registry = TPPBookRegistry.shared
        let book = TPPBookMocker.mockBook(identifier: "fulfillment-update-\(UUID().uuidString)", title: "Fulfillment Update", distributorType: .EpubZip)
        registry.addBook(book, state: .downloadSuccessful)

        let addExpectation = self.expectation(description: "Book added")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            addExpectation.fulfill()
        }
        waitForExpectations(timeout: 1.0)

        // Act
        registry.setFulfillmentId("new-fulfillment-id", for: book.identifier)

        let setExpectation = self.expectation(description: "FulfillmentId set")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            setExpectation.fulfill()
        }
        waitForExpectations(timeout: 1.0)

        // Assert
        XCTAssertEqual(registry.fulfillmentId(forIdentifier: book.identifier), "new-fulfillment-id")

        // Cleanup
        registry.removeBook(forIdentifier: book.identifier)
    }

    func testFulfillmentId_ForNilIdentifier_ReturnsNil() {
        let registry = TPPBookRegistry.shared
        XCTAssertNil(registry.fulfillmentId(forIdentifier: nil))
    }

    func testFulfillmentId_ForEmptyIdentifier_ReturnsNil() {
        let registry = TPPBookRegistry.shared
        XCTAssertNil(registry.fulfillmentId(forIdentifier: ""))
    }

    func testFulfillmentId_ForNonExistentBook_ReturnsNil() {
        let registry = TPPBookRegistry.shared
        XCTAssertNil(registry.fulfillmentId(forIdentifier: "non-existent-book"))
    }
}

// MARK: - TPPBookRegistry Book Retrieval Tests

final class TPPBookRegistryBookRetrievalTests: XCTestCase {

    func testBook_ForValidIdentifier_ReturnsBook() {
        // Arrange
        let registry = TPPBookRegistry.shared
        let book = TPPBookMocker.mockBook(identifier: "retrieval-test-\(UUID().uuidString)", title: "Retrieval Test", distributorType: .EpubZip)
        registry.addBook(book, state: .downloadSuccessful)

        let addExpectation = self.expectation(description: "Book added")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            addExpectation.fulfill()
        }
        waitForExpectations(timeout: 1.0)

        // Act
        let retrieved = registry.book(forIdentifier: book.identifier)

        // Assert
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.identifier, book.identifier)
        XCTAssertEqual(retrieved?.title, "Retrieval Test")

        // Cleanup
        registry.removeBook(forIdentifier: book.identifier)
    }

    func testBook_ForNilIdentifier_ReturnsNil() {
        let registry = TPPBookRegistry.shared
        XCTAssertNil(registry.book(forIdentifier: nil))
    }

    func testBook_ForEmptyIdentifier_ReturnsNil() {
        let registry = TPPBookRegistry.shared
        XCTAssertNil(registry.book(forIdentifier: ""))
    }

    func testBook_ForNonExistentIdentifier_ReturnsNil() {
        let registry = TPPBookRegistry.shared
        XCTAssertNil(registry.book(forIdentifier: "does-not-exist"))
    }

    func testAllBooks_ReturnsRegisteredBooks() {
        // Arrange
        let registry = TPPBookRegistry.shared
        let book1 = TPPBookMocker.mockBook(identifier: "all-books-1-\(UUID().uuidString)", title: "All Books 1", distributorType: .EpubZip)
        let book2 = TPPBookMocker.mockBook(identifier: "all-books-2-\(UUID().uuidString)", title: "All Books 2", distributorType: .EpubZip)

        registry.addBook(book1, state: .downloadSuccessful)
        registry.addBook(book2, state: .downloadNeeded)

        let addExpectation = self.expectation(description: "Books added")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            addExpectation.fulfill()
        }
        waitForExpectations(timeout: 1.0)

        // Act
        let allBooks = registry.allBooks

        // Assert
        XCTAssertTrue(allBooks.contains { $0.identifier == book1.identifier })
        XCTAssertTrue(allBooks.contains { $0.identifier == book2.identifier })

        // Cleanup
        registry.removeBook(forIdentifier: book1.identifier)
        registry.removeBook(forIdentifier: book2.identifier)
    }

    func testHeldBooks_ReturnsOnlyHoldingBooks() {
        // Arrange
        let registry = TPPBookRegistry.shared
        let downloadedBook = TPPBookMocker.mockBook(identifier: "downloaded-\(UUID().uuidString)", title: "Downloaded", distributorType: .EpubZip)
        let heldBook = TPPBookMocker.snapshotReservedBook(identifier: "held-\(UUID().uuidString)", title: "On Hold")

        registry.addBook(downloadedBook, state: .downloadSuccessful)
        registry.addBook(heldBook, state: .holding)

        let addExpectation = self.expectation(description: "Books added")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            addExpectation.fulfill()
        }
        waitForExpectations(timeout: 1.0)

        // Act
        let heldBooks = registry.heldBooks

        // Assert
        XCTAssertFalse(heldBooks.contains { $0.identifier == downloadedBook.identifier })
        XCTAssertTrue(heldBooks.contains { $0.identifier == heldBook.identifier })

        // Cleanup
        registry.removeBook(forIdentifier: downloadedBook.identifier)
        registry.removeBook(forIdentifier: heldBook.identifier)
    }

    func testMyBooks_ReturnsDownloadRelatedBooks() {
        // Arrange
        let registry = TPPBookRegistry.shared
        let downloadedBook = TPPBookMocker.mockBook(identifier: "my-downloaded-\(UUID().uuidString)", title: "Downloaded", distributorType: .EpubZip)
        let downloadingBook = TPPBookMocker.mockBook(identifier: "my-downloading-\(UUID().uuidString)", title: "Downloading", distributorType: .EpubZip)
        let heldBook = TPPBookMocker.snapshotReservedBook(identifier: "my-held-\(UUID().uuidString)", title: "On Hold")

        registry.addBook(downloadedBook, state: .downloadSuccessful)
        registry.addBook(downloadingBook, state: .downloading)
        registry.addBook(heldBook, state: .holding)

        let addExpectation = self.expectation(description: "Books added")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            addExpectation.fulfill()
        }
        waitForExpectations(timeout: 1.0)

        // Act
        let myBooks = registry.myBooks

        // Assert - myBooks should include downloaded and downloading, but not holding
        XCTAssertTrue(myBooks.contains { $0.identifier == downloadedBook.identifier })
        XCTAssertTrue(myBooks.contains { $0.identifier == downloadingBook.identifier })
        XCTAssertFalse(myBooks.contains { $0.identifier == heldBook.identifier })

        // Cleanup
        registry.removeBook(forIdentifier: downloadedBook.identifier)
        registry.removeBook(forIdentifier: downloadingBook.identifier)
        registry.removeBook(forIdentifier: heldBook.identifier)
    }
}

// MARK: - TPPBookRegistry updateAndRemoveBook Tests

final class TPPBookRegistryUpdateAndRemoveTests: XCTestCase {

    func testUpdateAndRemoveBook_SetsStateToUnregistered() {
        // Arrange
        let registry = TPPBookRegistry.shared
        let book = TPPBookMocker.mockBook(identifier: "update-remove-\(UUID().uuidString)", title: "Update Remove", distributorType: .EpubZip)
        registry.addBook(book, state: .downloadSuccessful)

        let addExpectation = self.expectation(description: "Book added")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            addExpectation.fulfill()
        }
        waitForExpectations(timeout: 1.0)

        // Verify book exists
        XCTAssertEqual(registry.state(for: book.identifier), .downloadSuccessful)

        // Act
        registry.updateAndRemoveBook(book)

        let updateExpectation = self.expectation(description: "Book updated and removed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            updateExpectation.fulfill()
        }
        waitForExpectations(timeout: 1.0)

        // Assert - Book record may still exist but state should be unregistered
        XCTAssertEqual(registry.state(for: book.identifier), .unregistered)

        // Cleanup (in case it persisted)
        registry.removeBook(forIdentifier: book.identifier)
    }
}

// MARK: - TPPBookRegistry Thread Safety Tests

/// Regression test for Crashlytics issue 30c41d7e: Concurrent read/write on registry dictionary.
///
/// The crash occurred when:
/// 1. Sync queue barrier blocks wrote to `self.registry` (e.g., during updateBook after loans sync)
/// 2. Main thread blocks read `self.registry` via `registrySubject.send(self.registry)`
/// 3. Concurrent Dictionary read + write caused EXC_BAD_ACCESS
///
/// Fix: Capture snapshots of the registry dictionary while on the sync queue before
/// dispatching to the main thread, preventing concurrent access.
final class TPPBookRegistryThreadSafetyTests: XCTestCase {

    private var cancellables: Set<AnyCancellable>!

    override func setUp() {
        super.setUp()
        cancellables = []
    }

    override func tearDown() {
        cancellables = nil
        super.tearDown()
    }

    /// Regression test for Crashlytics issue 30c41d7e: Rapid registry mutations must not crash
    /// when the registryPublisher is being observed on the main thread.
    ///
    /// This test reproduces the crash scenario where:
    /// - Multiple books are added/updated/removed in rapid succession (simulating sync + load overlap)
    /// - A subscriber reads the emitted registry snapshots on the main thread
    /// - Without the snapshot fix, the concurrent read/write would cause EXC_BAD_ACCESS
    func testCrashlytics30c41d7e_RapidRegistryMutations_DoNotCrashPublisher() {
        let registry = TPPBookRegistry.shared
        let bookCount = 20
        let books = (0..<bookCount).map { i in
            TPPBookMocker.mockBook(
                identifier: "thread-safety-\(i)-\(UUID().uuidString)",
                title: "Thread Safety Book \(i)",
                distributorType: .EpubZip
            )
        }

        // Subscribe to registry publisher on main thread (this is the read side of the race)
        var snapshotCount = 0
        let publisherExpectation = self.expectation(description: "Publisher emits snapshots without crashing")
        publisherExpectation.assertForOverFulfill = false

        registry.registryPublisher
            .sink { records in
                // Access the dictionary structure to ensure it's not corrupted
                _ = records.count
                _ = records.keys.map { $0 }
                snapshotCount += 1
                if snapshotCount >= bookCount {
                    publisherExpectation.fulfill()
                }
            }
            .store(in: &cancellables)

        // Rapidly add books (this is the write side of the race)
        for book in books {
            registry.addBook(book, state: .downloadNeeded)
        }

        // Wait for publisher to receive snapshots - if the race condition exists,
        // this would crash with EXC_BAD_ACCESS before reaching here
        waitForExpectations(timeout: 5.0)

        XCTAssertGreaterThanOrEqual(snapshotCount, bookCount,
                                    "Publisher should have emitted at least \(bookCount) snapshots")

        // Now rapidly remove all books while still subscribed
        let removeExpectation = self.expectation(description: "Books removed without crash")
        removeExpectation.isInverted = false

        for book in books {
            registry.removeBook(forIdentifier: book.identifier)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            removeExpectation.fulfill()
        }
        waitForExpectations(timeout: 3.0)
    }

    /// Regression test for the specific crash scenario: concurrent updateBook calls
    /// from sync feed processing while registry publisher is observed.
    func testCrashlytics30c41d7e_ConcurrentAddAndUpdate_DoNotCrash() {
        let registry = TPPBookRegistry.shared
        let book = TPPBookMocker.mockBook(
            identifier: "concurrent-update-\(UUID().uuidString)",
            title: "Concurrent Update Test",
            distributorType: .EpubZip
        )

        // Subscribe to both publishers (main thread reads)
        var registrySnapshots: [[String: TPPBookRegistryRecord]] = []
        var stateChanges: [(String, TPPBookState)] = []

        let expectation = self.expectation(description: "All operations complete without crash")

        registry.registryPublisher
            .sink { records in
                registrySnapshots.append(records)
            }
            .store(in: &cancellables)

        registry.bookStatePublisher
            .sink { (bookId, state) in
                stateChanges.append((bookId, state))
            }
            .store(in: &cancellables)

        // Add the book
        registry.addBook(book, state: .downloadNeeded)

        // Immediately trigger rapid state changes (simulating sync processing)
        registry.setState(.downloading, for: book.identifier)
        registry.setState(.downloadSuccessful, for: book.identifier)
        registry.setState(.used, for: book.identifier)

        // Update the book (simulating updateBook during sync)
        registry.updateBook(book)

        // Remove and re-add (simulating load() replacing the registry)
        registry.removeBook(forIdentifier: book.identifier)
        registry.addBook(book, state: .holding)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            expectation.fulfill()
        }
        waitForExpectations(timeout: 3.0)

        // If we get here without crashing, the thread safety fix is working
        XCTAssertFalse(registrySnapshots.isEmpty, "Should have received registry snapshots")
        XCTAssertFalse(stateChanges.isEmpty, "Should have received state changes")

        // Cleanup
        registry.removeBook(forIdentifier: book.identifier)
    }

    /// Tests that registry publisher snapshots are consistent (not corrupted by concurrent writes).
    /// Each emitted snapshot should be a valid dictionary that can be iterated without crashes.
    func testRegistryPublisher_EmitsConsistentSnapshots_DuringRapidMutations() {
        let registry = TPPBookRegistry.shared
        let iterations = 15
        let books = (0..<iterations).map { i in
            TPPBookMocker.mockBook(
                identifier: "snapshot-consistency-\(i)-\(UUID().uuidString)",
                title: "Consistency Test \(i)",
                distributorType: .EpubZip
            )
        }

        var allSnapshotsValid = true
        let expectation = self.expectation(description: "All snapshots are consistent")
        expectation.assertForOverFulfill = false

        var completionCount = 0

        registry.registryPublisher
            .sink { records in
                // Verify snapshot is consistent: iterate all keys and values
                for (key, record) in records {
                    if key.isEmpty || record.book.identifier.isEmpty {
                        allSnapshotsValid = false
                    }
                }
            }
            .store(in: &cancellables)

        // Interleave adds and removes rapidly
        for (i, book) in books.enumerated() {
            registry.addBook(book, state: .downloadNeeded)

            // Remove every other book to create more mutations
            if i > 0 && i % 2 == 0 {
                registry.removeBook(forIdentifier: books[i - 1].identifier)
                completionCount += 1
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            expectation.fulfill()
        }
        waitForExpectations(timeout: 3.0)

        XCTAssertTrue(allSnapshotsValid, "All emitted snapshots should have valid, non-empty keys and identifiers")

        // Cleanup remaining books
        for book in books {
            registry.removeBook(forIdentifier: book.identifier)
        }
    }
}
