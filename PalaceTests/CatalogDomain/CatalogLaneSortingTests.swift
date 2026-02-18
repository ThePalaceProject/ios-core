//
//  CatalogLaneSortingTests.swift
//  PalaceTests
//
//  Regression tests for PP-3629: Reverse sorting in lanes.
//  Verifies that sort facets (including reverse options) are extracted
//  from grouped OPDS feeds and made available in lane views.
//

import XCTest
@testable import Palace

final class CatalogLaneSortingTests: XCTestCase {
  
  // MARK: - extractFacets Tests
  
  /// PP-3629: Verify extractFacets parses sort facets from an OPDS grouped feed
  /// that includes reverse sort options (e.g., "Title (Z-A)").
  @MainActor
  func testExtractFacets_GroupedFeedWithSortFacets_ExtractsSortGroup() {
    // Arrange — A grouped OPDS feed with sort facets including reverse options
    let xml = makeGroupedFeedWithSortFacets()
    guard let data = xml.data(using: .utf8),
          let tppxml = TPPXML(data: data),
          let feed = TPPOPDSFeed(xml: tppxml) else {
      XCTFail("Failed to parse OPDS XML")
      return
    }
    
    // Act
    let (facetGroups, _) = CatalogViewModel.extractFacets(from: feed)
    
    // Assert — should have a "Sort by" group with 4 sort options
    XCTAssertFalse(facetGroups.isEmpty, "Facet groups should not be empty for a feed with facets")
    
    let sortGroup = facetGroups.first { $0.name.lowercased().contains("sort") }
    XCTAssertNotNil(sortGroup, "Should find a sort facet group")
    XCTAssertEqual(sortGroup?.filters.count, 4, "Should have 4 sort options (2 forward + 2 reverse)")
    
    let titles = sortGroup?.filters.map(\.title) ?? []
    XCTAssertTrue(titles.contains("Title"), "Should include 'Title' sort option")
    XCTAssertTrue(titles.contains("Title (Z-A)"), "Should include reverse 'Title (Z-A)' sort option")
    XCTAssertTrue(titles.contains("Author"), "Should include 'Author' sort option")
    XCTAssertTrue(titles.contains("Author (Z-A)"), "Should include reverse 'Author (Z-A)' sort option")
  }
  
  /// PP-3629: Verify the active facet is correctly identified.
  @MainActor
  func testExtractFacets_ActiveSortFacet_IsMarkedActive() {
    let xml = makeGroupedFeedWithSortFacets(activeSortTitle: "Title")
    guard let data = xml.data(using: .utf8),
          let tppxml = TPPXML(data: data),
          let feed = TPPOPDSFeed(xml: tppxml) else {
      XCTFail("Failed to parse OPDS XML")
      return
    }
    
    let (facetGroups, _) = CatalogViewModel.extractFacets(from: feed)
    let sortGroup = facetGroups.first { $0.name.lowercased().contains("sort") }
    
    let activeFacet = sortGroup?.filters.first { $0.active }
    XCTAssertEqual(activeFacet?.title, "Title", "The 'Title' sort should be marked active")
    
    let inactiveFacets = sortGroup?.filters.filter { !$0.active } ?? []
    XCTAssertEqual(inactiveFacets.count, 3, "Other sort options should be inactive")
  }
  
  // MARK: - CatalogLaneMoreViewModel Tests
  
  /// PP-3629: When a grouped feed has sort facets, CatalogLaneMoreViewModel
  /// should expose them via sortFacets so the sort toolbar appears.
  @MainActor
  func testLaneMoreViewModel_GroupedFeedWithSortFacets_ExposesSortFacets() async {
    // Arrange
    let feedURL = URL(string: "https://example.com/feed")!
    let xml = makeGroupedFeedWithSortFacets()
    
    let networkClient = NetworkClientMock()
    networkClient.stubOPDSResponse(for: feedURL, xml: xml)
    
    let api = DefaultCatalogAPI(client: networkClient, parser: OPDSParser())
    let viewModel = CatalogLaneMoreViewModel(title: "Test", url: feedURL, api: api)
    
    // Act
    await viewModel.fetchAndApplyFeed(at: feedURL)
    
    // Assert — should have lanes (grouped content)
    XCTAssertFalse(viewModel.lanes.isEmpty, "Should have lanes from grouped feed")
    
    // Assert — sort facets should be available
    XCTAssertFalse(viewModel.facetGroups.isEmpty, "Facet groups should be extracted from grouped feed")
    XCTAssertFalse(viewModel.sortFacets.isEmpty, "Sort facets should be available for grouped feed")
    XCTAssertEqual(viewModel.sortFacets.count, 4, "Should expose 4 sort options including reverse")
    
    // Verify reverse options are present
    let sortTitles = viewModel.sortFacets.map(\.title)
    XCTAssertTrue(sortTitles.contains("Title (Z-A)"), "Reverse title sort should be available")
    XCTAssertTrue(sortTitles.contains("Author (Z-A)"), "Reverse author sort should be available")
  }
  
