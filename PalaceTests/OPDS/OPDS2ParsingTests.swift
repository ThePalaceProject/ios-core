//
//  OPDS2ParsingTests.swift
//  PalaceTests
//
//  Deep, mutation-killing unit tests for the OPDS 2.0 parser stack:
//  OPDS2Feed, OPDS2Publication, OPDS2PublicationExtended.toBook(),
//  OPDS2CatalogsFeed, OPDS2Group, and the OPDS2AuthenticationDocument /
//  TPPProblemDocument decoders that ship alongside them.
//
//  These tests pin existing parser behavior — they intentionally do NOT
//  modify production code. Tests load fixtures from
//  PalaceTests/Fixtures/OPDSFeeds/ via #filePath, keeping them purely
//  deterministic with no network and no mocks.
//

import XCTest
@testable import Palace
import PalaceCatalog
import PalaceBookModel

// MARK: - Fixture loader

private enum OPDS2Fixture {
    static func load(_ name: String) -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // OPDS
            .deletingLastPathComponent()      // PalaceTests
            .appendingPathComponent("Fixtures/OPDSFeeds/\(name)")
        return try! Data(contentsOf: url)
    }
}

@MainActor
final class OPDS2ParsingTests: XCTestCase {

    // MARK: - OPDS2Feed: typical catalog (opds2_catalog.json)

    func testCatalog_decodesWithExpectedPublicationCount() throws {
        let data = OPDS2Fixture.load("opds2_catalog.json")
        let feed = try OPDS2Feed.from(data: data)
        XCTAssertEqual(feed.publications?.count, 2,
                       "opds2_catalog.json must decode exactly 2 publications")
    }

    func testCatalog_metadataTitleAndIdentifier() throws {
        let feed = try OPDS2Feed.from(data: OPDS2Fixture.load("opds2_catalog.json"))
        XCTAssertEqual(feed.metadata.title, "OPDS2 Test Catalog")
        XCTAssertEqual(feed.id, "urn:uuid:opds2-catalog-id",
                       "feed.id must surface metadata.identifier")
    }

    func testCatalog_publicationTitlesInOrder() throws {
        let feed = try OPDS2Feed.from(data: OPDS2Fixture.load("opds2_catalog.json"))
        let titles = feed.publications?.map { $0.metadata.title }
        XCTAssertEqual(titles, ["Sunrise Over Pines", "Whispers of the Forest"],
                       "Publications must be preserved in document order")
    }

    func testCatalog_multipleAuthors_preservedInOrder() throws {
        let feed = try OPDS2Feed.from(data: OPDS2Fixture.load("opds2_catalog.json"))
        let second = try XCTUnwrap(feed.publications?[1])
        let names = second.metadata.author?.map { $0.name }
        XCTAssertEqual(names, ["Mateo Reyes", "Naomi Sato"],
                       "Both authors must be preserved in array order")
    }

    func testCatalog_nextPageURL_capturedForPagination() throws {
        let feed = try OPDS2Feed.from(data: OPDS2Fixture.load("opds2_catalog.json"))
        XCTAssertEqual(feed.nextPageURL?.absoluteString,
                       "https://example.org/opds2/catalog?page=2",
                       "feed.nextPageURL must surface rel='next' link")
    }

    func testCatalog_selfURL_captured() throws {
        let feed = try OPDS2Feed.from(data: OPDS2Fixture.load("opds2_catalog.json"))
        XCTAssertEqual(feed.selfURL?.absoluteString, "https://example.org/opds2/catalog")
    }

    func testCatalog_searchURL_captured() throws {
        let feed = try OPDS2Feed.from(data: OPDS2Fixture.load("opds2_catalog.json"))
        // URL percent-encodes '{' and '}', so compare on the underlying link
        // string and on the URL host/path components rather than full URL.
        let searchLink = feed.links?.first { $0.rel == "search" }
        XCTAssertEqual(searchLink?.href, "https://example.org/opds2/search{?query}",
                       "Raw link.href must preserve the templated URI verbatim")
        XCTAssertEqual(feed.searchURL?.host, "example.org")
        XCTAssertEqual(searchLink?.templated, true,
                       "Templated flag from JSON must round-trip")
    }

    func testCatalog_isPublicationFeedFlag() throws {
        let feed = try OPDS2Feed.from(data: OPDS2Fixture.load("opds2_catalog.json"))
        XCTAssertTrue(feed.isPublicationFeed,
                      "Feed with publications must report isPublicationFeed = true")
        XCTAssertFalse(feed.isGroupedFeed,
                       "Catalog without groups must report isGroupedFeed = false")
        XCTAssertFalse(feed.isNavigationFeed)
    }

