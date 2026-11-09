//  BookCoverStoreTests.swift
//
//  A loans sync replaces every TPPBook object. Covers, loading flags and the
//  cover color live in `BookCoverStore` by book ID, so the replacement objects
//  reuse them instead of reading the cache and computing the color again.

import XCTest
import UIKit
import Combine
@testable import PalaceBookModel

@MainActor
final class BookCoverStoreTests: XCTestCase {

    private var colorQueue: DispatchQueue!
    private var extractor: CountingColorExtractor!
    private var store: BookCoverStore!

    override func setUp() async throws {
        try await super.setUp()
        // No loader: a cache miss must not start a network fetch in these tests.
        TPPBookImageContext._resetForTesting()
        colorQueue = DispatchQueue(label: "BookCoverStoreTests.color")
        extractor = CountingColorExtractor()
        let extractor = extractor!
        store = BookCoverStore(colorQueue: colorQueue, colorExtractor: { extractor.extract($0) })
    }

    override func tearDown() async throws {
        TPPBookImageContext._resetForTesting()
        store = nil
        extractor = nil
        colorQueue = nil
        try await super.tearDown()
    }

    /// A sync builds a new object for a book whose cover is already decoded; it must reuse it.
    func testNewObjectForSameID_whenCoverIsStored_readsNoCacheAndComputesNoColor() async {
        let cover = UIImage()
        let cache = CountingCache(hits: ["id-a": cover])
        let first = Self.makeBook("id-a", cache: cache, store: store)
        await awaitConditionAsync(timeout: 3) { first.coverImage === cover && first.dominantUIColor == .red }
        XCTAssertEqual(extractor.count, 1)
        let readsBefore = cache.totalReads

        let second = Self.makeBook("id-a", cache: cache, store: store)

        XCTAssertIdentical(second.coverImage, cover, "the stored cover is visible without a main-queue hop")
        await settle()
        XCTAssertEqual(cache.totalReads, readsBefore, "no cache read for a cover the store already holds")
        XCTAssertEqual(extractor.count, 1, "no new color calculation")
        XCTAssertEqual(second.dominantUIColor, .red)
        withExtendedLifetime(first) {}
    }

    /// Views observe one object; a cover that lands through another live object for
    /// the same book must reach them, with the notice sent before the value changes.
    func testCoverSetOnOneObject_isVisibleOnAnotherAndNotifiesItBeforeTheChange() async {
        let cache = CountingCache()
        let writer = Self.makeBook("id-b", cache: cache, store: store)
        let observed = Self.makeBook("id-b", cache: cache, store: store)
        await settle()
        var coversSeenAtWillChange: [UIImage?] = []
        let subscription = observed.objectWillChange.sink { [unowned observed] _ in
            coversSeenAtWillChange.append(observed.coverImage)
        }
        let cover = UIImage()

        writer.coverImage = cover

        XCTAssertIdentical(observed.coverImage, cover)
        XCTAssertEqual(coversSeenAtWillChange.count, 1)
        XCTAssertNil(coversSeenAtWillChange.first ?? cover, "objectWillChange fires before the new value is stored")
        subscription.cancel()
    }

    func testReleasingLastObjectForID_dropsTheEntry() async {
        let cache = CountingCache()
        var book: TPPBook? = Self.makeBook("id-c", cache: cache, store: store)
        book?.coverImage = UIImage()
        XCTAssertEqual(store.liveObjectCount(for: "id-c"), 1)

        book = nil
        await settle()

        XCTAssertEqual(store.liveObjectCount(for: "id-c"), 0)
        XCTAssertEqual(store.entryCount, 0)
        XCTAssertNil(Self.makeBook("id-c", cache: cache, store: store).coverImage,
                     "a new object after the entry is dropped starts without a cover")
    }

    /// A loans sync merges into a new object before the registry releases the old one,
    /// so the live count never reaches zero and the cover survives.
    func testSyncReplacement_newObjectBeforeOldIsReleased_keepsCoverWithoutCacheReads() async {
        let cache = CountingCache()
        let cover = UIImage()
        let thumbnail = UIImage()
        var old: TPPBook? = Self.makeBook("id-s", cache: cache, store: store)
        old?.coverImage = cover
        old?.thumbnailImage = thumbnail
        old?.dominantUIColor = .blue
        let readsBefore = cache.totalReads

        var merged: TPPBook?
        do {
            let fresh = Self.makeBook("id-s", cache: cache, store: store)
            merged = old?.mergingPreservingMetadata(from: fresh)
        }
        old = nil
        await settle()

        XCTAssertIdentical(merged?.coverImage, cover)
        XCTAssertIdentical(merged?.thumbnailImage, thumbnail)
        XCTAssertEqual(merged?.dominantUIColor, .blue)
        XCTAssertEqual(cache.totalReads, readsBefore, "neither the feed object nor the merge reads the cache")
        XCTAssertEqual(store.liveObjectCount(for: "id-s"), 1)
    }

