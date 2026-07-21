//
//  TPPLastReadPositionPosterTests.swift
//  PalaceTests
//
//  Tests for `TPPLastReadPositionPoster`. As of the PalaceReadingPosition
//  migration the poster's job is:
//
//  1. Reject locators with zero progression and no CSS selector
//     (`shouldStore` guard).
//  2. Save the locator locally via `bookRegistry.setLocation`.
//  3. Build a `PositionSnapshot` and delegate to the injected
//     `PositionWriter`.
//
//  Throttling/queuing now lives in `PositionWriter`; the writer is
//  exercised in its own SPM tests. Here we verify the poster's
//  delegation + the snapshot shape it produces.
//

import XCTest
import ReadiumShared
import PalaceCatalog
import PalaceReadingPosition
@testable import Palace

// MARK: - Spy PositionWriter

private actor SpyPositionWriter: PositionWriter {
    private(set) var savedSnapshots: [PositionSnapshot] = []
    private(set) var loadedBookIDs: [String] = []
    private(set) var cancelledBookIDs: [String] = []
    private var savedThrows: Error?

    func setSaveError(_ error: Error?) { savedThrows = error }

    func save(_ snapshot: PositionSnapshot) async throws -> ServerPositionID? {
        savedSnapshots.append(snapshot)
        if let err = savedThrows { throw err }
        return "spy-server-id"
    }

    func load(for bookID: String) async throws -> PositionSnapshot? {
        loadedBookIDs.append(bookID)
        return nil
    }

    func cancel(for bookID: String) async {
        cancelledBookIDs.append(bookID)
    }
}

@MainActor
final class TPPLastReadPositionPosterTests: XCTestCase {

    // MARK: - Properties

    private var bookRegistryMock: TPPBookRegistryMock!
    private var testBook: TPPBook!
    private var publication: Publication!
    private var spyWriter: SpyPositionWriter!
    // `nonisolated(unsafe)`: the poster is a plain (nonisolated) class touched only
    // serially across setUp→test→tearDown on the main thread, so awaiting its
    // `awaitPendingWrites()` join seam must not be treated as sending a @MainActor
    // property across an isolation boundary (Swift 6 "sending 'self.poster'" error).
    nonisolated(unsafe) private var poster: TPPLastReadPositionPoster!

    // MARK: - Setup

    // async setUp adopts the class's @MainActor isolation so the @MainActor
    // createTestPublication() result is not returned to a nonisolated context.
    override func setUp() async throws {
        try await super.setUp()

        bookRegistryMock = TPPBookRegistryMock()
        testBook = createTestBook()
        publication = createTestPublication()
        spyWriter = SpyPositionWriter()

        bookRegistryMock.addBook(
            testBook,
            location: nil,
            state: .downloadSuccessful,
            fulfillmentId: nil,
            readiumBookmarks: nil,
            genericBookmarks: nil
        )

        poster = TPPLastReadPositionPoster(
            book: testBook,
            publication: publication,
            bookRegistryProvider: bookRegistryMock,
            positionWriter: spyWriter
        )
    }

    override func tearDownWithError() throws {
        poster = nil
        publication = nil
        testBook = nil
        bookRegistryMock?.registry = [:]
        bookRegistryMock = nil
        spyWriter = nil
        try super.tearDownWithError()
    }

    // MARK: - Throttling Interval Sentinel

    /// `TPPLastReadPositionPoster.throttlingInterval` is the shared 15s
    /// contract value pinned at `PalaceTests/Reader/EPUBPositionTests:114`.
    /// If this constant drifts, the SPM-side `RemotePositionWriter` default
    /// drifts with it — both are 15.0 by contract.
    func testThrottlingInterval_isLockedAtFifteenSeconds() {
        XCTAssertEqual(TPPLastReadPositionPoster.throttlingInterval, 15.0,
                       "Throttle window is contract-locked at 15s")
    }

    // MARK: - Store: shouldStore predicate

