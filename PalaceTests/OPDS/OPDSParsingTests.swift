//
//  OPDSParsingTests.swift
//  PalaceTests
//
//  Comprehensive unit tests for OPDS parsing in the Palace iOS app.
//  Tests cover TPPOPDSFeed, TPPOPDSEntry, and TPPOPDSLink parsing.
//

import XCTest
@testable import Palace

final class OPDSParsingTests: XCTestCase {

    // MARK: - Test Fixtures

    /// Minimal valid OPDS feed with required elements only
    private let minimalFeedXML = """
        <?xml version="1.0" encoding="utf-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom">
            <id>http://example.org/feed</id>
            <title>Test Feed</title>
            <updated>2024-01-15T12:00:00Z</updated>
        </feed>
        """

    /// Complete OPDS feed with multiple entries
    private let completeFeedXML = """
        <?xml version="1.0" encoding="utf-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom">
            <id>http://example.org/catalog</id>
            <title>Library Catalog</title>
            <updated>2024-01-15T12:00:00Z</updated>
            <link href="http://example.org/catalog" rel="self" type="application/atom+xml"/>
            <link href="http://example.org/search" rel="search" type="application/opensearchdescription+xml"/>
            <link href="http://example.org/next" rel="next" type="application/atom+xml"/>
            <entry>
                <id>urn:isbn:9780123456789</id>
                <title>The Great Book</title>
                <updated>2024-01-10T10:00:00Z</updated>
                <author>
                    <name>John Author</name>
                </author>
                <summary type="html">A wonderful book about testing.</summary>
                <link href="http://example.org/books/1" rel="alternate" type="application/atom+xml"/>
                <link href="http://example.org/books/1/cover.jpg" rel="http://opds-spec.org/image" type="image/jpeg"/>
                <link href="http://example.org/books/1/thumb.jpg" rel="http://opds-spec.org/image/thumbnail" type="image/jpeg"/>
                <link href="http://example.org/books/1/download" rel="http://opds-spec.org/acquisition/open-access" type="application/epub+zip"/>
                <category term="Fiction" scheme="http://schema.org/genre" label="Fiction"/>
            </entry>
            <entry>
                <id>urn:isbn:9780987654321</id>
                <title>Another Book</title>
                <updated>2024-01-12T14:30:00Z</updated>
                <author>
                    <name>Jane Writer</name>
                </author>
                <link href="http://example.org/books/2" rel="alternate" type="application/atom+xml"/>
                <link href="http://example.org/books/2/borrow" rel="http://opds-spec.org/acquisition/borrow" type="application/atom+xml;type=entry;profile=opds-catalog"/>
            </entry>
        </feed>
        """

    /// Single entry XML (standalone, not in a feed)
    private let singleEntryXML = """
        <entry xmlns="http://www.w3.org/2005/Atom">
            <id>urn:uuid:test-entry-001</id>
            <title>Standalone Entry</title>
            <updated>2024-01-20T08:00:00Z</updated>
            <author>
                <name>Test Author</name>
            </author>
            <link href="http://example.org/entry" rel="alternate" type="application/atom+xml"/>
            <link href="http://example.org/acquire" rel="http://opds-spec.org/acquisition" type="application/epub+zip"/>
        </entry>
        """

    /// Entry with multiple authors and contributors
    private let multiAuthorEntryXML = """
        <entry xmlns="http://www.w3.org/2005/Atom">
            <id>urn:uuid:multi-author-001</id>
            <title>Collaborative Work</title>
            <updated>2024-01-18T16:00:00Z</updated>
            <author>
                <name>First Author</name>
                <link href="http://example.org/authors/first" rel="contributor" type="application/atom+xml"/>
            </author>
            <author>
                <name>Second Author</name>
                <link href="http://example.org/authors/second" rel="contributor" type="application/atom+xml"/>
            </author>
            <contributor opf:role="narrator">
                <name>Voice Actor</name>
            </contributor>
            <contributor opf:role="editor">
                <name>Chief Editor</name>
            </contributor>
            <link href="http://example.org/entry" rel="alternate" type="application/atom+xml"/>
            <link href="http://example.org/acquire" rel="http://opds-spec.org/acquisition/open-access" type="application/epub+zip"/>
        </entry>
        """

