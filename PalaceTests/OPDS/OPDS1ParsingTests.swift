//
//  OPDS1ParsingTests.swift
//  PalaceTests
//
//  Deep, mutation-killing unit tests for the OPDS 1.x parser stack:
//  TPPOPDSFeed, TPPOPDSEntry, TPPOPDSLink, plus facet-group attributes.
//
//  These tests pin existing parser behavior — they intentionally do NOT
//  modify production code. Tests load fixtures from
//  PalaceTests/Fixtures/OPDSFeeds/ via #filePath (no bundle resources
//  wiring required), keeping them purely deterministic with no network
//  and no mocks beyond the fixture bytes.
//

import XCTest
@testable import Palace
import PalaceCatalog

// MARK: - Fixture loader

private enum OPDS1Fixture {
    static func load(_ name: String) -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // OPDS
            .deletingLastPathComponent()      // PalaceTests
            .appendingPathComponent("Fixtures/OPDSFeeds/\(name)")
        return try! Data(contentsOf: url)
    }

    static func parseFeed(_ name: String) -> TPPOPDSFeed? {
        let data = load(name)
        guard let xml = TPPXML.xml(withData: data) else { return nil }
        return TPPOPDSFeed(xml: xml)
    }
}

@MainActor
final class OPDS1ParsingTests: XCTestCase {

    // MARK: - Catalog feed (opds1_catalog.xml)

    func testCatalog_parsesExpectedEntryCount() throws {
        let feed = try XCTUnwrap(OPDS1Fixture.parseFeed("opds1_catalog.xml"))
        XCTAssertEqual(feed.entries.count, 3,
                       "Expected exactly 3 well-formed entries in opds1_catalog.xml")
    }

    func testCatalog_parsesFeedIdentifier() throws {
        let feed = try XCTUnwrap(OPDS1Fixture.parseFeed("opds1_catalog.xml"))
        XCTAssertEqual(feed.identifier, "https://example.org/testlib/catalog")
    }

    func testCatalog_parsesFeedTitle() throws {
        let feed = try XCTUnwrap(OPDS1Fixture.parseFeed("opds1_catalog.xml"))
        XCTAssertEqual(feed.title, "Testlib Acquisition Feed")
    }

    func testCatalog_parsesFeedUpdatedAsRFC3339Date() throws {
        let feed = try XCTUnwrap(OPDS1Fixture.parseFeed("opds1_catalog.xml"))
        let updated = try XCTUnwrap(feed.updated, "feed.updated must be parsed")
        let components = Calendar(identifier: .iso8601)
            .dateComponents(in: TimeZone(secondsFromGMT: 0)!, from: updated)
        XCTAssertEqual(components.year, 2024)
        XCTAssertEqual(components.month, 6)
        XCTAssertEqual(components.day, 15)
        XCTAssertEqual(components.hour, 10)
        XCTAssertEqual(components.minute, 0)
    }

    func testCatalog_parsesEntryTitlesInDocumentOrder() throws {
        let feed = try XCTUnwrap(OPDS1Fixture.parseFeed("opds1_catalog.xml"))
        let titles = feed.entries.map { $0.title }
        XCTAssertEqual(titles, ["Bright Star", "The Quiet River", "Algorithms of the Heart"],
                       "Entries must be preserved in document order with exact titles")
    }

    func testCatalog_parsesEntryIdentifiers() throws {
        let feed = try XCTUnwrap(OPDS1Fixture.parseFeed("opds1_catalog.xml"))
        let ids = feed.entries.map { $0.identifier }
        XCTAssertEqual(ids, [
            "urn:uuid:opds1-entry-001",
            "urn:uuid:opds1-entry-002",
            "urn:uuid:opds1-entry-003"
        ])
    }

    func testCatalog_multipleAuthors_allPreservedInOrder() throws {
        let feed = try XCTUnwrap(OPDS1Fixture.parseFeed("opds1_catalog.xml"))
        let first = try XCTUnwrap(feed.entries.first)
        XCTAssertEqual(first.authorStrings, ["Adelaide North", "Bernard South"],
                       "Multiple <author><name> children must be preserved in order")
    }