    func testCatalog_publication_imageURLs_separated() throws {
        let feed = try OPDS2Feed.from(data: OPDS2Fixture.load("opds2_catalog.json"))
        let first = try XCTUnwrap(feed.publications?.first)
        let thumbnail = first.images?.first { $0.rel?.contains("thumbnail") == true }
        XCTAssertNotNil(thumbnail, "Thumbnail image must be retained on the publication")
        XCTAssertEqual(thumbnail?.href,
                       "https://example.org/opds2/img/001-thumb.jpg")
    }

    func testCatalog_borrowLink_propertiesPreserved() throws {
        let feed = try OPDS2Feed.from(data: OPDS2Fixture.load("opds2_catalog.json"))
        let first = try XCTUnwrap(feed.publications?.first)
        let borrow = try XCTUnwrap(first.links.first { $0.isBorrow })
        XCTAssertEqual(borrow.properties?.availability?.state, "available")
        XCTAssertEqual(borrow.properties?.copies?.total, 5)
        XCTAssertEqual(borrow.properties?.copies?.available, 3)
        XCTAssertEqual(borrow.properties?.indirectAcquisition?.first?.type,
                       "application/vnd.adobe.adept+xml")
        XCTAssertEqual(borrow.properties?.indirectAcquisition?.first?.child?.first?.type,
                       "application/epub+zip",
                       "Nested indirect acquisitions must be preserved through Codable")
    }

    func testCatalog_openAccessLink_isFlaggedOpenAccess() throws {
        let feed = try OPDS2Feed.from(data: OPDS2Fixture.load("opds2_catalog.json"))
        let second = try XCTUnwrap(feed.publications?[1])
        let open = try XCTUnwrap(second.links.first { $0.isOpenAccess })
        XCTAssertFalse(open.isBorrow,
                       "open-access link must NOT be classified as borrow")
        XCTAssertTrue(open.isAcquisition,
                      "open-access link must still be classified as acquisition")
    }

    // MARK: - OPDS2 publication-only fixture (opds2_publication.json)

    func testPublication_multipleAcquisitionLinks_allRetained() throws {
        let data = OPDS2Fixture.load("opds2_publication.json")
        let pub = try JSONDecoder().decode(OPDS2Publication.self, from: data)
        let acqRels = pub.links.compactMap { $0.rel }.filter { $0.contains("acquisition") || $0 == "preview" }
        // borrow, open-access, sample, preview
        XCTAssertEqual(Set(acqRels), Set([
            "http://opds-spec.org/acquisition/borrow",
            "http://opds-spec.org/acquisition/open-access",
            "http://opds-spec.org/acquisition/sample",
            "preview"
        ]))
    }

    func testPublication_isSampleClassifier_acceptsBothPreviewAndSampleRel() throws {
        let data = OPDS2Fixture.load("opds2_publication.json")
        let pub = try JSONDecoder().decode(OPDS2Publication.self, from: data)
        let samples = pub.links.filter { $0.isSample }
        XCTAssertEqual(samples.count, 2,
                       "Both rel='preview' and rel='.../sample' must satisfy isSample")
    }

    func testPublication_imageURLs_areExtractedFromImagesArray() throws {
        let data = OPDS2Fixture.load("opds2_publication.json")
        let pub = try JSONDecoder().decode(OPDS2Publication.self, from: data)
        XCTAssertEqual(pub.imageURL?.absoluteString,
                       "https://example.org/pubs/multi-cover.png")
        XCTAssertEqual(pub.thumbnailURL?.absoluteString,
                       "https://example.org/pubs/multi-thumb.png")
    }

    func testPublication_toBook_skipsWhenNoSupportedAcquisitionPath() throws {
        // Build a synthetic publication whose ONLY acquisition link is for a
        // content type the iOS client cannot render (text/html). Pins the
        // [OPDS2-DIAG] "no supported acquisition path" behavior documented in
        // OPDS2PublicationExtended.swift.
        let json = """
        {
          "metadata": {
            "identifier": "urn:uuid:unsupported-only",
            "title": "HTML-only Pub"
          },
          "links": [
            {
              "rel": "http://opds-spec.org/acquisition/open-access",
              "href": "https://example.org/unsupported/stream",
              "type": "text/html"
            }
          ]
        }
        """
        let pub = try JSONDecoder().decode(OPDS2Publication.self, from: Data(json.utf8))
        let book = pub.toBook()
        XCTAssertNil(book,
                     "Publication whose only acquisition path is unsupported (text/html) must be dropped, not returned")
    }

