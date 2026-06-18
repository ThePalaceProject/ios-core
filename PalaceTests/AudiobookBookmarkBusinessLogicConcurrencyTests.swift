//
//  AudiobookBookmarkBusinessLogicConcurrencyTests.swift
//  PalaceTests
//
//  Regression coverage for the 3.3.0 bookmark-sync thread-safety crash
//  (Crashlytics abfef568). `AudiobookBookmarkBusinessLogic` kept three pieces
//  of mutable state — `deletedBookmarkIds` (a Swift Set), `isSyncing`, and
//  `completionHandlersQueue` — that were read/written from the UI thread,
//  URLSession completion threads, and the work queue with no shared
//  serialization. Concurrent mutation of the Set/Array corrupted its
//  copy-on-write buffer refcount → an over-release surfaced in the captured
//  network-completion closure chain. The fix routes all of that state through
//  the class's serial `queue` via `onStateQueue`.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import PalaceCatalog
@testable import Palace
@testable import PalaceAudiobookToolkit

final class AudiobookBookmarkBusinessLogicConcurrencyTests: XCTestCase {

    // MARK: - Thread-safe mock so concurrency failures are attributable to the SUT

    /// `TPPBookRegistryMock` stores in a plain dictionary with no locking, so a
    /// concurrent test would otherwise race the *mock* rather than the SUT.
    /// Guard the methods the bookmark flow touches with one recursive lock; the
    /// only remaining unsynchronized shared state is then the SUT's own.
    private final class LockedRegistryMock: TPPBookRegistryMock {
        private let lock = NSRecursiveLock()
        private func sync<T>(_ body: () -> T) -> T {
            lock.lock(); defer { lock.unlock() }; return body()
        }
        override func setLocation(_ location: TPPBookLocation?, forIdentifier identifier: String) {
            sync { super.setLocation(location, forIdentifier: identifier) }
        }
        override func location(forIdentifier identifier: String) -> TPPBookLocation? {
            sync { super.location(forIdentifier: identifier) }
        }
        override func genericBookmarksForIdentifier(_ bookIdentifier: String) -> [TPPBookLocation] {
            sync { super.genericBookmarksForIdentifier(bookIdentifier) }
        }
        override func addOrReplaceGenericBookmark(_ location: TPPBookLocation, forIdentifier bookIdentifier: String) {
            sync { super.addOrReplaceGenericBookmark(location, forIdentifier: bookIdentifier) }
        }
        override func deleteGenericBookmark(_ location: TPPBookLocation, forIdentifier bookIdentifier: String) {
            sync { super.deleteGenericBookmark(location, forIdentifier: bookIdentifier) }
        }
        override func replaceGenericBookmark(_ oldLocation: TPPBookLocation, with newLocation: TPPBookLocation, forIdentifier bookIdentifier: String) {
            sync { super.replaceGenericBookmark(oldLocation, with: newLocation, forIdentifier: bookIdentifier) }
        }
    }

    private let bookIdentifier = "fakeAudiobook"
    private let testID = "TestID"
    private let manifestJSON: ManifestJSON = .snowcrash
    private var fakeBook: TPPBook!
    private var tracks: Tracks!

    override func setUp() {
        super.setUp()
        let placeholderUrl = URL(string: "https://test.example.com/book")!
        let fakeAcquisition = TPPOPDSAcquisition(
            relation: .generic,
            type: "application/epub+zip",
            hrefURL: placeholderUrl,
            indirectAcquisitions: [TPPOPDSIndirectAcquisition](),
            availability: TPPOPDSAcquisitionAvailabilityUnlimited()
        )
        fakeBook = TPPBook(
            acquisitions: [fakeAcquisition],
            authors: [TPPBookAuthor](),
            categoryStrings: [String](),
            distributor: "",
            identifier: bookIdentifier,
            imageURL: nil,
            imageThumbnailURL: nil,
            published: Date(),
            publisher: "",
            subtitle: "",
            summary: "",
            title: "",
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
            contributors: [:],
            bookDuration: nil,
            imageCache: MockImageCache()
        )
        let manifest = try! Manifest.from(jsonFileName: manifestJSON.rawValue, bundle: Bundle(for: type(of: self)))
        tracks = Tracks(manifest: manifest, audiobookID: testID, token: nil)
    }