    /// Entry with all link relation types
    private let linkRelationsEntryXML = """
        <entry xmlns="http://www.w3.org/2005/Atom">
            <id>urn:uuid:links-test-001</id>
            <title>Link Relations Test</title>
            <updated>2024-01-19T12:00:00Z</updated>
            <link href="http://example.org/cover.jpg" rel="http://opds-spec.org/image" type="image/jpeg"/>
            <link href="http://example.org/thumb.jpg" rel="http://opds-spec.org/image/thumbnail" type="image/jpeg"/>
            <link href="http://example.org/alternate" rel="alternate" type="application/atom+xml"/>
            <link href="http://example.org/related" rel="related" type="application/atom+xml"/>
            <link href="http://example.org/annotations" rel="http://www.w3.org/ns/oa#annotationService" type="application/ld+json"/>
            <link href="http://example.org/borrow" rel="http://opds-spec.org/acquisition/borrow" type="application/atom+xml;type=entry;profile=opds-catalog"/>
            <link href="http://example.org/open-access" rel="http://opds-spec.org/acquisition/open-access" type="application/epub+zip"/>
            <link href="http://example.org/sample" rel="http://opds-spec.org/acquisition/sample" type="application/epub+zip"/>
            <link href="http://example.org/preview" rel="preview" type="application/epub+zip"/>
            <link href="http://example.org/group" rel="collection" title="Popular Books" href="http://example.org/popular"/>
            <link href="http://example.org/timetracking" rel="http://palaceproject.io/terms/timeTracking" type="application/json"/>
        </entry>
        """

    /// Feed with licensor and patron information
    private let feedWithLicensorXML = """
        <?xml version="1.0" encoding="utf-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom"
              xmlns:drm="http://librarysimplified.org/terms/drm"
              xmlns:simplified="http://librarysimplified.org/terms/">
            <id>http://example.org/loans</id>
            <title>My Loans</title>
            <updated>2024-01-15T12:00:00Z</updated>
            <simplified:patron simplified:authorizationIdentifier="12345678"/>
            <licensor drm:vendor="Adobe">
                <clientToken>test-client-token-value</clientToken>
            </licensor>
        </feed>
        """

    /// Grouped acquisition feed
    private let groupedFeedXML = """
        <?xml version="1.0" encoding="utf-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom">
            <id>http://example.org/grouped</id>
            <title>Grouped Feed</title>
            <updated>2024-01-15T12:00:00Z</updated>
            <entry>
                <id>urn:uuid:grouped-001</id>
                <title>Grouped Book 1</title>
                <updated>2024-01-10T10:00:00Z</updated>
                <link href="http://example.org/group1" rel="collection" title="Featured Books"/>
                <link href="http://example.org/acquire" rel="http://opds-spec.org/acquisition/open-access" type="application/epub+zip"/>
            </entry>
            <entry>
                <id>urn:uuid:grouped-002</id>
                <title>Grouped Book 2</title>
                <updated>2024-01-11T10:00:00Z</updated>
                <link href="http://example.org/group1" rel="collection" title="Featured Books"/>
                <link href="http://example.org/acquire2" rel="http://opds-spec.org/acquisition/open-access" type="application/epub+zip"/>
            </entry>
        </feed>
        """

    /// Navigation feed (entries without acquisition links)
    private let navigationFeedXML = """
        <?xml version="1.0" encoding="utf-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom">
            <id>http://example.org/navigation</id>
            <title>Navigation Feed</title>
            <updated>2024-01-15T12:00:00Z</updated>
            <entry>
                <id>urn:uuid:nav-001</id>
                <title>Fiction</title>
                <updated>2024-01-10T10:00:00Z</updated>
                <link href="http://example.org/fiction" rel="subsection" type="application/atom+xml"/>
            </entry>
            <entry>
                <id>urn:uuid:nav-002</id>
                <title>Non-Fiction</title>
                <updated>2024-01-10T10:00:00Z</updated>
                <link href="http://example.org/nonfiction" rel="subsection" type="application/atom+xml"/>
            </entry>
        </feed>
        """

    /// Entry with categories
    private let entryWithCategoriesXML = """
        <entry xmlns="http://www.w3.org/2005/Atom">
            <id>urn:uuid:categories-001</id>
            <title>Categorized Book</title>
            <updated>2024-01-20T08:00:00Z</updated>
            <category term="Adult" scheme="http://schema.org/audience" label="Adult"/>
            <category term="Fiction" scheme="http://librarysimplified.org/terms/fiction/" label="Fiction"/>
            <category term="Mystery" scheme="http://librarysimplified.org/terms/genres/Simplified/" label="Mystery"/>
            <category term="Thriller" scheme="http://librarysimplified.org/terms/genres/Simplified/" label="Thriller"/>
            <link href="http://example.org/entry" rel="alternate" type="application/atom+xml"/>
            <link href="http://example.org/acquire" rel="http://opds-spec.org/acquisition/open-access" type="application/epub+zip"/>
        </entry>
        """

    /// Entry with series information
    private let entryWithSeriesXML = """
        <entry xmlns="http://www.w3.org/2005/Atom" xmlns:schema="http://schema.org/">
            <id>urn:uuid:series-001</id>
            <title>Book One of the Series</title>
            <updated>2024-01-20T08:00:00Z</updated>
            <schema:Series>
                <link href="http://example.org/series/test-series" rel="series" title="The Test Series" schema:position="1"/>
            </schema:Series>
            <link href="http://example.org/entry" rel="alternate" type="application/atom+xml"/>
            <link href="http://example.org/acquire" rel="http://opds-spec.org/acquisition/open-access" type="application/epub+zip"/>
        </entry>
        """

