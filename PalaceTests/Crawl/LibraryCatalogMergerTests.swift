import XCTest
import PalaceCatalog
@testable import Palace

final class LibraryCatalogMergerTests: XCTestCase {

    // MARK: - Helpers

    private func makePub(
        id: String,
        title: String = "Library",
        thumbnailHref: String? = nil,
        updated: Date? = nil
    ) -> OPDS2Publication {
        var images: [OPDS2Link]? = nil
        if let href = thumbnailHref {
            images = [OPDS2Link(href: href, type: "image/png", rel: "http://opds-spec.org/image/thumbnail")]
        }
        return OPDS2Publication(
            links: [OPDS2Link(href: "https://example.com/\(id)/catalog", rel: "http://opds-spec.org/catalog")],
            metadata: OPDS2Publication.Metadata(
                updated: updated,
                description: nil,
                id: id,
                title: title
            ),
            images: images
        )
    }

    // MARK: - Merge: Incremental (isFullCrawl = false)

    func testMerge_EmptyExistingWithNewPublications_AddsAll() {
        let updates = [makePub(id: "a"), makePub(id: "b")]
        let result = LibraryCatalogMerger.merge(existing: [], updates: updates, isFullCrawl: false)

        XCTAssertEqual(result.publications.count, 2)
        XCTAssertEqual(Set(result.publications.map(\.metadata.id)), Set(["a", "b"]))
    }

    func testMerge_UpdatesExistingByID_ReplacesOldPublication() {
        let existing = [makePub(id: "a", title: "Old Name")]
        let updates = [makePub(id: "a", title: "New Name")]

        let result = LibraryCatalogMerger.merge(existing: existing, updates: updates, isFullCrawl: false)

        XCTAssertEqual(result.publications.count, 1)
        XCTAssertEqual(result.publications.first?.metadata.title, "New Name")
    }

    func testMerge_NewPublication_AppendsToList() {
        let existing = [makePub(id: "a")]
        let updates = [makePub(id: "b")]

        let result = LibraryCatalogMerger.merge(existing: existing, updates: updates, isFullCrawl: false)

        XCTAssertEqual(result.publications.count, 2)
        let ids = Set(result.publications.map(\.metadata.id))
        XCTAssertEqual(ids, Set(["a", "b"]))
    }

    func testMerge_PreservesUnmodifiedPublications_InIncrementalMode() {
        let existing = [makePub(id: "a"), makePub(id: "b"), makePub(id: "c")]
        let updates = [makePub(id: "b", title: "Updated B")]

        let result = LibraryCatalogMerger.merge(existing: existing, updates: updates, isFullCrawl: false)

        XCTAssertEqual(result.publications.count, 3)
        let bPub = result.publications.first { $0.metadata.id == "b" }
        XCTAssertEqual(bPub?.metadata.title, "Updated B")
    }

    // MARK: - Merge: Full Crawl (isFullCrawl = true)

    func testMerge_FullCrawl_RemovesAbsentPublications() {
        let existing = [makePub(id: "a"), makePub(id: "b"), makePub(id: "c")]
        let updates = [makePub(id: "a"), makePub(id: "c")]

        let result = LibraryCatalogMerger.merge(existing: existing, updates: updates, isFullCrawl: true)

        XCTAssertEqual(result.publications.count, 2)
        let ids = Set(result.publications.map(\.metadata.id))
        XCTAssertEqual(ids, Set(["a", "c"]))
    }

    func testMerge_FullCrawl_ReplacesAllWithUpdates() {
        let existing = [makePub(id: "a", title: "Old")]
        let updates = [makePub(id: "a", title: "New"), makePub(id: "d")]

        let result = LibraryCatalogMerger.merge(existing: existing, updates: updates, isFullCrawl: true)

        XCTAssertEqual(result.publications.count, 2)
        let aPub = result.publications.first { $0.metadata.id == "a" }
        XCTAssertEqual(aPub?.metadata.title, "New")
    }

