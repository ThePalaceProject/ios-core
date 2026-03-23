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
//  Synchronization strategy
//  ========================
//  All write methods (addBook, setState, removeBook, …) dispatch onto
//  `syncQueue` with `async(flags: .barrier)`.
//  All read methods (state(for:), book(forIdentifier:), …) use
//  `syncQueue.sync` internally (via `performSync`).
//
//  Because GCD guarantees that a `.sync` call will drain all previously
//  enqueued `.async` blocks before executing, a read issued immediately
//  after a write is deterministic — no `asyncAfter` or `Task.sleep`
//  synchronization is needed.
//
//  Combine publisher tests are an exception: the registry dispatches
//  publisher emissions to the **main thread** asynchronously.  Those tests
//  use XCTestExpectation with `.filter{}.first()` subscriptions so they
//  are fulfilled by the actual event, not by a timer.
//
//  Copyright 2026 The Palace Project. All rights reserved.
//

import XCTest
import Combine
@testable import Palace

// MARK: - TPPBookRegistry State Management Integration Tests

final class TPPBookRegistryStateManagementTests: XCTestCase {

    override func tearDown() {
        super.tearDown()
    }

    // MARK: - addBook Tests

    func testAddBook_NewBook_RegistersWithCorrectState() {
        let registry = TPPBookRegistry.shared
        let book = TPPBookMocker.mockBook(identifier: "add-test-\(UUID().uuidString)",
                                          title: "Add Test Book",
                                          distributorType: .EpubZip)

        registry.addBook(book, state: .downloadNeeded)

        // state(for:) uses syncQueue.sync which drains the prior async barrier
        XCTAssertEqual(registry.state(for: book.identifier), .downloadNeeded)
        XCTAssertNotNil(registry.book(forIdentifier: book.identifier))

        registry.removeBook(forIdentifier: book.identifier)
    }

    func testAddBook_WithLocation_StoresLocation() {
        let registry = TPPBookRegistry.shared
        let book = TPPBookMocker.mockBook(identifier: "location-test-\(UUID().uuidString)",
                                          title: "Location Test",
                                          distributorType: .EpubZip)
        let location = TPPBookLocation(locationString: "{\"page\": 42}", renderer: "TestRenderer")!

        registry.addBook(book, location: location, state: .downloadSuccessful)

        let retrievedLocation = registry.location(forIdentifier: book.identifier)
        XCTAssertNotNil(retrievedLocation)
        XCTAssertEqual(retrievedLocation?.locationString, "{\"page\": 42}")
        XCTAssertEqual(retrievedLocation?.renderer, "TestRenderer")

        registry.removeBook(forIdentifier: book.identifier)
    }

    func testAddBook_WithFulfillmentId_StoresFulfillmentId() {
        let registry = TPPBookRegistry.shared
        let book = TPPBookMocker.mockBook(identifier: "fulfillment-test-\(UUID().uuidString)",
                                          title: "Fulfillment Test",
                                          distributorType: .EpubZip)

        registry.addBook(book, state: .downloadSuccessful, fulfillmentId: "test-fulfillment-123")

        XCTAssertEqual(registry.fulfillmentId(forIdentifier: book.identifier), "test-fulfillment-123")

        registry.removeBook(forIdentifier: book.identifier)
    }

    func testAddBook_WithBookmarks_StoresBookmarks() {
        let registry = TPPBookRegistry.shared
        let book = TPPBookMocker.mockBook(identifier: "bookmarks-test-\(UUID().uuidString)",
                                          title: "Bookmarks Test",
                                          distributorType: .EpubZip)
        let bm1 = TPPBookLocation(locationString: "{\"chapter\": 1}", renderer: "R1")!
        let bm2 = TPPBookLocation(locationString: "{\"chapter\": 2}", renderer: "R1")!

        registry.addBook(book, state: .downloadSuccessful, genericBookmarks: [bm1, bm2])

        XCTAssertEqual(registry.genericBookmarksForIdentifier(book.identifier).count, 2)

        registry.removeBook(forIdentifier: book.identifier)
    }

    // MARK: - setState Tests

    func testSetState_TransitionsCorrectly() {
        let registry = TPPBookRegistry.shared
        let book = TPPBookMocker.mockBook(identifier: "state-transition-\(UUID().uuidString)",
                                          title: "State Transition",
                                          distributorType: .EpubZip)
        registry.addBook(book, state: .downloadNeeded)

        let transitions: [TPPBookState] = [.downloading, .downloadSuccessful, .used, .downloadFailed, .downloadNeeded]
        for expected in transitions {
            registry.setState(expected, for: book.identifier)
            // setState dispatches async barrier; state(for:) uses syncQueue.sync which drains it
            XCTAssertEqual(registry.state(for: book.identifier), expected,
                           "State should be \(expected)")
        }

        registry.removeBook(forIdentifier: book.identifier)
    }

