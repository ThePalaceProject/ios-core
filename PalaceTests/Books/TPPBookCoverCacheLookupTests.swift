//
//  TPPBookCoverCacheLookupTests.swift
//  PalaceTests
//
//  Regression coverage for the cover-image cache lookup in
//  `TPPBook.fetchCoverImage(forDisplayHeight:)`.
//
//  The lookup used to read:
//
//      lookupKeys.lazy.compactMap { [weak self] in self?.imageCache.get(for: $0) }.first
//
//  `LazySequenceProtocol.compactMap` is implemented as
//  `map(transform).filter { $0 != nil }.map { $0! }`, so the transform runs
//  TWICE per element — once for the filter's nil test, once for the trailing
//  force-unwrap. That force-unwrap is the `closure #2 in compactMap` that
//  appears in the crash report, and it traps whenever the second evaluation
//  disagrees with the first. Two ways that happens in production, both real:
//  the cache evicts the entry between the two reads, or `self` deallocates and
//  `self?.` starts returning nil.
//
//  Crash: `_assertionFailure` → `closure #2 in compactMap` → `Collection.first`
//  → `TPPBook.fetchCoverImage(forDisplayHeight:)`, reached from
//  `CatalogContentView.swift:93` (the lane-prefetch `onAppear`).
//
//  These tests pin the property that actually prevents the trap — the cache is
//  consulted exactly ONCE per key — rather than merely asserting the happy-path
//  return value, which the buggy implementation also satisfied. Restoring the
//  lazy `compactMap` doubles the call counts below and fails these by name.
//

import XCTest
import UIKit
@testable import PalaceBookModel

final class TPPBookCoverCacheLookupTests: XCTestCase {

    /// Counts reads per key and can be told to answer differently on the
    /// second read of a key — which is precisely the production race the lazy
    /// `compactMap` could not survive.
    private final class CountingCache: ImageCacheType, @unchecked Sendable {
        private let lock = NSLock()
        private var hits: [String: UIImage] = [:]
        private var evictAfterFirstRead: Set<String> = []
        private(set) var reads: [String: Int] = [:]

        init(hits: [String: UIImage] = [:], evictAfterFirstRead: Set<String> = []) {
            self.hits = hits
            self.evictAfterFirstRead = evictAfterFirstRead
        }

        func get(for key: String) -> UIImage? {
            lock.withLock {
                reads[key, default: 0] += 1
                let image = hits[key]
                if reads[key] == 1 && evictAfterFirstRead.contains(key) {
                    hits[key] = nil
                }
                return image
            }
        }

        func readCount(for key: String) -> Int { lock.withLock { reads[key] ?? 0 } }
        func resetCounts() { lock.withLock { reads.removeAll() } }

        func set(_ image: UIImage, for key: String, expiresIn: TimeInterval?) {}
        /// Counted SEPARATELY from `get`. On a full cache miss
        /// `fetchCoverImage` spawns a Task that awaits `getAsync` per key; if
        /// that shared the `reads` counter the synchronous assertions below
        /// would race it. Keeping the tallies apart makes them deterministic.
        private(set) var asyncReads: [String: Int] = [:]
        func getAsync(for key: String) async -> UIImage? {
            lock.withLock {
                asyncReads[key, default: 0] += 1
                return hits[key]
            }
        }
        func remove(for key: String) {}
        func clear() {}
        func warmMemoryCache(for keys: [String]) async {}
        func evictDecodedImages() {}
    }

    private let image = UIImage()

    // MARK: - The defect

    /// THE regression test. With the lazy `compactMap`, the filter's nil test
    /// read the (present) entry, the eviction removed it, and the trailing
    /// `{ $0! }` re-read nil and trapped. Evaluating once per key cannot trap,
    /// and returns the value the first read observed.
    func test_lookup_whenEntryIsEvictedBetweenReads_returnsFirstReadAndDoesNotTrap() {
        let cache = CountingCache(hits: ["book-1": image], evictAfterFirstRead: ["book-1"])

        let found = TPPBook.firstCachedImage(in: cache, keys: ["book-1"])

        XCTAssertNotNil(found, "an entry present on the first read must be returned, not re-read and force-unwrapped")
        XCTAssertEqual(cache.readCount(for: "book-1"), 1,
                       "the cache must be consulted exactly once per key — a second read is what trapped")
    }