    func testPublication_toBook_skipsWhenNoAcquisitionLinks() throws {
        let json = """
        {
          "metadata": {
            "identifier": "urn:uuid:no-acq",
            "title": "No Acquisitions"
          },
          "links": [
            { "rel": "alternate", "href": "https://example.org/no-acq" }
          ]
        }
        """
        let pub = try JSONDecoder().decode(OPDS2Publication.self, from: Data(json.utf8))
        XCTAssertNil(pub.toBook(),
                     "Publication with zero acquisition links must yield nil from toBook()")
    }

    func testPublication_toBook_succeedsForSupportedEpubOpenAccess() throws {
        let json = """
        {
          "metadata": {
            "identifier": "urn:uuid:supported-epub",
            "title": "Supported EPUB"
          },
          "links": [
            {
              "rel": "http://opds-spec.org/acquisition/open-access",
              "href": "https://example.org/openaccess.epub",
              "type": "application/epub+zip"
            }
          ]
        }
        """
        let pub = try JSONDecoder().decode(OPDS2Publication.self, from: Data(json.utf8))
        let book = pub.toBook()
        XCTAssertNotNil(book,
                        "Publication with a supported EPUB open-access path must yield a TPPBook")
        XCTAssertEqual(book?.title, "Supported EPUB")
        XCTAssertEqual(book?.identifier, "urn:uuid:supported-epub")
    }

    // MARK: - OPDS2 → TPPOPDSAcquisition bridge

    func testBookBridge_relationMapping_isExhaustiveForKnownRels() {
        XCTAssertEqual(OPDS2BookBridge.relation(from: "http://opds-spec.org/acquisition"), .generic)
        XCTAssertEqual(OPDS2BookBridge.relation(from: "http://opds-spec.org/acquisition/open-access"), .openAccess)
        XCTAssertEqual(OPDS2BookBridge.relation(from: "http://opds-spec.org/acquisition/borrow"), .borrow)
        XCTAssertEqual(OPDS2BookBridge.relation(from: "http://opds-spec.org/acquisition/buy"), .buy)
        XCTAssertEqual(OPDS2BookBridge.relation(from: "http://opds-spec.org/acquisition/sample"), .sample)
        XCTAssertEqual(OPDS2BookBridge.relation(from: "http://opds-spec.org/acquisition/subscribe"), .subscribe)
        XCTAssertEqual(OPDS2BookBridge.relation(from: "preview"), .sample,
                       "'preview' rel must be normalised to .sample in the bridge")
    }

    func testBookBridge_revokeAndIssues_excludedFromAcquisitions() {
        XCTAssertNil(OPDS2BookBridge.relation(from: "http://opds-spec.org/acquisition/revoke"),
                     "revoke must not be classified as an acquisition")
        XCTAssertNil(OPDS2BookBridge.relation(from: "http://opds-spec.org/acquisition/issues"),
                     "issues must not be classified as an acquisition")
    }

    func testBookBridge_unknownRel_returnsNil() {
        XCTAssertNil(OPDS2BookBridge.relation(from: "alternate"))
        XCTAssertNil(OPDS2BookBridge.relation(from: nil))
    }

    // MARK: - Groups → lanes mapping (opds2_with_groups.json)

    func testGroupedFeed_decodesAllGroups() throws {
        let feed = try OPDS2Feed.from(data: OPDS2Fixture.load("opds2_with_groups.json"))
        XCTAssertEqual(feed.groups?.count, 3,
                       "All three group blocks must be decoded as lanes")
        XCTAssertTrue(feed.isGroupedFeed)
    }

    func testGroupedFeed_groupTitlesInOrder() throws {
        let feed = try OPDS2Feed.from(data: OPDS2Fixture.load("opds2_with_groups.json"))
        let names = feed.groups?.map { $0.title }
        XCTAssertEqual(names, ["Best Sellers", "Staff Picks", "New Arrivals"])
    }

    func testGroupedFeed_publicationsPerGroup() throws {
        let feed = try OPDS2Feed.from(data: OPDS2Fixture.load("opds2_with_groups.json"))
        let counts = feed.groups?.map { $0.publications?.count ?? 0 }
        XCTAssertEqual(counts, [2, 1, 0],
                       "Per-group publication counts must match the fixture")
    }

    func testGroupedFeed_navigationLanePreserved() throws {
        let feed = try OPDS2Feed.from(data: OPDS2Fixture.load("opds2_with_groups.json"))
        let navGroup = try XCTUnwrap(feed.groups?.last)
        XCTAssertEqual(navGroup.navigation?.first?.title, "All New Arrivals")
        XCTAssertEqual(navGroup.navigation?.first?.href,
                       "https://example.org/opds2/grouped/new")
    }

