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

final class TPPLastReadPositionPosterTests: XCTestCase {

    // MARK: - Properties

    private var bookRegistryMock: TPPBookRegistryMock!
    private var testBook: TPPBook!
    private var publication: Publication!
    private var spyWriter: SpyPositionWriter!
    private var poster: TPPLastReadPositionPoster!

    // MARK: - Setup

    override func setUpWithError() throws {
        try super.setUpWithError()

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

        try await Task.sleep(nanoseconds: 50_000_000)

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
        try await Task.sleep(nanoseconds: 50_000_000)

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
        try await Task.sleep(nanoseconds: 50_000_000)

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
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertNotNil(bookRegistryMock.location(forIdentifier: testBook.identifier),
                        "Writer failures must not roll back the local registry write")
    }

    // MARK: - Multiple calls

    func testStoreReadPosition_multipleCalls_eachDelegatesToWriter() async throws {
        let locator1 = createLocator(href: "/chapter1.xhtml", progression: 0.25, totalProgression: 0.1)
        let locator2 = createLocator(href: "/chapter2.xhtml", progression: 0.5, totalProgression: 0.3)

        poster.storeReadPosition(locator: locator1)
        poster.storeReadPosition(locator: locator2)
        try await Task.sleep(nanoseconds: 100_000_000)

        let saved = await spyWriter.savedSnapshots
        XCTAssertEqual(saved.count, 2,
                       "Poster always delegates to writer; throttling is the writer's job")
        XCTAssertTrue(saved.allSatisfy { $0.bookID == testBook.identifier })
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
