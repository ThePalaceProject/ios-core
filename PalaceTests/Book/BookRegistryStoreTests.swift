//
//  BookRegistryStoreTests.swift
//  PalaceTests
//
//  Tests for BookRegistryStore: thread-safe CRUD, queries, state transitions,
//  Combine subjects, processing flags, and bulk operations.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import XCTest
import Combine
@testable import Palace

final class BookRegistryStoreTests: XCTestCase {

    private var store: BookRegistryStore!
    private var cancellables: Set<AnyCancellable>!

    // MARK: - Helpers

    override func setUp() {
        super.setUp()
        store = BookRegistryStore()
        cancellables = []
    }

    override func tearDown() {
        cancellables = nil
        store = nil
        super.tearDown()
    }

    private func makeBook(
        identifier: String = "book-1",
        title: String = "Test Book"
    ) -> TPPBook {
        TPPBook(
            acquisitions: [TPPFake.genericAcquisition],
            authors: [TPPBookAuthor(authorName: "Author", relatedBooksURL: nil)],
            categoryStrings: ["Fiction"],
            distributor: nil,
            identifier: identifier,
            imageURL: nil,
            imageThumbnailURL: nil,
            published: nil,
            publisher: nil,
            subtitle: nil,
            summary: nil,
            title: title,
            updated: Date(),
            annotationsURL: nil,
            analyticsURL: nil,
            alternateURL: nil,
            relatedWorksURL: nil,
            previewLink: nil,
            seriesURL: nil,
            revokeURL: nil,
            reportURL: nil,
            timeTrackingURL: nil,
            contributors: nil,
            bookDuration: nil,
            imageCache: MockImageCache()
        )
    }

    // MARK: - Add / Retrieve