    func testGroupedFeed_groupMoreURL_resolvesFromSelfOrSubsection() throws {
        let feed = try OPDS2Feed.from(data: OPDS2Fixture.load("opds2_with_groups.json"))
        let bestsellers = try XCTUnwrap(feed.groups?[0])
        let staffPicks = try XCTUnwrap(feed.groups?[1])
        XCTAssertEqual(bestsellers.moreURL?.absoluteString,
                       "https://example.org/opds2/grouped/bestsellers",
                       "Group with rel='self' link must expose it as moreURL")
        XCTAssertEqual(staffPicks.moreURL?.absoluteString,
                       "https://example.org/opds2/grouped/staff-picks",
                       "Group with only rel='subsection' must expose it as moreURL")
    }

    // MARK: - Auth document (opds2_auth_document.json)

    func testAuthDocument_decodesTitleAndId() throws {
        let doc = try OPDS2AuthenticationDocument.fromData(
            OPDS2Fixture.load("opds2_auth_document.json"))
        XCTAssertEqual(doc.title, "Testlib Authentication")
        XCTAssertEqual(doc.id, "https://example.org/auth-doc/library-123")
    }

    func testAuthDocument_basicAuthMechanism() throws {
        let doc = try OPDS2AuthenticationDocument.fromData(
            OPDS2Fixture.load("opds2_auth_document.json"))
        let auths = try XCTUnwrap(doc.authentication)
        XCTAssertEqual(auths.count, 1)
        let basic = auths[0]
        XCTAssertEqual(basic.type, "http://opds-spec.org/auth/basic")
        XCTAssertEqual(basic.labels?.login, "Barcode")
        XCTAssertEqual(basic.labels?.password, "PIN")
        XCTAssertEqual(basic.inputs?.login.keyboard, "numeric")
        XCTAssertEqual(basic.inputs?.login.maximumLength, 14)
        XCTAssertEqual(basic.inputs?.password.keyboard, "numeric")
    }

    func testAuthDocument_featuresAndAnnouncements() throws {
        let doc = try OPDS2AuthenticationDocument.fromData(
            OPDS2Fixture.load("opds2_auth_document.json"))
        XCTAssertEqual(doc.features?.enabled?.first,
                       "https://librarysimplified.org/rel/policy/reservations")
        XCTAssertEqual(doc.announcements?.count, 1)
        XCTAssertEqual(doc.announcements?.first?.id, "announcement-1")
        XCTAssertEqual(doc.announcements?.first?.content,
                       "Library closed for holiday on July 4.")
    }

    func testAuthDocument_passwordResetLink_present() throws {
        let doc = try OPDS2AuthenticationDocument.fromData(
            OPDS2Fixture.load("opds2_auth_document.json"))
        let basic = try XCTUnwrap(doc.authentication?.first)
        let resetLink = basic.links?.first { $0.rel == OPDS2LinkRel.passwordReset.rawValue }
        XCTAssertNotNil(resetLink,
                        "Auth mechanism must surface patron-password-reset link")
        XCTAssertEqual(resetLink?.href, "https://example.org/auth-doc/forgot-pin")
    }

    // MARK: - Problem document (opds2_problem_document.json)

    func testProblemDocument_decodesAllRFC7807Fields() throws {
        let data = OPDS2Fixture.load("opds2_problem_document.json")
        let doc = try TPPProblemDocument.fromData(data)
        XCTAssertEqual(doc.type, "http://librarysimplified.org/terms/problem/loan-already-exists")
        XCTAssertEqual(doc.title, "Loan Already Exists")
        XCTAssertEqual(doc.status, 409)
        XCTAssertEqual(doc.detail, "This patron already has a loan for the requested item.")
        XCTAssertEqual(doc.instance, "https://example.org/instance/abc-123")
    }

    func testProblemDocument_malformedJSON_throwsNotCrashes() {
        let bad = Data("{not json".utf8)
        XCTAssertThrowsError(try TPPProblemDocument.fromData(bad))
    }

    // MARK: - Malformed / empty inputs

    func testFeed_malformedJSON_throwsNotCrashes() {
        let bad = Data("{not json".utf8)
        XCTAssertThrowsError(try OPDS2Feed.from(data: bad))
    }

    func testFeed_emptyData_throwsNotCrashes() {
        XCTAssertThrowsError(try OPDS2Feed.from(data: Data()))
    }

