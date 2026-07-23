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
import PalaceBookModel

@MainActor
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

        // Let queued main-queue completions land before tearing down.
        // Deterministic drain (a no-op enqueued behind the prior completions),
        // not a fixed sleep — the storm already completed synchronously, and
        // the SUT's async Tasks capture `[weak self]`, so any straggler is a
        // safe no-op. The crash this guards against (CoW over-release) would
        // already have fired during the storm above.
        drainMainQueue()
        XCTAssertNotNil(sut, "SUT survived concurrent delete/fetch without an over-release crash")
    }

    // MARK: - isSyncing / completionHandlersQueue: every completion fires once

    func testSyncBookmarks_concurrentCallers_everyCompletionFiresExactlyOnce() {
        let (sut, _, _) = makeSUT()

        let n = 25
        let expectations = (0..<n).map { expectation(description: "sync completion \($0)") }
        // Swift 6: captured mutable vars can't be mutated inside the @Sendable
        // concurrentPerform closure even under a lock — the var storage is shared.
        // Fold the count + first-fire set + lock into one Sendable tracker.
        final class FireTracker: @unchecked Sendable {
            private let lock = NSLock()
            private var counts = [Int: Int]()
            private var fulfilled = Set<Int>()
            /// Records a fire for `i`; returns true iff this is its FIRST fire.
            func recordFire(_ i: Int) -> Bool {
                lock.withLock {
                    counts[i, default: 0] += 1
                    return fulfilled.insert(i).inserted
                }
            }
            var snapshot: [Int: Int] { lock.withLock { counts } }
        }
        let tracker = FireTracker()

        // When a sync is already in flight, additional callers enqueue their
        // completion in `completionHandlersQueue`, which `finalizeSync` drains.
        // Without serialization the append raced the drain → a CoW-corruption
        // crash. The fix routes both through the serial `queue`.
        //
        // Count fires under the lock and fulfill each expectation AT MOST ONCE:
        // decoupling the fire-count from the XCTestExpectation API means a stray
        // double-delivery surfaces as `fireCount > 1` (a clean assertion failure)
        // instead of an `NSInternalInconsistencyException` from a double
        // `fulfill()` — which previously crashed the whole test runner under
        // load and forced a suite restart. The timeout is generous because the
        // 25 completions fan out through `DispatchQueue.main.async`, which can
        // back up behind a saturated main queue on a heavily loaded host; a slow
        // drain must not be misread as a lost completion.
        DispatchQueue.concurrentPerform(iterations: n) { i in
            sut.syncBookmarks(localBookmarks: []) { _ in
                if tracker.recordFire(i) { expectations[i].fulfill() }
            }
        }

        wait(for: expectations, timeout: 60.0) // FLAKE-003-OK: 25-way concurrent sync fan-out via DispatchQueue.main.async; generous ceiling tolerates main-queue saturation under full-suite load (fires in <1s uncontended). Crash-safe via idempotent fulfill.
        let counts = tracker.snapshot
        for i in 0..<n {
            XCTAssertEqual(counts[i], 1, "sync completion \(i) must fire exactly once")
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
