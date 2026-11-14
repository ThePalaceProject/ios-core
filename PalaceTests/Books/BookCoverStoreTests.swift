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
        (TPPBookImageContext.imageLoaderProvider?() as? MockImageLoader)?.releaseSizedCover()
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

    /// The detail header and a related-books lane cell can show the same book. The
    /// lane's cache hit holds a smaller image and must not replace the header's cover.
    func testLaneSizedCacheHitOnAnotherObject_keepsTheLargerCover() async {
        let small = solidImage(width: 10, height: 15)
        let large = solidImage(width: 200, height: 300)
        let cache = CountingCache(hits: ["id-l": small])
        let loader = MockImageLoader()
        loader.stubbedCoverImage = large
        TPPBookImageContext.imageLoaderProvider = { loader }
        let header = Self.makeBook("id-l", cache: cache, store: store)
        await awaitConditionAsync(timeout: 3) { header.coverImage === small }
        header.fetchCoverImage(forDisplayHeight: 280)
        await awaitConditionAsync(timeout: 3) { header.coverImage === large && !header.isCoverLoading }
        await settle()
        let colorCalculations = extractor.count

        let laneCell = Self.makeBook("id-l", cache: cache, store: store)
        laneCell.fetchCoverImage(forDisplayHeight: 160)
        await settle()

        XCTAssertIdentical(header.coverImage, large)
        XCTAssertIdentical(laneCell.coverImage, large)
        XCTAssertEqual(extractor.count, colorCalculations, "a refused cover computes no color")
    }

    /// A TenPrint drawn at display size can have more pixels than a real decode capped
    /// at 1200 px; the real cover from a later visit must still replace it.
    func testRealCoverOnLaterFetch_replacesALargerGeneratedPlaceholder() async {
        let generated = solidImage(width: 600, height: 900)
        generated.isGeneratedCoverPlaceholder = true
        let real = solidImage(width: 525, height: 840)
        let loader = MockImageLoader()
        loader.stubbedCoverImage = generated
        TPPBookImageContext.imageLoaderProvider = { loader }
        let header = Self.makeBook("id-g", cache: CountingCache(), store: store)
        header.fetchCoverImage(forDisplayHeight: 280)
        await awaitConditionAsync(timeout: 3) { header.coverImage === generated && !header.isCoverLoading }

        loader.stubbedCoverImage = real
        header.fetchCoverImage(forDisplayHeight: 280)

        await awaitConditionAsync(timeout: 3) { header.coverImage === real }
    }

    /// An offline visit gets a TenPrint; it must not replace the real cover already shown.
    func testGeneratedPlaceholderOnLaterFetch_doesNotReplaceARealCover() async {
        let real = solidImage(width: 525, height: 840)
        let generated = solidImage(width: 600, height: 900)
        generated.isGeneratedCoverPlaceholder = true
        let loader = MockImageLoader()
        loader.stubbedCoverImage = real
        TPPBookImageContext.imageLoaderProvider = { loader }
        let header = Self.makeBook("id-r", cache: CountingCache(), store: store)
        header.fetchCoverImage(forDisplayHeight: 280)
        await awaitConditionAsync(timeout: 3) { header.coverImage === real && !header.isCoverLoading }

        loader.stubbedCoverImage = generated
        loader.holdSizedCover(for: "id-r")
        header.fetchCoverImage(forDisplayHeight: 280)
        await awaitConditionAsync(timeout: 3) { self.sizedFetchCount(loader, "id-r") == 2 }
        await drainMainQueueAsync()
        XCTAssertTrue(header.isCoverLoading, "precondition: the second fetch is in flight")

        loader.releaseSizedCover()

        await awaitConditionAsync(timeout: 3) { !header.isCoverLoading }
        XCTAssertIdentical(header.coverImage, real)
    }

    /// Loader callbacks and merges write off the main thread; SwiftUI must still hear about it on main.
    func testOffMainWrite_sendsObjectWillChangeOnMain() async {
        let book = Self.makeBook("id-o", cache: CountingCache(), store: store)
        await settle()
        var noticesOnMain: [Bool] = []
        let subscription = book.objectWillChange.sink { _ in noticesOnMain.append(Thread.isMainThread) }
        let cover = UIImage()

        DispatchQueue.global().async { book.coverImage = cover }

        await awaitConditionAsync(timeout: 3) { !noticesOnMain.isEmpty }
        XCTAssertEqual(noticesOnMain, [true])
        XCTAssertIdentical(book.coverImage, cover)
        subscription.cancel()
    }

    /// The object that started a thumbnail fetch can be released by a sync before the
    /// loader answers; its replacement skipped its own fetch and depends on that answer.
    func testThumbnailCallbackAfterStartingObjectIsReleased_reachesTheReplacement() async {
        let loader = HeldThumbnailLoader()
        TPPBookImageContext.imageLoaderProvider = { loader }
        let cache = CountingCache()
        var first: TPPBook? = Self.makeBook("id-t", cache: cache, store: store)
        XCTAssertEqual(loader.pendingThumbnailCount, 1)
        let second = Self.makeBook("id-t", cache: cache, store: store)
        XCTAssertEqual(loader.pendingThumbnailCount, 1, "the replacement waits on the fetch in flight")
        first = nil
        await settle()
        XCTAssertEqual(store.liveObjectCount(for: "id-t"), 1)
        let thumbnail = UIImage()

        loader.answerThumbnails(with: thumbnail)
        await settle()

        XCTAssertIdentical(second.thumbnailImage, thumbnail)
        XCTAssertFalse(second.isThumbnailLoading)
        withExtendedLifetime(first) {}
    }

    /// A thumbnail stands in for the color only while a book has no cover.
    func testThumbnailArrival_setsTheColorOnlyForABookWithoutACover() async {
        let loader = HeldThumbnailLoader()
        TPPBookImageContext.imageLoaderProvider = { loader }
        let cache = CountingCache()
        let coverless = Self.makeBook("id-h1", cache: cache, store: store)
        let covered = Self.makeBook("id-h2", cache: cache, store: store)
        let cover = UIImage()
        covered.coverImage = cover
        covered.updateDominantColor(using: cover)
        await awaitConditionAsync(timeout: 3) { covered.dominantUIColor == .red }

        loader.answerThumbnails(with: UIImage())

        await awaitConditionAsync(timeout: 3) { coverless.dominantUIColor == .blue }
        await settle()
        XCTAssertEqual(covered.dominantUIColor, .red, "the cover's color stays")
        XCTAssertEqual(extractor.count, 2)
    }

    // MARK: - Byte limit and release (PP-5583)

    /// Over the byte limit the store lets go of the cover read longest ago, so a
    /// long scroll does not keep every cover it passed.
    func testOverByteLimit_releasesTheLeastRecentlyReadCover() async {
        let first = solidImage(width: 10, height: 10)
        let limited = makeLimitedStore(byteLimit: 2 * first.decodedBytes, keepRecent: 1)
        let cache = CountingCache()
        let a = Self.makeBook("lru-a", cache: cache, store: limited)
        let b = Self.makeBook("lru-b", cache: cache, store: limited)
        let c = Self.makeBook("lru-c", cache: cache, store: limited)
        await settle()

        a.coverImage = first
        b.coverImage = solidImage(width: 10, height: 10)
        _ = a.coverImage
        c.coverImage = solidImage(width: 10, height: 10)

        XCTAssertNil(limited.state(for: "lru-b").coverImage, "b was read longest ago")
        XCTAssertIdentical(limited.state(for: "lru-a").coverImage, first)
        XCTAssertNotNil(limited.state(for: "lru-c").coverImage)
        XCTAssertLessThanOrEqual(limited.imageByteCount, 2 * first.decodedBytes)
    }

    /// When one release is not enough, the limit keeps releasing the next oldest
    /// cover until the store is back under it.
    func testFarOverByteLimit_releasesUntilUnderTheLimit() async {
        let first = solidImage(width: 10, height: 10)
        let limit = 2 * first.decodedBytes
        let limited = makeLimitedStore(byteLimit: limit, keepRecent: 1)
        let cache = CountingCache()
        let a = Self.makeBook("far-a", cache: cache, store: limited)
        let b = Self.makeBook("far-b", cache: cache, store: limited)
        let c = Self.makeBook("far-c", cache: cache, store: limited)
        await settle()
        a.coverImage = first
        b.coverImage = solidImage(width: 10, height: 10)
        XCTAssertEqual(limited.imageByteCount, limit, "precondition: at the limit")

        // Twice the size of the others, so one release is not enough.
        c.coverImage = solidImage(width: 10, height: 20)

        XCTAssertNil(limited.state(for: "far-a").coverImage)
        XCTAssertNil(limited.state(for: "far-b").coverImage)
        XCTAssertNotNil(limited.state(for: "far-c").coverImage)
        XCTAssertLessThanOrEqual(limited.imageByteCount, limit)
    }

    /// A book that has only a thumbnail is released too; My Books rows can hold
    /// thumbnails with no full cover.
    func testReleaseImages_releasesAThumbnailOnlyEntry() async {
        let limited = makeLimitedStore(byteLimit: .max, keepRecent: 0)
        let book = Self.makeBook("thumb-only", cache: CountingCache(), store: limited)
        await settle()
        book.thumbnailImage = solidImage(width: 5, height: 5)
        XCTAssertNil(limited.state(for: "thumb-only").coverImage, "precondition: no cover")

        limited.releaseImages()

        XCTAssertNil(limited.state(for: "thumb-only").thumbnailImage)
        XCTAssertEqual(limited.imageByteCount, 0)
    }

    /// A memory warning releases covers outside the recently read floor and sends
    /// no change notice, so a view that drew the cover keeps its frame.
    func testReleaseImages_keepsRecentlyReadCovers_releasesTheRestWithoutNotices() async {
        let limited = makeLimitedStore(byteLimit: .max, keepRecent: 2)
        let cache = CountingCache()
        let a = Self.makeBook("rel-a", cache: cache, store: limited)
        let b = Self.makeBook("rel-b", cache: cache, store: limited)
        let c = Self.makeBook("rel-c", cache: cache, store: limited)
        await settle()
        a.coverImage = solidImage(width: 10, height: 10)
        a.thumbnailImage = solidImage(width: 5, height: 5)
        let coverB = solidImage(width: 10, height: 10)
        let coverC = solidImage(width: 10, height: 10)
        b.coverImage = coverB
        c.coverImage = coverC
        _ = b.coverImage
        _ = c.coverImage
        var notices = 0
        let subscription = a.objectWillChange.sink { _ in notices += 1 }

        limited.releaseImages()
        await settle()

        XCTAssertNil(limited.state(for: "rel-a").coverImage)
        XCTAssertNil(limited.state(for: "rel-a").thumbnailImage)
        XCTAssertIdentical(b.coverImage, coverB)
        XCTAssertIdentical(c.coverImage, coverC)
        XCTAssertEqual(limited.imageByteCount, coverB.decodedBytes + coverC.decodedBytes)
        XCTAssertEqual(notices, 0, "a release must not redraw views")
        subscription.cancel()
    }

    /// A cover a visible cell has drawn is still there after a memory warning, and
    /// nothing asks the loader for it again.
    func testCoverDrawnInVisibleCell_stillRendersAfterRelease_withoutAFetch() async {
        let loader = MockImageLoader()
        TPPBookImageContext.imageLoaderProvider = { loader }
        let limited = makeLimitedStore(byteLimit: .max, keepRecent: 1)
        let cache = CountingCache()
        let offscreen = Self.makeBook("vis-off", cache: cache, store: limited)
        let visible = Self.makeBook("vis-on", cache: cache, store: limited)
        await settle()
        offscreen.coverImage = solidImage(width: 10, height: 10)
        let drawn = solidImage(width: 10, height: 10)
        visible.coverImage = drawn
        _ = visible.coverImage
        let fetchesBefore = loader.coverCalls.count

        limited.releaseImages()
        await settle()

        XCTAssertIdentical(visible.coverImage, drawn)
        XCTAssertEqual(loader.coverCalls.count, fetchesBefore)
        XCTAssertNil(limited.state(for: "vis-off").coverImage, "precondition: the release ran")
    }

    /// After a release the getter shows the decoded copy the image cache still holds,
    /// so a redraw before the next fetch does not show an empty cell.
    func testReleasedCover_getterFallsBackToTheImageCacheMemoryCopy() async {
        let limited = makeLimitedStore(byteLimit: .max, keepRecent: 0)
        let cache = CountingCache()
        let book = Self.makeBook("fb-a", cache: cache, store: limited)
        await settle()
        autoreleasepool {
            book.coverImage = solidImage(width: 10, height: 10)
        }
        let cached = solidImage(width: 10, height: 10)
        cache.set(cached, for: "fb-a", expiresIn: nil)

        autoreleasepool { limited.releaseImages() }

        XCTAssertIdentical(book.coverImage, cached)
        XCTAssertNil(limited.state(for: "fb-a").coverImage, "the store holds no copy of its own")
    }

    /// A released thumbnail reads the image cache's thumbnail copy, as the cover does.
    func testReleasedThumbnail_getterFallsBackToTheImageCacheMemoryCopy() async {
        let limited = makeLimitedStore(byteLimit: .max, keepRecent: 0)
        let cache = CountingCache()
        let book = Self.makeBook("fb-thumb", cache: cache, store: limited)
        await settle()
        autoreleasepool {
            book.thumbnailImage = solidImage(width: 5, height: 5)
        }
        let cached = solidImage(width: 5, height: 5)
        cache.set(cached, for: "fb-thumb_thumbnail", expiresIn: nil)

        autoreleasepool { limited.releaseImages() }

        XCTAssertIdentical(book.thumbnailImage, cached)
    }

    /// A book read recently but holding no image does not take a place in the
    /// recently read floor, so an older cover that is in the floor stays.
    func testRecentlyReadBookWithoutImages_doesNotTakeAFloorPlace() async {
        let limited = makeLimitedStore(byteLimit: .max, keepRecent: 1)
        let cache = CountingCache()
        let withCover = Self.makeBook("floor-a", cache: cache, store: limited)
        let loading = Self.makeBook("floor-b", cache: cache, store: limited)
        await settle()
        let cover = solidImage(width: 10, height: 10)
        withCover.coverImage = cover
        _ = withCover.coverImage
        _ = loading.coverImage

        limited.releaseImages()

        XCTAssertIdentical(limited.state(for: "floor-a").coverImage, cover)
    }

    /// The fallback is only for a released cover: a book whose cover never loaded
    /// keeps showing its loading state.
    func testCoverNeverLoaded_getterDoesNotReadTheImageCache() async {
        let limited = makeLimitedStore(byteLimit: .max, keepRecent: 0)
        let cache = CountingCache()
        let book = Self.makeBook("fb-b", cache: cache, store: limited)
        await settle()
        cache.set(solidImage(width: 10, height: 10), for: "fb-b", expiresIn: nil)

        XCTAssertNil(book.coverImage)
    }

    /// A release keeps the cover color, and the same cover coming back computes no
    /// new color.
    func testReleasedCover_keepsColor_andTheReturningCoverComputesNoNewColor() async {
        let limited = makeLimitedStore(byteLimit: .max, keepRecent: 0)
        let book = Self.makeBook("col-a", cache: CountingCache(), store: limited)
        await settle()
        limited.offerCover(solidImage(width: 10, height: 10), for: "col-a")
        await settle()
        XCTAssertEqual(extractor.count, 1, "precondition: the first cover computed a color")

        limited.releaseImages()
        let returning = solidImage(width: 10, height: 10)
        limited.offerCover(returning, for: "col-a")
        await settle()

        XCTAssertIdentical(book.coverImage, returning)
        XCTAssertEqual(book.dominantUIColor, .red)
        XCTAssertEqual(extractor.count, 1)
    }

    /// Limits follow the device tiers the image cache uses.
    func testLimitsForDevice_followMemoryTiers() {
        let mb = 1024 * 1024
        XCTAssertEqual(BookCoverStore.Limits.forDevice(memoryMB: 2047), .init(byteLimit: 15 * mb, keepRecent: 40))
        XCTAssertEqual(BookCoverStore.Limits.forDevice(memoryMB: 2048), .init(byteLimit: 25 * mb, keepRecent: 40))
        XCTAssertEqual(BookCoverStore.Limits.forDevice(memoryMB: 4095), .init(byteLimit: 25 * mb, keepRecent: 40))
        XCTAssertEqual(BookCoverStore.Limits.forDevice(memoryMB: 4096), .init(byteLimit: 40 * mb, keepRecent: 80))
    }

    /// A release keeps the identifiers it is told to keep, such as the playing
    /// audiobook (PP-5581).
    func testReleaseImagesKeeping_keepsNamedCovers() async {
        let limited = makeLimitedStore(byteLimit: .max, keepRecent: 0)
        let cache = CountingCache()
        let kept = Self.makeBook("keep-a", cache: cache, store: limited)
        let other = Self.makeBook("keep-b", cache: cache, store: limited)
        await settle()
        let cover = solidImage(width: 10, height: 10)
        kept.coverImage = cover
        other.coverImage = solidImage(width: 10, height: 10)

        limited.releaseImages(keeping: ["keep-a"])

        XCTAssertIdentical(limited.state(for: "keep-a").coverImage, cover)
        XCTAssertNil(limited.state(for: "keep-b").coverImage)
    }

    /// A released cover that a view still holds comes back as the same image,
    /// at the same size, from the getter and after a restore (PP-5581).
    func testReleasedCoverStillHeldElsewhere_getterAndRestoreReturnTheSameImage() async {
        let limited = makeLimitedStore(byteLimit: .max, keepRecent: 0)
        let book = Self.makeBook("weak-a", cache: CountingCache(), store: limited)
        await settle()
        let drawn = solidImage(width: 10, height: 10)
        book.coverImage = drawn

        limited.releaseImages()

        XCTAssertIdentical(book.coverImage, drawn, "the getter finds the image a view still holds")
        limited.restoreReleasedImages()
        XCTAssertIdentical(limited.state(for: "weak-a").coverImage, drawn)
    }

    /// A released cover nothing else holds is freed, and a restore does not bring
    /// it back.
    func testReleasedCoverHeldNowhere_isFreed() async {
        let limited = makeLimitedStore(byteLimit: .max, keepRecent: 0)
        let book = Self.makeBook("weak-b", cache: CountingCache(), store: limited)
        await settle()
        autoreleasepool {
            book.coverImage = solidImage(width: 10, height: 10)
        }

        autoreleasepool { limited.releaseImages() }
        limited.restoreReleasedImages()

        XCTAssertNil(limited.state(for: "weak-b").coverImage)
        XCTAssertEqual(limited.imageByteCount, 0)
    }

    private func makeLimitedStore(byteLimit: Int, keepRecent: Int) -> BookCoverStore {
        let extractor = extractor!
        return BookCoverStore(
            colorQueue: colorQueue,
            colorExtractor: { extractor.extract($0) },
            limits: .init(byteLimit: byteLimit, keepRecent: keepRecent)
        )
    }

    // MARK: - Helpers

    private func sizedFetchCount(_ loader: MockImageLoader, _ identifier: String) -> Int {
        loader.coverCalls.filter { $0.identifier == identifier && $0.displayPoints != nil }.count
    }

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

