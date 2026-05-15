//
//  CatalogOPDS2NegotiationTests.swift
//  PalaceTests
//
//  Deep mutation-killing tests for OPDS2 ⇄ OPDS1 negotiation in the catalog
//  assembly layer (DefaultCatalogAPI + CatalogRepository + OPDSParser).
//
//  ──────────────────────────────────────────────────────────────────────────
//  Negotiation contract under test
//  ──────────────────────────────────────────────────────────────────────────
//
//  When `FeatureFlagProvider.isOPDS2Enabled == true`, the catalog API:
//    1. Sends `Accept: application/opds+json, application/atom+xml;q=0.9, …`.
//    2. Receives EITHER an OPDS 2 JSON body or an OPDS 1 Atom body.
//    3. Routes parsing by inspecting the FIRST BYTE of the body:
//         • `{` or `[` → OPDS 2 JSON parser.
//         • `<`        → OPDS 1 XML parser.
//
//  When the server returns OPDS 2 but the body fails JSON shape validation
//  (e.g. missing "metadata"), the parser throws `ParserError.invalidJSON`.
//  When the server returns OPDS 1 despite OPDS 2 being requested, the parser
//  silently routes to XML — this is the "fallback" branch.
//
//  We exercise BOTH branches and pin the OPDS 2 → OPDS 1 fallback semantic.
//
//  ──────────────────────────────────────────────────────────────────────────
//  House rules
//  ──────────────────────────────────────────────────────────────────────────
//   • No production code modified. The parser's first-byte heuristic IS the
//     negotiation seam. We exercise it through the public API.
//   • Hermetic. We use `NetworkClientMock`, not the OS URL stack.
//   • Each test targets at least one mutation:
//       - flip first-byte check `{` ↔ `<`
//       - drop OPDS 2 branch (route everything to OPDS 1)
//       - drop OPDS 1 branch (route everything to OPDS 2)
//       - swap `Accept` header content
//       - remove JSON-failure throw
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import XCTest
import PalaceCatalog
import PalaceNetwork
@testable import Palace

final class CatalogOPDS2NegotiationTests: XCTestCase {

    // MARK: - Fixtures

    private var networkClient: NetworkClientMock!
    private var parser: OPDSParser!
    private let topURL = URL(string: "https://library.example.com/catalog")!

    /// Minimal-but-realistic OPDS 2 JSON used to anchor "this body MUST be
    /// parsed as OPDS 2". Includes a publication so we can also verify that
    /// the entry list flowed through the OPDS 2 init path.
    private static let opds2Body = """
    {
      "metadata": { "title": "OPDS2 Manifest" },
      "links": [{ "href": "https://library.example.com/catalog", "rel": "self", "type": "application/opds+json" }],
      "publications": [
        {
          "metadata": { "id": "pub-1", "title": "OPDS2 Book", "updated": "2026-01-01T00:00:00Z" },
          "links": [
            { "href": "https://library.example.com/borrow/pub-1",
              "rel": "http://opds-spec.org/acquisition/borrow",
              "type": "application/epub+zip" }
          ]
        }
      ]
    }
    """

    /// Minimal OPDS 1 Atom XML. Whitespace before `<` would defeat the
    /// first-byte heuristic, so we deliberately keep the body free of
    /// leading whitespace and BOM.
    private static let opds1Body = """
    <?xml version="1.0" encoding="UTF-8"?>\
    <feed xmlns="http://www.w3.org/2005/Atom" xmlns:opds="http://opds-spec.org/2010/catalog">
      <id>urn:uuid:opds1-fallback</id>
      <title>OPDS1 Fallback Feed</title>
      <updated>2026-01-01T00:00:00Z</updated>
      <entry>
        <id>urn:uuid:entry-1</id>
        <title>Legacy Book</title>
        <updated>2026-01-01T00:00:00Z</updated>
      </entry>
    </feed>
    """

    // MARK: - Setup / Teardown

    override func setUp() {
        super.setUp()
        networkClient = NetworkClientMock()
        parser = OPDSParser()
    }