    func testDominantColor_isComputedOncePerImage_andAgainForADifferentImage() async {
        let book = Self.makeBook("id-d", cache: CountingCache(), store: store)
        await settle()
        let first = UIImage()
        let second = UIImage()

        book.updateDominantColor(using: first)
        await awaitConditionAsync(timeout: 3) { book.dominantUIColor == .red }
        book.updateDominantColor(using: first)
        await settle()
        XCTAssertEqual(extractor.count, 1, "same image object: no second calculation")

        book.updateDominantColor(using: second)
        await awaitConditionAsync(timeout: 3) { book.dominantUIColor == .blue }
        XCTAssertEqual(extractor.count, 2)
    }

    /// Replaces `$dominantUIColor`: emits the current color on subscribe, then each change,
    /// including a change made through another object for the same book.
    func testDominantColorPublisher_emitsCurrentThenColorSetThroughAnotherObject() async {
        let cache = CountingCache()
        let writer = Self.makeBook("id-p", cache: cache, store: store)
        let observed = Self.makeBook("id-p", cache: cache, store: store)
        await settle()
        var received: [UIColor] = []
        let subscription = observed.dominantUIColorPublisher.sink { received.append($0) }

        writer.dominantUIColor = .green

        await awaitConditionAsync(timeout: 3) { received.last == .green }
        XCTAssertEqual(received.first, .gray)
        subscription.cancel()
    }

    /// Covers are written from loader callbacks and merges off the main thread.
    func testConcurrentReadsAndWritesForManyIDs_keepCountsAndDropAllEntriesAfterRelease() async {
        let cache = CountingCache()
        let store = store!
        let ids = (0..<16).map { "id-e-\($0)" }
        var anchors: [TPPBook]? = ids.map { Self.makeBook($0, cache: cache, store: store) }
        let images = (0..<4).map { _ in UIImage() }

        DispatchQueue.concurrentPerform(iterations: 8) { worker in
            for step in 0..<40 {
                let id = ids[(worker * 7 + step) % ids.count]
                let transient = Self.makeBook(id, cache: cache, store: store)
                transient.coverImage = images[step % images.count]
                transient.thumbnailImage = images[(step + 1) % images.count]
                transient.isCoverLoading.toggle()
                _ = transient.dominantUIColor
                _ = transient.isThumbnailLoading
            }
        }
        await settle()

        for (index, id) in ids.enumerated() {
            XCTAssertEqual(store.liveObjectCount(for: id), 1, id)
            XCTAssertNotNil(anchors?[index].coverImage, id)
        }
        anchors = nil
        await settle()
        XCTAssertEqual(store.entryCount, 0)
    }

    // MARK: - Helpers

    /// Lets queued main-thread writes, color work and its write-back finish.
    private func settle() async {
        await drainMainQueueAsync()
        colorQueue.sync {}
        await drainMainQueueAsync()
        await drainMainQueueAsync()
    }

    nonisolated private static func makeBook(_ identifier: String, cache: ImageCacheType, store: BookCoverStore) -> TPPBook {
        TPPBook(
            acquisitions: [],
            authors: [],
            categoryStrings: [],
            distributor: "",
            identifier: identifier,
            imageURL: nil,
            imageThumbnailURL: nil,
            published: nil,
            publisher: "",
            subtitle: "",
            summary: "",
            title: "Title",
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
            imageCache: cache,
            coverStore: store
        )
    }
}

/// Returns red, then blue, then green, so a test can tell which call produced the color.
private final class CountingColorExtractor: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    var count: Int { lock.withLock { calls } }

    func extract(_ image: UIImage) -> UIColor {
        let call = lock.withLock { calls += 1; return calls }
        switch call {
        case 1: return .red
        case 2: return .blue
        default: return .green
        }
    }
}

private final class CountingCache: ImageCacheType, @unchecked Sendable {
    private let lock = NSLock()
    private var hits: [String: UIImage]
    private var reads = 0
    var totalReads: Int { lock.withLock { reads } }

    init(hits: [String: UIImage] = [:]) { self.hits = hits }

    func get(for key: String) -> UIImage? { lock.withLock { reads += 1; return hits[key] } }
    func getAsync(for key: String) async -> UIImage? { get(for: key) }
    func set(_ image: UIImage, for key: String, expiresIn: TimeInterval?) { lock.withLock { hits[key] = image } }
    func remove(for key: String) { lock.withLock { hits[key] = nil } }
    func clear() { lock.withLock { hits.removeAll() } }
    func warmMemoryCache(for keys: [String]) async {}
    func evictDecodedImages() {}
}
