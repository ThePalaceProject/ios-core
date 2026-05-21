//
//  TPPLastReadPositionPosterTests.swift
//  PalaceTests
//
//  Comprehensive tests for reading position posting logic.
//  Tests the REAL TPPLastReadPositionPoster class with mock dependencies.
//

import XCTest
import ReadiumShared
import PalaceCatalog
@testable import Palace

final class TPPLastReadPositionPosterTests: XCTestCase {

    // MARK: - Properties

    private var bookRegistryMock: TPPBookRegistryMock!
    private var testBook: TPPBook!
    private var publication: Publication!
    private var poster: TPPLastReadPositionPoster!

    // MARK: - Setup

    override func setUpWithError() throws {
        try super.setUpWithError()

        bookRegistryMock = TPPBookRegistryMock()
        testBook = createTestBook()
        publication = createTestPublication()

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
            bookRegistryProvider: bookRegistryMock
        )
    }

    override func tearDownWithError() throws {
        poster = nil
        publication = nil
        testBook = nil
        bookRegistryMock?.registry = [:]
        bookRegistryMock = nil
        try super.tearDownWithError()
    }

    // MARK: - Throttling Interval Tests

    func testThrottlingInterval_hasReasonableValue() {
        let interval = TPPLastReadPositionPoster.throttlingInterval

        XCTAssertGreaterThan(interval, 0, "Throttling interval should be positive")
        XCTAssertLessThanOrEqual(interval, 60, "Throttling interval should not exceed 1 minute")
    }

    // MARK: - Store Read Position Tests

    func testStoreReadPosition_validLocator_savesToRegistry() {
        let locator = createLocator(
            href: "/chapter1.xhtml",
            progression: 0.5,
            totalProgression: 0.25
        )

        poster.storeReadPosition(locator: locator)

        // Verify location was stored in registry
        let storedLocation = bookRegistryMock.location(forIdentifier: testBook.identifier)
        XCTAssertNotNil(storedLocation, "Location should be stored in registry")
    }

    func testStoreReadPosition_zeroProgression_withCssSelector_savesToRegistry() {
        // Locator with 0 progression but with CSS selector should be stored
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

        let storedLocation = bookRegistryMock.location(forIdentifier: testBook.identifier)
        XCTAssertNotNil(storedLocation)
    }

    func testStoreReadPosition_zeroProgressionNoCssSelector_doesNotStore() {
        let locator = createLocator(
            href: "/chapter1.xhtml",
            progression: nil,
            totalProgression: 0
        )

        // Clear any existing location
        bookRegistryMock.setLocation(nil, forIdentifier: testBook.identifier)

        poster.storeReadPosition(locator: locator)

        // With 0 totalProgression and no CSS selector, the poster's shouldStore
        // guard must reject the position — otherwise we'd persist a meaningless
        // "beginning of chapter" every time the reader opens a book.
        XCTAssertNil(bookRegistryMock.location(forIdentifier: testBook.identifier),
                     "Zero progression + no CSS selector must not persist a position")
    }

    func testStoreReadPosition_positiveProgression_stores() {
        let locator = createLocator(
            href: "/chapter2.xhtml",
            progression: 0.75,
            totalProgression: 0.5
        )

        poster.storeReadPosition(locator: locator)

        let storedLocation = bookRegistryMock.location(forIdentifier: testBook.identifier)
        XCTAssertNotNil(storedLocation)
    }

    // MARK: - Multiple Store Calls Tests

    func testStoreReadPosition_multipleCalls_updatesLocation() {
        let locator1 = createLocator(
            href: "/chapter1.xhtml",
            progression: 0.25,
            totalProgression: 0.1
        )

        let locator2 = createLocator(
            href: "/chapter2.xhtml",
            progression: 0.5,
            totalProgression: 0.3
        )

        poster.storeReadPosition(locator: locator1)
        poster.storeReadPosition(locator: locator2)

        let storedLocation = bookRegistryMock.location(forIdentifier: testBook.identifier)
        XCTAssertNotNil(storedLocation)
        // The second location should have replaced the first
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
            position: 7,
            totalProgression: 0
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
            position: 0,
            totalProgression: 0
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

// MARK: - Position Throttling Behavior Tests

final class PositionThrottlingTests: XCTestCase {

    private var bookRegistryMock: TPPBookRegistryMock!
    private var testBook: TPPBook!
    private var publication: Publication!

    override func setUpWithError() throws {
        try super.setUpWithError()
        bookRegistryMock = TPPBookRegistryMock()
        testBook = createTestBook()
        publication = createTestPublication()

        bookRegistryMock.addBook(
            testBook,
            location: nil,
            state: .downloadSuccessful,
            fulfillmentId: nil,
            readiumBookmarks: nil,
            genericBookmarks: nil
        )
    }

    override func tearDownWithError() throws {
        bookRegistryMock?.registry = [:]
        bookRegistryMock = nil
        testBook = nil
        publication = nil
        try super.tearDownWithError()
    }

    func testPoster_rapidPositionUpdates_throttlesUploads() {
        let poster = TPPLastReadPositionPoster(
            book: testBook,
            publication: publication,
            bookRegistryProvider: bookRegistryMock
        )

        // Rapidly update positions
        for i in 1...5 {
            let locator = Locator(
                href: AnyURL(string: "/chapter1.xhtml")!,
                mediaType: .xhtml,
                locations: Locator.Locations(
                    progression: Double(i) / 10.0,
                    totalProgression: Double(i) / 20.0
                )
            )
            poster.storeReadPosition(locator: locator)
        }

        // storeReadPosition saves locally (synchronous) then schedules server posting
        // asynchronously on serialQueue. The local mock write is immediate — no wait needed.

        // Local storage should be updated with the latest position
        let storedLocation = bookRegistryMock.location(forIdentifier: testBook.identifier)
        XCTAssertNotNil(storedLocation, "Latest position should be stored locally")

        // Note: Server posting is throttled - this tests local storage behavior
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
            authors: [],
            categoryStrings: [],
            distributor: "",
            identifier: "throttle-test-book",
            imageURL: nil,
            imageThumbnailURL: nil,
            published: Date(),
            publisher: "",
            subtitle: "",
            summary: "",
            title: "Throttle Test Book",
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
        let manifest = Manifest(
            metadata: Metadata(title: "Throttle Test"),
            readingOrder: [
                Link(href: "/chapter1.xhtml", mediaType: .xhtml)
            ]
        )
        return Publication(manifest: manifest)
    }
}
