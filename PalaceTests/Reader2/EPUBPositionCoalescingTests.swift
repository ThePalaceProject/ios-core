//
//  EPUBPositionCoalescingTests.swift
//  PalaceTests
//
//  PP-5507: the EPUB poster keeps the registry's in-memory position current on
//  every page turn and writes the registry file at most once per 15 s; closing
//  the reader writes the newest position. Runs the poster against a real
//  registry over a temporary directory.
//

import XCTest
import ReadiumShared
import PalaceReadingPosition
@testable import Palace
import PalaceBookModel
@_spi(Testing) @testable import PalaceBookRegistry

private actor DiscardingPositionWriter: PositionWriter {
    func save(_ snapshot: PositionSnapshot) async throws -> ServerPositionID? { nil }
    func load(for bookID: String) async throws -> PositionSnapshot? { nil }
    func cancel(for bookID: String) async {}
}

// Not @MainActor: the poster and the Readium fixtures are non-Sendable and
// nonisolated, as in `TPPLastReadPositionPosterTests`.
final class EPUBPositionCoalescingTests: XCTestCase {

    private static let bookID = "epub-coalescing-book"

    private static func makePublication() -> Publication {
        Publication(manifest: Manifest(
            metadata: Metadata(title: "Coalescing", languages: ["en"]),
            readingOrder: [
                Link(href: "/chapter1.xhtml", mediaType: .xhtml),
                Link(href: "/chapter2.xhtml", mediaType: .xhtml)
            ]
        ))
    }

    private static func makeBook() -> TPPBook {
        TPPBookMocker.mockBook(identifier: bookID, title: "Coalescing", distributorType: .EpubZip)
    }

    private static func locator(_ href: String, progression: Double?, total: Double?) -> Locator {
        Locator(
            href: AnyURL(string: href)!,
            mediaType: .xhtml,
            locations: Locator.Locations(progression: progression, totalProgression: total)
        )
    }

    private func makeFixture() async -> PositionRegistryFixture {
        let fixture = PositionRegistryFixture(account: "epub-\(UUID().uuidString)")
        let account = fixture.scope.currentAccountID!
        await fixture.load(account)
        await fixture.addBooks([Self.bookID])
        return fixture
    }

    private func makePoster(_ fixture: PositionRegistryFixture) -> TPPLastReadPositionPoster {
        TPPLastReadPositionPoster(
            book: Self.makeBook(),
            publication: Self.makePublication(),
            bookRegistryProvider: fixture.registry,
            positionWriter: DiscardingPositionWriter()
        )
    }

    private func persistedHref(_ fixture: PositionRegistryFixture) -> String? {
        let account = fixture.scope.currentAccountID!
        guard let string = fixture.persistedLocations(account)?[Self.bookID],
              let json = try? JSONSerialization.jsonObject(with: Data(string.utf8)) as? [String: Any] else { return nil }
        return json["href"] as? String
    }

    private func memoryHref(_ fixture: PositionRegistryFixture) -> String? {
        guard let string = fixture.registry.location(forIdentifier: Self.bookID)?.locationString,
              let json = try? JSONSerialization.jsonObject(with: Data(string.utf8)) as? [String: Any] else { return nil }
        return json["href"] as? String
    }

    func testPageTurns_TenWithinFifteenSeconds_OneRegistryWriteAndNewestInMemory() async {
        let fixture = await makeFixture()
        defer { fixture.removeFiles() }
        let account = fixture.scope.currentAccountID!
        let poster = makePoster(fixture)
        let writesBefore = fixture.primaryWrites(account)

        for turn in 1...10 {
            poster.storeReadPosition(locator: Self.locator("/chapter\(turn % 2 + 1).xhtml", progression: Double(turn) / 20, total: Double(turn) / 20))
            fixture.clock.advance(1.4)
        }
        await fixture.registry._awaitPendingPersistenceForTesting()

        XCTAssertEqual(fixture.primaryWrites(account) - writesBefore, 1,
                       "ten page turns inside 15 s must rewrite the registry file once, not ten times")
        XCTAssertEqual(memoryHref(fixture), "/chapter1.xhtml", "the tenth turn must be current in memory")
    }

    func testBookmark_OneSecondAfterAPageTurn_CarriesTheNewHrefAndProgress() async throws {
        let fixture = await makeFixture()
        defer { fixture.removeFiles() }
        let poster = makePoster(fixture)
        poster.storeReadPosition(locator: Self.locator("/chapter1.xhtml", progression: 0.2, total: 0.1))
        fixture.clock.advance(1)
        let turned = Self.locator("/chapter2.xhtml", progression: 0.5, total: 0.6)
        poster.storeReadPosition(locator: turned)
        await fixture.registry._awaitPendingPersistenceForTesting()
        XCTAssertNotEqual(persistedHref(fixture), "/chapter2.xhtml", "premise: the turn has not reached disk")

        let publication = Self.makePublication()
        let factory = TPPBookmarkFactory(book: Self.makeBook(), publication: publication, drmDeviceID: "device")
        let bookmark = await factory.make(
            fromR3Location: TPPBookmarkR3Location(resourceIndex: 1, locator: turned),
            usingBookRegistry: fixture.registry,
            for: Self.makeBook(),
            publication: publication
        )

        // The saved dictionary lets the registry location's keys override the
        // bookmark's own, so a stale location would move the bookmark.
        let saved = try XCTUnwrap(bookmark?.toJSONDictionary())
        XCTAssertEqual(saved["href"] as? String, "/chapter2.xhtml")
        XCTAssertEqual((saved["progressWithinChapter"] as? NSNumber)?.doubleValue ?? -1, 0.5, accuracy: 0.001)
    }

    func testReaderClose_WritesTheNewestPosition() async {
        let fixture = await makeFixture()
        defer { fixture.removeFiles() }
        let poster = makePoster(fixture)
        poster.storeReadPosition(locator: Self.locator("/chapter1.xhtml", progression: 0.2, total: 0.1))
        fixture.clock.advance(1)

        poster.storeFinalPositionAndFlush(locator: Self.locator("/chapter2.xhtml", progression: 0.5, total: 0.6))

        XCTAssertEqual(persistedHref(fixture), "/chapter2.xhtml",
                       "closing the reader must leave the last page on disk")
    }

    func testRejectedLocator_IsNeverStoredInMemoryOrOnDisk() async {
        let fixture = await makeFixture()
        defer { fixture.removeFiles() }
        let account = fixture.scope.currentAccountID!
        let poster = makePoster(fixture)
        poster.storeReadPosition(locator: Self.locator("/chapter1.xhtml", progression: 0.2, total: 0.1))
        await fixture.registry._awaitPendingPersistenceForTesting()
        let writesBefore = fixture.primaryWrites(account)
        fixture.clock.advance(20)

        poster.storeFinalPositionAndFlush(locator: Self.locator("/chapter2.xhtml", progression: 0.5, total: nil))
        await fixture.registry._awaitPendingPersistenceForTesting()

        XCTAssertEqual(memoryHref(fixture), "/chapter1.xhtml", "a pre-layout locator must not replace the position")
        XCTAssertEqual(persistedHref(fixture), "/chapter1.xhtml")
        XCTAssertEqual(fixture.primaryWrites(account), writesBefore, "nothing was pending, so nothing is written")
    }
}