    func testCatalog_singleAuthor_preserved() throws {
        let feed = try XCTUnwrap(OPDS1Fixture.parseFeed("opds1_catalog.xml"))
        XCTAssertEqual(feed.entries[1].authorStrings, ["Carla West"])
    }

    func testCatalog_paginationNextLink_captured() throws {
        let feed = try XCTUnwrap(OPDS1Fixture.parseFeed("opds1_catalog.xml"))
        let next = feed.links.first { $0.rel == "next" }
        XCTAssertNotNil(next, "Feed must expose 'next' link for pagination state")
        XCTAssertEqual(next?.href.absoluteString,
                       "https://example.org/testlib/catalog?page=2")
    }

    func testCatalog_searchLink_parsedWithType() throws {
        let feed = try XCTUnwrap(OPDS1Fixture.parseFeed("opds1_catalog.xml"))
        let search = try XCTUnwrap(feed.links.first { $0.rel == "search" })
        XCTAssertEqual(search.type, "application/opensearchdescription+xml")
    }

    func testCatalog_acquisitionLinks_areBucketedSeparatelyFromLinks() throws {
        let feed = try XCTUnwrap(OPDS1Fixture.parseFeed("opds1_catalog.xml"))
        let first = feed.entries[0]
        // Both open-access and borrow should land in acquisitions.
        let acqRels = first.acquisitions
            .map { NYPLOPDSAcquisitionRelationString($0.relation) }
            .sorted()
        XCTAssertEqual(acqRels, [
            "http://opds-spec.org/acquisition/borrow",
            "http://opds-spec.org/acquisition/open-access"
        ])
        // Acquisition links must NOT also appear in entry.links (they are
        // bucketed exclusively into entry.acquisitions when matched).
        let acquisitionHrefsInLinks = first.links.filter {
            $0.rel?.contains("opds-spec.org/acquisition") == true
        }
        XCTAssertTrue(acquisitionHrefsInLinks.isEmpty,
                      "Acquisition rel links must not be duplicated into entry.links")
        // alternate captured into entry.alternate, not into entry.links
        XCTAssertEqual(first.alternate?.href.absoluteString,
                       "https://example.org/testlib/works/001",
                       "rel='alternate' link must populate entry.alternate")
        XCTAssertFalse(first.links.contains { $0.rel == "alternate" },
                       "alternate must be moved out of entry.links")
    }

    func testCatalog_openAccessAndBorrow_bothPreservedWithCorrectRelation() throws {
        let feed = try XCTUnwrap(OPDS1Fixture.parseFeed("opds1_catalog.xml"))
        let first = feed.entries[0]
        let openAccess = first.acquisitions.first { $0.relation == .openAccess }
        let borrow = first.acquisitions.first { $0.relation == .borrow }
        XCTAssertNotNil(openAccess,
                        "open-access acquisition must be parsed with .openAccess relation")
        XCTAssertNotNil(borrow,
                        "borrow acquisition must be parsed with .borrow relation")
        XCTAssertEqual(openAccess?.type, "application/epub+zip")
    }