    private func makeSUT() -> (AudiobookBookmarkBusinessLogic, LockedRegistryMock, TPPAnnotationMock) {
        let registry = LockedRegistryMock()
        registry.addBook(fakeBook, state: .downloadSuccessful)
        let annotations = TPPAnnotationMock()
        let sut = AudiobookBookmarkBusinessLogic(
            book: fakeBook, registry: registry, annotationsManager: annotations
        )
        return (sut, registry, annotations)
    }

    // MARK: - abfef568: concurrent mutation must not corrupt the deleted-id Set

    func testConcurrentDeleteAndFetch_doesNotCrash() {
        let (sut, _, _) = makeSUT()

        // Writers (deleteBookmark → deletedBookmarkIds.insert) interleaved with
        // readers (fetchBookmarks → fetchLocalBookmarks snapshots the Set).
        // Pre-fix, the raw `Set` insert/contains from many threads tore the CoW
        // buffer and over-released. Survival across 3 CI iterations is the
        // assertion.
        let iterations = 400
        DispatchQueue.concurrentPerform(iterations: iterations) { i in
            if i % 4 == 0 {
                sut.fetchBookmarks(for: self.tracks, toc: []) { _ in }
            } else {
                let bookmark = AudioBookmark(
                    type: .locatorAudioBookTime,
                    annotationId: "",                 // unsynced → no network leg
                    chapter: "track-\(i % 6)",
                    time: i
                )
                sut.deleteBookmark(at: bookmark) { _ in }
            }
        }

        // Let any queued fetches settle before tearing down.
        let settle = expectation(description: "queue settles")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { settle.fulfill() }
        wait(for: [settle], timeout: 5.0)
        XCTAssertNotNil(sut, "SUT survived concurrent delete/fetch without an over-release crash")
    }

    // MARK: - isSyncing / completionHandlersQueue: every completion fires once

    func testSyncBookmarks_concurrentCallers_everyCompletionFiresExactlyOnce() {
        let (sut, _, _) = makeSUT()

        let n = 25
        let expectations = (0..<n).map { expectation(description: "sync completion \($0)") }
        let countLock = NSLock()
        var fireCount = [Int: Int]()

        // When a sync is already in flight, additional callers enqueue their
        // completion in `completionHandlersQueue`, which `finalizeSync` drains.
        // Without serialization the append raced the drain → a completion could
        // be lost (timeout) or double-invoked (over-fulfill). Assert each fires
        // exactly once.
        DispatchQueue.concurrentPerform(iterations: n) { i in
            sut.syncBookmarks(localBookmarks: []) { _ in
                countLock.lock(); fireCount[i, default: 0] += 1; countLock.unlock()
                expectations[i].fulfill()
            }
        }

        wait(for: expectations, timeout: 15.0)
        for i in 0..<n {
            XCTAssertEqual(fireCount[i], 1, "sync completion \(i) must fire exactly once")
        }
    }

    // MARK: - Deterministic: a deleted bookmark is filtered from local fetch

    func testDeleteBookmark_thenFetch_filtersDeletedBookmark() {
        let (sut, registry, _) = makeSUT()

        // Seed one synced bookmark locally.
        let bookmark = AudioBookmark(
            type: .locatorAudioBookTime,
            annotationId: "ann-keepme-then-delete",
            chapter: "track-1",
            time: 1234
        )
        guard let location = bookmark.toTPPBookLocation() else {
            return XCTFail("bookmark must convert to a TPPBookLocation")
        }
        registry.addOrReplaceGenericBookmark(location, forIdentifier: bookIdentifier)

        // Delete it — this inserts its id into the serialized deleted-id set.
        let deleted = expectation(description: "delete completes")
        sut.deleteBookmark(at: bookmark) { _ in deleted.fulfill() }
        wait(for: [deleted], timeout: 5.0)

        // A subsequent fetch must NOT surface the deleted bookmark.
        let fetched = expectation(description: "fetch completes")
        var returned: [TrackPosition] = []
        sut.fetchBookmarks(for: tracks, toc: []) { positions in
            returned = positions
            fetched.fulfill()
        }
        wait(for: [fetched], timeout: 5.0)

        XCTAssertFalse(
            returned.contains { $0.annotationId == "ann-keepme-then-delete" },
            "Deleted bookmark must be filtered out via the serialized deleted-id set"
        )
    }
}