  /// PP-3629: activeSortTitle should return the title of the active sort facet.
  @MainActor
  func testLaneMoreViewModel_ActiveSortTitle_ReturnsActiveFacetTitle() async {
    let feedURL = URL(string: "https://example.com/feed")!
    let xml = makeGroupedFeedWithSortFacets(activeSortTitle: "Author (Z-A)")
    
    let networkClient = NetworkClientMock()
    networkClient.stubOPDSResponse(for: feedURL, xml: xml)
    
    let api = DefaultCatalogAPI(client: networkClient, parser: OPDSParser())
    let viewModel = CatalogLaneMoreViewModel(title: "Test", url: feedURL, api: api)
    
    await viewModel.fetchAndApplyFeed(at: feedURL)
    
    XCTAssertEqual(viewModel.activeSortTitle, "Author (Z-A)",
                   "Active sort title should reflect the active reverse sort facet")
  }
  
  // MARK: - Test Feed Helpers
  
  /// Creates a grouped OPDS feed XML that includes sort facets with reverse options.
  private func makeGroupedFeedWithSortFacets(activeSortTitle: String = "Title") -> String {
    let sortFacets = [
      ("Title", "https://example.com/sort/title", activeSortTitle == "Title"),
      ("Title (Z-A)", "https://example.com/sort/title-desc", activeSortTitle == "Title (Z-A)"),
      ("Author", "https://example.com/sort/author", activeSortTitle == "Author"),
      ("Author (Z-A)", "https://example.com/sort/author-desc", activeSortTitle == "Author (Z-A)")
    ]
    
    let facetLinksXML = sortFacets.map { (title, href, isActive) -> String in
      let activeAttr = isActive ? " opds:activeFacet=\"true\"" : ""
      return """
        <link rel="http://opds-spec.org/facet" href="\(href)" title="\(title)" opds:facetGroup="Sort by"\(activeAttr)/>
      """
    }.joined(separator: "\n")
    
    // Grouped feed: entries have collection links which makes them grouped
    return """
    <?xml version="1.0" encoding="UTF-8"?>
    <feed xmlns="http://www.w3.org/2005/Atom"
          xmlns:opds="http://opds-spec.org/2010/catalog"
          xmlns:dcterms="http://purl.org/dc/terms/"
          xmlns:schema="http://schema.org/">
      <id>urn:uuid:grouped-feed</id>
      <title>Test Grouped Feed</title>
      <updated>2024-01-01T00:00:00Z</updated>
      \(facetLinksXML)
      \(makeGroupedEntry(groupTitle: "Recently Added", bookTitle: "Book One", bookId: "book-1"))
      \(makeGroupedEntry(groupTitle: "Recently Added", bookTitle: "Book Two", bookId: "book-2"))
      \(makeGroupedEntry(groupTitle: "Popular", bookTitle: "Book Three", bookId: "book-3"))
      \(makeGroupedEntry(groupTitle: "Popular", bookTitle: "Book Four", bookId: "book-4"))
    </feed>
    """
  }
  
  /// Creates a single entry belonging to a group (lane) in an OPDS grouped feed.
  private func makeGroupedEntry(groupTitle: String, bookTitle: String, bookId: String) -> String {
    return """
    <entry>
      <id>urn:uuid:\(bookId)</id>
      <title>\(bookTitle)</title>
      <updated>2024-01-01T00:00:00Z</updated>
      <link rel="http://opds-spec.org/acquisition/open-access"
            href="https://example.com/books/\(bookId).epub"
            type="application/epub+zip"/>
      <link rel="collection"
            href="https://example.com/group/\(groupTitle.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? groupTitle)"
            title="\(groupTitle)"/>
    </entry>
    """
  }
}
