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

@MainActor
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

    // nonisolated: pure factory (no isolated state); called from @Sendable
    // dispatch closures in the concurrency stress test — an isolated factory
    // there is a Swift 6 sending error.
    private nonisolated func makeBook(
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

    func test_addBook_thenRetrieve() async {
        let book = makeBook()

        // CONVERTED: expectation+wait(for:) on the addBook completion replaced
        // with the S1 seam join (BookRegistryStore._awaitPendingWritesForTesting).
        // The barrier write is committed by the time the seam resumes, so the
        // registry read below is deterministic — no drainMainQueue needed since
        // `book(forIdentifier:)` is a plain `performSync` read with no main hop.
        store.addBook(book, state: .downloadNeeded)
        await store._awaitPendingWritesForTesting()

        let retrieved = store.book(forIdentifier: book.identifier)
        XCTAssertEqual(retrieved?.identifier, book.identifier)
        XCTAssertEqual(retrieved?.title, "Test Book")
        XCTAssertEqual(store.allBooks.count, 1)
    }

    /// Lookup guards: nil/empty/unknown identifiers must all resolve to a
    /// safe absent value (nil here). Consolidated so a regression on any
    /// branch (e.g. an early return that only handles nil but not "") fails
    /// loudly. Also asserts the positive case in the same test so a mutant
    /// flipping the lookup-hit path is caught here too.
    func test_bookForIdentifier_returnsNilForUnregisteredOrInvalidInputs() async {
        // Negative cases — three distinct invalid-input shapes.
        XCTAssertNil(store.book(forIdentifier: nil),         "nil → nil")
        XCTAssertNil(store.book(forIdentifier: ""),          "empty string → nil")
        XCTAssertNil(store.book(forIdentifier: "missing"),   "unknown id → nil")

        // Positive case — registered book is retrievable, distinguishing
        // "always-nil" mutants from real lookup behaviour.
        let book = makeBook(identifier: "registered")
        store.addBook(book, state: .downloadNeeded)
        await store._awaitPendingWritesForTesting()
        XCTAssertEqual(store.book(forIdentifier: "registered")?.identifier, "registered")
    }

    // MARK: - State

    /// Same guard pattern for `state(for:)` — every invalid-input shape must
    /// resolve to `.unregistered`, and the positive case must surface the
    /// stored state so an "always-unregistered" mutant fails.
    func test_state_returnsUnregisteredForUnregisteredOrInvalidInputs() async {
        XCTAssertEqual(store.state(for: nil),       .unregistered, "nil → .unregistered")
        XCTAssertEqual(store.state(for: ""),        .unregistered, "empty → .unregistered")
        XCTAssertEqual(store.state(for: "unknown"), .unregistered, "unknown id → .unregistered")

        let book = makeBook(identifier: "tracked")
        store.addBook(book, state: .downloadSuccessful)
        await store._awaitPendingWritesForTesting()
        XCTAssertEqual(store.state(for: "tracked"), .downloadSuccessful,
                       "Registered books must surface their stored state, not .unregistered")
    }

    func test_setState_updatesState() async {
        let book = makeBook()
        store.addBook(book, state: .downloadNeeded)
        store.setState(.downloadSuccessful, for: book.identifier)
        // Both barrier writes are enqueued FIFO on the same syncQueue, so a
        // single trailing seam join drains both.
        await store._awaitPendingWritesForTesting()

        XCTAssertEqual(store.state(for: book.identifier), .downloadSuccessful)
    }

    // MARK: - Remove

    func test_removeBook_removesFromRegistry() async {
        let book = makeBook()
        store.addBook(book, state: .downloadNeeded)
        await store._awaitPendingWritesForTesting()

        var removedBook: TPPBook?
        var snapshotAfterRemove: [String: TPPBookRegistryRecord] = [:]
        store.removeBook(forIdentifier: book.identifier) { removed, snapshot in
            removedBook = removed
            snapshotAfterRemove = snapshot
        }
        await store._awaitPendingWritesForTesting()

        XCTAssertEqual(removedBook?.identifier, book.identifier)
        XCTAssertTrue(snapshotAfterRemove.isEmpty)
        XCTAssertNil(store.book(forIdentifier: book.identifier))
    }

    func test_removeBook_nonexistentId_completesWithNilBook() async {
        var removedBook: TPPBook?
        var snapshotAfterRemove: [String: TPPBookRegistryRecord] = [:]
        store.removeBook(forIdentifier: "nonexistent") { removed, snapshot in
            removedBook = removed
            snapshotAfterRemove = snapshot
        }
        await store._awaitPendingWritesForTesting()

        XCTAssertNil(removedBook)
        XCTAssertTrue(snapshotAfterRemove.isEmpty)
    }

    // MARK: - Query: allBooks, heldBooks, myBooks

    func test_allBooks_returnsAllRegisteredBooks() async {
        let book1 = makeBook(identifier: "b1", title: "Book 1")
        let book2 = makeBook(identifier: "b2", title: "Book 2")

        store.addBook(book1, state: .downloadNeeded)
        store.addBook(book2, state: .holding)
        await store._awaitPendingWritesForTesting()

        let allBooks = store.allBooks
        XCTAssertEqual(allBooks.count, 2)
        let ids = Set(allBooks.map { $0.identifier })
        XCTAssertTrue(ids.contains("b1"))
        XCTAssertTrue(ids.contains("b2"))
    }

    func test_heldBooks_onlyReturnsHoldingState() async {
        let held = makeBook(identifier: "held-1")
        let downloading = makeBook(identifier: "dl-1")

        store.addBook(held, state: .holding)
        store.addBook(downloading, state: .downloading)
        await store._awaitPendingWritesForTesting()

        let heldBooks = store.heldBooks
        XCTAssertEqual(heldBooks.count, 1)
        XCTAssertEqual(heldBooks.first?.identifier, "held-1")
    }

    func test_myBooks_returnsCorrectStates() async {
        let book1 = makeBook(identifier: "dn")
        let book2 = makeBook(identifier: "ds")
        let book3 = makeBook(identifier: "df")
        let book4 = makeBook(identifier: "used")
        let book5 = makeBook(identifier: "held")

        store.addBook(book1, state: .downloadNeeded)
        store.addBook(book2, state: .downloadSuccessful)
        store.addBook(book3, state: .downloadFailed)
        store.addBook(book4, state: .used)
        store.addBook(book5, state: .holding)
        await store._awaitPendingWritesForTesting()

        let myBooks = store.myBooks
        // myBooks includes: downloadNeeded, downloading, SAMLStarted, downloadFailed, downloadSuccessful, used
        // NOT holding
        XCTAssertEqual(myBooks.count, 4)
        let ids = Set(myBooks.map { $0.identifier })
        XCTAssertTrue(ids.contains("dn"))
        XCTAssertTrue(ids.contains("ds"))
        XCTAssertTrue(ids.contains("df"))
        XCTAssertTrue(ids.contains("used"))
        XCTAssertFalse(ids.contains("held"))
    }

    // MARK: - FulfillmentId

    func test_fulfillmentId_setAndGet() async {
        let book = makeBook()
        store.addBook(book, state: .downloadNeeded, fulfillmentId: "initial-fid")
        await store._awaitPendingWritesForTesting()

        XCTAssertEqual(store.fulfillmentId(forIdentifier: book.identifier), "initial-fid")

        store.setFulfillmentId("updated-fid", for: book.identifier)
        await store._awaitPendingWritesForTesting()

        XCTAssertEqual(store.fulfillmentId(forIdentifier: book.identifier), "updated-fid")
    }

    func test_fulfillmentId_nilIdentifier_returnsNil() {
        XCTAssertNil(store.fulfillmentId(forIdentifier: nil))
    }

    func test_fulfillmentId_emptyIdentifier_returnsNil() {
        XCTAssertNil(store.fulfillmentId(forIdentifier: ""))
    }

    // MARK: - Processing

    /// Processing flag defaults to false for every identifier (registered or
    /// not). This guards against an "always-true" mutant on the dictionary
    /// lookup as well as an unintended default of `true`.
    func test_processing_defaultsFalseForUnknownAndRegisteredBooks() async {
        // Unknown identifier — never seen by the store.
        XCTAssertFalse(store.processing(forIdentifier: "never-seen"))

        // Registered book — the processing flag is independent of registry
        // membership and starts false until setProcessing flips it.
        let book = makeBook(identifier: "tracked")
        store.addBook(book, state: .downloadNeeded)
        await store._awaitPendingWritesForTesting()
        XCTAssertFalse(store.processing(forIdentifier: "tracked"),
                       "Adding a book must not flip its processing flag — that is reserved for setProcessing")
    }

    // KEPT: `setProcessing` posts `.TPPBookProcessingDidChange` via a nested
    // `DispatchQueue.main.async` *inside* the barrier block, so this is testing
    // the actual NotificationCenter contract (name + userInfo payload), not
    // just registry-write convergence. `_awaitPendingWritesForTesting()` only
    // proves the barrier ran (i.e. the post was *submitted*); it does not
    // prove the notification was *delivered* with the right payload. There is
    // no catalog seam for "assert this specific notification's userInfo", so
    // converting would silently drop coverage of the notification contract
    // that UI badges depend on. `expectation(forNotification:)` is the correct
    // bounded primitive for this and is left byte-for-byte.
    func test_setProcessing_true_thenFalse() {
        let notifExpectation = expectation(forNotification: .TPPBookProcessingDidChange, object: nil) { notif in
            let id = notif.userInfo?[TPPNotificationKeys.bookProcessingBookIDKey] as? String
            let value = notif.userInfo?[TPPNotificationKeys.bookProcessingValueKey] as? Bool
            return id == "book-1" && value == true
        }

        store.setProcessing(true, for: "book-1")
        wait(for: [notifExpectation], timeout: 2.0)

        drainMainQueue()
            XCTAssertTrue(self.store.processing(forIdentifier: "book-1"))

        let notifExpectation2 = expectation(forNotification: .TPPBookProcessingDidChange, object: nil) { notif in
            let value = notif.userInfo?[TPPNotificationKeys.bookProcessingValueKey] as? Bool
            return value == false
        }

        store.setProcessing(false, for: "book-1")
        wait(for: [notifExpectation2], timeout: 2.0)

        drainMainQueue()
            XCTAssertFalse(self.store.processing(forIdentifier: "book-1"))
    }

    // MARK: - RemoveAll

    func test_removeAll_clearsRegistry() async {
        let book1 = makeBook(identifier: "a")
        let book2 = makeBook(identifier: "b")

        store.addBook(book1, state: .downloadNeeded)
        store.addBook(book2, state: .holding)
        await store._awaitPendingWritesForTesting()

        store.removeAll()
        await store._awaitPendingWritesForTesting()

        XCTAssertTrue(store.allBooks.isEmpty)
        XCTAssertNil(store.book(forIdentifier: "a"))
        XCTAssertNil(store.book(forIdentifier: "b"))
    }

    // MARK: - Combine Subjects

    func test_registrySubject_emitsOnAdd() async {
        let book = makeBook()

        // Skip the initial empty value
        var receivedCount = 0
        var receivedSnapshotContainsBook = false
        store.registrySubject
            .dropFirst()
            .sink { snapshot in
                receivedCount += 1
                if snapshot[book.identifier] != nil {
                    receivedSnapshotContainsBook = true
                }
            }
            .store(in: &cancellables)

        store.addBook(book, state: .downloadNeeded)
        // The subject is published from a `DispatchQueue.main.async` in
        // `registry`'s `didSet`, which runs AFTER the barrier write completes.
        // Join the S1 seam first (barrier drained), then flush the one
        // resulting main-queue hop via the bounded `drainMainQueueAsync`
        // primitive — the composite the playbook explicitly allows.
        await store._awaitPendingWritesForTesting()
        await drainMainQueueAsync()

        XCTAssertGreaterThan(receivedCount, 0,
                             "Subject must emit at least once when a book is added")
        XCTAssertTrue(receivedSnapshotContainsBook,
                      "Emitted snapshot must contain the added book")
        XCTAssertEqual(store.state(for: book.identifier), .downloadNeeded,
                       "Added book's state must be observable via state(for:)")
    }

    // MARK: - MutateRegistrySync

    func test_mutateRegistrySync_directMutation() async {
        let book = makeBook()
        store.addBook(book, state: .downloadNeeded)
        await store._awaitPendingWritesForTesting()

        store.mutateRegistrySync { registry in
            registry[book.identifier]?.state = .downloadFailed
        }

        XCTAssertEqual(store.state(for: book.identifier), .downloadFailed)
    }

    func test_readRegistry_returnsSnapshot() async {
        let book = makeBook()
        store.addBook(book, state: .holding)
        await store._awaitPendingWritesForTesting()

        let count = store.readRegistry { registry in
            registry.count
        }
        XCTAssertEqual(count, 1)
    }

    // MARK: - RegistrySnapshot

    func test_registrySnapshot_returnsDictionaryRepresentations() async {
        let book = makeBook()
        store.addBook(book, state: .downloadNeeded)
        await store._awaitPendingWritesForTesting()

        let snapshot = store.registrySnapshot()
        XCTAssertEqual(snapshot.count, 1)
        // Each element should be a dictionary representation
        XCTAssertTrue(snapshot.first is [String: Any])
    }

    // MARK: - UpdateAndRemoveBook

    func test_updateAndRemoveBook_setsStateUnregistered() async {
        let book = makeBook()
        store.addBook(book, state: .downloadSuccessful)
        await store._awaitPendingWritesForTesting()

        var recordStateAfterUpdate: TPPBookState?
        store.updateAndRemoveBook(book) { snapshot in
            // The record should still exist but with state unregistered
            recordStateAfterUpdate = snapshot[book.identifier]?.state
        }
        await store._awaitPendingWritesForTesting()

        XCTAssertEqual(recordStateAfterUpdate, .unregistered)
    }

    // MARK: - Thread Safety Under Concurrent Access

    // KEPT: this deliberately drives the store from raw `DispatchQueue.global`
    // work items (not through the seam) to exercise the store's OWN internal
    // synchronization under real concurrent pressure — routing it through
    // `_awaitPendingWritesForTesting()` would defeat the point of the stress
    // test. The completion signal is a `DispatchGroup.notify`, which is a
    // deterministic zero-count callback (not a wall-clock/deadline poll), so
    // it does not violate the wave's wait-elimination goal.
    func test_concurrentReadsAndWrites_noDataRace() {
        let iterations = 50
        let group = DispatchGroup()

        // Swift 6: capture Sendable locals (the @unchecked Sendable store + a
        // pre-built [TPPBook]) so the @Sendable global-queue closures don't
        // capture the non-Sendable @MainActor test `self`.
        let store = store!
        let books = (0..<iterations).map { makeBook(identifier: "book-\($0)", title: "Title \($0)") }

        // Concurrent writes
        for i in 0..<iterations {
            group.enter()
            DispatchQueue.global().async {
                store.addBook(books[i], state: .downloadNeeded) { _ in
                    group.leave()
                }
            }
        }

        // Concurrent reads interleaved
        for i in 0..<iterations {
            group.enter()
            DispatchQueue.global().async {
                _ = store.book(forIdentifier: "book-\(i)")
                _ = store.state(for: "book-\(i)")
                _ = store.allBooks
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

    func test_addBook_withLocationAndBookmarks() async {
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

        store.addBook(
            book,
            location: location,
            state: .downloadSuccessful,
            fulfillmentId: "fid-123",
            readiumBookmarks: bookmark != nil ? [bookmark!] : nil,
            genericBookmarks: nil
        )
        await store._awaitPendingWritesForTesting()

        let record = store.record(forIdentifier: book.identifier)
        XCTAssertNotNil(record)
        XCTAssertEqual(record?.state, .downloadSuccessful)
        XCTAssertEqual(record?.fulfillmentId, "fid-123")
        XCTAssertEqual(record?.location?.renderer, "test-renderer")
        XCTAssertEqual(record?.readiumBookmarks?.count, 1)
    }

    // MARK: - Record for nil/empty identifier

    /// `record(forIdentifier:)` is the lower-level lookup that
    /// `book(forIdentifier:)` and `state(for:)` build on. Same guard contract,
    /// pinned alongside the positive case so an "always-nil" mutant fails.
    func test_record_returnsNilForUnregisteredOrInvalidInputs() async {
        XCTAssertNil(store.record(forIdentifier: nil),        "nil → nil")
        XCTAssertNil(store.record(forIdentifier: ""),         "empty → nil")
        XCTAssertNil(store.record(forIdentifier: "unknown"),  "unknown id → nil")

        let book = makeBook(identifier: "tracked")
        store.addBook(book, state: .downloadNeeded)
        await store._awaitPendingWritesForTesting()
        XCTAssertNotNil(store.record(forIdentifier: "tracked"),
                        "Registered book MUST yield a record, otherwise the store can't be queried")
    }

    // MARK: - UpdatedBookMetadata

    /// updatedBookMetadata returns nil when the registry has no record for
    /// the incoming book. Pairs with the existing preserves-authors and
    /// takes-incoming-authors tests below to cover all three branches of the
    /// merge: missing → nil; existing-poor + incoming-rich → adopt;
    /// existing-rich + incoming-poor → keep.
    func test_updatedBookMetadata_returnsNilWhenBookIsNotInRegistry() {
        let unregistered = makeBook(identifier: "never-added")
        let result = store.updatedBookMetadata(unregistered)
        XCTAssertNil(result, "Merging metadata for an unknown book must yield nil — there is nothing to merge against")

        // Sanity: the unrelated registry remains untouched by the lookup.
        XCTAssertTrue(store.allBooks.isEmpty,
                      "updatedBookMetadata must be a pure read; no side effect on the registry")
    }

    /// Regression guard for the "authors disappear on reload" bug. The
    /// catalog enrichment path must no longer wipe previously-populated
    /// author data when the catalog feed comes back with a lean entry.
    func test_updatedBookMetadata_preservesExistingAuthorsWhenIncomingIsEmpty() {
        let rich = bookWithAuthors([TPPBookAuthor(authorName: "Original Author", relatedBooksURL: nil)])
        store.addBook(rich, state: .downloadSuccessful)

        let lean = bookWithAuthors([])
        let merged = store.updatedBookMetadata(lean)

        XCTAssertEqual(merged?.bookAuthors?.first?.name, "Original Author",
                       "A lean catalog refresh must not overwrite previously-populated authors")
        XCTAssertEqual(store.book(forIdentifier: "book-1")?.bookAuthors?.first?.name, "Original Author",
                       "The registry's stored record must also retain the original author")
    }

    /// Complement to the above: when the catalog entry has richer data,
    /// the merge must adopt it so new metadata still flows into the
    /// registry in the normal, non-degraded case.
    func test_updatedBookMetadata_takesIncomingAuthorsWhenPresent() {
        let existing = bookWithAuthors([TPPBookAuthor(authorName: "Old Author", relatedBooksURL: nil)])
        store.addBook(existing, state: .downloadSuccessful)

        let fresh = bookWithAuthors([TPPBookAuthor(authorName: "Enriched Author", relatedBooksURL: nil)])
        let merged = store.updatedBookMetadata(fresh)

        XCTAssertEqual(merged?.bookAuthors?.first?.name, "Enriched Author")
    }

    /// Helper producing a TPPBook with the given author list, with
    /// everything else held constant. Keeps identifier = "book-1" so it
    /// matches the default helper used across this file.
    private func bookWithAuthors(_ authors: [TPPBookAuthor]?) -> TPPBook {
        TPPBook(
            acquisitions: [TPPFake.genericAcquisition],
            authors: authors,
            categoryStrings: ["Fiction"],
            distributor: nil,
            identifier: "book-1",
            imageURL: nil,
            imageThumbnailURL: nil,
            published: nil,
            publisher: nil,
            subtitle: nil,
            summary: nil,
            title: "Test Book",
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
}
