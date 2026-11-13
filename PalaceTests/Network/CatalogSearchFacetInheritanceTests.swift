//
//  CatalogSearchFacetInheritanceTests.swift
//  PalaceTests
//
//  A search link discovered inside a browsed feed carries that feed's facets.
//  These tests pin which of those facets reach the search request (PP-5391).
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import XCTest
import PalaceNetwork
@testable import PalaceCatalog
@testable import Palace

@MainActor
final class CatalogSearchFacetInheritanceTests: XCTestCase {

    private var networkClient: NetworkClientMock!
    private var parser: OPDSParser!
    private var sut: DefaultCatalogAPI!

    private let browsedFeedURL = URL(string: "https://library.example.com/groups/audiobooks")!

    override func setUp() {
        super.setUp()
        networkClient = NetworkClientMock()
        parser = OPDSParser()
        sut = DefaultCatalogAPI(
            client: networkClient,
            parser: parser,
            featureFlags: MockFeatureFlagProvider(isOPDS2Enabled: true)
        )
    }

    override func tearDown() {
        networkClient = nil
        parser = nil
        sut = nil
        super.tearDown()
    }

    // MARK: - Helpers

    /// Stub the browsed feed so its `rel="search"` link is `searchHref`, and
    /// serve a valid OPDS 2 body for whatever search URL the API then builds.
    private func stubBrowsedFeed(searchHref: String) {
        let feedJSON = """
        {
          "metadata": { "title": "Audiobooks" },
          "links": [
            { "href": "\(browsedFeedURL.absoluteString)", "rel": "self", "type": "application/opds+json" },
            { "href": "\(searchHref)", "rel": "search", "type": "application/opds+json" }
          ]
        }
        """
        networkClient.stubJSONResponse(for: browsedFeedURL, json: feedJSON)
        networkClient.defaultResponse = jsonResponse(
            for: browsedFeedURL,
            json: #"{ "metadata": { "title": "Search Results" }, "publications": [] }"#
        )
    }

    private func jsonResponse(for url: URL, json: String) -> NetworkResponse {
        NetworkResponse(
            data: Data(json.utf8),
            response: HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/opds+json"]
            )!
        )
    }

    /// Query items of the request the API issued after the browsed feed fetch.
    private func issuedSearchQueryItems() throws -> [URLQueryItem] {
        let history = networkClient.requestHistory
        let searchRequest = try XCTUnwrap(
            history.dropFirst().first,
            "Expected a search request after the browsed-feed fetch, got \(history.map(\.url))"
        )
        let comps = try XCTUnwrap(URLComponents(url: searchRequest.url, resolvingAgainstBaseURL: false))
        return comps.queryItems ?? []
    }

    // MARK: - Tests

    /// A patron who sorted a shelf by author and then typed a title did not ask
    /// for an author sort of their search, so `order` must not reach the search.
    func testSearch_whenSearchLinkCarriesBrowseSort_doesNotRankByThatSort() async throws {
        stubBrowsedFeed(
            searchHref: "https://library.example.com/search/?order=author&available=all&distributor=All&collectionName=All"
        )

        _ = try await sut.search(query: "Nona Vincent", baseURL: browsedFeedURL)

        let items = try issuedSearchQueryItems()
        XCTAssertFalse(
            items.contains { $0.name == "order" },
            "Search must not inherit the browse sort; issued \(items)"
        )
        XCTAssertEqual(items.first { $0.name == "q" }?.value, "Nona Vincent")
    }

    /// The scope the patron is standing in — availability, distributor,
    /// collection — is part of what they asked for and must survive.
    func testSearch_whenSearchLinkCarriesScopeFacets_keepsThem() async throws {
        stubBrowsedFeed(
            searchHref: "https://library.example.com/search/?order=author&available=all&distributor=All&collectionName=All"
        )

        _ = try await sut.search(query: "Nona Vincent", baseURL: browsedFeedURL)

        let items = try issuedSearchQueryItems()
        XCTAssertEqual(items.first { $0.name == "available" }?.value, "all")
        XCTAssertEqual(items.first { $0.name == "distributor" }?.value, "All")
        XCTAssertEqual(items.first { $0.name == "collectionName" }?.value, "All")
    }

    /// A search link with no facets gets the query and nothing invented.
    func testSearch_whenSearchLinkHasNoFacets_issuesQueryOnly() async throws {
        stubBrowsedFeed(searchHref: "https://library.example.com/search/")

        _ = try await sut.search(query: "Nona Vincent", baseURL: browsedFeedURL)

        let items = try issuedSearchQueryItems()
        XCTAssertEqual(items.map(\.name), ["q"], "Expected only the query item, got \(items)")
        XCTAssertEqual(items.first?.value, "Nona Vincent")
    }

    /// A feed may repeat a facet; every `order` item has to go, not just the first.
    func testSearch_whenSearchLinkRepeatsBrowseSort_dropsEveryOccurrence() async throws {
        stubBrowsedFeed(searchHref: "https://library.example.com/search/?order=author&order=title&entrypoint=Audio")

        _ = try await sut.search(query: "Nona Vincent", baseURL: browsedFeedURL)

        let items = try issuedSearchQueryItems()
        XCTAssertEqual(items.filter { $0.name == "order" }.count, 0, "issued \(items)")
        XCTAssertEqual(items.first { $0.name == "entrypoint" }?.value, "Audio")
    }
}