    /// Entry with publisher and distribution info
    private let entryWithPublisherXML = """
        <entry xmlns="http://www.w3.org/2005/Atom"
               xmlns:dcterms="http://purl.org/dc/terms/"
               xmlns:bibframe="http://bibframe.org/vocab/">
            <id>urn:uuid:publisher-001</id>
            <title>Published Book</title>
            <updated>2024-01-20T08:00:00Z</updated>
            <dcterms:publisher>Big Publishing House</dcterms:publisher>
            <issued>2024-01-01</issued>
            <bibframe:distribution bibframe:ProviderName="Palace Marketplace"/>
            <link href="http://example.org/entry" rel="alternate" type="application/atom+xml"/>
            <link href="http://example.org/acquire" rel="http://opds-spec.org/acquisition/open-access" type="application/epub+zip"/>
        </entry>
        """

    /// Entry with duration (audiobook)
    private let audiobookEntryXML = """
        <entry xmlns="http://www.w3.org/2005/Atom">
            <id>urn:uuid:audiobook-001</id>
            <title>Audiobook Title</title>
            <updated>2024-01-20T08:00:00Z</updated>
            <duration>PT10H30M</duration>
            <link href="http://example.org/entry" rel="alternate" type="application/atom+xml"/>
            <link href="http://example.org/acquire" rel="http://opds-spec.org/acquisition/open-access" type="application/audiobook+json"/>
        </entry>
        """

    // MARK: - TPPOPDSFeed Initialization Tests

    func testFeedInitializationFromMinimalXML() {
        guard let data = minimalFeedXML.data(using: .utf8),
              let xml = TPPXML(data: data) else {
            XCTFail("Failed to create XML from minimal feed string")
            return
        }

        let feed = TPPOPDSFeed(xml: xml)

        XCTAssertNotNil(feed, "Feed should be created from minimal valid XML")
        XCTAssertEqual(feed?.identifier, "http://example.org/feed")
        XCTAssertEqual(feed?.title, "Test Feed")
        XCTAssertNotNil(feed?.updated, "Updated date should be parsed")
        XCTAssertEqual(feed?.entries.count, 0, "Minimal feed should have no entries")
        XCTAssertEqual(feed?.links.count, 0, "Minimal feed should have no links")
    }

    func testFeedInitializationFromCompleteFeed() {
        guard let data = completeFeedXML.data(using: .utf8),
              let xml = TPPXML(data: data) else {
            XCTFail("Failed to create XML from complete feed string")
            return
        }

        let feed = TPPOPDSFeed(xml: xml)

        XCTAssertNotNil(feed, "Feed should be created from complete XML")
        XCTAssertEqual(feed?.identifier, "http://example.org/catalog")
        XCTAssertEqual(feed?.title, "Library Catalog")
        XCTAssertNotNil(feed?.updated)
        XCTAssertEqual(feed?.entries.count, 2, "Feed should have 2 entries")
        XCTAssertEqual(feed?.links.count, 3, "Feed should have 3 links")
    }

    func testFeedInitializationFromSingleEntry() {
        guard let data = singleEntryXML.data(using: .utf8),
              let xml = TPPXML(data: data) else {
            XCTFail("Failed to create XML from single entry string")
            return
        }

        let feed = TPPOPDSFeed(xml: xml)

        XCTAssertNotNil(feed, "Feed should be created from single entry XML")
        XCTAssertEqual(feed?.entries.count, 1, "Feed should contain exactly one entry")

        if let entry = feed?.entries.first as? TPPOPDSEntry {
            XCTAssertEqual(entry.identifier, "urn:uuid:test-entry-001")
            XCTAssertEqual(entry.title, "Standalone Entry")
        } else {
            XCTFail("Entry should be present and correctly typed")
        }
    }

    func testFeedWithLicensorAndPatron() {
        guard let data = feedWithLicensorXML.data(using: .utf8),
              let xml = TPPXML(data: data) else {
            XCTFail("Failed to create XML from feed with licensor")
            return
        }

        let feed = TPPOPDSFeed(xml: xml)

        XCTAssertNotNil(feed, "Feed should be created")
        XCTAssertEqual(feed?.authorizationIdentifier, "12345678", "Authorization identifier should be parsed")
        XCTAssertNotNil(feed?.licensor, "Licensor should be present")
        XCTAssertEqual(feed?.licensor?["vendor"] as? String, "Adobe")
        XCTAssertEqual(feed?.licensor?["clientToken"] as? String, "test-client-token-value")
    }

    // MARK: - TPPOPDSFeed Type Tests

    func testFeedTypeAcquisitionUngroupedWithEmptyFeed() {
        guard let data = minimalFeedXML.data(using: .utf8),
              let xml = TPPXML(data: data),
              let feed = TPPOPDSFeed(xml: xml) else {
            XCTFail("Failed to create feed")
            return
        }

        XCTAssertEqual(feed.type, .acquisitionUngrouped, "Empty feed should be ungrouped acquisition type")
    }