    /// Same single-evaluation guarantee on the plain hit, stated as a call
    /// count so the lazy implementation cannot pass by returning the right
    /// image twice.
    func test_lookup_onHit_consultsCacheExactlyOncePerKey() {
        let cache = CountingCache(hits: ["sized": image])

        let found = TPPBook.firstCachedImage(in: cache, keys: ["sized", "unsized"])

        XCTAssertNotNil(found)
        XCTAssertEqual(cache.readCount(for: "sized"), 1)
        XCTAssertEqual(cache.readCount(for: "unsized"), 0,
                       "lookup must stop at the first hit and not consult later keys")
    }

    // MARK: - Ordering and misses

    func test_lookup_prefersEarlierKey_whenBothArePresent() {
        let sized = UIImage()
        let unsized = UIImage()
        let cache = CountingCache(hits: ["sized": sized, "unsized": unsized])

        let found = TPPBook.firstCachedImage(in: cache, keys: ["sized", "unsized"])

        XCTAssertIdentical(found, sized, "the size-specific key must win over the bare identifier")
    }

    func test_lookup_fallsThroughToLaterKey_whenEarlierMisses() {
        let cache = CountingCache(hits: ["unsized": image])

        let found = TPPBook.firstCachedImage(in: cache, keys: ["sized", "unsized"])

        XCTAssertIdentical(found, image)
        XCTAssertEqual(cache.readCount(for: "sized"), 1)
        XCTAssertEqual(cache.readCount(for: "unsized"), 1)
    }

    func test_lookup_returnsNil_whenNoKeyIsCached() {
        let cache = CountingCache()

        XCTAssertNil(TPPBook.firstCachedImage(in: cache, keys: ["a", "b"]))
        XCTAssertEqual(cache.readCount(for: "a"), 1)
        XCTAssertEqual(cache.readCount(for: "b"), 1)
    }

    func test_lookup_withNoKeys_returnsNilWithoutTouchingCache() {
        let cache = CountingCache(hits: ["a": image])

        XCTAssertNil(TPPBook.firstCachedImage(in: cache, keys: []))
        XCTAssertEqual(cache.readCount(for: "a"), 0)
    }

    // MARK: - The real caller

    /// The helper tests above all call `firstCachedImage` directly, so on their
    /// own they do not stop someone reverting the CALL SITE in
    /// `fetchCoverImage(forDisplayHeight:)` back to the lazy `compactMap` — the
    /// helper would simply sit unused and every one of them would still pass.
    /// That is the "green guard on the wrong surface" failure mode, so this test
    /// drives the producer and asserts the same single-read property there.
    func test_fetchCoverImage_consultsTheCacheOncePerKey() {
        let cache = CountingCache(hits: [:])
        let book = Self.makeBook(identifier: "book-42", imageCache: cache)

        // The initializer already calls fetchCoverImage() (unsized). Reset so
        // the assertion below measures only the sized call we make explicitly.
        cache.resetCounts()
        book.fetchCoverImage(forDisplayHeight: 44)

        XCTAssertEqual(cache.readCount(for: "book-42_44pt"), 1,
                       "the size-specific key must be read exactly once — a second read is what trapped")
        XCTAssertEqual(cache.readCount(for: "book-42"), 1,
                       "the bare identifier fallback must also be read exactly once")
    }

    /// Companion to the above on the hit path: a cached cover must be found
    /// without the cache being consulted twice for the same key.
    func test_fetchCoverImage_onHit_doesNotReReadTheHitKey() {
        let cache = CountingCache(hits: ["book-42_44pt": UIImage()])
        let book = Self.makeBook(identifier: "book-42", imageCache: cache)

        cache.resetCounts()
        book.fetchCoverImage(forDisplayHeight: 44)

        XCTAssertEqual(cache.readCount(for: "book-42_44pt"), 1)
        XCTAssertEqual(cache.readCount(for: "book-42"), 0,
                       "a hit on the sized key must short-circuit the fallback")
    }

    // MARK: - Helpers

    private static func makeBook(identifier: String, imageCache: ImageCacheType) -> TPPBook {
        TPPBook(
            acquisitions: [],
            authors: [],
            categoryStrings: [],
            distributor: "",
            identifier: identifier,
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
            imageCache: imageCache
        )
    }
}