final class DominantCoverColorTests: XCTestCase {

    func testExtract_solidImage_returnsItsColor() {
        let color = UIColor(red: 0.2, green: 0.6, blue: 0.4, alpha: 1)

        let result = DominantCoverColor.extract(from: solidImage(width: 20, height: 30, color: color))

        assertSameColor(result, color)
    }

    /// Images over 500 px are scaled down before averaging; the average must not move.
    func testExtract_imageWiderThan500Pixels_returnsTheSameColor() {
        let color = UIColor(red: 0.7, green: 0.1, blue: 0.3, alpha: 1)

        let result = DominantCoverColor.extract(from: solidImage(width: 900, height: 200, color: color))

        assertSameColor(result, color)
    }

    func testExtract_zeroSizeImage_returnsGray() {
        XCTAssertEqual(DominantCoverColor.extract(from: UIImage()), .gray)
    }

    private func assertSameColor(_ actual: UIColor, _ expected: UIColor, file: StaticString = #filePath, line: UInt = #line) {
        let a = rgba(actual)
        let e = rgba(expected)
        for index in 0..<4 {
            XCTAssertEqual(a[index], e[index], accuracy: 0.02, "component \(index)", file: file, line: line)
        }
    }

    private func rgba(_ color: UIColor) -> [CGFloat] {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        XCTAssertTrue(color.getRed(&red, green: &green, blue: &blue, alpha: &alpha))
        return [red, green, blue, alpha]
    }
}