    func test_addBook_thenRetrieve() {
        let book = makeBook()
        let addExpectation = expectation(description: "add completes")

        store.addBook(book, state: .downloadNeeded) { snapshot in
            XCTAssertEqual(snapshot.count, 1)
            XCTAssertEqual(snapshot[book.identifier]?.state, .downloadNeeded)
            addExpectation.fulfill()
        }

        wait(for: [addExpectation], timeout: 2.0)

        // Allow the async barrier to complete
        let readExpectation = expectation(description: "read after add")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let retrieved = self.store.book(forIdentifier: book.identifier)
            XCTAssertEqual(retrieved?.identifier, book.identifier)
            XCTAssertEqual(retrieved?.title, "Test Book")
            readExpectation.fulfill()
        }
        wait(for: [readExpectation], timeout: 2.0)
    }

    func test_bookForIdentifier_nilIdentifier_returnsNil() {
        XCTAssertNil(store.book(forIdentifier: nil))
    }

    func test_bookForIdentifier_emptyString_returnsNil() {
        XCTAssertNil(store.book(forIdentifier: ""))
    }

    func test_bookForIdentifier_nonexistent_returnsNil() {
        XCTAssertNil(store.book(forIdentifier: "nonexistent"))
    }

    // MARK: - State

    func test_stateForNilIdentifier_returnsUnregistered() {
        let state = store.state(for: nil)
        XCTAssertEqual(state, .unregistered)
    }

    func test_stateForEmptyIdentifier_returnsUnregistered() {
        let state = store.state(for: "")
        XCTAssertEqual(state, .unregistered)
    }

    func test_stateForMissingBook_returnsUnregistered() {
        let state = store.state(for: "missing-id")
        XCTAssertEqual(state, .unregistered)
    }

    func test_setState_updatesState() {
        let book = makeBook()
        let addDone = expectation(description: "added")
        store.addBook(book, state: .downloadNeeded) { _ in addDone.fulfill() }
        wait(for: [addDone], timeout: 2.0)

        let setDone = expectation(description: "state set")
        store.setState(.downloadSuccessful, for: book.identifier) {
            setDone.fulfill()
        }
        wait(for: [setDone], timeout: 2.0)

        // Read after barrier completes
        let verify = expectation(description: "verify state")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(self.store.state(for: book.identifier), .downloadSuccessful)
            verify.fulfill()
        }
        wait(for: [verify], timeout: 2.0)
    }

    // MARK: - Remove

    func test_removeBook_removesFromRegistry() {
        let book = makeBook()
        let addDone = expectation(description: "added")
        store.addBook(book, state: .downloadNeeded) { _ in addDone.fulfill() }
        wait(for: [addDone], timeout: 2.0)

        let removeDone = expectation(description: "removed")
        store.removeBook(forIdentifier: book.identifier) { removedBook, snapshot in
            XCTAssertEqual(removedBook?.identifier, book.identifier)
            XCTAssertTrue(snapshot.isEmpty)
            removeDone.fulfill()
        }
        wait(for: [removeDone], timeout: 2.0)

        let verify = expectation(description: "verify")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertNil(self.store.book(forIdentifier: book.identifier))
            verify.fulfill()
        }
        wait(for: [verify], timeout: 2.0)
    }

    func test_removeBook_nonexistentId_completesWithNilBook() {
        let removeDone = expectation(description: "removed")
        store.removeBook(forIdentifier: "nonexistent") { removedBook, snapshot in
            XCTAssertNil(removedBook)
            XCTAssertTrue(snapshot.isEmpty)
            removeDone.fulfill()
        }
        wait(for: [removeDone], timeout: 2.0)
    }

    // MARK: - Query: allBooks, heldBooks, myBooks

    func test_allBooks_returnsAllRegisteredBooks() {
        let book1 = makeBook(identifier: "b1", title: "Book 1")
        let book2 = makeBook(identifier: "b2", title: "Book 2")

        let done = expectation(description: "books added")
        done.expectedFulfillmentCount = 2
        store.addBook(book1, state: .downloadNeeded) { _ in done.fulfill() }
        store.addBook(book2, state: .holding) { _ in done.fulfill() }
        wait(for: [done], timeout: 2.0)

        let verify = expectation(description: "verify")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let allBooks = self.store.allBooks
            XCTAssertEqual(allBooks.count, 2)
            let ids = Set(allBooks.map { $0.identifier })
            XCTAssertTrue(ids.contains("b1"))
            XCTAssertTrue(ids.contains("b2"))
            verify.fulfill()
        }
        wait(for: [verify], timeout: 2.0)
    }

    func test_heldBooks_onlyReturnsHoldingState() {
        let held = makeBook(identifier: "held-1")
        let downloading = makeBook(identifier: "dl-1")

        let done = expectation(description: "added")
        done.expectedFulfillmentCount = 2
        store.addBook(held, state: .holding) { _ in done.fulfill() }
        store.addBook(downloading, state: .downloading) { _ in done.fulfill() }
        wait(for: [done], timeout: 2.0)

        let verify = expectation(description: "verify")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let heldBooks = self.store.heldBooks
            XCTAssertEqual(heldBooks.count, 1)
            XCTAssertEqual(heldBooks.first?.identifier, "held-1")
            verify.fulfill()
        }
        wait(for: [verify], timeout: 2.0)
    }

    func test_myBooks_returnsCorrectStates() {
        let book1 = makeBook(identifier: "dn")
        let book2 = makeBook(identifier: "ds")
        let book3 = makeBook(identifier: "df")
        let book4 = makeBook(identifier: "used")
        let book5 = makeBook(identifier: "held")

        let done = expectation(description: "added")
        done.expectedFulfillmentCount = 5
        store.addBook(book1, state: .downloadNeeded) { _ in done.fulfill() }
        store.addBook(book2, state: .downloadSuccessful) { _ in done.fulfill() }
        store.addBook(book3, state: .downloadFailed) { _ in done.fulfill() }
        store.addBook(book4, state: .used) { _ in done.fulfill() }
        store.addBook(book5, state: .holding) { _ in done.fulfill() }
        wait(for: [done], timeout: 2.0)

        let verify = expectation(description: "verify")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let myBooks = self.store.myBooks
            // myBooks includes: downloadNeeded, downloading, SAMLStarted, downloadFailed, downloadSuccessful, used
            // NOT holding
            XCTAssertEqual(myBooks.count, 4)
            let ids = Set(myBooks.map { $0.identifier })
            XCTAssertTrue(ids.contains("dn"))
            XCTAssertTrue(ids.contains("ds"))
            XCTAssertTrue(ids.contains("df"))
            XCTAssertTrue(ids.contains("used"))
            XCTAssertFalse(ids.contains("held"))
            verify.fulfill()
        }
        wait(for: [verify], timeout: 2.0)
    }

    // MARK: - FulfillmentId

    func test_fulfillmentId_setAndGet() {
        let book = makeBook()
        let addDone = expectation(description: "added")
        store.addBook(book, state: .downloadNeeded, fulfillmentId: "initial-fid") { _ in
            addDone.fulfill()
        }
        wait(for: [addDone], timeout: 2.0)

        let verify1 = expectation(description: "verify initial")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(self.store.fulfillmentId(forIdentifier: book.identifier), "initial-fid")
            verify1.fulfill()
        }
        wait(for: [verify1], timeout: 2.0)

        store.setFulfillmentId("updated-fid", for: book.identifier)

        let verify2 = expectation(description: "verify updated")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            XCTAssertEqual(self.store.fulfillmentId(forIdentifier: book.identifier), "updated-fid")
            verify2.fulfill()
        }
        wait(for: [verify2], timeout: 2.0)
    }

    func test_fulfillmentId_nilIdentifier_returnsNil() {
        XCTAssertNil(store.fulfillmentId(forIdentifier: nil))
    }

    func test_fulfillmentId_emptyIdentifier_returnsNil() {
        XCTAssertNil(store.fulfillmentId(forIdentifier: ""))
    }

    // MARK: - Processing

    func test_processing_defaultsFalse() {
        XCTAssertFalse(store.processing(forIdentifier: "any-id"))
    }

    func test_setProcessing_true_thenFalse() {
        let notifExpectation = expectation(forNotification: .TPPBookProcessingDidChange, object: nil) { notif in
            let id = notif.userInfo?[TPPNotificationKeys.bookProcessingBookIDKey] as? String
            let value = notif.userInfo?[TPPNotificationKeys.bookProcessingValueKey] as? Bool
            return id == "book-1" && value == true
        }

        store.setProcessing(true, for: "book-1")
        wait(for: [notifExpectation], timeout: 2.0)

        let verify = expectation(description: "verify processing true")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertTrue(self.store.processing(forIdentifier: "book-1"))
            verify.fulfill()
        }
        wait(for: [verify], timeout: 2.0)

        let notifExpectation2 = expectation(forNotification: .TPPBookProcessingDidChange, object: nil) { notif in
            let value = notif.userInfo?[TPPNotificationKeys.bookProcessingValueKey] as? Bool
            return value == false
        }

        store.setProcessing(false, for: "book-1")
        wait(for: [notifExpectation2], timeout: 2.0)

        let verify2 = expectation(description: "verify processing false")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertFalse(self.store.processing(forIdentifier: "book-1"))
            verify2.fulfill()
        }
        wait(for: [verify2], timeout: 2.0)
    }

    // MARK: - RemoveAll

    func test_removeAll_clearsRegistry() {
        let book1 = makeBook(identifier: "a")
        let book2 = makeBook(identifier: "b")

        let done = expectation(description: "added")
        done.expectedFulfillmentCount = 2
        store.addBook(book1, state: .downloadNeeded) { _ in done.fulfill() }
        store.addBook(book2, state: .holding) { _ in done.fulfill() }
        wait(for: [done], timeout: 2.0)

        store.removeAll()

        let verify = expectation(description: "verify empty")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            XCTAssertTrue(self.store.allBooks.isEmpty)
            XCTAssertNil(self.store.book(forIdentifier: "a"))
            XCTAssertNil(self.store.book(forIdentifier: "b"))
            verify.fulfill()
        }
        wait(for: [verify], timeout: 2.0)
    }

    // MARK: - Combine Subjects

    func test_registrySubject_emitsOnAdd() {
        let book = makeBook()
        let received = expectation(description: "received snapshot")

        // Skip the initial empty value
        var receivedCount = 0
        store.registrySubject
            .dropFirst()
            .sink { snapshot in
                receivedCount += 1
                if snapshot[book.identifier] != nil {
                    received.fulfill()
                }
            }
            .store(in: &cancellables)

        store.addBook(book, state: .downloadNeeded)
        wait(for: [received], timeout: 3.0)
    }

    // MARK: - MutateRegistrySync

    func test_mutateRegistrySync_directMutation() {
        let book = makeBook()
        let addDone = expectation(description: "added")
        store.addBook(book, state: .downloadNeeded) { _ in addDone.fulfill() }
        wait(for: [addDone], timeout: 2.0)

        // Wait for barrier to complete
        let ready = expectation(description: "ready")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { ready.fulfill() }
        wait(for: [ready], timeout: 2.0)

        store.mutateRegistrySync { registry in
            registry[book.identifier]?.state = .downloadFailed
        }

        XCTAssertEqual(store.state(for: book.identifier), .downloadFailed)
    }

    func test_readRegistry_returnsSnapshot() {
        let book = makeBook()
        let addDone = expectation(description: "added")
        store.addBook(book, state: .holding) { _ in addDone.fulfill() }
        wait(for: [addDone], timeout: 2.0)

        let ready = expectation(description: "ready")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { ready.fulfill() }
        wait(for: [ready], timeout: 2.0)

        let count = store.readRegistry { registry in
            registry.count
        }
        XCTAssertEqual(count, 1)
    }

    // MARK: - RegistrySnapshot

    func test_registrySnapshot_returnsDictionaryRepresentations() {
        let book = makeBook()
        let addDone = expectation(description: "added")
        store.addBook(book, state: .downloadNeeded) { _ in addDone.fulfill() }
        wait(for: [addDone], timeout: 2.0)

        let ready = expectation(description: "ready")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { ready.fulfill() }
        wait(for: [ready], timeout: 2.0)

        let snapshot = store.registrySnapshot()
        XCTAssertEqual(snapshot.count, 1)
        // Each element should be a dictionary representation
        XCTAssertTrue(snapshot.first is [String: Any])
    }

    // MARK: - UpdateAndRemoveBook

    func test_updateAndRemoveBook_setsStateUnregistered() {
        let book = makeBook()
        let addDone = expectation(description: "added")
        store.addBook(book, state: .downloadSuccessful) { _ in addDone.fulfill() }
        wait(for: [addDone], timeout: 2.0)

        let updateDone = expectation(description: "updated and removed")
        store.updateAndRemoveBook(book) { snapshot in
            // The record should still exist but with state unregistered
            let record = snapshot[book.identifier]
            XCTAssertEqual(record?.state, .unregistered)
            updateDone.fulfill()
        }
        wait(for: [updateDone], timeout: 2.0)
    }

    // MARK: - Thread Safety Under Concurrent Access

    func test_concurrentReadsAndWrites_noDataRace() {
        let iterations = 50
        let group = DispatchGroup()

        // Concurrent writes
        for i in 0..<iterations {
            group.enter()
            DispatchQueue.global().async {
                let book = self.makeBook(identifier: "book-\(i)", title: "Title \(i)")
                self.store.addBook(book, state: .downloadNeeded) { _ in
                    group.leave()
                }
            }
        }

        // Concurrent reads interleaved
        for i in 0..<iterations {
            group.enter()
            DispatchQueue.global().async {
                _ = self.store.book(forIdentifier: "book-\(i)")
                _ = self.store.state(for: "book-\(i)")
                _ = self.store.allBooks
                group.leave()
            }
        }

        let done = expectation(description: "all done")
        group.notify(queue: .main) { done.fulfill() }
        wait(for: [done], timeout: 10.0)

        // After all writes, we should have some books
        let finalCount = store.allBooks.count
        XCTAssertGreaterThan(finalCount, 0)
        XCTAssertLessThanOrEqual(finalCount, iterations)
    }

    // MARK: - AddBook with Location and Bookmarks

    func test_addBook_withLocationAndBookmarks() {
        let book = makeBook()
        let location = TPPBookLocation(locationString: "{\"page\": 5}", renderer: "test-renderer")
        let bookmark = TPPReadiumBookmark(
            annotationId: "ann-1",
            href: "/chapter1",
            chapter: "Chapter 1",
            page: "5",
            location: "{}",
            progressWithinChapter: 0.5,
            progressWithinBook: 0.1,
            readingOrderItem: nil,
            readingOrderItemOffsetMilliseconds: nil,
            time: "2026-01-01T00:00:00Z",
            device: nil
        )

        let addDone = expectation(description: "added")
        store.addBook(
            book,
            location: location,
            state: .downloadSuccessful,
            fulfillmentId: "fid-123",
            readiumBookmarks: bookmark != nil ? [bookmark!] : nil,
            genericBookmarks: nil
        ) { _ in addDone.fulfill() }
        wait(for: [addDone], timeout: 2.0)

        let verify = expectation(description: "verify")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let record = self.store.record(forIdentifier: book.identifier)
            XCTAssertNotNil(record)
            XCTAssertEqual(record?.state, .downloadSuccessful)
            XCTAssertEqual(record?.fulfillmentId, "fid-123")
            XCTAssertEqual(record?.location?.renderer, "test-renderer")
            XCTAssertEqual(record?.readiumBookmarks?.count, 1)
            verify.fulfill()
        }
        wait(for: [verify], timeout: 2.0)
    }

    // MARK: - Record for nil/empty identifier

    func test_recordForNilIdentifier_returnsNil() {
        XCTAssertNil(store.record(forIdentifier: nil))
    }

    func test_recordForEmptyIdentifier_returnsNil() {
        XCTAssertNil(store.record(forIdentifier: ""))
    }

    // MARK: - UpdatedBookMetadata

    func test_updatedBookMetadata_returnsNilForMissingBook() {
        let book = makeBook(identifier: "missing")
        let result = store.updatedBookMetadata(book)
        XCTAssertNil(result)
    }
}
