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

final class BookmarkManagerTests: XCTestCase {

    private var store: BookRegistryStore!
    private var manager: BookmarkManager!
    private var saveCallCount: Int!
    private var saveSyncCallCount: Int!

    override func setUp() {
        super.setUp()
        store = BookRegistryStore()
        saveCallCount = 0
        saveSyncCallCount = 0
        manager = BookmarkManager(
            store: store,
            save: { [weak self] in self?.saveCallCount += 1 },
            saveSync: { [weak self] in self?.saveSyncCallCount += 1 }
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
        let ready = expectation(description: "store ready")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { ready.fulfill() }
        wait(for: [ready], timeout: 2.0)
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

    private func waitForBarrier() {
        let done = expectation(description: "barrier done")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { done.fulfill() }
        wait(for: [done], timeout: 2.0)
    }

    // MARK: - Location Tracking

    func test_setAndGetLocation() {
        let book = makeBook()
        addBookToStore(book)

        let location = makeLocation(page: 42)
        manager.setLocation(location, forIdentifier: book.identifier)
        waitForBarrier()

        let retrieved = manager.location(forIdentifier: book.identifier)
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.renderer, "test-renderer")
        XCTAssertTrue(retrieved?.locationString.contains("42") ?? false)
        XCTAssertEqual(saveCallCount, 1, "save should be called once after setting location")
    }

    func test_setLocation_emptyIdentifier_doesNothing() {
        let location = makeLocation()
        manager.setLocation(location, forIdentifier: "")
        waitForBarrier()

        XCTAssertEqual(saveCallCount, 0, "save should not be called for empty identifier")
    }

    func test_setLocation_nil_clearsLocation() {
        let book = makeBook()
        addBookToStore(book)

        let location = makeLocation(page: 10)
        manager.setLocation(location, forIdentifier: book.identifier)
        waitForBarrier()

        manager.setLocation(nil, forIdentifier: book.identifier)
        waitForBarrier()

        let retrieved = manager.location(forIdentifier: book.identifier)
        XCTAssertNil(retrieved)
    }

    func test_locationForMissingBook_returnsNil() {
        let location = manager.location(forIdentifier: "nonexistent-book")
        XCTAssertNil(location)
    }

    func test_setLocationSync_callsSaveSyncInsteadOfSave() {
        let book = makeBook()
        addBookToStore(book)

        let location = makeLocation(page: 7)
        manager.setLocationSync(location, forIdentifier: book.identifier)

        XCTAssertEqual(saveSyncCallCount, 1, "saveSync should be called")
        XCTAssertEqual(saveCallCount, 0, "async save should NOT be called")

        let retrieved = manager.location(forIdentifier: book.identifier)
        XCTAssertNotNil(retrieved)
    }

    func test_setLocationSync_emptyIdentifier_doesNothing() {
        manager.setLocationSync(makeLocation(), forIdentifier: "")
        XCTAssertEqual(saveSyncCallCount, 0)
    }

    // MARK: - Readium Bookmarks

    func test_addReadiumBookmark() {
        let book = makeBook()
        addBookToStore(book)

        let bookmark = makeReadiumBookmark(annotationId: "ann-1")
        manager.addReadiumBookmark(bookmark, forIdentifier: book.identifier)
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

        manager.addReadiumBookmark(bm1, forIdentifier: book.identifier)
        waitForBarrier()
        manager.addReadiumBookmark(bm2, forIdentifier: book.identifier)
        waitForBarrier()
        manager.addReadiumBookmark(bm3, forIdentifier: book.identifier)
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

        manager.addReadiumBookmark(bm1, forIdentifier: book.identifier)
        waitForBarrier()
        manager.addReadiumBookmark(bm2, forIdentifier: book.identifier)
        waitForBarrier()

        manager.deleteReadiumBookmark(bm2, forIdentifier: book.identifier)
        waitForBarrier()

        let bookmarks = manager.readiumBookmarks(forIdentifier: book.identifier)
        XCTAssertEqual(bookmarks.count, 1)
        XCTAssertEqual(bookmarks.first?.annotationId, "keep")
    }

    func test_replaceReadiumBookmark() {
        let book = makeBook()
        addBookToStore(book)

        let original = makeReadiumBookmark(annotationId: "orig", progressWithinBook: 0.3)
        manager.addReadiumBookmark(original, forIdentifier: book.identifier)
        waitForBarrier()

        let replacement = makeReadiumBookmark(annotationId: "replaced", progressWithinBook: 0.6)
        manager.replaceReadiumBookmark(original, with: replacement, forIdentifier: book.identifier)
        waitForBarrier()

        let bookmarks = manager.readiumBookmarks(forIdentifier: book.identifier)
        XCTAssertEqual(bookmarks.count, 1)
        XCTAssertEqual(bookmarks.first?.annotationId, "replaced")
        XCTAssertEqual(Double(bookmarks.first?.progressWithinBook ?? 0), 0.6, accuracy: 0.01)
    }

    func test_readiumBookmarks_emptyForMissingBook() {
        let bookmarks = manager.readiumBookmarks(forIdentifier: "nonexistent")
        XCTAssertTrue(bookmarks.isEmpty)
    }

    func test_addReadiumBookmark_toMissingBook_doesNotCrash() {
        let bookmark = makeReadiumBookmark()
        manager.addReadiumBookmark(bookmark, forIdentifier: "nonexistent")
        waitForBarrier()
        // Should not crash, save should not be called since guard fails
    }

    // MARK: - Generic Bookmarks

    func test_addGenericBookmark() {
        let book = makeBook()
        addBookToStore(book)

        let location = makeLocation(page: 10)
        manager.addGenericBookmark(location, forIdentifier: book.identifier)
        waitForBarrier()

        let bookmarks = manager.genericBookmarks(forIdentifier: book.identifier)
        XCTAssertEqual(bookmarks.count, 1)
        XCTAssertEqual(saveCallCount, 1)
    }

    func test_addGenericBookmark_toMissingBook_doesNotCrash() {
        let location = makeLocation(page: 10)
        manager.addGenericBookmark(location, forIdentifier: "nonexistent")
        waitForBarrier()
        // Should handle gracefully
    }

    func test_deleteGenericBookmark_bySimilarity() {
        let book = makeBook()
        addBookToStore(book)

        let loc1 = makeLocation(page: 10, renderer: "r1")
        let loc2 = makeLocation(page: 20, renderer: "r1")

        manager.addGenericBookmark(loc1, forIdentifier: book.identifier)
        waitForBarrier()
        manager.addGenericBookmark(loc2, forIdentifier: book.identifier)
        waitForBarrier()

        // Delete loc1
        manager.deleteGenericBookmark(loc1, forIdentifier: book.identifier)
        waitForBarrier()

        let remaining = manager.genericBookmarks(forIdentifier: book.identifier)
        XCTAssertEqual(remaining.count, 1)
    }

    func test_deleteGenericBookmark_byAnnotationId() {
        let book = makeBook()
        addBookToStore(book)

        let loc = makeLocation(page: 10, annotationId: "ann-42")
        manager.addGenericBookmark(loc, forIdentifier: book.identifier)
        waitForBarrier()

        // Create a deletion target with matching annotationId but different page
        let deleteTarget = makeLocation(page: 99, annotationId: "ann-42")
        manager.deleteGenericBookmark(deleteTarget, forIdentifier: book.identifier)
        waitForBarrier()

        let remaining = manager.genericBookmarks(forIdentifier: book.identifier)
        XCTAssertEqual(remaining.count, 0, "Should delete by annotationId match")
    }

    func test_replaceGenericBookmark() {
        let book = makeBook()
        addBookToStore(book)

        let original = makeLocation(page: 5, renderer: "r1")
        manager.addGenericBookmark(original, forIdentifier: book.identifier)
        waitForBarrier()

        let replacement = makeLocation(page: 50, renderer: "r1")
        manager.replaceGenericBookmark(original, with: replacement, forIdentifier: book.identifier)
        waitForBarrier()

        let bookmarks = manager.genericBookmarks(forIdentifier: book.identifier)
        XCTAssertEqual(bookmarks.count, 1)
        XCTAssertTrue(bookmarks.first?.locationString.contains("50") ?? false)
    }

    func test_addOrReplaceGenericBookmark_addsWhenNew() {
        let book = makeBook()
        addBookToStore(book)

        let loc = makeLocation(page: 10)
        manager.addOrReplaceGenericBookmark(loc, forIdentifier: book.identifier)
        waitForBarrier()

        let bookmarks = manager.genericBookmarks(forIdentifier: book.identifier)
        XCTAssertEqual(bookmarks.count, 1)
    }

    func test_addOrReplaceGenericBookmark_replacesExisting() {
        let book = makeBook()
        addBookToStore(book)

        let loc1 = makeLocation(page: 10, renderer: "r1")
        manager.addGenericBookmark(loc1, forIdentifier: book.identifier)
        waitForBarrier()

        // addOrReplace with same-ish location (same renderer, same content)
        let loc2 = makeLocation(page: 10, renderer: "r1")
        manager.addOrReplaceGenericBookmark(loc2, forIdentifier: book.identifier)
        waitForBarrier()

        let bookmarks = manager.genericBookmarks(forIdentifier: book.identifier)
        // Should have exactly 1, not 2 (the duplicate was replaced)
        XCTAssertEqual(bookmarks.count, 1)
    }

    func test_genericBookmarks_emptyForMissingBook() {
        let bookmarks = manager.genericBookmarks(forIdentifier: "nonexistent")
        XCTAssertTrue(bookmarks.isEmpty)
    }

    // MARK: - Multiple Books

    func test_bookmarksAreIsolatedBetweenBooks() {
        let book1 = makeBook(identifier: "book-1")
        let book2 = makeBook(identifier: "book-2")
        addBookToStore(book1)
        addBookToStore(book2)

        let loc1 = makeLocation(page: 1)
        let loc2 = makeLocation(page: 2)

        manager.addGenericBookmark(loc1, forIdentifier: "book-1")
        waitForBarrier()
        manager.addGenericBookmark(loc2, forIdentifier: "book-2")
        waitForBarrier()

        XCTAssertEqual(manager.genericBookmarks(forIdentifier: "book-1").count, 1)
        XCTAssertEqual(manager.genericBookmarks(forIdentifier: "book-2").count, 1)

        // Deleting from book-1 should not affect book-2
        manager.deleteGenericBookmark(loc1, forIdentifier: "book-1")
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
        manager.setLocation(location, forIdentifier: book.identifier)
        waitForBarrier()

        // Add bookmarks
        let bookmark = makeReadiumBookmark()
        manager.addReadiumBookmark(bookmark, forIdentifier: book.identifier)
        waitForBarrier()

        let genericLoc = makeLocation(page: 99)
        manager.addGenericBookmark(genericLoc, forIdentifier: book.identifier)
        waitForBarrier()

        // All three should coexist
        XCTAssertNotNil(manager.location(forIdentifier: book.identifier))
        XCTAssertEqual(manager.readiumBookmarks(forIdentifier: book.identifier).count, 1)
        XCTAssertEqual(manager.genericBookmarks(forIdentifier: book.identifier).count, 1)

        // Clearing location should not affect bookmarks
        manager.setLocation(nil, forIdentifier: book.identifier)
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
        manager.setLocation(location, forIdentifier: book.identifier)
        waitForBarrier()

        // 2. addReadiumBookmark
        manager.addReadiumBookmark(readiumBm, forIdentifier: book.identifier)
        waitForBarrier()

        // 3. deleteReadiumBookmark
        manager.deleteReadiumBookmark(readiumBm, forIdentifier: book.identifier)
        waitForBarrier()

        // 4. addGenericBookmark
        manager.addGenericBookmark(genericLoc, forIdentifier: book.identifier)
        waitForBarrier()

        // 5. deleteGenericBookmark
        manager.deleteGenericBookmark(genericLoc, forIdentifier: book.identifier)
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
        manager.addReadiumBookmark(bookmark, forIdentifier: book.identifier)
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
        manager.addGenericBookmark(loc, forIdentifier: book.identifier)
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
        manager.addOrReplaceGenericBookmark(loc, forIdentifier: book.identifier)
        waitForBarrier()

        let bookmarks = manager.genericBookmarks(forIdentifier: book.identifier)
        XCTAssertEqual(bookmarks.count, 1)
    }
}
