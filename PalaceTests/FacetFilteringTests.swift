import XCTest
@testable import Palace

// MARK: - FacetFilteringTests

final class FacetFilteringTests: XCTestCase {
  struct MockNetworkClient: NetworkClient {
    let dataForURL: [String: Data]
    func send(_ request: NetworkRequest) async throws -> NetworkResponse {
      guard let data = dataForURL[request.url.absoluteString] else {
        throw NSError(domain: NSURLErrorDomain, code: NSURLErrorFileDoesNotExist)
      }
      let response = HTTPURLResponse(url: request.url, statusCode: 200, httpVersion: nil, headerFields: nil)!
      return NetworkResponse(data: data, response: response)
    }
  }

  func testFacetApplicationChangesActiveFacetsAndEntries() async throws {
    // Given a top-level feed and a filtered feed
    let topURL = URL(string: "https://example.org/feed")!
    let filteredURL = URL(string: "https://example.org/feed?available=now")!

    let topXML = TestResources.topLevelWithFacetXML(activeFacetHref: filteredURL.absoluteString)
    let filteredXML = TestResources.filteredFacetXML()

    let mock = MockNetworkClient(dataForURL: [
      topURL.absoluteString: topXML.data(using: .utf8)!,
      filteredURL.absoluteString: filteredXML.data(using: .utf8)!
    ])

    let api = DefaultCatalogAPI(client: mock, parser: OPDSParser())

    // When fetch top-level
    let top = try await api.fetchFeed(at: topURL)
    XCTAssertNotNil(top)
    guard let objcFeed = top?.opdsFeed else {
      return XCTFail("missing opds feed")
    }
    let ungrouped = TPPCatalogUngroupedFeed(opdsFeed: objcFeed)!
    let groups = (ungrouped.facetGroups as? [TPPCatalogFacetGroup]) ?? []
    XCTAssertFalse(groups.isEmpty)

    // Find the active facet
    let active = groups.flatMap { $0.facets as? [TPPCatalogFacet] ?? [] }.first(where: { $0.active })
    XCTAssertNotNil(active)
    XCTAssertEqual(active?.href?.absoluteString, filteredURL.absoluteString)

    // When apply the active facet
    let filtered = try await api.fetchFeed(at: filteredURL)
    XCTAssertNotNil(filtered)
    // Then entries and facets are updated
    if let entries = filtered?.opdsFeed.entries as? [TPPOPDSEntry] {
      XCTAssertGreaterThan(entries.count, 0)
    }
  }
}

// MARK: - TestResources

private enum TestResources {
  static func topLevelWithFacetXML(activeFacetHref: String) -> String {
    """
    <?xml version="1.0" encoding="utf-8"?>
    <feed xmlns="http://www.w3.org/2005/Atom">
      <title>Test</title>
      <entry>
        <title>Book A</title>
      </entry>
      <link rel="http://opds-spec.org/facet" title="Available Now" href="\(activeFacetHref)" />
    </feed>
    """
  }

  static func filteredFacetXML() -> String {
    """
    <?xml version="1.0" encoding="utf-8"?>
    <feed xmlns="http://www.w3.org/2005/Atom">
      <title>Filtered</title>
      <entry>
        <title>Book B</title>
      </entry>
    </feed>
    """
  }
}