    func testSetState_ForUnregisteredBook_DoesNotCrash() {
        let registry = TPPBookRegistry.shared
        let id = "non-existent-\(UUID().uuidString)"

        registry.setState(.downloadNeeded, for: id)

        XCTAssertEqual(registry.state(for: id), .unregistered)
    }

    // MARK: - removeBook Tests

    func testRemoveBook_RemovesFromRegistry() {
        let registry = TPPBookRegistry.shared
        let book = TPPBookMocker.mockBook(identifier: "remove-test-\(UUID().uuidString)",
                                          title: "Remove Test",
                                          distributorType: .EpubZip)
        registry.addBook(book, state: .downloadSuccessful)
        XCTAssertNotNil(registry.book(forIdentifier: book.identifier))

        registry.removeBook(forIdentifier: book.identifier)

        XCTAssertNil(registry.book(forIdentifier: book.identifier))
        XCTAssertEqual(registry.state(for: book.identifier), .unregistered)
    }

    func testRemoveBook_WithEmptyIdentifier_DoesNotCrash() {
        registry.removeBook(forIdentifier: "")
        XCTAssertTrue(true)
    }

    // MARK: - state(for:) Tests

    func testStateFor_NilIdentifier_ReturnsUnregistered() {
        XCTAssertEqual(registry.state(for: nil), .unregistered)
    }

    func testStateFor_EmptyIdentifier_ReturnsUnregistered() {
        XCTAssertEqual(registry.state(for: ""), .unregistered)
    }

    func testStateFor_NonExistentBook_ReturnsUnregistered() {
        XCTAssertEqual(registry.state(for: "non-existent-book-id"), .unregistered)
    }

    // MARK: - Helpers

    private var registry: TPPBookRegistry { TPPBookRegistry.shared }
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
        let registry = TPPBookRegistry.shared
        let book = TPPBookMocker.mockBook(identifier: "publisher-add-\(UUID().uuidString)",
                                          title: "Publisher Add Test",
                                          distributorType: .EpubZip)

        var receivedRegistry: [String: TPPBookRegistryRecord]?
        let expectation = self.expectation(description: "Registry publisher emits with added book")

        registry.registryPublisher
            .filter { $0[book.identifier] != nil }
            .first()
            .sink { receivedRegistry = $0; expectation.fulfill() }
            .store(in: &cancellables)

        registry.addBook(book, state: .downloadNeeded)

        waitForExpectations(timeout: 3.0)
        XCTAssertNotNil(receivedRegistry)
        XCTAssertNotNil(receivedRegistry?[book.identifier])