    func testFeedTypeAcquisitionGrouped() {
        guard let data = groupedFeedXML.data(using: .utf8),
              let xml = TPPXML(data: data),
              let feed = TPPOPDSFeed(xml: xml) else {
            XCTFail("Failed to create grouped feed")
            return
        }

        XCTAssertEqual(feed.type, .acquisitionGrouped, "Feed with grouped entries should be grouped acquisition type")
    }

    func testFeedTypeNavigation() {
        guard let data = navigationFeedXML.data(using: .utf8),
              let xml = TPPXML(data: data),
              let feed = TPPOPDSFeed(xml: xml) else {
            XCTFail("Failed to create navigation feed")
            return
        }

        XCTAssertEqual(feed.type, .navigation, "Feed without acquisition links should be navigation type")
    }

    func testFeedTypeAcquisitionUngrouped() {
        guard let data = completeFeedXML.data(using: .utf8),
              let xml = TPPXML(data: data),
              let feed = TPPOPDSFeed(xml: xml) else {
            XCTFail("Failed to create feed")
            return
        }

        XCTAssertEqual(feed.type, .acquisitionUngrouped, "Feed with ungrouped acquisition entries should be ungrouped acquisition type")
    }

    // MARK: - TPPOPDSEntry Extraction Tests

    func testEntryExtractionFromFeed() {
        guard let data = completeFeedXML.data(using: .utf8),
              let xml = TPPXML(data: data),
              let feed = TPPOPDSFeed(xml: xml) else {
            XCTFail("Failed to create feed")
            return
        }

        XCTAssertEqual(feed.entries.count, 2)

        guard let firstEntry = feed.entries.first as? TPPOPDSEntry else {
            XCTFail("First entry should exist")
            return
        }

        XCTAssertEqual(firstEntry.identifier, "urn:isbn:9780123456789")
        XCTAssertEqual(firstEntry.title, "The Great Book")
        XCTAssertNotNil(firstEntry.updated)
        XCTAssertEqual(firstEntry.authorStrings.count, 1)
        XCTAssertEqual(firstEntry.authorStrings.first as? String, "John Author")
        XCTAssertNotNil(firstEntry.summary)
        XCTAssertTrue(firstEntry.summary?.contains("wonderful book") ?? false)
    }

    func testEntryWithMultipleAuthors() {
        guard let data = multiAuthorEntryXML.data(using: .utf8),
              let xml = TPPXML(data: data),
              let entry = TPPOPDSEntry(xml: xml) else {
            XCTFail("Failed to create entry")
            return
        }

        XCTAssertEqual(entry.authorStrings.count, 2, "Entry should have 2 authors")
        XCTAssertTrue(entry.authorStrings.contains { ($0 as? String) == "First Author" })
        XCTAssertTrue(entry.authorStrings.contains { ($0 as? String) == "Second Author" })
        XCTAssertEqual(entry.authorLinks.count, 2, "Entry should have 2 author links")
    }

    func testEntryWithContributors() {
        guard let data = multiAuthorEntryXML.data(using: .utf8),
              let xml = TPPXML(data: data),
              let entry = TPPOPDSEntry(xml: xml) else {
            XCTFail("Failed to create entry")
            return
        }

        XCTAssertNotNil(entry.contributors, "Contributors should be present")
        XCTAssertEqual(entry.contributors?["narrator"]?.count, 1)
        XCTAssertEqual(entry.contributors?["narrator"]?.first, "Voice Actor")
        XCTAssertEqual(entry.contributors?["editor"]?.count, 1)
        XCTAssertEqual(entry.contributors?["editor"]?.first, "Chief Editor")
    }

    func testEntryWithCategories() {
        guard let data = entryWithCategoriesXML.data(using: .utf8),
              let xml = TPPXML(data: data),
              let entry = TPPOPDSEntry(xml: xml) else {
            XCTFail("Failed to create entry")
            return
        }

        XCTAssertEqual(entry.categories.count, 4, "Entry should have 4 categories")

        let categoryTerms = entry.categories.map { $0.term }
        XCTAssertTrue(categoryTerms.contains("Adult"))
        XCTAssertTrue(categoryTerms.contains("Fiction"))
        XCTAssertTrue(categoryTerms.contains("Mystery"))
        XCTAssertTrue(categoryTerms.contains("Thriller"))
    }

    func testEntryWithPublisherAndDistribution() {
        guard let data = entryWithPublisherXML.data(using: .utf8),
              let xml = TPPXML(data: data),
              let entry = TPPOPDSEntry(xml: xml) else {
            XCTFail("Failed to create entry")
            return
        }

        XCTAssertEqual(entry.publisher, "Big Publishing House")
        XCTAssertEqual(entry.providerName, "Palace Marketplace")
        XCTAssertNotNil(entry.published)
    }

