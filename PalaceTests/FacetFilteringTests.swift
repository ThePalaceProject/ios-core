import XCTest
@testable import Palace

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
    guard let objcFeed = top?.opdsFeed else { return XCTFail("missing opds feed") }
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
  
  static func audiobooksOnlyFeedXML() -> String {
    """
    <?xml version="1.0" encoding="utf-8"?>
    <feed xmlns="http://www.w3.org/2005/Atom">
      <title>Audiobooks</title>
      <entry>
        <title>Audiobook 1</title>
        <category term="Audiobooks"/>
      </entry>
      <entry>
        <title>Audiobook 2</title>
        <category term="Audiobooks"/>
      </entry>
    </feed>
    """
  }
  
  static func sortedByAuthorFeedXML() -> String {
    """
    <?xml version="1.0" encoding="utf-8"?>
    <feed xmlns="http://www.w3.org/2005/Atom">
      <title>Sorted by Author</title>
      <entry>
        <title>Book by Alice</title>
        <author><name>Alice Adams</name></author>
      </entry>
      <entry>
        <title>Book by Bob</title>
        <author><name>Bob Brown</name></author>
      </entry>
      <entry>
        <title>Book by Carol</title>
        <author><name>Carol Chen</name></author>
      </entry>
    </feed>
    """
  }
  
  static func sortedByTitleFeedXML() -> String {
    """
    <?xml version="1.0" encoding="utf-8"?>
    <feed xmlns="http://www.w3.org/2005/Atom">
      <title>Sorted by Title</title>
      <entry>
        <title>Alpha Story</title>
      </entry>
      <entry>
        <title>Beta Tales</title>
      </entry>
      <entry>
        <title>Gamma Adventures</title>
      </entry>
    </feed>
    """
  }
  
  static func sortedByRecentlyAddedFeedXML() -> String {
    """
    <?xml version="1.0" encoding="utf-8"?>
    <feed xmlns="http://www.w3.org/2005/Atom">
      <title>Recently Added</title>
      <entry>
        <title>Newest Book</title>
        <updated>2024-12-01T00:00:00Z</updated>
      </entry>
      <entry>
        <title>Second Newest</title>
        <updated>2024-11-15T00:00:00Z</updated>
      </entry>
      <entry>
        <title>Older Book</title>
        <updated>2024-10-01T00:00:00Z</updated>
      </entry>
    </feed>
    """
  }
}

// MARK: - Extended Sorting and Filtering Tests

extension FacetFilteringTests {
  
  func testCatalogFilter_AudiobooksOnly() async throws {
    let feedURL = URL(string: "https://example.org/audiobooks")!
    let feedXML = TestResources.audiobooksOnlyFeedXML()
    
    let mock = MockNetworkClient(dataForURL: [
      feedURL.absoluteString: feedXML.data(using: .utf8)!
    ])
    
    let api = DefaultCatalogAPI(client: mock, parser: OPDSParser())
    let result = try await api.fetchFeed(at: feedURL)
    
    XCTAssertNotNil(result)
    
    if let entries = result?.opdsFeed.entries as? [TPPOPDSEntry] {
      XCTAssertEqual(entries.count, 2, "Should have 2 audiobook entries")
      XCTAssertEqual(entries[0].title, "Audiobook 1")
      XCTAssertEqual(entries[1].title, "Audiobook 2")
    }
  }
  
  func testCatalogSort_ByAuthor() async throws {
    let feedURL = URL(string: "https://example.org/sorted?by=author")!
    let feedXML = TestResources.sortedByAuthorFeedXML()
    
    let mock = MockNetworkClient(dataForURL: [
      feedURL.absoluteString: feedXML.data(using: .utf8)!
    ])
    
    let api = DefaultCatalogAPI(client: mock, parser: OPDSParser())
    let result = try await api.fetchFeed(at: feedURL)
    
    XCTAssertNotNil(result)
    
    if let entries = result?.opdsFeed.entries as? [TPPOPDSEntry] {
      XCTAssertEqual(entries.count, 3, "Should have 3 entries")
      // Verify alphabetical order by author
      XCTAssertEqual(entries[0].title, "Book by Alice")
      XCTAssertEqual(entries[1].title, "Book by Bob")
      XCTAssertEqual(entries[2].title, "Book by Carol")
    }
  }
  
  func testCatalogSort_ByTitle() async throws {
    let feedURL = URL(string: "https://example.org/sorted?by=title")!
    let feedXML = TestResources.sortedByTitleFeedXML()
    
    let mock = MockNetworkClient(dataForURL: [
      feedURL.absoluteString: feedXML.data(using: .utf8)!
    ])
    
    let api = DefaultCatalogAPI(client: mock, parser: OPDSParser())
    let result = try await api.fetchFeed(at: feedURL)
    
    XCTAssertNotNil(result)
    
    if let entries = result?.opdsFeed.entries as? [TPPOPDSEntry] {
      XCTAssertEqual(entries.count, 3, "Should have 3 entries")
      // Verify alphabetical order by title
      XCTAssertEqual(entries[0].title, "Alpha Story")
      XCTAssertEqual(entries[1].title, "Beta Tales")
      XCTAssertEqual(entries[2].title, "Gamma Adventures")
    }
  }
  
  func testCatalogSort_ByRecentlyAdded() async throws {
    let feedURL = URL(string: "https://example.org/sorted?by=added")!
    let feedXML = TestResources.sortedByRecentlyAddedFeedXML()
    
    let mock = MockNetworkClient(dataForURL: [
      feedURL.absoluteString: feedXML.data(using: .utf8)!
    ])
    
    let api = DefaultCatalogAPI(client: mock, parser: OPDSParser())
    let result = try await api.fetchFeed(at: feedURL)
    
    XCTAssertNotNil(result)
    
    if let entries = result?.opdsFeed.entries as? [TPPOPDSEntry] {
      XCTAssertEqual(entries.count, 3, "Should have 3 entries")
      // Verify order by date (newest first)
      XCTAssertEqual(entries[0].title, "Newest Book")
      XCTAssertEqual(entries[1].title, "Second Newest")
      XCTAssertEqual(entries[2].title, "Older Book")
    }
  }
  
  func testCatalogFilter_EmptyResultsHandled() async throws {
    let feedURL = URL(string: "https://example.org/empty")!
    let emptyFeedXML = """
    <?xml version="1.0" encoding="utf-8"?>
    <feed xmlns="http://www.w3.org/2005/Atom">
      <title>Empty Results</title>
    </feed>
    """
    
    let mock = MockNetworkClient(dataForURL: [
      feedURL.absoluteString: emptyFeedXML.data(using: .utf8)!
    ])
    
    let api = DefaultCatalogAPI(client: mock, parser: OPDSParser())
    let result = try await api.fetchFeed(at: feedURL)
    
    XCTAssertNotNil(result)
    
    if let entries = result?.opdsFeed.entries as? [TPPOPDSEntry] {
      XCTAssertEqual(entries.count, 0, "Empty feed should have 0 entries")
    }
  }
}
