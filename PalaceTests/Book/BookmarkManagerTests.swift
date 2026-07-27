//
//  BookmarkManagerTests.swift
//  PalaceTests
//
//  Tests for BookmarkManager: reading location CRUD, Readium bookmark
//  management (add/delete/replace), generic bookmark management with
//  annotationId and content-based matching, and edge cases.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace
import PalaceBookModel

@MainActor
final class BookmarkManagerTests: XCTestCase {

    private var store: BookRegistryStore!
    private var manager: BookmarkManager!
    private var saveCallCount: Int!
    private var saveSyncCallCount: Int!
    private var lastSavedAccount: String?

    private let testAccount = "urn:uuid:bookmark-mgr-test"

    override func setUp() {
        super.setUp()
        store = BookRegistryStore()
        saveCallCount = 0
        saveSyncCallCount = 0
        lastSavedAccount = nil
        manager = BookmarkManager(
            store: store,
            save: { [weak self] account in
                self?.saveCallCount += 1
                self?.lastSavedAccount = account
            },
            saveSync: { [weak self] account in
                self?.saveSyncCallCount += 1
                self?.lastSavedAccount = account
            }
        )
    }

    override func tearDown() {
        manager = nil
        store = nil
        saveCallCount = nil
        saveSyncCallCount = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeBook(identifier: String = "book-1") -> TPPBook {
        TPPBook(
            acquisitions: [TPPFake.genericAcquisition],
            authors: nil,
            categoryStrings: nil,
            distributor: nil,
            identifier: identifier,
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

    private func addBookToStore(
        _ book: TPPBook,
        state: TPPBookState = .downloadSuccessful
    ) {
        let done = expectation(description: "book added to store")
        store.addBook(book, state: state) { _ in done.fulfill() }
        wait(for: [done], timeout: 2.0)
        // Wait for barrier completion
        drainMainQueue()
    }

    private func makeLocation(
        page: Int = 1,
        renderer: String = "test-renderer",
        annotationId: String? = nil
    ) -> TPPBookLocation {
        var dict: [String: Any] = ["page": page, "chapter": 1]
        if let annotationId = annotationId {
            dict["annotationId"] = annotationId
        }
        let jsonData = try! JSONSerialization.data(withJSONObject: dict)
        let jsonString = String(data: jsonData, encoding: .utf8)!
        return TPPBookLocation(locationString: jsonString, renderer: renderer)!
    }

    private func makeReadiumBookmark(
        annotationId: String? = nil,
        href: String = "/chapter1",
        progressWithinBook: Float = 0.1,
        time: String = "2026-01-01T00:00:00Z"
    ) -> TPPReadiumBookmark {
        TPPReadiumBookmark(
            annotationId: annotationId,
            href: href,
            chapter: "Chapter 1",
            page: "1",
            location: "{}",
            progressWithinChapter: 0.5,
            progressWithinBook: progressWithinBook,
            readingOrderItem: nil,
            readingOrderItemOffsetMilliseconds: nil,
            time: time,
            device: nil
        )!
    }

    /// Synchronously waits for BookRegistryStore's concurrent-queue work
    /// (barrier mutation + onComplete) to land before returning.
    ///
    /// Previously this was just `drainMainQueue()`, which only flushed the
    /// MAIN queue. But `mutateRegistry` enqueues two barrier blocks on the
    /// store's internal concurrent queue: the mutation, then the onComplete
    /// (which calls `save`). Neither hops through main, so draining main
    /// didn't actually wait for the save closure to fire — the next test
    /// step could land before `saveCallCount` was incremented, manifesting
    /// as the long-standing `test_everyMutationCallsSave` flake (saw 4
    /// instead of 5 saves).
    ///
    /// Fix: a sync read on the store. `readRegistry` calls `performSync`,
    /// which blocks behind ALL prior enqueued barriers — guaranteeing the
    /// preceding mutation + onComplete are done by the time it returns.
    private func waitForBarrier() {
        _ = store.readRegistry { _ in }
        drainMainQueue()
    }

    // MARK: - Location Tracking

    func test_setAndGetLocation() {
        let book = makeBook()
        addBookToStore(book)

        let location = makeLocation(page: 42)
        manager.setLocation(location, forIdentifier: book.identifier, account: testAccount)
        waitForBarrier()

        let retrieved = manager.location(forIdentifier: book.identifier)
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.renderer, "test-renderer")
        XCTAssertTrue(retrieved?.locationString.contains("42") ?? false)
        XCTAssertEqual(saveCallCount, 1, "save should be called once after setting location")
    }

    /// `setLocation` with an empty identifier must short-circuit — neither
    /// trigger a save NOR mutate any other book's location. Previously the
    /// test only checked saveCallCount; this version also pins that no
    /// other book got hit (cross-contamination guard).
    func test_setLocation_emptyIdentifier_doesNotSaveAndDoesNotTouchAnyBook() {
        let other = makeBook(identifier: "other-book")
        addBookToStore(other)
        let originalLocation = makeLocation(page: 99)
        manager.setLocation(originalLocation, forIdentifier: other.identifier, account: testAccount)
        waitForBarrier()

        let beforeSaveCount = saveCallCount

        // Empty identifier — must do nothing.
        manager.setLocation(makeLocation(page: 1), forIdentifier: "", account: testAccount)
        waitForBarrier()

        XCTAssertEqual(saveCallCount, beforeSaveCount,
                       "save must not fire for empty identifier")
        let stored = manager.location(forIdentifier: other.identifier)
        XCTAssertTrue(stored?.locationString.contains("99") ?? false,
                      "Empty-id setLocation must NOT cross-contaminate another book's location")
    }

    func test_setLocation_nil_clearsLocation() {
        let book = makeBook()
        addBookToStore(book)

        let location = makeLocation(page: 10)
        manager.setLocation(location, forIdentifier: book.identifier, account: testAccount)
        waitForBarrier()

        manager.setLocation(nil, forIdentifier: book.identifier, account: testAccount)
        waitForBarrier()

        let retrieved = manager.location(forIdentifier: book.identifier)
        XCTAssertNil(retrieved)
    }

    /// Missing-book lookup contracts in one place — `location(forIdentifier:)`
    /// AND the empty/nil readout paths all return absent values without
    /// inventing entries. A mutant that returns a default `TPPBookLocation`
    /// for missing keys fails on the first nil-assertion.
    func test_missingBook_locationAndBookmarkLookups_returnAbsentValues() {
        // Pure read on an empty manager — none of these may invent state.
        XCTAssertNil(manager.location(forIdentifier: "missing-1"),
                     "location(forIdentifier:) on missing book must yield nil")
        XCTAssertTrue(manager.readiumBookmarks(forIdentifier: "missing-1").isEmpty,
                      "readiumBookmarks on missing book must be empty array")
        XCTAssertTrue(manager.genericBookmarks(forIdentifier: "missing-1").isEmpty,
                      "genericBookmarks on missing book must be empty array")
        XCTAssertEqual(saveCallCount, 0,
                       "Pure reads must not trigger any save side-effect")
    }

    func test_setLocationSync_callsSaveSyncInsteadOfSave() {
        let book = makeBook()
        addBookToStore(book)

        let location = makeLocation(page: 7)
        manager.setLocationSync(location, forIdentifier: book.identifier, account: testAccount)

        XCTAssertEqual(saveSyncCallCount, 1, "saveSync should be called")
        XCTAssertEqual(saveCallCount, 0, "async save should NOT be called")

        let retrieved = manager.location(forIdentifier: book.identifier)
        XCTAssertNotNil(retrieved)
    }

    /// setLocationSync mirrors setLocation but on the sync queue — empty
    /// identifier must also short-circuit, neither calling saveSync NOR
    /// triggering the async save path (mutant that conflates the two
    /// would fire the wrong save).
    func test_setLocationSync_emptyIdentifier_neitherSyncNorAsyncSaveFires() {
        manager.setLocationSync(makeLocation(), forIdentifier: "", account: testAccount)
        XCTAssertEqual(saveSyncCallCount, 0,
                       "saveSync must not fire on empty identifier")
        XCTAssertEqual(saveCallCount, 0,
                       "Async save must not fire either — guards against a mutant that falls through to setLocation()")
    }

    // MARK: - Readium Bookmarks

    func test_addReadiumBookmark() {
        let book = makeBook()
        addBookToStore(book)

        let bookmark = makeReadiumBookmark(annotationId: "ann-1")
        manager.addReadiumBookmark(bookmark, forIdentifier: book.identifier, account: testAccount)
        waitForBarrier()

        let bookmarks = manager.readiumBookmarks(forIdentifier: book.identifier)
        XCTAssertEqual(bookmarks.count, 1)
        XCTAssertEqual(bookmarks.first?.annotationId, "ann-1")
        XCTAssertEqual(saveCallCount, 1)
    }

    func test_addMultipleReadiumBookmarks_sortedByProgress() {
        let book = makeBook()
        addBookToStore(book)

        let bm1 = makeReadiumBookmark(annotationId: "a", progressWithinBook: 0.9)
        let bm2 = makeReadiumBookmark(annotationId: "b", progressWithinBook: 0.1)
        let bm3 = makeReadiumBookmark(annotationId: "c", progressWithinBook: 0.5)

        manager.addReadiumBookmark(bm1, forIdentifier: book.identifier, account: testAccount)
        waitForBarrier()
        manager.addReadiumBookmark(bm2, forIdentifier: book.identifier, account: testAccount)
        waitForBarrier()
        manager.addReadiumBookmark(bm3, forIdentifier: book.identifier, account: testAccount)
        waitForBarrier()

        let bookmarks = manager.readiumBookmarks(forIdentifier: book.identifier)
        XCTAssertEqual(bookmarks.count, 3)
        // readiumBookmarks sorts by progressWithinBook ascending
        XCTAssertEqual(bookmarks[0].annotationId, "b") // 0.1
        XCTAssertEqual(bookmarks[1].annotationId, "c") // 0.5
        XCTAssertEqual(bookmarks[2].annotationId, "a") // 0.9
    }

    func test_deleteReadiumBookmark() {
        let book = makeBook()
        addBookToStore(book)

        let bm1 = makeReadiumBookmark(annotationId: "keep", href: "/ch1", progressWithinBook: 0.1)
        let bm2 = makeReadiumBookmark(annotationId: "delete", href: "/ch2", progressWithinBook: 0.5)

        manager.addReadiumBookmark(bm1, forIdentifier: book.identifier, account: testAccount)
        waitForBarrier()
        manager.addReadiumBookmark(bm2, forIdentifier: book.identifier, account: testAccount)
        waitForBarrier()

        manager.deleteReadiumBookmark(bm2, forIdentifier: book.identifier, account: testAccount)
        waitForBarrier()

        let bookmarks = manager.readiumBookmarks(forIdentifier: book.identifier)
        XCTAssertEqual(bookmarks.count, 1)
        XCTAssertEqual(bookmarks.first?.annotationId, "keep")
    }

    func test_replaceReadiumBookmark() {
        let book = makeBook()
        addBookToStore(book)

        let original = makeReadiumBookmark(annotationId: "orig", progressWithinBook: 0.3)
        manager.addReadiumBookmark(original, forIdentifier: book.identifier, account: testAccount)
        waitForBarrier()

        let replacement = makeReadiumBookmark(annotationId: "replaced", progressWithinBook: 0.6)
        manager.replaceReadiumBookmark(original, with: replacement, forIdentifier: book.identifier, account: testAccount)
        waitForBarrier()

        let bookmarks = manager.readiumBookmarks(forIdentifier: book.identifier)
        XCTAssertEqual(bookmarks.count, 1)
        XCTAssertEqual(bookmarks.first?.annotationId, "replaced")
        XCTAssertEqual(Double(bookmarks.first?.progressWithinBook ?? 0), 0.6, accuracy: 0.01)
    }

    // (Missing-book readiumBookmarks coverage now lives in
    // test_missingBook_locationAndBookmarkLookups_returnAbsentValues above —
    // covering location, readiumBookmarks AND genericBookmarks together so
    // a mutant that returns nil-for-one-but-default-for-another fails.)

    func test_addReadiumBookmark_toMissingBook_doesNotCrash() {
        let bookmark = makeReadiumBookmark()
        manager.addReadiumBookmark(bookmark, forIdentifier: "nonexistent", account: testAccount)
        waitForBarrier()
        // Guard must fail: no bookmark stored, no save triggered
        XCTAssertTrue(manager.readiumBookmarks(forIdentifier: "nonexistent").isEmpty,
                      "Readium bookmarks for a missing book must remain empty")
        XCTAssertEqual(saveCallCount, 0,
                       "Save must not fire when book is missing from the store")
    }

    // MARK: - Generic Bookmarks

    func test_addGenericBookmark() {
        let book = makeBook()
        addBookToStore(book)

        let location = makeLocation(page: 10)
        manager.addGenericBookmark(location, forIdentifier: book.identifier, account: testAccount)
        waitForBarrier()

        let bookmarks = manager.genericBookmarks(forIdentifier: book.identifier)
        XCTAssertEqual(bookmarks.count, 1)
        XCTAssertEqual(saveCallCount, 1)
    }

    func test_addGenericBookmark_toMissingBook_doesNotCrash() {
        let location = makeLocation(page: 10)
        manager.addGenericBookmark(location, forIdentifier: "nonexistent", account: testAccount)
        waitForBarrier()
        XCTAssertTrue(manager.genericBookmarks(forIdentifier: "nonexistent").isEmpty,
                      "Generic bookmarks for a missing book must remain empty")
        XCTAssertEqual(saveCallCount, 0,
                       "Save must not fire when book is missing from the store")
    }

    func test_deleteGenericBookmark_bySimilarity() {
        let book = makeBook()
        addBookToStore(book)

        let loc1 = makeLocation(page: 10, renderer: "r1")
        let loc2 = makeLocation(page: 20, renderer: "r1")

        manager.addGenericBookmark(loc1, forIdentifier: book.identifier, account: testAccount)
        waitForBarrier()
        manager.addGenericBookmark(loc2, forIdentifier: book.identifier, account: testAccount)
        waitForBarrier()

        // Delete loc1
        manager.deleteGenericBookmark(loc1, forIdentifier: book.identifier, account: testAccount)
        waitForBarrier()

        let remaining = manager.genericBookmarks(forIdentifier: book.identifier)
        XCTAssertEqual(remaining.count, 1)
    }

    func test_deleteGenericBookmark_byAnnotationId() {
        let book = makeBook()
        addBookToStore(book)

        let loc = makeLocation(page: 10, annotationId: "ann-42")
        manager.addGenericBookmark(loc, forIdentifier: book.identifier, account: testAccount)
        waitForBarrier()

        // Create a deletion target with matching annotationId but different page
        let deleteTarget = makeLocation(page: 99, annotationId: "ann-42")
        manager.deleteGenericBookmark(deleteTarget, forIdentifier: book.identifier, account: testAccount)
        waitForBarrier()

        let remaining = manager.genericBookmarks(forIdentifier: book.identifier)
        XCTAssertEqual(remaining.count, 0, "Should delete by annotationId match")
    }

    func test_replaceGenericBookmark() {
        let book = makeBook()
        addBookToStore(book)

        let original = makeLocation(page: 5, renderer: "r1")
        manager.addGenericBookmark(original, forIdentifier: book.identifier, account: testAccount)
        waitForBarrier()

        let replacement = makeLocation(page: 50, renderer: "r1")
        manager.replaceGenericBookmark(original, with: replacement, forIdentifier: book.identifier, account: testAccount)
        waitForBarrier()

        let bookmarks = manager.genericBookmarks(forIdentifier: book.identifier)
        XCTAssertEqual(bookmarks.count, 1)
        XCTAssertTrue(bookmarks.first?.locationString.contains("50") ?? false)
    }

    func test_addOrReplaceGenericBookmark_addsWhenNew() {
        let book = makeBook()
        addBookToStore(book)

        let loc = makeLocation(page: 10)
        manager.addOrReplaceGenericBookmark(loc, forIdentifier: book.identifier, account: testAccount)
        waitForBarrier()

        let bookmarks = manager.genericBookmarks(forIdentifier: book.identifier)
        XCTAssertEqual(bookmarks.count, 1)
    }

    func test_addOrReplaceGenericBookmark_replacesExisting() {
        let book = makeBook()
        addBookToStore(book)

        let loc1 = makeLocation(page: 10, renderer: "r1")
        manager.addGenericBookmark(loc1, forIdentifier: book.identifier, account: testAccount)
        waitForBarrier()

        // addOrReplace with same-ish location (same renderer, same content)
        let loc2 = makeLocation(page: 10, renderer: "r1")
        manager.addOrReplaceGenericBookmark(loc2, forIdentifier: book.identifier, account: testAccount)
        waitForBarrier()

        let bookmarks = manager.genericBookmarks(forIdentifier: book.identifier)
        // Should have exactly 1, not 2 (the duplicate was replaced)
        XCTAssertEqual(bookmarks.count, 1)
    }

    // (Missing-book genericBookmarks coverage now lives in
    // test_missingBook_locationAndBookmarkLookups_returnAbsentValues above.)

    // MARK: - Multiple Books

    func test_bookmarksAreIsolatedBetweenBooks() {
        let book1 = makeBook(identifier: "book-1")
        let book2 = makeBook(identifier: "book-2")
        addBookToStore(book1)
        addBookToStore(book2)

        let loc1 = makeLocation(page: 1)
        let loc2 = makeLocation(page: 2)

        manager.addGenericBookmark(loc1, forIdentifier: "book-1", account: testAccount)
        waitForBarrier()
        manager.addGenericBookmark(loc2, forIdentifier: "book-2", account: testAccount)
        waitForBarrier()

        XCTAssertEqual(manager.genericBookmarks(forIdentifier: "book-1").count, 1)
        XCTAssertEqual(manager.genericBookmarks(forIdentifier: "book-2").count, 1)

        // Deleting from book-1 should not affect book-2
        manager.deleteGenericBookmark(loc1, forIdentifier: "book-1", account: testAccount)
        waitForBarrier()

        XCTAssertEqual(manager.genericBookmarks(forIdentifier: "book-1").count, 0)
        XCTAssertEqual(manager.genericBookmarks(forIdentifier: "book-2").count, 1)
    }

    // MARK: - Location and Bookmarks Together

    func test_locationAndBookmarksAreIndependent() {
        let book = makeBook()
        addBookToStore(book)

        // Set location
        let location = makeLocation(page: 42)
        manager.setLocation(location, forIdentifier: book.identifier, account: testAccount)
        waitForBarrier()

        // Add bookmarks
        let bookmark = makeReadiumBookmark()
        manager.addReadiumBookmark(bookmark, forIdentifier: book.identifier, account: testAccount)
        waitForBarrier()

        let genericLoc = makeLocation(page: 99)
        manager.addGenericBookmark(genericLoc, forIdentifier: book.identifier, account: testAccount)
        waitForBarrier()

        // All three should coexist
        XCTAssertNotNil(manager.location(forIdentifier: book.identifier))
        XCTAssertEqual(manager.readiumBookmarks(forIdentifier: book.identifier).count, 1)
        XCTAssertEqual(manager.genericBookmarks(forIdentifier: book.identifier).count, 1)

        // Clearing location should not affect bookmarks
        manager.setLocation(nil, forIdentifier: book.identifier, account: testAccount)
        waitForBarrier()

        XCTAssertNil(manager.location(forIdentifier: book.identifier))
        XCTAssertEqual(manager.readiumBookmarks(forIdentifier: book.identifier).count, 1)
        XCTAssertEqual(manager.genericBookmarks(forIdentifier: book.identifier).count, 1)
    }

    // MARK: - Save Callback Counting

    func test_everyMutationCallsSave() {
        let book = makeBook()
        addBookToStore(book)
        saveCallCount = 0 // Reset after addBookToStore

        let location = makeLocation(page: 1)
        let readiumBm = makeReadiumBookmark()
        let genericLoc = makeLocation(page: 2)

        // 1. setLocation
        manager.setLocation(location, forIdentifier: book.identifier, account: testAccount)
        waitForBarrier()

        // 2. addReadiumBookmark
        manager.addReadiumBookmark(readiumBm, forIdentifier: book.identifier, account: testAccount)
        waitForBarrier()

        // 3. deleteReadiumBookmark
        manager.deleteReadiumBookmark(readiumBm, forIdentifier: book.identifier, account: testAccount)
        waitForBarrier()

        // 4. addGenericBookmark
        manager.addGenericBookmark(genericLoc, forIdentifier: book.identifier, account: testAccount)
        waitForBarrier()

        // 5. deleteGenericBookmark
        manager.deleteGenericBookmark(genericLoc, forIdentifier: book.identifier, account: testAccount)
        waitForBarrier()

        XCTAssertEqual(saveCallCount, 5,
                       "Each mutation should trigger exactly one save")
    }

    // MARK: - Readium Bookmarks with Nil Initial Array

    func test_addReadiumBookmark_initializesArrayIfNil() {
        let book = makeBook()
        // Add book with nil readiumBookmarks
        let done = expectation(description: "added")
        store.addBook(book, state: .downloadSuccessful, readiumBookmarks: nil) { _ in done.fulfill() }
        wait(for: [done], timeout: 2.0)
        waitForBarrier()

        let bookmark = makeReadiumBookmark(annotationId: "first")
        manager.addReadiumBookmark(bookmark, forIdentifier: book.identifier, account: testAccount)
        waitForBarrier()

        let bookmarks = manager.readiumBookmarks(forIdentifier: book.identifier)
        XCTAssertEqual(bookmarks.count, 1)
    }

    // MARK: - Generic Bookmarks with Nil Initial Array

    func test_addGenericBookmark_initializesArrayIfNil() {
        let book = makeBook()
        let done = expectation(description: "added")
        store.addBook(book, state: .downloadSuccessful, genericBookmarks: nil) { _ in done.fulfill() }
        wait(for: [done], timeout: 2.0)
        waitForBarrier()

        let loc = makeLocation(page: 1)
        manager.addGenericBookmark(loc, forIdentifier: book.identifier, account: testAccount)
        waitForBarrier()

        let bookmarks = manager.genericBookmarks(forIdentifier: book.identifier)
        XCTAssertEqual(bookmarks.count, 1)
    }

    func test_addOrReplaceGenericBookmark_initializesArrayIfNil() {
        let book = makeBook()
        let done = expectation(description: "added")
        store.addBook(book, state: .downloadSuccessful, genericBookmarks: nil) { _ in done.fulfill() }
        wait(for: [done], timeout: 2.0)
        waitForBarrier()

        let loc = makeLocation(page: 5)
        manager.addOrReplaceGenericBookmark(loc, forIdentifier: book.identifier, account: testAccount)
        waitForBarrier()

        let bookmarks = manager.genericBookmarks(forIdentifier: book.identifier)
        XCTAssertEqual(bookmarks.count, 1)
    }
}