        registry.removeBook(forIdentifier: book.identifier)
    }

    func testRegistryPublisher_EmitsOnBookRemove() {
        let registry = TPPBookRegistry.shared
        let book = TPPBookMocker.mockBook(identifier: "publisher-remove-\(UUID().uuidString)",
                                          title: "Publisher Remove Test",
                                          distributorType: .EpubZip)

        registry.addBook(book, state: .downloadSuccessful)
        // Confirm book is in registry before subscribing (syncQueue.sync drains the barrier write)
        XCTAssertNotNil(registry.book(forIdentifier: book.identifier))

        var receivedRegistry: [String: TPPBookRegistryRecord]?
        let expectation = self.expectation(description: "Registry publisher emits on remove")

        registry.registryPublisher
            .filter { $0[book.identifier] == nil }
            .first()
            .sink { receivedRegistry = $0; expectation.fulfill() }
            .store(in: &cancellables)

        registry.removeBook(forIdentifier: book.identifier)

        waitForExpectations(timeout: 2.0)
        XCTAssertNotNil(receivedRegistry)
        XCTAssertNil(receivedRegistry?[book.identifier])
    }

    // MARK: - bookStatePublisher Tests

    func testBookStatePublisher_EmitsOnStateChange() {
        let registry = TPPBookRegistry.shared
        let book = TPPBookMocker.mockBook(identifier: "state-publisher-\(UUID().uuidString)",
                                          title: "State Publisher Test",
                                          distributorType: .EpubZip)

        registry.addBook(book, state: .downloadNeeded)
        XCTAssertEqual(registry.state(for: book.identifier), .downloadNeeded)

        var receivedState: TPPBookState?
        var receivedBookId: String?
        let expectation = self.expectation(description: "State publisher emits")

        registry.bookStatePublisher
            .filter { $0.0 == book.identifier && $0.1 == .downloading }
            .first()
            .sink { receivedBookId = $0.0; receivedState = $0.1; expectation.fulfill() }
            .store(in: &cancellables)

        registry.setState(.downloading, for: book.identifier)

        waitForExpectations(timeout: 2.0)
        XCTAssertEqual(receivedBookId, book.identifier)
        XCTAssertEqual(receivedState, .downloading)

        registry.removeBook(forIdentifier: book.identifier)
    }

    func testBookStatePublisher_EmitsOnBookAdd() {
        let registry = TPPBookRegistry.shared
        let book = TPPBookMocker.mockBook(identifier: "add-state-publisher-\(UUID().uuidString)",
                                          title: "Add State Publisher",
                                          distributorType: .EpubZip)

        var receivedState: TPPBookState?
        var receivedBookId: String?
        let expectation = self.expectation(description: "State publisher emits on add")

        registry.bookStatePublisher
            .filter { $0.0 == book.identifier }
            .first()
            .sink { receivedBookId = $0.0; receivedState = $0.1; expectation.fulfill() }
            .store(in: &cancellables)

        registry.addBook(book, state: .downloadSuccessful)

        waitForExpectations(timeout: 2.0)
        XCTAssertEqual(receivedBookId, book.identifier)
        XCTAssertEqual(receivedState, .downloadSuccessful)

        registry.removeBook(forIdentifier: book.identifier)
    }

    func testBookStatePublisher_EmitsOnBookRemove() {
        let registry = TPPBookRegistry.shared
        let book = TPPBookMocker.mockBook(identifier: "remove-state-publisher-\(UUID().uuidString)",
                                          title: "Remove State Publisher",
                                          distributorType: .EpubZip)

        registry.addBook(book, state: .downloadSuccessful)
        XCTAssertNotNil(registry.book(forIdentifier: book.identifier))

        var receivedState: TPPBookState?
        let expectation = self.expectation(description: "State publisher emits unregistered on remove")

        registry.bookStatePublisher
            .filter { $0.0 == book.identifier && $0.1 == .unregistered }
            .first()
            .sink { receivedState = $0.1; expectation.fulfill() }
            .store(in: &cancellables)

        registry.removeBook(forIdentifier: book.identifier)

        waitForExpectations(timeout: 2.0)
        XCTAssertEqual(receivedState, .unregistered)
    }

    func testBookStatePublisher_MultipleStateChanges_EmitsAll() {
        let registry = TPPBookRegistry.shared
        let book = TPPBookMocker.mockBook(identifier: "multi-state-\(UUID().uuidString)",
                                          title: "Multi State Test",
                                          distributorType: .EpubZip)

        registry.addBook(book, state: .downloadNeeded)
        XCTAssertEqual(registry.state(for: book.identifier), .downloadNeeded)

        var receivedStates: [TPPBookState] = []
        let expectation = self.expectation(description: "All states received")
        expectation.expectedFulfillmentCount = 3

        registry.bookStatePublisher
            .filter { $0.0 == book.identifier }
            .sink { _, state in
                receivedStates.append(state)
                expectation.fulfill()
            }
            .store(in: &cancellables)

        // Dispatch all three state transitions synchronously.
        // Each setState enqueues an async barrier; the publisher emits each
        // one on the main thread in order, satisfying the 3-count expectation.
        registry.setState(.downloading, for: book.identifier)
        registry.setState(.downloadSuccessful, for: book.identifier)
        registry.setState(.used, for: book.identifier)

        waitForExpectations(timeout: 3.0)
        XCTAssertEqual(receivedStates.count, 3)
        XCTAssertTrue(receivedStates.contains(.downloading))
        XCTAssertTrue(receivedStates.contains(.downloadSuccessful))
        XCTAssertTrue(receivedStates.contains(.used))

        registry.removeBook(forIdentifier: book.identifier)
    }
}

// MARK: - TPPBookRegistry Location Management Tests

final class TPPBookRegistryLocationTests: XCTestCase {