    func testFeed_emptyPublicationsArray_isEmptyNotNil() throws {
        let json = """
        {
          "metadata": { "title": "Empty Catalog" },
          "links": [],
          "publications": []
        }
        """
        let feed = try OPDS2Feed.from(data: Data(json.utf8))
        XCTAssertEqual(feed.publications?.count, 0)
        XCTAssertFalse(feed.isPublicationFeed,
                       "Empty publications array must NOT report isPublicationFeed=true")
    }

    // MARK: - Unicode + long-string edge cases

    func testFeed_publicationWithVeryLongTitle_preserved() throws {
        let longTitle = String(repeating: "A long passage of metadata. ", count: 60)
        XCTAssertGreaterThan(longTitle.count, 1024)
        let json = """
        {
          "metadata": { "title": "Edge" },
          "publications": [
            {
              "metadata": {
                "identifier": "urn:uuid:long",
                "title": \(jsonEscape(longTitle))
              },
              "links": [
                {
                  "rel": "http://opds-spec.org/acquisition/open-access",
                  "href": "https://example.org/x.epub",
                  "type": "application/epub+zip"
                }
              ]
            }
          ]
        }
        """
        let feed = try OPDS2Feed.from(data: Data(json.utf8))
        XCTAssertEqual(feed.publications?.first?.metadata.title, longTitle,
                       "Long titles must round-trip exactly")
    }

    func testFeed_publicationWithUnicodeTitle_preserved() throws {
        let unicode = "Tale of the dragon \u{1F409} — مرحبا — 你好"
        let json = """
        {
          "metadata": { "title": "Unicode" },
          "publications": [
            {
              "metadata": {
                "identifier": "urn:uuid:unicode",
                "title": \(jsonEscape(unicode)),
                "author": [{ "name": "Yokoyama 横山" }]
              },
              "links": [
                {
                  "rel": "http://opds-spec.org/acquisition/open-access",
                  "href": "https://example.org/x.epub",
                  "type": "application/epub+zip"
                }
              ]
            }
          ]
        }
        """
        let feed = try OPDS2Feed.from(data: Data(json.utf8))
        XCTAssertEqual(feed.publications?.first?.metadata.title, unicode)
        XCTAssertEqual(feed.publications?.first?.metadata.author?.first?.name,
                       "Yokoyama 横山")
    }

    // MARK: - OPDS2CatalogsFeed (library registry shape)

    func testCatalogsFeed_parsesExistingFixture() throws {
        // Uses the existing OPDS2/Fixtures/OPDS2CatalogFeed.json shipped with the project.
        // Loaded directly to avoid duplicating the fixture under OPDSFeeds/.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // OPDS
            .deletingLastPathComponent()      // PalaceTests
            .appendingPathComponent("OPDS2/Fixtures/OPDS2CatalogFeed.json")
        let data = try Data(contentsOf: url)
        // The registry-shape catalogs feed isn't pure OPDS2CatalogsFeed but
        // OPDS2Feed handles it. The OPDS2CatalogsFeed decoder requires a
        // `catalogs` array which this fixture lacks; just verify the negative
        // case to pin behavior.
        XCTAssertThrowsError(try OPDS2CatalogsFeed.fromData(data),
                             "OPDS2CatalogsFeed.fromData must throw when 'catalogs' is missing")
    }

    func testCatalogsFeed_parsesSyntheticCatalogsArray() throws {
        let json = """
        {
          "metadata": { "title": "Registry" },
          "catalogs": [
            {
              "metadata": {
                "identifier": "urn:uuid:lib-1",
                "title": "Library One"
              },
              "links": [
                {
                  "rel": "http://opds-spec.org/catalog",
                  "href": "https://example.org/library-1/",
                  "type": "application/opds+json"
                }
              ]
            }
          ],
          "links": [
            {
              "rel": "next",
              "href": "https://example.org/registry?page=2",
              "type": "application/opds+json"
            }
          ]
        }
        """
        let feed = try OPDS2CatalogsFeed.fromData(Data(json.utf8))
        XCTAssertEqual(feed.catalogs.count, 1)
        XCTAssertEqual(feed.catalogs.first?.metadata.title, "Library One")
        XCTAssertEqual(feed.nextPageURL?.absoluteString,
                       "https://example.org/registry?page=2",
                       "Registry feed must expose rel='next' for pagination")
    }

    // MARK: - Helpers

    /// Tiny JSON string escaper so we can embed literal long/unicode strings
    /// into multi-line JSON without smuggling stray quotes/backslashes.
    private func jsonEscape(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }
}