    func testStoreReadPosition_zeroProgressionNoCssSelector_doesNotStore() async throws {
        let locator = createLocator(
            href: "/chapter1.xhtml",
            progression: nil,
            totalProgression: 0
        )

        bookRegistryMock.setLocation(nil, forIdentifier: testBook.identifier)
        poster.storeReadPosition(locator: locator)

        // Join the actual write path deterministically. `shouldStore` rejects
        // this locator so no Task is spawned; awaiting the (nil) pending task
        // is a correct no-op that still asserts nothing was persisted.
        for task in poster.pendingWriteTasksForTesting() { await task.value }

        XCTAssertNil(bookRegistryMock.location(forIdentifier: testBook.identifier),
                     "Zero progression + no CSS selector must not persist locally")
        let saved = await spyWriter.savedSnapshots
        XCTAssertTrue(saved.isEmpty,
                      "Zero progression + no CSS selector must not delegate to writer")
    }

    func testStoreReadPosition_zeroProgressionWithCssSelector_storesLocally_andDelegates() async throws {
        let locations = Locator.Locations(
            totalProgression: 0,
            otherLocations: ["cssSelector": "#heading"]
        )
        let locator = Locator(
            href: AnyURL(string: "/chapter1.xhtml")!,
            mediaType: .xhtml,
            locations: locations
        )

        poster.storeReadPosition(locator: locator)
        for task in poster.pendingWriteTasksForTesting() { await task.value }

        XCTAssertNotNil(bookRegistryMock.location(forIdentifier: testBook.identifier))
        let saved = await spyWriter.savedSnapshots
        XCTAssertEqual(saved.count, 1, "CSS-selector locator must reach the writer")
        XCTAssertEqual(saved.first?.bookID, testBook.identifier)
        XCTAssertEqual(saved.first?.format, .epubLocator)
    }

    // MARK: - Store: happy path

    func testStoreReadPosition_validLocator_savesLocally_andDelegatesToWriter() async throws {
        let locator = createLocator(
            href: "/chapter1.xhtml",
            progression: 0.5,
            totalProgression: 0.25
        )

        poster.storeReadPosition(locator: locator)
        for task in poster.pendingWriteTasksForTesting() { await task.value }

        // Local registry write
        XCTAssertNotNil(bookRegistryMock.location(forIdentifier: testBook.identifier))

        // Writer delegation
        let saved = await spyWriter.savedSnapshots
        XCTAssertEqual(saved.count, 1)
        let snapshot = try XCTUnwrap(saved.first)
        XCTAssertEqual(snapshot.bookID, testBook.identifier)
        XCTAssertEqual(snapshot.format, .epubLocator)
        let payloadString = String(data: snapshot.payload, encoding: .utf8) ?? ""
        XCTAssertTrue(payloadString.contains("/chapter1.xhtml"),
                      "Payload must carry the Readium locator JSON; got \(payloadString)")
    }

    func testStoreReadPosition_writerThrows_doesNotCrash_localStateUnaffected() async throws {
        await spyWriter.setSaveError(PositionWriterError.networkUnavailable)
        let locator = createLocator(
            href: "/chapter2.xhtml",
            progression: 0.75,
            totalProgression: 0.5
        )

        poster.storeReadPosition(locator: locator)
        for task in poster.pendingWriteTasksForTesting() { await task.value }

        XCTAssertNotNil(bookRegistryMock.location(forIdentifier: testBook.identifier),
                        "Writer failures must not roll back the local registry write")
    }

    // MARK: - Multiple calls

    func testStoreReadPosition_multipleCalls_eachDelegatesToWriter() async throws {
        let locator1 = createLocator(href: "/chapter1.xhtml", progression: 0.25, totalProgression: 0.1)
        let locator2 = createLocator(href: "/chapter2.xhtml", progression: 0.5, totalProgression: 0.3)

        poster.storeReadPosition(locator: locator1)
        poster.storeReadPosition(locator: locator2)
        // Both spawned tasks are retained; drain BOTH before reading the spy.
        for task in poster.pendingWriteTasksForTesting() { await task.value }

        let saved = await spyWriter.savedSnapshots
        XCTAssertEqual(saved.count, 2,
                       "Poster always delegates to writer; throttling is the writer's job")
        XCTAssertTrue(saved.allSatisfy { $0.bookID == testBook.identifier })
    }