    func testEntryWithDuration() {
        guard let data = audiobookEntryXML.data(using: .utf8),
              let xml = TPPXML(data: data),
              let entry = TPPOPDSEntry(xml: xml) else {
            XCTFail("Failed to create entry")
            return
        }

        XCTAssertEqual(entry.duration, "PT10H30M", "Duration should be parsed for audiobooks")
    }

    // MARK: - TPPOPDSLink Relation Handling Tests

    func testLinkRelationAlternate() {
        guard let data = linkRelationsEntryXML.data(using: .utf8),
              let xml = TPPXML(data: data),
              let entry = TPPOPDSEntry(xml: xml) else {
            XCTFail("Failed to create entry")
            return
        }

        XCTAssertNotNil(entry.alternate, "Alternate link should be parsed")
        XCTAssertEqual(entry.alternate?.href.absoluteString, "http://example.org/alternate")
        XCTAssertEqual(entry.alternate?.rel, "alternate")
    }

    func testLinkRelationRelatedWorks() {
        guard let data = linkRelationsEntryXML.data(using: .utf8),
              let xml = TPPXML(data: data),
              let entry = TPPOPDSEntry(xml: xml) else {
            XCTFail("Failed to create entry")
            return
        }

        XCTAssertNotNil(entry.relatedWorks, "Related works link should be parsed")
        XCTAssertEqual(entry.relatedWorks?.href.absoluteString, "http://example.org/related")
    }

    func testLinkRelationAnnotations() {
        guard let data = linkRelationsEntryXML.data(using: .utf8),
              let xml = TPPXML(data: data),
              let entry = TPPOPDSEntry(xml: xml) else {
            XCTFail("Failed to create entry")
            return
        }

        XCTAssertNotNil(entry.annotations, "Annotations link should be parsed")
        XCTAssertEqual(entry.annotations?.rel, "http://www.w3.org/ns/oa#annotationService")
    }

    func testLinkRelationTimeTracking() {
        guard let data = linkRelationsEntryXML.data(using: .utf8),
              let xml = TPPXML(data: data),
              let entry = TPPOPDSEntry(xml: xml) else {
            XCTFail("Failed to create entry")
            return
        }

        XCTAssertNotNil(entry.timeTrackingLink, "Time tracking link should be parsed")
        XCTAssertEqual(entry.timeTrackingLink?.rel, "http://palaceproject.io/terms/timeTracking")
    }

    func testAcquisitionLinks() {
        guard let data = linkRelationsEntryXML.data(using: .utf8),
              let xml = TPPXML(data: data),
              let entry = TPPOPDSEntry(xml: xml) else {
            XCTFail("Failed to create entry")
            return
        }

        XCTAssertGreaterThan(entry.acquisitions.count, 0, "Entry should have acquisition links")

        let acquisitionRelations = entry.acquisitions.map { $0.relation }
        XCTAssertTrue(acquisitionRelations.contains(.borrow), "Should contain borrow acquisition")
        XCTAssertTrue(acquisitionRelations.contains(.openAccess), "Should contain open-access acquisition")
    }

    func testImageLinks() {
        guard let data = completeFeedXML.data(using: .utf8),
              let xml = TPPXML(data: data),
              let feed = TPPOPDSFeed(xml: xml),
              let entry = feed.entries.first as? TPPOPDSEntry else {
            XCTFail("Failed to create feed or entry")
            return
        }

        let imageLinks = entry.links.compactMap { $0 as? TPPOPDSLink }.filter {
            $0.rel == "http://opds-spec.org/image"
        }
        let thumbnailLinks = entry.links.compactMap { $0 as? TPPOPDSLink }.filter {
            $0.rel == "http://opds-spec.org/image/thumbnail"
        }

        XCTAssertEqual(imageLinks.count, 1, "Should have 1 image link")
        XCTAssertEqual(thumbnailLinks.count, 1, "Should have 1 thumbnail link")
    }

    func testSeriesLink() {
        guard let data = entryWithSeriesXML.data(using: .utf8),
              let xml = TPPXML(data: data),
              let entry = TPPOPDSEntry(xml: xml) else {
            XCTFail("Failed to create entry")
            return
        }

        XCTAssertNotNil(entry.seriesLink, "Series link should be parsed")
    }

    func testGroupAttributes() {
        guard let data = groupedFeedXML.data(using: .utf8),
              let xml = TPPXML(data: data),
              let feed = TPPOPDSFeed(xml: xml),
              let entry = feed.entries.first as? TPPOPDSEntry else {
            XCTFail("Failed to create feed or entry")
            return
        }

        XCTAssertNotNil(entry.groupAttributes, "Group attributes should be present")
        XCTAssertEqual(entry.groupAttributes?.title, "Featured Books")
    }

    // MARK: - TPPOPDSLink Tests