    func testEntry_published_isParsedFromPublishedElement() throws {
        // Atom (RFC 4287) uses <published> for the canonical publication
        // date. The parser must populate entry.published from <published>.
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom">
            <id>urn:uuid:published-feed</id>
            <title>Published Feed</title>
            <updated>2024-07-01T00:00:00Z</updated>
            <entry>
                <id>urn:uuid:published-entry</id>
                <title>Has Published</title>
                <updated>2024-07-01T00:00:00Z</updated>
                <published>2019-04-01T00:00:00Z</published>
                <author><name>A</name></author>
            </entry>
        </feed>
        """
        let parsed = TPPOPDSFeed(xml: TPPXML.xml(withData: Data(xml.utf8)))
        let entry = parsed?.entries.first { $0.identifier == "urn:uuid:published-entry" }
        let published = try XCTUnwrap(entry?.published,
                                      "Entry with <published> must populate entry.published")
        let components = Calendar(identifier: .iso8601)
            .dateComponents(in: TimeZone(secondsFromGMT: 0)!, from: published)
        XCTAssertEqual(components.year, 2019)
        XCTAssertEqual(components.month, 4)
        XCTAssertEqual(components.day, 1)
    }

    func testEntry_published_fallsBackToIssuedWhenPublishedAbsent() throws {
        // Legacy/Dublin Core feeds use <issued>. When <published> is absent,
        // the parser must fall back to <issued> rather than leaving the
        // timestamp nil.
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom">
            <id>urn:uuid:issued-feed</id>
            <title>Issued Feed</title>
            <updated>2024-07-01T00:00:00Z</updated>
            <entry>
                <id>urn:uuid:issued-only-entry</id>
                <title>Has Only Issued</title>
                <updated>2024-07-01T00:00:00Z</updated>
                <issued>2020-05-10T00:00:00Z</issued>
                <author><name>A</name></author>
            </entry>
            <entry>
                <id>urn:uuid:no-date-entry</id>
                <title>No Date</title>
                <updated>2024-07-01T00:00:00Z</updated>
                <author><name>B</name></author>
            </entry>
        </feed>
        """
        let parsed = TPPOPDSFeed(xml: TPPXML.xml(withData: Data(xml.utf8)))
        let withIssuedOnly = parsed?.entries.first { $0.identifier == "urn:uuid:issued-only-entry" }
        let noDate = parsed?.entries.first { $0.identifier == "urn:uuid:no-date-entry" }
        let published = try XCTUnwrap(withIssuedOnly?.published,
                                      "Entry with only <issued> must fall back to populate entry.published")
        let components = Calendar(identifier: .iso8601)
            .dateComponents(in: TimeZone(secondsFromGMT: 0)!, from: published)
        XCTAssertEqual(components.year, 2020)
        XCTAssertEqual(components.month, 5)
        XCTAssertEqual(components.day, 10)
        XCTAssertNil(noDate?.published,
                     "Entry with neither <published> nor <issued> must leave entry.published nil")
    }