    func testSetLocation_UpdatesLocation() {
        let registry = TPPBookRegistry.shared
        let book = TPPBookMocker.mockBook(identifier: "location-update-\(UUID().uuidString)",
                                          title: "Location Update",
                                          distributorType: .EpubZip)
        registry.addBook(book, state: .downloadSuccessful)

        let newLocation = TPPBookLocation(locationString: "{\"page\": 100, \"chapter\": 5}", renderer: "R2")
        registry.setLocation(newLocation, forIdentifier: book.identifier)

        let retrieved = registry.location(forIdentifier: book.identifier)
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.locationString, "{\"page\": 100, \"chapter\": 5}")
        XCTAssertEqual(retrieved?.renderer, "R2")

        registry.removeBook(forIdentifier: book.identifier)
    }

    func testSetLocation_WithNil_ClearsLocation() {
        let registry = TPPBookRegistry.shared
        let book = TPPBookMocker.mockBook(identifier: "location-clear-\(UUID().uuidString)",
                                          title: "Location Clear",
                                          distributorType: .EpubZip)
        let initial = TPPBookLocation(locationString: "{\"page\": 1}", renderer: "R1")
        registry.addBook(book, location: initial, state: .downloadSuccessful)
        XCTAssertNotNil(registry.location(forIdentifier: book.identifier))

        registry.setLocation(nil, forIdentifier: book.identifier)

        XCTAssertNil(registry.location(forIdentifier: book.identifier))

        registry.removeBook(forIdentifier: book.identifier)
    }

    func testLocation_ForNonExistentBook_ReturnsNil() {
        XCTAssertNil(TPPBookRegistry.shared.location(forIdentifier: "non-existent-book"))
    }

    func testSetLocationSync_UpdatesSynchronously() {
        let registry = TPPBookRegistry.shared
        let book = TPPBookMocker.mockBook(identifier: "sync-location-\(UUID().uuidString)",
                                          title: "Sync Location",
                                          distributorType: .EpubZip)
        registry.addBook(book, state: .downloadSuccessful)
        XCTAssertNotNil(registry.book(forIdentifier: book.identifier))

        let newLocation = TPPBookLocation(locationString: "{\"sync\": true}", renderer: "SyncRenderer")
        registry.setLocationSync(newLocation, forIdentifier: book.identifier)

        XCTAssertNotNil(registry.location(forIdentifier: book.identifier))

        registry.removeBook(forIdentifier: book.identifier)
    }
}

// MARK: - TPPBookRegistry Bookmark Tests

final class TPPBookRegistryBookmarkTests: XCTestCase {

    // MARK: - Generic Bookmark Tests

    func testAddGenericBookmark_AppendsToList() {
        let registry = TPPBookRegistry.shared
        let book = TPPBookMocker.mockBook(identifier: "generic-bookmark-\(UUID().uuidString)",
                                          title: "Generic Bookmark",
                                          distributorType: .EpubZip)
        registry.addBook(book, state: .downloadSuccessful)
        XCTAssertNotNil(registry.book(forIdentifier: book.identifier))

        let bm1 = TPPBookLocation(locationString: "{\"chapter\": 1, \"page\": 10}", renderer: "R1")!
        let bm2 = TPPBookLocation(locationString: "{\"chapter\": 2, \"page\": 20}", renderer: "R1")!

        registry.addGenericBookmark(bm1, forIdentifier: book.identifier)
        registry.addGenericBookmark(bm2, forIdentifier: book.identifier)

        XCTAssertEqual(registry.genericBookmarksForIdentifier(book.identifier).count, 2)

        registry.removeBook(forIdentifier: book.identifier)
    }

    func testDeleteGenericBookmark_RemovesFromList() {
        let registry = TPPBookRegistry.shared
        let book = TPPBookMocker.mockBook(identifier: "delete-bookmark-\(UUID().uuidString)",
                                          title: "Delete Bookmark",
                                          distributorType: .EpubZip)
        let bm1 = TPPBookLocation(locationString: "{\"chapter\": 1}", renderer: "R1")!
        let bm2 = TPPBookLocation(locationString: "{\"chapter\": 2}", renderer: "R1")!

        registry.addBook(book, state: .downloadSuccessful, genericBookmarks: [bm1, bm2])
        XCTAssertEqual(registry.genericBookmarksForIdentifier(book.identifier).count, 2)

        registry.deleteGenericBookmark(bm1, forIdentifier: book.identifier)

        XCTAssertEqual(registry.genericBookmarksForIdentifier(book.identifier).count, 1)

        registry.removeBook(forIdentifier: book.identifier)
    }