    func testLinkInitialization() {
        let linkXML = """
            <link xmlns="http://www.w3.org/2005/Atom"
                  href="http://example.org/resource"
                  rel="alternate"
                  type="application/atom+xml"
                  hreflang="en"
                  title="Resource Title"/>
            """

        guard let data = linkXML.data(using: .utf8),
              let xml = TPPXML(data: data),
              let link = TPPOPDSLink(xml: xml) else {
            XCTFail("Failed to create link")
            return
        }

        XCTAssertEqual(link.href.absoluteString, "http://example.org/resource")
        XCTAssertEqual(link.rel, "alternate")
        XCTAssertEqual(link.type, "application/atom+xml")
        XCTAssertEqual(link.hreflang, "en")
        XCTAssertEqual(link.title, "Resource Title")
        XCTAssertNotNil(link.attributes)
    }

    func testLinkWithOptionalAttributesNil() {
        let linkXML = """
            <link xmlns="http://www.w3.org/2005/Atom" href="http://example.org/resource"/>
            """

        guard let data = linkXML.data(using: .utf8),
              let xml = TPPXML(data: data),
              let link = TPPOPDSLink(xml: xml) else {
            XCTFail("Failed to create link")
            return
        }

        XCTAssertEqual(link.href.absoluteString, "http://example.org/resource")
        XCTAssertNil(link.rel, "rel should be nil when not provided")
        XCTAssertNil(link.type, "type should be nil when not provided")
        XCTAssertNil(link.hreflang, "hreflang should be nil when not provided")
        XCTAssertNil(link.title, "title should be nil when not provided")
    }

    // MARK: - Edge Cases Tests

    func testFeedWithMissingId() {
        let feedWithoutId = """
            <?xml version="1.0" encoding="utf-8"?>
            <feed xmlns="http://www.w3.org/2005/Atom">
                <title>Test Feed</title>
                <updated>2024-01-15T12:00:00Z</updated>
            </feed>
            """

        guard let data = feedWithoutId.data(using: .utf8),
              let xml = TPPXML(data: data) else {
            XCTFail("Failed to create XML")
            return
        }

        let feed = TPPOPDSFeed(xml: xml)
        XCTAssertNil(feed, "Feed without id should fail to initialize")
    }

    func testFeedWithMissingTitle() {
        let feedWithoutTitle = """
            <?xml version="1.0" encoding="utf-8"?>
            <feed xmlns="http://www.w3.org/2005/Atom">
                <id>http://example.org/feed</id>
                <updated>2024-01-15T12:00:00Z</updated>
            </feed>
            """

        guard let data = feedWithoutTitle.data(using: .utf8),
              let xml = TPPXML(data: data) else {
            XCTFail("Failed to create XML")
            return
        }

        let feed = TPPOPDSFeed(xml: xml)
        XCTAssertNil(feed, "Feed without title should fail to initialize")
    }

    func testFeedWithMissingUpdated() {
        let feedWithoutUpdated = """
            <?xml version="1.0" encoding="utf-8"?>
            <feed xmlns="http://www.w3.org/2005/Atom">
                <id>http://example.org/feed</id>
                <title>Test Feed</title>
            </feed>
            """

        guard let data = feedWithoutUpdated.data(using: .utf8),
              let xml = TPPXML(data: data) else {
            XCTFail("Failed to create XML")
            return
        }

        let feed = TPPOPDSFeed(xml: xml)
        XCTAssertNil(feed, "Feed without updated should fail to initialize")
    }

    func testFeedWithInvalidDate() {
        let feedWithInvalidDate = """
            <?xml version="1.0" encoding="utf-8"?>
            <feed xmlns="http://www.w3.org/2005/Atom">
                <id>http://example.org/feed</id>
                <title>Test Feed</title>
                <updated>not-a-valid-date</updated>
            </feed>
            """

        guard let data = feedWithInvalidDate.data(using: .utf8),
              let xml = TPPXML(data: data) else {
            XCTFail("Failed to create XML")
            return
        }

        let feed = TPPOPDSFeed(xml: xml)
        XCTAssertNil(feed, "Feed with invalid date should fail to initialize")
    }

    func testEntryWithMissingId() {
        let entryWithoutId = """
            <entry xmlns="http://www.w3.org/2005/Atom">
                <title>Test Entry</title>
                <updated>2024-01-20T08:00:00Z</updated>
            </entry>
            """

        guard let data = entryWithoutId.data(using: .utf8),
              let xml = TPPXML(data: data) else {
            XCTFail("Failed to create XML")
            return
        }

        let entry = TPPOPDSEntry(xml: xml)
        XCTAssertNil(entry, "Entry without id should fail to initialize")
    }

    func testEntryWithMissingTitle() {
        let entryWithoutTitle = """
            <entry xmlns="http://www.w3.org/2005/Atom">
                <id>urn:uuid:test-001</id>
                <updated>2024-01-20T08:00:00Z</updated>
            </entry>
            """

        guard let data = entryWithoutTitle.data(using: .utf8),
              let xml = TPPXML(data: data) else {
            XCTFail("Failed to create XML")
            return
        }

        let entry = TPPOPDSEntry(xml: xml)
        XCTAssertNil(entry, "Entry without title should fail to initialize")
    }