    func testEntry_published_prefersPublishedOverIssuedWhenBothPresent() throws {
        // When both elements are present, the Atom-canonical <published>
        // must win — <issued> is a legacy Dublin Core extension.
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom">
            <id>urn:uuid:both-feed</id>
            <title>Both Feed</title>
            <updated>2024-07-01T00:00:00Z</updated>
            <entry>
                <id>urn:uuid:both-entry</id>
                <title>Has Both</title>
                <updated>2024-07-01T00:00:00Z</updated>
                <published>2019-04-01T00:00:00Z</published>
                <issued>2020-05-10T00:00:00Z</issued>
                <author><name>A</name></author>
            </entry>
        </feed>
        """
        let parsed = TPPOPDSFeed(xml: TPPXML.xml(withData: Data(xml.utf8)))
        let entry = parsed?.entries.first { $0.identifier == "urn:uuid:both-entry" }
        let published = try XCTUnwrap(entry?.published,
                                      "Entry with both elements must populate entry.published")
        let components = Calendar(identifier: .iso8601)
            .dateComponents(in: TimeZone(secondsFromGMT: 0)!, from: published)
        XCTAssertEqual(components.year, 2019,
                       "Canonical <published> must take precedence over legacy <issued>")
        XCTAssertEqual(components.month, 4)
        XCTAssertEqual(components.day, 1)
    }

    func testEntry_publisher_extracted() throws {
        let feed = try XCTUnwrap(OPDS1Fixture.parseFeed("opds1_catalog.xml"))
        XCTAssertEqual(feed.entries[0].publisher, "Open Press")
    }

    func testEntry_category_parsedWithTerm() throws {
        let feed = try XCTUnwrap(OPDS1Fixture.parseFeed("opds1_catalog.xml"))
        let first = feed.entries[0]
        XCTAssertEqual(first.categories.count, 1)
        XCTAssertEqual(first.categories.first?.term, "fiction")
        XCTAssertEqual(first.categories.first?.label, "Fiction")
    }

    func testEntry_imageThumbnail_keptAsLink() throws {
        let feed = try XCTUnwrap(OPDS1Fixture.parseFeed("opds1_catalog.xml"))
        let thumb = feed.entries[0].links.first { $0.rel == TPPOPDSRelationConstants.imageThumbnail }
        XCTAssertNotNil(thumb,
                        "Image thumbnail must be retained on entry.links")
    }

    func testEntry_summary_decoded() throws {
        let feed = try XCTUnwrap(OPDS1Fixture.parseFeed("opds1_catalog.xml"))
        XCTAssertEqual(feed.entries[0].summary, "Short tale of bright stars.")
    }

    // MARK: - Faceted feed (opds1_with_facets.xml)

    func testFacetedFeed_facetLinks_groupedCorrectly() throws {
        let feed = try XCTUnwrap(OPDS1Fixture.parseFeed("opds1_with_facets.xml"))
        let facetLinks = feed.links.filter { $0.rel == TPPOPDSRelationConstants.facet }
        XCTAssertEqual(facetLinks.count, 5,
                       "All five facet links across both groups must be preserved on the feed")
        // Bucket facets by their facetGroup attribute (the parser preserves
        // them as-is; downstream code groups by attribute lookup).
        let buckets: [String: [TPPOPDSLink]] = facetLinks.reduce(into: [:]) { acc, link in
            let attrs = link.attributes as? [String: String] ?? [:]
            // The XML uses the qualified name "opds:facetGroup" but TPPXML strips
            // the prefix when shouldProcessNamespaces is true, so we look the
            // attribute up by local name.
            let groupName = attrs["facetGroup"] ?? attrs["opds:facetGroup"] ?? ""
            acc[groupName, default: []].append(link)
        }
        XCTAssertEqual(buckets["Entrypoint"]?.count, 3,
                       "Entrypoint facet group must contain All / eBooks / Audiobooks")
        XCTAssertEqual(buckets["Sort by"]?.count, 2,
                       "Sort facet group must contain Title / Author")
    }

    func testFacetedFeed_activeFacet_attributeRecognized() throws {
        let feed = try XCTUnwrap(OPDS1Fixture.parseFeed("opds1_with_facets.xml"))
        // Defensive: the OPDS namespace-prefixed attribute may surface as
        // either the local name or the qualified name depending on the XML
        // parser settings. Look up both keys and find the facet with the
        // active flag set to "true".
        let active = feed.links
            .filter { $0.rel == TPPOPDSRelationConstants.facet }
            .first { link in
                let attrs = link.attributes as? [String: String] ?? [:]
                let raw = attrs["activeFacet"] ?? attrs["opds:activeFacet"]
                return raw == "true"
            }
        if active == nil {
            // Dump attribute keys so a regression has actionable diagnostics.
            let dump = feed.links
                .filter { $0.rel == TPPOPDSRelationConstants.facet }
                .map { ($0.attributes as? [String: String])?.keys.sorted().joined(separator: ",") ?? "<no-attrs>" }
            XCTFail("No facet link exposed activeFacet=true; per-link attribute keys were: \(dump)")
            return
        }
        let attrs = active?.attributes as? [String: String] ?? [:]
        XCTAssertEqual(attrs["title"], "All")
    }

    func testFacetedFeed_otherFacetsNotMarkedActive() throws {
        let feed = try XCTUnwrap(OPDS1Fixture.parseFeed("opds1_with_facets.xml"))
        let nonActive = feed.links
            .filter { $0.rel == TPPOPDSRelationConstants.facet }
            .filter { link in
                let attrs = link.attributes as? [String: String] ?? [:]
                let raw = attrs["activeFacet"] ?? attrs["opds:activeFacet"]
                return raw != "true"
            }
        XCTAssertEqual(nonActive.count, 4,
                       "Only the All-entrypoint facet should be marked active")
    }

    // MARK: - Malformed entries (opds1_malformed_entry.xml)

    func testMalformedEntries_skippedNotCrashed() throws {
        let feed = try XCTUnwrap(OPDS1Fixture.parseFeed("opds1_malformed_entry.xml"),
                                 "Feed parse must succeed even when some entries are malformed")
        // Three malformed entries (missing id, missing title, missing updated)
        // must be skipped. Two valid sibling entries must survive.
        XCTAssertEqual(feed.entries.count, 2,
                       "Parser must skip malformed entries but keep valid siblings")
        XCTAssertEqual(feed.entries.map { $0.identifier },
                       ["urn:uuid:valid-001", "urn:uuid:valid-002"])
        XCTAssertEqual(feed.entries.map { $0.title },
                       ["Valid First", "Valid Last"])
    }

    func testMalformedXML_returnsNilNotCrash() {
        // Truncated XML — the parser must return nil rather than crash.
        let bad = Data("<?xml version=\"1.0\"?><feed><id>x</id>".utf8)
        let xml = TPPXML.xml(withData: bad)
        XCTAssertNil(xml, "TPPXML must return nil for malformed XML")
        // Even if TPPXML somehow returned a non-nil partial tree, TPPOPDSFeed
        // must return nil when required <id>/<title>/<updated> are missing.
        let feed = xml.flatMap { TPPOPDSFeed(xml: $0) }
        XCTAssertNil(feed, "TPPOPDSFeed must reject malformed XML")
    }

    func testEmptyData_returnsNilNotCrash() {
        XCTAssertNil(TPPXML.xml(withData: Data()))
        XCTAssertNil(TPPOPDSFeed(xml: nil))
    }

    func testNonOPDSXML_returnsNil() {
        let other = Data("""
        <?xml version="1.0"?>
        <root><not-a-feed/></root>
        """.utf8)
        let xml = TPPXML.xml(withData: other)
        XCTAssertNotNil(xml, "Well-formed XML must parse into a TPPXML tree")
        XCTAssertNil(TPPOPDSFeed(xml: xml),
                     "Non-OPDS XML (missing required <id>/<title>/<updated>) must yield a nil feed")
    }

    // MARK: - Edge cases via inline XML (kept tiny and deterministic)

    func testEntry_veryLongTitle_preservedExactly() {
        // > 1KB title to defend against truncation/length mutations.
        let longTitle = String(repeating: "Long Title Segment. ", count: 60)
        XCTAssertGreaterThan(longTitle.count, 1024)
        let xmlString = """
        <?xml version="1.0" encoding="utf-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom">
            <id>urn:uuid:long-title-feed</id>
            <title>Long Title Feed</title>
            <updated>2024-07-01T00:00:00Z</updated>
            <entry>
                <id>urn:uuid:long-title-entry</id>
                <title>\(longTitle)</title>
                <updated>2024-07-01T00:00:00Z</updated>
                <author><name>Author</name></author>
            </entry>
        </feed>
        """
        let xml = TPPXML.xml(withData: Data(xmlString.utf8))
        let feed = TPPOPDSFeed(xml: xml)
        XCTAssertEqual(feed?.entries.first?.title, longTitle,
                       "Long titles must be preserved verbatim (no truncation)")
    }

    func testEntry_unicodeTitle_preservedExactly() {
        // Emoji + RTL + non-Latin characters.
        let unicodeTitle = "Tale of the dragon \u{1F409} — مرحبا — 你好"
        let xmlString = """
        <?xml version="1.0" encoding="utf-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom">
            <id>urn:uuid:unicode-feed</id>
            <title>Unicode Feed</title>
            <updated>2024-07-01T00:00:00Z</updated>
            <entry>
                <id>urn:uuid:unicode-entry</id>
                <title>\(unicodeTitle)</title>
                <updated>2024-07-01T00:00:00Z</updated>
                <author><name>Yokoyama 横山</name></author>
            </entry>
        </feed>
        """
        let xml = TPPXML.xml(withData: Data(xmlString.utf8))
        let feed = TPPOPDSFeed(xml: xml)
        XCTAssertEqual(feed?.entries.first?.title, unicodeTitle,
                       "Unicode (emoji, RTL, CJK) must be preserved verbatim")
        XCTAssertEqual(feed?.entries.first?.authorStrings, ["Yokoyama 横山"])
    }

    func testEmptyFeed_yieldsEmptyEntriesArrayNotNil() {
        let xmlString = """
        <?xml version="1.0" encoding="utf-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom">
            <id>urn:uuid:empty</id>
            <title>Empty</title>
            <updated>2024-07-01T00:00:00Z</updated>
        </feed>
        """
        let xml = TPPXML.xml(withData: Data(xmlString.utf8))
        let feed = TPPOPDSFeed(xml: xml)
        XCTAssertNotNil(feed, "Empty feed with required elements must parse")
        XCTAssertEqual(feed?.entries.count, 0,
                       "Empty feed must produce zero entries, not nil")
        XCTAssertEqual(feed?.identifier, "urn:uuid:empty")
    }

    // MARK: - TPPOPDSLink unit tests

    func testLink_missingHref_returnsNil() {
        let xmlString = """
        <link rel="self" type="application/atom+xml"/>
        """
        let xml = TPPXML.xml(withData: Data(xmlString.utf8))
        let link = TPPOPDSLink(xml: xml)
        XCTAssertNil(link, "TPPOPDSLink must reject link XML without an href")
    }

    func testLink_invalidHrefScheme_capturedAsIs() {
        // URL(string:) is fairly permissive — this defends against a mutant
        // that drops the URL guard entirely.
        let xmlString = """
        <link href="" rel="self"/>
        """
        let xml = TPPXML.xml(withData: Data(xmlString.utf8))
        let link = TPPOPDSLink(xml: xml)
        XCTAssertNil(link, "TPPOPDSLink must reject empty-string href")
    }

    func testLink_validHref_returnsLinkWithAttributes() {
        let xmlString = """
        <link href="https://example.org/feed" rel="next" type="application/atom+xml" title="More"/>
        """
        let xml = TPPXML.xml(withData: Data(xmlString.utf8))
        let link = TPPOPDSLink(xml: xml)
        XCTAssertNotNil(link)
        XCTAssertEqual(link?.href.absoluteString, "https://example.org/feed")
        XCTAssertEqual(link?.rel, "next")
        XCTAssertEqual(link?.type, "application/atom+xml")
        XCTAssertEqual(link?.title, "More")
    }

    // MARK: - Feed type detection

    func testFeedType_emptyFeed_returnsAcquisitionUngrouped() throws {
        // Pin existing behavior: an empty feed reports .acquisitionUngrouped.
        let xmlString = """
        <?xml version="1.0" encoding="utf-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom">
            <id>urn:uuid:empty-type</id>
            <title>Empty</title>
            <updated>2024-07-01T00:00:00Z</updated>
        </feed>
        """
        let xml = TPPXML.xml(withData: Data(xmlString.utf8))
        let feed = try XCTUnwrap(TPPOPDSFeed(xml: xml))
        XCTAssertEqual(feed.type, .acquisitionUngrouped)
    }

    func testFeedType_acquisitionFeed_detectedUngrouped() throws {
        let feed = try XCTUnwrap(OPDS1Fixture.parseFeed("opds1_catalog.xml"))
        // Entries have acquisition links but no rel="collection" → ungrouped.
        XCTAssertEqual(feed.type, .acquisitionUngrouped,
                       "Acquisition entries without rel='collection' must yield .acquisitionUngrouped")
    }
}