    override func tearDown() {
        networkClient = nil
        parser = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeAPI(opds2Enabled: Bool) -> DefaultCatalogAPI {
        DefaultCatalogAPI(
            client: networkClient,
            parser: parser,
            featureFlags: MockFeatureFlagProvider(isOPDS2Enabled: opds2Enabled)
        )
    }

    /// Build an HTTPURLResponse with the given Content-Type and stub it on
    /// the mock for `topURL`. Used to verify that the parser's routing
    /// depends on body bytes, not the server's declared MIME type.
    private func stub(body: String, contentType: String) {
        let data = Data(body.utf8)
        let response = HTTPURLResponse(
            url: topURL,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": contentType]
        )!
        networkClient.stubbedResponses[topURL] = NetworkResponse(data: data, response: response)
    }

    // MARK: - Accept-header content negotiation
    //
    // The `Accept` header tells the server which formats the client will
    // accept. The feature flag drives this string. We pin both flag states
    // so a mutant that swaps the two strings is detected immediately.

    /// Mutant killed: swapping the OPDS2-enabled accept header with the
    /// OPDS1-only one. Pin: when OPDS 2 is enabled the request must list
    /// `application/opds+json` BEFORE `application/atom+xml` (preference
    /// order matters for server-driven negotiation).
    func testRequestAcceptHeader_WhenOPDS2Enabled_PrefersJSONOverAtom() async throws {
        stub(body: Self.opds2Body, contentType: "application/opds+json")
        let api = makeAPI(opds2Enabled: true)

        _ = try await api.fetchFeed(at: topURL)

        let accept = try XCTUnwrap(networkClient.lastRequestedHeaders?["Accept"],
                                   "fetchFeed must send an Accept header")
        XCTAssertTrue(accept.contains("application/opds+json"),
                      "OPDS2-enabled Accept must include application/opds+json")
        XCTAssertTrue(accept.contains("application/atom+xml"),
                      "OPDS2-enabled Accept must still accept atom+xml for graceful fallback")
        // Preference order: JSON before Atom (q-values + ordering).
        let jsonIdx = accept.range(of: "application/opds+json")?.lowerBound
        let atomIdx = accept.range(of: "application/atom+xml")?.lowerBound
        XCTAssertNotNil(jsonIdx)
        XCTAssertNotNil(atomIdx)
        if let j = jsonIdx, let a = atomIdx {
            XCTAssertLessThan(j, a,
                              "Accept header must list OPDS 2 JSON BEFORE OPDS 1 Atom when OPDS 2 is enabled")
        }
    }

    /// Mutant killed: leaking the OPDS 2 Accept header into the disabled
    /// flag path. With OPDS2 disabled the client must NOT advertise
    /// `application/opds+json` so legacy servers don't try to send it.
    func testRequestAcceptHeader_WhenOPDS2Disabled_DoesNotAdvertiseOPDS2() async throws {
        stub(body: Self.opds1Body, contentType: "application/atom+xml")
        let api = makeAPI(opds2Enabled: false)

        _ = try await api.fetchFeed(at: topURL)

        let accept = try XCTUnwrap(networkClient.lastRequestedHeaders?["Accept"])
        XCTAssertFalse(accept.contains("application/opds+json"),
                       "With OPDS2 disabled, Accept must NOT advertise application/opds+json")
        XCTAssertTrue(accept.contains("application/atom+xml"),
                      "With OPDS2 disabled, Accept must still request atom+xml")
    }

    // MARK: - OPDS 2 branch (server honors OPDS 2)

    /// Mutant killed: removing the JSON branch of `OPDSFormat.detect(from:)`
    /// (the `firstChar == "{"` branch) — the body would be misrouted to
    /// the XML parser, the feed's `isOPDS2` would be false, and the title
    /// would be lost.
    func testFetchFeed_ServerReturnsOPDS2JSON_ParsesAsOPDS2Feed() async throws {
        stub(body: Self.opds2Body, contentType: "application/opds+json")
        let api = makeAPI(opds2Enabled: true)

        let feed = try await api.fetchFeed(at: topURL)
        let unwrapped = try XCTUnwrap(feed, "OPDS 2 body must parse to a non-nil feed")

        XCTAssertTrue(unwrapped.isOPDS2,
                      "Body starting with `{` MUST be routed to the OPDS 2 parser")
        XCTAssertEqual(unwrapped.title, "OPDS2 Manifest",
                       "OPDS 2 feed title must come from the OPDS2 metadata block")
        XCTAssertNotNil(unwrapped.opds2Feed,
                        "OPDS 2 feed must populate opds2Feed for downstream lane assembly")
        // The OPDS 2 publication must be mapped to a CatalogEntry.
        XCTAssertEqual(unwrapped.entries.count, 1,
                       "Single-publication OPDS 2 feed must produce exactly one entry")
        XCTAssertEqual(unwrapped.entries.first?.id, "pub-1",
                       "OPDS 2 entry id must come from publication metadata")
    }

    /// Mutant killed: the parser using the Content-Type header instead of
    /// the body's first byte. We send OPDS 2 JSON but tag it with the OPDS 1
    /// MIME type; if the parser believes the header, this test fails.
    func testFetchFeed_OPDS2JSONBodyTaggedWithOPDS1ContentType_StillParsesAsOPDS2() async throws {
        // Lying server: tags OPDS 2 JSON as application/atom+xml.
        stub(body: Self.opds2Body, contentType: "application/atom+xml")
        let api = makeAPI(opds2Enabled: true)

        let feed = try await api.fetchFeed(at: topURL)
        let unwrapped = try XCTUnwrap(feed)

        XCTAssertTrue(unwrapped.isOPDS2,
                      "First-byte heuristic must override an incorrect Content-Type header")
        XCTAssertEqual(unwrapped.title, "OPDS2 Manifest")
    }

    // MARK: - OPDS 2 → OPDS 1 fallback (server returns Atom despite OPDS 2 advertised)

    /// Mutant killed: making the parser default to OPDS 2 for unknown shapes
    /// — would attempt to decode XML as JSON and throw `invalidJSON` instead
    /// of returning a parsed OPDS 1 feed.
    ///
    /// THIS IS THE CORE FALLBACK SEMANTIC: server returned OPDS 1 despite
    /// the OPDS 2 advertisement. The client must transparently parse it.
    func testFetchFeed_OPDS2RequestedButServerReturnsOPDS1Atom_FallsBackToOPDS1() async throws {
        stub(body: Self.opds1Body, contentType: "application/atom+xml")
        let api = makeAPI(opds2Enabled: true) // OPDS2 ENABLED, but server didn't honor it.

        let feed = try await api.fetchFeed(at: topURL)
        let unwrapped = try XCTUnwrap(feed, "OPDS 1 fallback must produce a non-nil feed")

        XCTAssertFalse(unwrapped.isOPDS2,
                       "Body starting with `<` MUST be routed to the OPDS 1 parser even when OPDS 2 is enabled")
        XCTAssertNil(unwrapped.opds2Feed,
                     "OPDS 1 fallback must NOT populate opds2Feed")
        XCTAssertEqual(unwrapped.title, "OPDS1 Fallback Feed",
                       "OPDS 1 fallback title must come from Atom XML <title>")
        XCTAssertEqual(unwrapped.entries.count, 1,
                       "OPDS 1 fallback must still extract entries from the Atom <entry>")
    }

    /// Mutant killed: parser silently returning nil for invalid JSON instead
    /// of throwing. The contract is that a body that LOOKS like JSON (`{`
    /// first byte) but isn't valid OPDS 2 MUST throw `invalidJSON` — not
    /// silently degrade to OPDS 1, because the JSON branch IS chosen.
    func testFetchFeed_OPDS2RequestedButServerReturnsMalformedJSON_ThrowsInvalidJSON() async {
        let badJSON = """
        { "this": "is not opds2"
        """
        stub(body: badJSON, contentType: "application/opds+json")
        let api = makeAPI(opds2Enabled: true)

        do {
            _ = try await api.fetchFeed(at: topURL)
            XCTFail("Malformed JSON body must NOT be silently converted to OPDS 1")
        } catch let error as OPDSParser.ParserError {
            XCTAssertEqual(error, .invalidJSON,
                           "First-byte `{` must commit to the JSON parser and surface its decode failure")
        } catch {
            // Any other thrown error is also acceptable — the contract is "throw, don't degrade".
        }
    }

    /// Mutant killed: parser routing on Content-Type instead of body bytes.
    /// We send OPDS 1 Atom but tag it as application/opds+json. The parser
    /// must still pick OPDS 1 because the BODY starts with `<`.
    func testFetchFeed_OPDS1AtomBodyTaggedWithOPDS2ContentType_StillFallsBackToOPDS1() async throws {
        stub(body: Self.opds1Body, contentType: "application/opds+json")
        let api = makeAPI(opds2Enabled: true)

        let feed = try await api.fetchFeed(at: topURL)
        let unwrapped = try XCTUnwrap(feed)

        XCTAssertFalse(unwrapped.isOPDS2,
                       "First-byte heuristic must override incorrect Content-Type header in BOTH directions")
        XCTAssertEqual(unwrapped.title, "OPDS1 Fallback Feed")
    }

    // MARK: - Parser-level negotiation seam (no network, just bytes)
    //
    // These pin the format-detection contract DIRECTLY on the parser. Any
    // mutation to the first-byte heuristic must surface here even if the
    // surrounding API code is rewritten.

    /// Mutant killed: flipping `firstChar == "{"` to `firstChar == "<"`
    /// — both arms of the routing decision flipped. JSON would be parsed
    /// as XML and fail.
    func testOPDSFormatDetect_ByFirstByte_JSON_RoutesToOPDS2() {
        XCTAssertEqual(OPDSFormat.detect(from: Data("{".utf8)), .opds2)
        XCTAssertEqual(OPDSFormat.detect(from: Data("[".utf8)), .opds2,
                       "JSON array body MUST also route to OPDS 2")
    }

    /// Mutant killed: dropping the `<` arm of the routing decision so XML
    /// would fall into `.unknown` and trigger the OPDS 1 branch via the
    /// `.unknown` case anyway. We specifically pin that `<` → `.opds1`,
    /// NOT `.unknown`, so a downstream that special-cases `.unknown`
    /// (e.g. an error log) doesn't silently fire.
    func testOPDSFormatDetect_ByFirstByte_XML_RoutesToOPDS1() {
        XCTAssertEqual(OPDSFormat.detect(from: Data("<".utf8)), .opds1)
        XCTAssertEqual(OPDSFormat.detect(from: Data("<?xml".utf8)), .opds1)
    }

    /// Mutant killed: returning `.opds2` for unknown/non-marker bodies —
    /// would force every empty or weird body into the JSON parser and
    /// cause `invalidJSON` throws instead of the existing `invalidXML`
    /// path.
    func testOPDSFormatDetect_NonJSONNonXMLFirstByte_RoutesToUnknown() {
        // Empty data → unknown.
        XCTAssertEqual(OPDSFormat.detect(from: Data()), .unknown)
        // A plain text body starting with a letter is neither JSON nor XML.
        XCTAssertEqual(OPDSFormat.detect(from: Data("plain".utf8)), .unknown)
    }

    // MARK: - End-to-end negotiation through CatalogRepository

    /// Mutant killed: dropping the `isOPDS2` propagation through
    /// CatalogFeed when going OPDS2 → CatalogRepository → consumer. The
    /// negotiation result must SURVIVE the cache layer (cache returns the
    /// same CatalogFeed shape we put in).
    func testRepositoryCache_AfterOPDS2Negotiation_PreservesIsOPDS2Flag() async throws {
        stub(body: Self.opds2Body, contentType: "application/opds+json")
        let api = makeAPI(opds2Enabled: true)
        let repo = CatalogRepository(api: api)

        // First read goes to the network.
        let first = try await repo.loadTopLevelCatalog(at: topURL)
        XCTAssertTrue(first?.isOPDS2 == true,
                      "Initial OPDS 2 fetch must surface isOPDS2 == true")

        // Second read hits the cache. The cached feed must still report OPDS 2.
        let second = try await repo.loadTopLevelCatalog(at: topURL)
        XCTAssertTrue(second?.isOPDS2 == true,
                      "Cache hit must NOT downgrade an OPDS 2 feed to OPDS 1")
        XCTAssertEqual(networkClient.sendCallCount, 1,
                       "Cache hit must not re-fetch")
    }

    /// Mutant killed: dropping the OPDS 1 fallback isOPDS2=false propagation
    /// through the cache. A cached OPDS 1 fallback must NEVER be tagged
    /// as OPDS 2 on subsequent reads.
    func testRepositoryCache_AfterOPDS1FallbackNegotiation_PreservesIsOPDS2False() async throws {
        stub(body: Self.opds1Body, contentType: "application/atom+xml")
        let api = makeAPI(opds2Enabled: true)
        let repo = CatalogRepository(api: api)

        let first = try await repo.loadTopLevelCatalog(at: topURL)
        XCTAssertFalse(first?.isOPDS2 ?? true,
                       "Initial OPDS 1 fallback must surface isOPDS2 == false")

        let second = try await repo.loadTopLevelCatalog(at: topURL)
        XCTAssertFalse(second?.isOPDS2 ?? true,
                       "Cache hit must NOT promote an OPDS 1 fallback to OPDS 2")
        XCTAssertEqual(networkClient.sendCallCount, 1)
    }
}