    func testEntryWithMissingUpdated() {
        let entryWithoutUpdated = """
            <entry xmlns="http://www.w3.org/2005/Atom">
                <id>urn:uuid:test-001</id>
                <title>Test Entry</title>
            </entry>
            """

        guard let data = entryWithoutUpdated.data(using: .utf8),
              let xml = TPPXML(data: data) else {
            XCTFail("Failed to create XML")
            return
        }

        let entry = TPPOPDSEntry(xml: xml)
        XCTAssertNil(entry, "Entry without updated should fail to initialize")
    }

    func testLinkWithMissingHref() {
        let linkWithoutHref = """
            <link xmlns="http://www.w3.org/2005/Atom" rel="alternate" type="application/atom+xml"/>
            """

        guard let data = linkWithoutHref.data(using: .utf8),
              let xml = TPPXML(data: data) else {
            XCTFail("Failed to create XML")
            return
        }

        let link = TPPOPDSLink(xml: xml)
        XCTAssertNil(link, "Link without href should fail to initialize")
    }

    func testMalformedXML() {
        let malformedXML = """
            <?xml version="1.0" encoding="utf-8"?>
            <feed xmlns="http://www.w3.org/2005/Atom">
                <id>http://example.org/feed</id>
                <title>Test Feed
                <updated>2024-01-15T12:00:00Z</updated>
            </feed>
            """

        guard let data = malformedXML.data(using: .utf8) else {
            XCTFail("Failed to create data")
            return
        }

        let xml = TPPXML(data: data)
        XCTAssertNil(xml, "Malformed XML should fail to parse")
    }

    func testEmptyXMLData() {
        let emptyData = Data()
        let xml = TPPXML(data: emptyData)
        XCTAssertNil(xml, "Empty data should fail to parse")
    }

    func testNilXMLFeed() {
        let feed = TPPOPDSFeed(xml: nil)
        XCTAssertNil(feed, "Feed with nil XML should return nil")
    }

    func testFeedIgnoresMalformedEntries() {
        let feedWithMalformedEntry = """
            <?xml version="1.0" encoding="utf-8"?>
            <feed xmlns="http://www.w3.org/2005/Atom">
                <id>http://example.org/feed</id>
                <title>Test Feed</title>
                <updated>2024-01-15T12:00:00Z</updated>
                <entry>
                    <title>Valid Entry</title>
                    <id>urn:uuid:valid-001</id>
                    <updated>2024-01-10T10:00:00Z</updated>
                </entry>
                <entry>
                    <title>Invalid Entry - No ID</title>
                    <updated>2024-01-10T10:00:00Z</updated>
                </entry>
                <entry>
                    <title>Another Valid Entry</title>
                    <id>urn:uuid:valid-002</id>
                    <updated>2024-01-10T10:00:00Z</updated>
                </entry>
            </feed>
            """

        guard let data = feedWithMalformedEntry.data(using: .utf8),
              let xml = TPPXML(data: data),
              let feed = TPPOPDSFeed(xml: xml) else {
            XCTFail("Failed to create feed")
            return
        }

        // Feed should be created with only the valid entries
        XCTAssertEqual(feed.entries.count, 2, "Feed should contain only valid entries, ignoring malformed ones")
    }

    func testFeedIgnoresMalformedLinks() {
        let feedWithMalformedLink = """
            <?xml version="1.0" encoding="utf-8"?>
            <feed xmlns="http://www.w3.org/2005/Atom">
                <id>http://example.org/feed</id>
                <title>Test Feed</title>
                <updated>2024-01-15T12:00:00Z</updated>
                <link href="http://example.org/valid" rel="self"/>
                <link rel="alternate"/>
                <link href="http://example.org/another" rel="next"/>
            </feed>
            """

        guard let data = feedWithMalformedLink.data(using: .utf8),
              let xml = TPPXML(data: data),
              let feed = TPPOPDSFeed(xml: xml) else {
            XCTFail("Failed to create feed")
            return
        }

        XCTAssertEqual(feed.links.count, 2, "Feed should contain only valid links")
    }

    func testCategoryWithMissingTerm() {
        let entryWithBadCategory = """
            <entry xmlns="http://www.w3.org/2005/Atom">
                <id>urn:uuid:cat-test-001</id>
                <title>Category Test</title>
                <updated>2024-01-20T08:00:00Z</updated>
                <category scheme="http://schema.org/genre" label="No Term Category"/>
                <category term="ValidTerm" scheme="http://schema.org/genre" label="Valid Category"/>
            </entry>
            """

        guard let data = entryWithBadCategory.data(using: .utf8),
              let xml = TPPXML(data: data),
              let entry = TPPOPDSEntry(xml: xml) else {
            XCTFail("Failed to create entry")
            return
        }

        XCTAssertEqual(entry.categories.count, 1, "Only valid categories should be parsed")
        XCTAssertEqual(entry.categories.first?.term, "ValidTerm")
    }