    // MARK: - Logo Change Detection

    /// `uuidsWithChangedLogos` is the cache-invalidation signal that drives
    /// logo image refetch. It must include a UUID iff the logo URL
    /// (thumbnailHref) actually changed: URL→different URL, nil→URL,
    /// URL→nil, and brand-new publication. It must NOT include a UUID
    /// when the URL is unchanged. Lock all five transitions in one body
    /// — a mutant that flips ANY single transition's classification fails
    /// here on a different row.
    func testMerge_uuidsWithChangedLogos_includesAllTransitionsAndExcludesUnchangedURL() {
        struct Transition {
            let label: String
            let existing: [OPDS2Publication]
            let updates: [OPDS2Publication]
            let uuid: String
            let expected: Bool
        }

        let transitions: [Transition] = [
            // Positive cases — logo signal MUST fire
            .init(label: "URL changed",
                  existing: [makePub(id: "a", thumbnailHref: "https://old.com/logo.png")],
                  updates:  [makePub(id: "a", thumbnailHref: "https://new.com/logo.png")],
                  uuid: "a", expected: true),
            .init(label: "nil → URL (logo added)",
                  existing: [makePub(id: "a", thumbnailHref: nil)],
                  updates:  [makePub(id: "a", thumbnailHref: "https://new.com/logo.png")],
                  uuid: "a", expected: true),
            .init(label: "URL → nil (logo removed)",
                  existing: [makePub(id: "a", thumbnailHref: "https://old.com/logo.png")],
                  updates:  [makePub(id: "a", thumbnailHref: nil)],
                  uuid: "a", expected: true),
            .init(label: "new publication",
                  existing: [],
                  updates:  [makePub(id: "new-lib", thumbnailHref: "https://new.com/logo.png")],
                  uuid: "new-lib", expected: true),

            // Negative case — must NOT fire when URL unchanged
            .init(label: "URL unchanged",
                  existing: [makePub(id: "a", thumbnailHref: "https://same.com/logo.png")],
                  updates:  [makePub(id: "a", thumbnailHref: "https://same.com/logo.png")],
                  uuid: "a", expected: false),
        ]

        for t in transitions {
            let result = LibraryCatalogMerger.merge(
                existing: t.existing, updates: t.updates, isFullCrawl: false)
            XCTAssertEqual(
                result.uuidsWithChangedLogos.contains(t.uuid),
                t.expected,
                "\(t.label): expected uuidsWithChangedLogos.contains('\(t.uuid)') == \(t.expected)")
        }
    }

    // MARK: - Serialization

    func testSerializeAsCatalogsFeed_ProducesValidJSON() throws {
        let pubs = [makePub(id: "a"), makePub(id: "b")]
        let metadata = OPDS2CatalogsFeed.Metadata(adobe_vendor_id: "TestVendor", title: "Test Registry")

        let data = try XCTUnwrap(
            LibraryCatalogMerger.serializeAsCatalogsFeed(publications: pubs, metadata: metadata)
        )

        let feed = try OPDS2CatalogsFeed.fromData(data)
        XCTAssertEqual(feed.catalogs.count, 2)
        XCTAssertEqual(feed.metadata.title, "Test Registry")
        XCTAssertEqual(feed.metadata.adobe_vendor_id, "TestVendor")
    }

    func testSerializeAsCatalogsFeed_PreservesPublicationIDs() throws {
        let pubs = [makePub(id: "uuid-1"), makePub(id: "uuid-2")]
        let metadata = OPDS2CatalogsFeed.Metadata(adobe_vendor_id: nil, title: "Registry")

        let data = try XCTUnwrap(
            LibraryCatalogMerger.serializeAsCatalogsFeed(publications: pubs, metadata: metadata)
        )

        let feed = try OPDS2CatalogsFeed.fromData(data)
        let ids = Set(feed.catalogs.map(\.metadata.id))
        XCTAssertEqual(ids, Set(["uuid-1", "uuid-2"]))
    }
}
