//  TPPBookLargeCoverUpgradeTests.swift
//
//  The bare-identifier cache entry usually holds a lane-sized thumbnail. A
//  large cover view shows it only while the cover sized for that view loads.

import XCTest
import UIKit
@testable import Palace
import PalaceBookModel

@MainActor
final class TPPBookLargeCoverUpgradeTests: XCTestCase {

    private var cache: MockImageCache!
    private var loader: MockImageLoader!
    private let small = UIImage()
    private let sized = UIImage()

    override func setUp() async throws {
        try await super.setUp()
        cache = MockImageCache()
        loader = MockImageLoader()
        let loader = loader!
        TPPBookImageContext.imageLoaderProvider = { loader }
    }

    override func tearDown() async throws {
        loader.releaseSizedCover()
        TPPBookImageContext._resetForTesting()
        cache = nil
        loader = nil
        try await super.tearDown()
    }

    func testLargeDisplay_whenOnlyUnsizedCoverIsCached_fetchesTheSizedCover() async {
        cache.set(small, for: "book-1", expiresIn: nil)
        loader.stubbedCoverImage = sized
        let book = makeBook(identifier: "book-1")
        await waitForCover(of: book, toBe: small)

        book.fetchCoverImage(forDisplayHeight: 280)

        await waitForCover(of: book, toBe: sized)
        XCTAssertEqual(sizedFetches(of: book.identifier), [280])
    }

    /// The book starts with no cover, so only the placeholder path can put `small` on screen.
    func testLargeDisplay_showsUnsizedCoverWhileSizedFetchIsInFlight() async {
        let book = await makeCoverlessBook(identifier: "book-2")
        cache.set(small, for: book.identifier, expiresIn: nil)
        loader.holdSizedCover(for: book.identifier)

        book.fetchCoverImage(forDisplayHeight: 280)

        // Wait on the fetch itself: the placeholder that puts `small` on screen
        // is queued on main BEFORE the sized Task is created, so waiting for
        // the cover alone would return before the loader was ever called.
        await awaitConditionAsync { self.sizedFetches(of: book.identifier) == [280] }
        await waitForCover(of: book, toBe: small)
        XCTAssertTrue(book.isCoverLoading, "the sized fetch is still held open")
        XCTAssertEqual(sizedFetches(of: book.identifier), [280])
    }

    func testLargeDisplay_whenSizedFetchFails_keepsTheUnsizedCover() async {
        let book = await makeCoverlessBook(identifier: "book-6")
        cache.set(small, for: book.identifier, expiresIn: nil)
        loader.holdSizedCover(for: book.identifier)
        book.fetchCoverImage(forDisplayHeight: 280)
        await awaitConditionAsync { book.isCoverLoading }

        loader.releaseSizedCover()

        await awaitConditionAsync { !book.isCoverLoading }
        XCTAssertIdentical(book.coverImage, small, "a failed upgrade must not blank the placeholder")
    }

    /// Point-keyed entries written by earlier versions were capped at 300 px.
    func testLargeDisplay_ignoresPointKeyedEntry_andAsksTheLoader() async {
        let stale = UIImage()
        cache.set(small, for: "book-3", expiresIn: nil)
        cache.set(stale, for: "book-3_280pt", expiresIn: nil)
        loader.stubbedCoverImage = sized
        let book = makeBook(identifier: "book-3")

        book.fetchCoverImage(forDisplayHeight: 280)

        await waitForCover(of: book, toBe: sized)
        XCTAssertEqual(sizedFetches(of: book.identifier), [280])
    }

    /// The registry caches real decodes under its own pixel key. The view must not pin
    /// what it got (possibly an offline fallback) under its point key, or it never upgrades.
    func testLargeDisplay_secondVisit_asksTheLoaderAgain() async {
        let book = await makeCoverlessBook(identifier: "book-7")
        loader.stubbedCoverImage = sized
        book.fetchCoverImage(forDisplayHeight: 280)
        await waitForCover(of: book, toBe: sized)
        await awaitConditionAsync { !book.isCoverLoading }

        book.fetchCoverImage(forDisplayHeight: 280)

        await awaitConditionAsync { self.sizedFetches(of: book.identifier) == [280, 280] }
        XCTAssertEqual(sizedFetches(of: book.identifier), [280, 280])
    }

    /// Lane cells keep reusing the unsized entry so scrolling does no extra decode work.
    func testSmallDisplay_whenUnsizedCoverIsCached_doesNotFetch() async {
        cache.set(small, for: "book-4", expiresIn: nil)
        let book = makeBook(identifier: "book-4")

        book.fetchCoverImage(forDisplayHeight: 150)

        await waitForCover(of: book, toBe: small)
        XCTAssertEqual(sizedFetches(of: book.identifier), [])
    }

    /// 200 pt is the largest lane size, where the registry still serves the thumbnail URL.
    func testDisplayAtThreshold_whenUnsizedCoverIsCached_doesNotFetch() async {
        cache.set(small, for: "book-5", expiresIn: nil)
        let book = makeBook(identifier: "book-5")

        book.fetchCoverImage(forDisplayHeight: 200)

        await waitForCover(of: book, toBe: small)
        XCTAssertEqual(sizedFetches(of: book.identifier), [])
    }

    // MARK: - Helpers

    /// Filtered by book: the test host's own catalog also loads covers through
    /// the global image loader while a test runs.
    private func sizedFetches(of identifier: String) -> [CGFloat] {
        loader.coverCalls.filter { $0.identifier == identifier }.compactMap(\.displayPoints)
    }

    /// Waits for the cover the view would show.
    ///
    /// `TPPBook` is not `@MainActor`, and the sized path completes from a
    /// `Task` on the cooperative pool, so this polls the condition rather
    /// than draining the main queue: a drain cannot order against work the
    /// pool has not enqueued yet (see `XCTestCase.drainMainQueueAsync`).
    private func waitForCover(of book: TPPBook, toBe expected: UIImage, file: StaticString = #filePath, line: UInt = #line) async {
        await awaitConditionAsync(file: file, line: line) { book.coverImage === expected }
    }

    /// Built while the cache is empty and the loader returns nil, so `init`
    /// leaves both `coverImage` and `thumbnailImage` nil.
    private func makeCoverlessBook(identifier: String) async -> TPPBook {
        let book = makeBook(identifier: identifier)
        // `init` queues its loading flag and both loader completions on main
        // before returning; each completion queues one more block. Two hops run
        // all of them, and the queue is FIFO, so this needs no deadline.
        await drainMainQueueAsync()
        await drainMainQueueAsync()
        XCTAssertFalse(book.isCoverLoading)
        XCTAssertNil(book.coverImage)
        XCTAssertNil(book.thumbnailImage)
        return book
    }

    private func makeBook(identifier: String) -> TPPBook {
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
            imageCache: cache
        )
    }
}