    func testAuthorWithMissingName() {
        let entryWithBadAuthor = """
            <entry xmlns="http://www.w3.org/2005/Atom">
                <id>urn:uuid:author-test-001</id>
                <title>Author Test</title>
                <updated>2024-01-20T08:00:00Z</updated>
                <author>
                    <uri>http://example.org/author1</uri>
                </author>
                <author>
                    <name>Valid Author</name>
                </author>
            </entry>
            """

        guard let data = entryWithBadAuthor.data(using: .utf8),
              let xml = TPPXML(data: data),
              let entry = TPPOPDSEntry(xml: xml) else {
            XCTFail("Failed to create entry")
            return
        }

        XCTAssertEqual(entry.authorStrings.count, 1, "Only authors with names should be parsed")
        XCTAssertEqual(entry.authorStrings.first as? String, "Valid Author")
    }

    // MARK: - Analytics URL Generation Test

    func testAnalyticsURLGeneration() {
        let entryWithAlternate = """
            <entry xmlns="http://www.w3.org/2005/Atom">
                <id>urn:uuid:analytics-001</id>
                <title>Analytics Test</title>
                <updated>2024-01-20T08:00:00Z</updated>
                <link href="http://example.org/works/book123" rel="alternate" type="application/atom+xml"/>
            </entry>
            """

        guard let data = entryWithAlternate.data(using: .utf8),
              let xml = TPPXML(data: data),
              let entry = TPPOPDSEntry(xml: xml) else {
            XCTFail("Failed to create entry")
            return
        }

        XCTAssertNotNil(entry.analytics, "Analytics URL should be generated from alternate link")
        XCTAssertEqual(entry.analytics?.absoluteString, "http://example.org/analytics/book123")
    }

    // MARK: - Preview Link Tests

    func testPreviewLinkParsing() {
        let entryWithPreview = """
            <entry xmlns="http://www.w3.org/2005/Atom">
                <id>urn:uuid:preview-001</id>
                <title>Preview Test</title>
                <updated>2024-01-20T08:00:00Z</updated>
                <link href="http://example.org/preview" rel="preview" type="application/epub+zip"/>
            </entry>
            """

        guard let data = entryWithPreview.data(using: .utf8),
              let xml = TPPXML(data: data),
              let entry = TPPOPDSEntry(xml: xml) else {
            XCTFail("Failed to create entry")
            return
        }

        XCTAssertNotNil(entry.previewLink, "Preview link should be parsed")
    }

    // MARK: - HTML Entity Decoding Test

    func testHTMLEntityDecoding() {
        let entryWithHTMLEntities = """
            <entry xmlns="http://www.w3.org/2005/Atom">
                <id>urn:uuid:html-001</id>
                <title>HTML &amp; Entities</title>
                <updated>2024-01-20T08:00:00Z</updated>
                <summary type="html">A book about &lt;programming&gt; &amp; testing.</summary>
            </entry>
            """

        guard let data = entryWithHTMLEntities.data(using: .utf8),
              let xml = TPPXML(data: data),
              let entry = TPPOPDSEntry(xml: xml) else {
            XCTFail("Failed to create entry")
            return
        }

        XCTAssertNotNil(entry.summary)
        // The summary should have HTML entities decoded
        XCTAssertTrue(entry.summary?.contains("<programming>") ?? false || entry.summary?.contains("&lt;programming&gt;") ?? false)
    }

    // MARK: - Date Parsing Tests

    func testRFC3339DateParsing() {
        let dates = [
            "2024-01-15T12:00:00Z",
            "2024-01-15T12:00:00+00:00",
            "2024-01-15T12:00:00.000Z"
        ]

        for dateString in dates {
            let feedXML = """
                <?xml version="1.0" encoding="utf-8"?>
                <feed xmlns="http://www.w3.org/2005/Atom">
                    <id>http://example.org/feed</id>
                    <title>Date Test</title>
                    <updated>\(dateString)</updated>
                </feed>
                """

            guard let data = feedXML.data(using: .utf8),
                  let xml = TPPXML(data: data),
                  let feed = TPPOPDSFeed(xml: xml) else {
                XCTFail("Failed to parse date: \(dateString)")
                continue
            }

            XCTAssertNotNil(feed.updated, "Date \(dateString) should be parsed successfully")
        }
    }

    // MARK: - Performance Tests

    func testFeedParsingPerformance() {
        guard let data = completeFeedXML.data(using: .utf8) else {
            XCTFail("Failed to create data")
            return
        }

        measure {
            for _ in 0..<100 {
                guard let xml = TPPXML(data: data) else { continue }
                _ = TPPOPDSFeed(xml: xml)
            }
        }
    }
}