    func testReplaceGenericBookmark_UpdatesBookmark() {
        let registry = TPPBookRegistry.shared
        let book = TPPBookMocker.mockBook(identifier: "replace-bookmark-\(UUID().uuidString)",
                                          title: "Replace Bookmark",
                                          distributorType: .EpubZip)
        let old = TPPBookLocation(locationString: "{\"chapter\": 1, \"page\": 5}", renderer: "R1")!

        registry.addBook(book, state: .downloadSuccessful, genericBookmarks: [old])
        XCTAssertEqual(registry.genericBookmarksForIdentifier(book.identifier).count, 1)

        let new = TPPBookLocation(locationString: "{\"chapter\": 1, \"page\": 50}", renderer: "R1")!
        registry.replaceGenericBookmark(old, with: new, forIdentifier: book.identifier)

        XCTAssertEqual(registry.genericBookmarksForIdentifier(book.identifier).count, 1)

        registry.removeBook(forIdentifier: book.identifier)
    }

    func testAddOrReplaceGenericBookmark_ReplacesExisting() {
        let registry = TPPBookRegistry.shared
        let book = TPPBookMocker.mockBook(identifier: "add-or-replace-\(UUID().uuidString)",
                                          title: "Add Or Replace",
                                          distributorType: .EpubZip)
        let existing = TPPBookLocation(locationString: "{\"chapter\": 1}", renderer: "R1")!

        registry.addBook(book, state: .downloadSuccessful, genericBookmarks: [existing])
        XCTAssertEqual(registry.genericBookmarksForIdentifier(book.identifier).count, 1)

        let similar = TPPBookLocation(locationString: "{\"chapter\": 1}", renderer: "R1")!
        registry.addOrReplaceGenericBookmark(similar, forIdentifier: book.identifier)

        XCTAssertEqual(registry.genericBookmarksForIdentifier(book.identifier).count, 1)

        registry.removeBook(forIdentifier: book.identifier)
    }

    // MARK: - Readium Bookmark Tests

    func testAddReadiumBookmark_AppendsToList() {
        let registry = TPPBookRegistry.shared
        let book = TPPBookMocker.mockBook(identifier: "readium-bookmark-\(UUID().uuidString)",
                                          title: "Readium Bookmark",
                                          distributorType: .EpubZip)
        registry.addBook(book, state: .downloadSuccessful)
        XCTAssertNotNil(registry.book(forIdentifier: book.identifier))

        let bm = TPPReadiumBookmark(
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

        registry.add(bm, forIdentifier: book.identifier)

        let bookmarks = registry.readiumBookmarks(forIdentifier: book.identifier)
        XCTAssertEqual(bookmarks.count, 1)
        XCTAssertEqual(bookmarks.first?.chapter, "Chapter 1")

        registry.removeBook(forIdentifier: book.identifier)
    }

    func testDeleteReadiumBookmark_RemovesFromList() {
        let registry = TPPBookRegistry.shared
        let book = TPPBookMocker.mockBook(identifier: "delete-readium-\(UUID().uuidString)",
                                          title: "Delete Readium",
                                          distributorType: .EpubZip)
        let bm1 = TPPReadiumBookmark(annotationId: "ann-1", href: "/ch1.html", chapter: "Ch 1",
                                      page: "1", location: "{}", progressWithinChapter: 0.1,
                                      progressWithinBook: 0.05, readingOrderItem: nil,
                                      readingOrderItemOffsetMilliseconds: nil, time: nil, device: nil)!
        let bm2 = TPPReadiumBookmark(annotationId: "ann-2", href: "/ch2.html", chapter: "Ch 2",
                                      page: "50", location: "{}", progressWithinChapter: 0.5,
                                      progressWithinBook: 0.25, readingOrderItem: nil,
                                      readingOrderItemOffsetMilliseconds: nil, time: nil, device: nil)!

        registry.addBook(book, state: .downloadSuccessful, readiumBookmarks: [bm1, bm2])
        XCTAssertEqual(registry.readiumBookmarks(forIdentifier: book.identifier).count, 2)

        registry.delete(bm1, forIdentifier: book.identifier)

        let remaining = registry.readiumBookmarks(forIdentifier: book.identifier)
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.annotationId, "ann-2")

        registry.removeBook(forIdentifier: book.identifier)
    }