/// A solid-color image at scale 1, so its pixel size equals its point size.
private func solidImage(width: Int, height: Int, color: UIColor = .red) -> UIImage {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let size = CGSize(width: width, height: height)
    return UIGraphicsImageRenderer(size: size, format: format).image { context in
        color.setFill()
        context.fill(CGRect(origin: .zero, size: size))
    }
}

/// Holds every thumbnail completion until the test answers it; cover fetches never answer.
private final class HeldThumbnailLoader: ImageLoading, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [(UIImage?) -> Void] = []
    var pendingThumbnailCount: Int { lock.withLock { pending.count } }

    func answerThumbnails(with image: UIImage?) {
        let completions = lock.withLock { () -> [(UIImage?) -> Void] in
            defer { pending = [] }
            return pending
        }
        completions.forEach { $0(image) }
    }

    func thumbnailImage(for book: TPPBook, completion: @escaping (UIImage?) -> Void) {
        lock.withLock { pending.append(completion) }
    }

    func coverImage(for book: TPPBook, completion: @escaping (UIImage?) -> Void) {}
    func coverImage(for book: TPPBook) async -> UIImage? { nil }
    func coverImage(for book: TPPBook, displayPoints: CGFloat) async -> UIImage? { nil }
    func thumbnailImage(for book: TPPBook) async -> UIImage? { nil }
    func playerCoverImage(for book: TPPBook) async -> UIImage? { nil }
    func get(for key: String) -> UIImage? { nil }
    func getAsync(for key: String) async -> UIImage? { nil }
    func set(_ image: UIImage, for key: String, expiresIn: TimeInterval?) {}
    func remove(for key: String) {}
    func clearAll() {}
    func evictDecodedImages() {}
    func warmMemoryCache(for keys: [String]) async {}
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
    func memoryImage(for key: String) -> UIImage? { lock.withLock { hits[key] } }
}

private extension UIImage {
    var decodedBytes: Int { cgImage.map { $0.bytesPerRow * $0.height } ?? 0 }
}