    // MARK: - shouldStore Predicate Boundary Tests (P0 #1)
    //
    // The shouldStore predicate is the gate between "the WKWebView fired a
    // locator-change event" and "we persist that position to the registry +
    // post it as the last-read-position annotation". Two real bugs we are
    // closing here:
    //
    //   * Pre-render junk persistence — Readium fires an initial
    //     locator-change with `totalProgression == nil` *before* the
    //     WKWebView has laid out the document. The old predicate
    //     `progression > 0 ?? 0` treated nil as 0, so the cssSelector
    //     escape-hatch alone was enough to persist garbage, blowing away
    //     the user's real last-read position.
    //
    //   * Zero-progression chapter-start persistence — at exactly the
    //     first paint of a chapter `totalProgression == 0.0`. The old
    //     predicate rejected that (good) but accepted it the moment ANY
    //     cssSelector was attached, even if the locator hadn't actually
    //     rendered. We now require BOTH: `totalProgression != nil` AND
    //     either non-zero total progression OR a position OR a cssSelector.

    func testShouldStore_progressionNil_doesNotStore() {
        // totalProgression == nil indicates the WKWebView has not rendered
        // — the locator is pre-paint junk. Even with a cssSelector, we
        // must NOT persist this, or we wipe the patron's real position.
        let locations = Locator.Locations(
            otherLocations: ["cssSelector": "#heading"]
        )
        let locator = Locator(
            href: AnyURL(string: "/chapter1.xhtml")!,
            mediaType: .xhtml,
            locations: locations
        )

        bookRegistryMock.setLocation(nil, forIdentifier: testBook.identifier)
        poster.storeReadPosition(locator: locator)

        XCTAssertNil(bookRegistryMock.location(forIdentifier: testBook.identifier),
                     "nil totalProgression (pre-render) must not persist a position, even with a cssSelector")
    }

    func testShouldStore_progressionExactlyZero_doesNotStore() {
        // totalProgression == 0.0 with no other anchor is the "user opened
        // the book and the very first paint completed" state. Persisting
        // here would overwrite their real saved position with chapter-1
        // start. Reject.
        let locator = createLocator(
            href: "/chapter1.xhtml",
            progression: nil,
            totalProgression: 0
        )

        bookRegistryMock.setLocation(nil, forIdentifier: testBook.identifier)
        poster.storeReadPosition(locator: locator)

        XCTAssertNil(bookRegistryMock.location(forIdentifier: testBook.identifier),
                     "totalProgression == 0 with no cssSelector / position must not persist")
    }

    func testShouldStore_meaningfulProgression_stores() {
        // Regression guard: a legitimate mid-book position must persist.
        let locator = createLocator(
            href: "/chapter2.xhtml",
            progression: 0.5,
            totalProgression: 0.45
        )

        bookRegistryMock.setLocation(nil, forIdentifier: testBook.identifier)
        poster.storeReadPosition(locator: locator)

        XCTAssertNotNil(bookRegistryMock.location(forIdentifier: testBook.identifier),
                        "Meaningful totalProgression (0.45) must persist")
    }

    func testShouldStore_cssSelectorWithRenderedZeroProgression_stores() {
        // CONTRACT DECISION: when totalProgression is non-nil (the WKWebView
        // has rendered) AND a cssSelector is present, we trust the
        // selector — even if total progression is exactly 0.0. This
        // covers the legitimate "first paragraph of chapter, scrolled to
        // a specific element" case.
        let locations = Locator.Locations(
            totalProgression: 0,
            otherLocations: ["cssSelector": "#para-7"]
        )
        let locator = Locator(
            href: AnyURL(string: "/chapter1.xhtml")!,
            mediaType: .xhtml,
            locations: locations
        )

        bookRegistryMock.setLocation(nil, forIdentifier: testBook.identifier)
        poster.storeReadPosition(locator: locator)

        XCTAssertNotNil(bookRegistryMock.location(forIdentifier: testBook.identifier),
                        "Rendered-zero progression WITH cssSelector must persist (CFI anchor)")
    }