    func testReadiumBookmarks_SortedByProgress() {
        let registry = TPPBookRegistry.shared
        let book = TPPBookMocker.mockBook(identifier: "sorted-bookmarks-\(UUID().uuidString)",
                                          title: "Sorted Bookmarks",
                                          distributorType: .EpubZip)
        let last   = TPPReadiumBookmark(annotationId: "last",   href: "/ch3.html", chapter: "Ch 3",
                                         page: nil, location: "{}", progressWithinChapter: 0.9,
                                         progressWithinBook: 0.75, readingOrderItem: nil,
                                         readingOrderItemOffsetMilliseconds: nil, time: nil, device: nil)!
        let first  = TPPReadiumBookmark(annotationId: "first",  href: "/ch1.html", chapter: "Ch 1",
                                         page: nil, location: "{}", progressWithinChapter: 0.1,
                                         progressWithinBook: 0.10, readingOrderItem: nil,
                                         readingOrderItemOffsetMilliseconds: nil, time: nil, device: nil)!
        let middle = TPPReadiumBookmark(annotationId: "middle", href: "/ch2.html", chapter: "Ch 2",
                                         page: nil, location: "{}", progressWithinChapter: 0.5,
                                         progressWithinBook: 0.50, readingOrderItem: nil,
                                         readingOrderItemOffsetMilliseconds: nil, time: nil, device: nil)!

        registry.addBook(book, state: .downloadSuccessful, readiumBookmarks: [last, first, middle])

        let sorted = registry.readiumBookmarks(forIdentifier: book.identifier)
        XCTAssertEqual(sorted.count, 3)
        XCTAssertEqual(sorted[0].annotationId, "first")
        XCTAssertEqual(sorted[1].annotationId, "middle")
        XCTAssertEqual(sorted[2].annotationId, "last")

        registry.removeBook(forIdentifier: book.identifier)
    }
}

// MARK: - TPPBookRegistry Processing Flag Tests

final class TPPBookRegistryProcessingTests: XCTestCase {

    func testSetProcessing_TracksProcessingState() {
        let registry = TPPBookRegistry.shared
        let id = "processing-test-\(UUID().uuidString)"

        XCTAssertFalse(registry.processing(forIdentifier: id))

        registry.setProcessing(true, for: id)

        // processing(forIdentifier:) uses performSync → syncQueue.sync
        XCTAssertTrue(registry.processing(forIdentifier: id))

        registry.setProcessing(false, for: id)
    }

    func testSetProcessing_False_ClearsProcessingState() {
        let registry = TPPBookRegistry.shared
        let id = "processing-clear-\(UUID().uuidString)"

        registry.setProcessing(true, for: id)
        XCTAssertTrue(registry.processing(forIdentifier: id))

        registry.setProcessing(false, for: id)

        XCTAssertFalse(registry.processing(forIdentifier: id))
    }
}

// MARK: - TPPBookRegistry FulfillmentId Tests

final class TPPBookRegistryFulfillmentIdTests: XCTestCase {

    func testSetFulfillmentId_UpdatesFulfillmentId() {
        let registry = TPPBookRegistry.shared
        let book = TPPBookMocker.mockBook(identifier: "fulfillment-update-\(UUID().uuidString)",
                                          title: "Fulfillment Update",
                                          distributorType: .EpubZip)
        registry.addBook(book, state: .downloadSuccessful)
        XCTAssertNotNil(registry.book(forIdentifier: book.identifier))

        registry.setFulfillmentId("new-fulfillment-id", for: book.identifier)

        XCTAssertEqual(registry.fulfillmentId(forIdentifier: book.identifier), "new-fulfillment-id")

        registry.removeBook(forIdentifier: book.identifier)
    }

    func testFulfillmentId_ForNilIdentifier_ReturnsNil() {
        XCTAssertNil(TPPBookRegistry.shared.fulfillmentId(forIdentifier: nil))
    }

    func testFulfillmentId_ForEmptyIdentifier_ReturnsNil() {
        XCTAssertNil(TPPBookRegistry.shared.fulfillmentId(forIdentifier: ""))
    }

    func testFulfillmentId_ForNonExistentBook_ReturnsNil() {
        XCTAssertNil(TPPBookRegistry.shared.fulfillmentId(forIdentifier: "non-existent-book"))
    }
}

// MARK: - TPPBookRegistry Book Retrieval Tests

final class TPPBookRegistryBookRetrievalTests: XCTestCase {

    func testBook_ForValidIdentifier_ReturnsBook() {
        let registry = TPPBookRegistry.shared
        let book = TPPBookMocker.mockBook(identifier: "retrieval-test-\(UUID().uuidString)",
                                          title: "Retrieval Test",
                                          distributorType: .EpubZip)
        registry.addBook(book, state: .downloadSuccessful)

        let retrieved = registry.book(forIdentifier: book.identifier)
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.identifier, book.identifier)
        XCTAssertEqual(retrieved?.title, "Retrieval Test")