    func testShouldStore_positionGreaterThanZero_stores() {
        // PDF / fixed-layout EPUB carry a page `position` instead of
        // continuous progression. A position > 0 must be sufficient
        // to persist even when totalProgression is exactly 0 and there
        // is no cssSelector — otherwise PDF readers can't restore
        // their saved page.
        //
        // Critical: keep totalProgression at 0 AND no cssSelector so
        // the position-branch is the ONLY accepting path. This pins
        // the mutant `position > 0 → return true ⇒ return false`.
        let locations = Locator.Locations(
            totalProgression: 0,
            position: 7
        )
        let locator = Locator(
            href: AnyURL(string: "/chapter1.xhtml")!,
            mediaType: .xhtml,
            locations: locations
        )

        bookRegistryMock.setLocation(nil, forIdentifier: testBook.identifier)
        poster.storeReadPosition(locator: locator)

        XCTAssertNotNil(bookRegistryMock.location(forIdentifier: testBook.identifier),
                        "Locator with explicit position > 0 must persist (even with zero totalProgression and no selector)")
    }

    func testShouldStore_positionZero_doesNotStore() {
        // Boundary guard against the `position > 0 → position >= 0`
        // mutant. A locator with `position == 0` and no other anchor
        // must NOT persist — position 0 is the equivalent of "before
        // page 1".
        let locations = Locator.Locations(
            totalProgression: 0,
            position: 0
        )
        let locator = Locator(
            href: AnyURL(string: "/chapter1.xhtml")!,
            mediaType: .xhtml,
            locations: locations
        )

        bookRegistryMock.setLocation(nil, forIdentifier: testBook.identifier)
        poster.storeReadPosition(locator: locator)

        XCTAssertNil(bookRegistryMock.location(forIdentifier: testBook.identifier),
                     "position == 0 with no other anchor must NOT persist")
    }

    func testShouldStore_progressionPositiveButTinyAndRendered_stores() {
        // Boundary guard: any positive totalProgression on a rendered page
        // is enough. The previous predicate also accepted this; the new
        // one keeps the behavior so a regression mutating `> 0` into
        // `>= 0` or similar surfaces in the zero-tests above.
        let locator = createLocator(
            href: "/chapter1.xhtml",
            progression: 0.001,
            totalProgression: 0.001
        )

        bookRegistryMock.setLocation(nil, forIdentifier: testBook.identifier)
        poster.storeReadPosition(locator: locator)

        XCTAssertNotNil(bookRegistryMock.location(forIdentifier: testBook.identifier),
                        "Small but positive totalProgression must persist")
    }

    // MARK: - Helper Methods

    private func createTestBook() -> TPPBook {
        let placeholderUrl = URL(string: "https://test.example.com/book")!
        let acquisition = TPPOPDSAcquisition(
            relation: .generic,
            type: "application/epub+zip",
            hrefURL: placeholderUrl,
            indirectAcquisitions: [],
            availability: TPPOPDSAcquisitionAvailabilityUnlimited()
        )

        return TPPBook(
            acquisitions: [acquisition],
            authors: [TPPBookAuthor(authorName: "Test Author", relatedBooksURL: nil)],
            categoryStrings: [],
            distributor: "",
            identifier: "position-poster-test-book",
            imageURL: nil,
            imageThumbnailURL: nil,
            published: Date(),
            publisher: "",
            subtitle: "",
            summary: "",
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
            contributors: [:],
            bookDuration: nil,
            imageCache: MockImageCache()
        )
    }

    private func createTestPublication() -> Publication {
        let metadata = Metadata(
            title: "Test Book",
            languages: ["en"]
        )

        let readingOrder = [
            Link(href: "/chapter1.xhtml", mediaType: .xhtml),
            Link(href: "/chapter2.xhtml", mediaType: .xhtml),
            Link(href: "/chapter3.xhtml", mediaType: .xhtml)
        ]

        let manifest = Manifest(
            metadata: metadata,
            readingOrder: readingOrder
        )

        return Publication(manifest: manifest)
    }

    private func createLocator(
        href: String,
        progression: Double?,
        totalProgression: Double
    ) -> Locator {
        return Locator(
            href: AnyURL(string: href)!,
            mediaType: .xhtml,
            locations: Locator.Locations(
                progression: progression,
                totalProgression: totalProgression
            )
        )
    }
}