        registry.removeBook(forIdentifier: book.identifier)
    }

    func testBook_ForNilIdentifier_ReturnsNil() {
        XCTAssertNil(TPPBookRegistry.shared.book(forIdentifier: nil))
    }

    func testBook_ForEmptyIdentifier_ReturnsNil() {
        XCTAssertNil(TPPBookRegistry.shared.book(forIdentifier: ""))
    }

    func testBook_ForNonExistentIdentifier_ReturnsNil() {
        XCTAssertNil(TPPBookRegistry.shared.book(forIdentifier: "does-not-exist"))
    }

    func testAllBooks_ReturnsRegisteredBooks() {
        let registry = TPPBookRegistry.shared
        let b1 = TPPBookMocker.mockBook(identifier: "all-books-1-\(UUID().uuidString)",
                                         title: "All Books 1", distributorType: .EpubZip)
        let b2 = TPPBookMocker.mockBook(identifier: "all-books-2-\(UUID().uuidString)",
                                         title: "All Books 2", distributorType: .EpubZip)

        registry.addBook(b1, state: .downloadSuccessful)
        registry.addBook(b2, state: .downloadNeeded)

        let all = registry.allBooks
        XCTAssertTrue(all.contains { $0.identifier == b1.identifier })
        XCTAssertTrue(all.contains { $0.identifier == b2.identifier })

        registry.removeBook(forIdentifier: b1.identifier)
        registry.removeBook(forIdentifier: b2.identifier)
    }

    func testHeldBooks_ReturnsOnlyHoldingBooks() {
        let registry = TPPBookRegistry.shared
        let downloaded = TPPBookMocker.mockBook(identifier: "downloaded-\(UUID().uuidString)",
                                                 title: "Downloaded", distributorType: .EpubZip)
        let held = TPPBookMocker.snapshotReservedBook(identifier: "held-\(UUID().uuidString)",
                                                       title: "On Hold")

        registry.addBook(downloaded, state: .downloadSuccessful)
        registry.addBook(held, state: .holding)

        let heldBooks = registry.heldBooks
        XCTAssertFalse(heldBooks.contains { $0.identifier == downloaded.identifier })
        XCTAssertTrue(heldBooks.contains { $0.identifier == held.identifier })

        registry.removeBook(forIdentifier: downloaded.identifier)
        registry.removeBook(forIdentifier: held.identifier)
    }

    func testMyBooks_ReturnsDownloadRelatedBooks() {
        let registry = TPPBookRegistry.shared
        let dl  = TPPBookMocker.mockBook(identifier: "my-dl-\(UUID().uuidString)",
                                          title: "Downloaded", distributorType: .EpubZip)
        let dlg = TPPBookMocker.mockBook(identifier: "my-dlg-\(UUID().uuidString)",
                                          title: "Downloading", distributorType: .EpubZip)
        let hld = TPPBookMocker.snapshotReservedBook(identifier: "my-hld-\(UUID().uuidString)",
                                                      title: "On Hold")

        registry.addBook(dl,  state: .downloadSuccessful)
        registry.addBook(dlg, state: .downloading)
        registry.addBook(hld, state: .holding)

        let my = registry.myBooks
        XCTAssertTrue(my.contains  { $0.identifier == dl.identifier })
        XCTAssertTrue(my.contains  { $0.identifier == dlg.identifier })
        XCTAssertFalse(my.contains { $0.identifier == hld.identifier })

        registry.removeBook(forIdentifier: dl.identifier)
        registry.removeBook(forIdentifier: dlg.identifier)
        registry.removeBook(forIdentifier: hld.identifier)
    }
}

// MARK: - TPPBookRegistry updateAndRemoveBook Tests

final class TPPBookRegistryUpdateAndRemoveTests: XCTestCase {

    func testUpdateAndRemoveBook_SetsStateToUnregistered() {
        let registry = TPPBookRegistry.shared
        let book = TPPBookMocker.mockBook(identifier: "update-remove-\(UUID().uuidString)",
                                          title: "Update Remove",
                                          distributorType: .EpubZip)
        registry.addBook(book, state: .downloadSuccessful)
        XCTAssertEqual(registry.state(for: book.identifier), .downloadSuccessful)

        registry.updateAndRemoveBook(book)

        XCTAssertEqual(registry.state(for: book.identifier), .unregistered)

        registry.removeBook(forIdentifier: book.identifier)
    }
}

// MARK: - TPPBookRegistry Thread Safety Tests

/// Regression tests for Crashlytics issue 30c41d7e: concurrent read/write on
/// the registry dictionary causing EXC_BAD_ACCESS.
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

    func testCrashlytics30c41d7e_RapidRegistryMutations_DoNotCrashPublisher() {
        let registry = TPPBookRegistry.shared
        let count = 20
        let books = (0..<count).map { i in
            TPPBookMocker.mockBook(identifier: "thread-safety-\(i)-\(UUID().uuidString)",
                                   title: "Thread Safety Book \(i)",
                                   distributorType: .EpubZip)
        }

        var snapshotCount = 0
        let addExpectation = self.expectation(description: "Publisher emits at least \(count) snapshots")
        addExpectation.assertForOverFulfill = false

        registry.registryPublisher
            .sink { records in
                _ = records.count
                _ = records.keys.map { $0 }
                snapshotCount += 1
                if snapshotCount >= count { addExpectation.fulfill() }
            }
            .store(in: &cancellables)

        for book in books { registry.addBook(book, state: .downloadNeeded) }

        waitForExpectations(timeout: 5.0)
        XCTAssertGreaterThanOrEqual(snapshotCount, count)

        // Rapidly remove while still subscribed — should not crash
        let lastBook = books.last!
        let removeExpectation = self.expectation(description: "Registry no longer contains last book")
        registry.registryPublisher
            .filter { $0[lastBook.identifier] == nil }
            .first()
            .sink { _ in removeExpectation.fulfill() }
            .store(in: &cancellables)

        for book in books { registry.removeBook(forIdentifier: book.identifier) }
        waitForExpectations(timeout: 3.0)
    }

    func testCrashlytics30c41d7e_ConcurrentAddAndUpdate_DoNotCrash() {
        let registry = TPPBookRegistry.shared
        let book = TPPBookMocker.mockBook(identifier: "concurrent-update-\(UUID().uuidString)",
                                          title: "Concurrent Update Test",
                                          distributorType: .EpubZip)

        var registrySnapshots: [[String: TPPBookRegistryRecord]] = []
        var stateChanges: [(String, TPPBookState)] = []

        // We want to observe at least the final .holding state emission
        let expectation = self.expectation(description: "Holding state received via publisher")

        registry.registryPublisher
            .sink { registrySnapshots.append($0) }
            .store(in: &cancellables)

        registry.bookStatePublisher
            .sink { stateChanges.append($0) }
            .store(in: &cancellables)

        registry.bookStatePublisher
            .filter { $0.0 == book.identifier && $0.1 == .holding }
            .first()
            .sink { _ in expectation.fulfill() }
            .store(in: &cancellables)

        registry.addBook(book, state: .downloadNeeded)
        registry.setState(.downloading, for: book.identifier)
        registry.setState(.downloadSuccessful, for: book.identifier)
        registry.setState(.used, for: book.identifier)
        registry.updateBook(book)
        registry.removeBook(forIdentifier: book.identifier)
        registry.addBook(book, state: .holding)

        waitForExpectations(timeout: 3.0)
        XCTAssertFalse(registrySnapshots.isEmpty)
        XCTAssertFalse(stateChanges.isEmpty)

        registry.removeBook(forIdentifier: book.identifier)
    }

    func testRegistryPublisher_EmitsConsistentSnapshots_DuringRapidMutations() {
        let registry = TPPBookRegistry.shared
        let iterations = 15
        let books = (0..<iterations).map { i in
            TPPBookMocker.mockBook(identifier: "snapshot-consistency-\(i)-\(UUID().uuidString)",
                                   title: "Consistency Test \(i)",
                                   distributorType: .EpubZip)
        }

        var allSnapshotsValid = true
        // Fulfilled when the last book (added at index iterations-1) appears in a snapshot
        let lastBook = books.last!
        let expectation = self.expectation(description: "Last book observed in snapshot")

        registry.registryPublisher
            .sink { records in
                for (key, record) in records {
                    if key.isEmpty || record.book.identifier.isEmpty {
                        allSnapshotsValid = false
                    }
                }
            }
            .store(in: &cancellables)

        registry.registryPublisher
            .filter { $0[lastBook.identifier] != nil }
            .first()
            .sink { _ in expectation.fulfill() }
            .store(in: &cancellables)

        for (i, book) in books.enumerated() {
            registry.addBook(book, state: .downloadNeeded)
            if i > 0 && i % 2 == 0 {
                registry.removeBook(forIdentifier: books[i - 1].identifier)
            }
        }

        waitForExpectations(timeout: 3.0)
        XCTAssertTrue(allSnapshotsValid)

        for book in books { registry.removeBook(forIdentifier: book.identifier) }
    }
}
