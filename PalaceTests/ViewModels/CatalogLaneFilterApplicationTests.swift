//
//  CatalogLaneFilterApplicationTests.swift
//  PalaceTests
//
//  Behavioral tests for CatalogLaneMoreViewModel.applySingleFilters — the
//  sequential facet-chaining path that applies more than one filter group.
//
//  OPDS facets are links, not parameters, so applying N filter groups means N
//  dependent requests: fetch the base feed, locate the chosen facet among its
//  links, fetch that, then locate the next chosen facet among the *resulting*
//  feed's links, and so on. (Android's `FeedFacetOPDS12Composite` does the same
//  walk for the same reason.)
//
//  A filter can therefore drop out mid-walk: the feed we just loaded may not
//  advertise the group the user picked from. When that happens the request the
//  user actually got is narrower than the one they asked for, and
//  `appliedSelections` — which drives the "Filter (N)" badge and the ticks in
//  the sheet — must reflect what was applied, never what was requested.
//

import XCTest
import PalaceCatalog
@testable import Palace

@MainActor
final class CatalogLaneFilterApplicationTests: XCTestCase {

  private let feedURL = URL(string: "https://example.com/lane")!
  private let formatFacetURL = URL(string: "https://example.com/lane?entrypoint=Book")!
  private let languageFacetURL = URL(string: "https://example.com/lane?entrypoint=Book&language=eng")!

  // MARK: - Regression: applied state must describe what was applied

  /// The user picks Format and Language, but the feed only advertises Format.
  /// The Language facet has no link to follow, so it never reaches the server.
  /// The badge must say 1, not 2 — reporting 2 tells the user their results are
  /// narrowed by a filter that was never sent.
  func testApplyFilters_WhenAGroupIsAbsentFromTheFeed_OnlyReportsFiltersThatWereApplied() async {
    let client = NetworkClientMock()
    client.stubOPDSResponse(for: feedURL, xml: ungroupedFeed(facets: [
      ("Format", "Ebook", formatFacetURL.absoluteString, false),
      ("Format", "Audiobook", "https://example.com/lane?entrypoint=Audio", false)
    ]))
    // The Format facet's feed still only advertises Format — no Language group.
    client.stubOPDSResponse(for: formatFacetURL, xml: ungroupedFeed(facets: [
      ("Format", "Ebook", formatFacetURL.absoluteString, true),
      ("Format", "Audiobook", "https://example.com/lane?entrypoint=Audio", false)
    ]))

    let viewModel = makeViewModel(client: client)
    viewModel.pendingSelections = [
      key(group: "Format", title: "Ebook", href: formatFacetURL.absoluteString),
      key(group: "Language", title: "English", href: languageFacetURL.absoluteString)
    ]

    await viewModel.applySingleFilters(coordinator: NavigationCoordinator())

    XCTAssertEqual(
      viewModel.appliedSelections,
      ["Format|Ebook"],
      "Language had no facet link to follow, so it was never applied and must not be reported as applied"
    )
    XCTAssertEqual(
      viewModel.activeFiltersCount, 1,
      "The Filter badge must count filters that reached the server, not filters the user selected"
    )
  }

  /// Every selected filter is unreachable. The results are entirely unfiltered,
  /// so the badge must be absent rather than claiming one filter is active.
  func testApplyFilters_WhenNoSelectedGroupIsInTheFeed_ReportsNoAppliedFilters() async {
    let client = NetworkClientMock()
    client.stubOPDSResponse(for: feedURL, xml: ungroupedFeed(facets: [
      ("Format", "Ebook", formatFacetURL.absoluteString, false)
    ]))

    let viewModel = makeViewModel(client: client)
    viewModel.pendingSelections = [
      key(group: "Language", title: "English", href: languageFacetURL.absoluteString)
    ]

    await viewModel.applySingleFilters(coordinator: NavigationCoordinator())

    XCTAssertTrue(
      viewModel.appliedSelections.isEmpty,
      "No filter reached the server, so nothing may be reported as applied"
    )
    XCTAssertEqual(viewModel.activeFiltersCount, 0)
  }

  // MARK: - Guard: the happy path must keep chaining correctly

  /// Both groups are reachable: Format from the base feed, then Language from
  /// the feed Format returned. Both must be applied, in that order, and both
  /// reported.
  func testApplyFilters_WhenEachGroupIsReachable_ChainsRequestsAndReportsBoth() async {
    let client = NetworkClientMock()
    client.stubOPDSResponse(for: feedURL, xml: ungroupedFeed(facets: [
      ("Format", "Ebook", formatFacetURL.absoluteString, false)
    ]))
    // Following Format yields a feed that now advertises Language too — this is
    // what lets the second filter compose on top of the first.
    client.stubOPDSResponse(for: formatFacetURL, xml: ungroupedFeed(facets: [
      ("Format", "Ebook", formatFacetURL.absoluteString, true),
      ("Language", "English", languageFacetURL.absoluteString, false)
    ]))
    client.stubOPDSResponse(for: languageFacetURL, xml: ungroupedFeed(facets: [
      ("Format", "Ebook", formatFacetURL.absoluteString, true),
      ("Language", "English", languageFacetURL.absoluteString, true)
    ]))

    let viewModel = makeViewModel(client: client)
    viewModel.pendingSelections = [
      key(group: "Format", title: "Ebook", href: formatFacetURL.absoluteString),
      key(group: "Language", title: "English", href: languageFacetURL.absoluteString)
    ]

    await viewModel.applySingleFilters(coordinator: NavigationCoordinator())

    XCTAssertEqual(
      viewModel.appliedSelections,
      ["Format|Ebook", "Language|English"],
      "Both filters were reachable and applied"
    )

    let requested = client.requestHistory.map(\.url)
    XCTAssertTrue(
      requested.contains(formatFacetURL) && requested.contains(languageFacetURL),
      "Both facet feeds must be fetched; got \(requested)"
    )
    XCTAssertLessThan(
      requested.firstIndex(of: formatFacetURL) ?? .max,
      requested.firstIndex(of: languageFacetURL) ?? .min,
      "Language must be resolved from the feed Format returned, so Format is fetched first"
    )
  }

  /// Clearing every filter must reload the unfiltered feed and empty the badge.
  func testApplyFilters_WhenSelectionIsCleared_ResetsAppliedState() async {
    let client = NetworkClientMock()
    client.stubOPDSResponse(for: feedURL, xml: ungroupedFeed(facets: [
      ("Format", "Ebook", formatFacetURL.absoluteString, false)
    ]))

    let viewModel = makeViewModel(client: client)
    viewModel.appliedSelections = ["Format|Ebook"]
    viewModel.pendingSelections = []

    await viewModel.applySingleFilters(coordinator: NavigationCoordinator())

    XCTAssertTrue(viewModel.appliedSelections.isEmpty)
    XCTAssertEqual(viewModel.activeFiltersCount, 0)
  }

  // MARK: - Helpers

  private func makeViewModel(client: NetworkClientMock) -> CatalogLaneMoreViewModel {
    let container = makeTestAppContainer()
    let api = DefaultCatalogAPI(
      client: client,
      parser: OPDSParser(),
      featureFlags: MockFeatureFlagProvider()
    )
    return CatalogLaneMoreViewModel(
      title: "Lane",
      url: feedURL,
      bookRegistry: container.bookRegistry,
      bookCellModelCache: container.bookCellModelCache,
      api: api
    )
  }

  private func key(group: String, title: String, href: String) -> String {
    CatalogFilterService.makeKey(group: group, title: title, hrefString: href)
  }

  /// Facet hrefs carry query strings, so `&` must be escaped exactly as a real
  /// OPDS feed escapes it. An unescaped `&` makes the document malformed and the
  /// feed fails to parse, which looks identical to "the server returned nothing".
  private func xmlEscaped(_ value: String) -> String {
    value
      .replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
      .replacingOccurrences(of: "\"", with: "&quot;")
  }

  /// An ungrouped OPDS acquisition feed (entries carry no `rel="collection"`
  /// link) with the supplied facet links. Ungrouped is what a facet URL returns
  /// in production, and it is the shape the view model re-reads facets from.
  private func ungroupedFeed(facets: [(group: String, title: String, href: String, active: Bool)]) -> String {
    let facetLinks = facets.map { facet in
      let activeAttr = facet.active ? " opds:activeFacet=\"true\"" : ""
      return """
        <link rel="http://opds-spec.org/facet" href="\(xmlEscaped(facet.href))" title="\(xmlEscaped(facet.title))" opds:facetGroup="\(xmlEscaped(facet.group))"\(activeAttr)/>
      """
    }.joined(separator: "\n")

    return """
    <?xml version="1.0" encoding="UTF-8"?>
    <feed xmlns="http://www.w3.org/2005/Atom"
          xmlns:opds="http://opds-spec.org/2010/catalog"
          xmlns:dcterms="http://purl.org/dc/terms/"
          xmlns:schema="http://schema.org/">
      <id>urn:uuid:lane-feed</id>
      <title>Lane</title>
      <updated>2024-01-01T00:00:00Z</updated>
    \(facetLinks)
      <entry>
        <id>urn:uuid:book-1</id>
        <title>Book One</title>
        <updated>2024-01-01T00:00:00Z</updated>
        <link rel="http://opds-spec.org/acquisition/open-access"
              href="https://example.com/books/book-1.epub"
              type="application/epub+zip"/>
      </entry>
    </feed>
    """
  }
}
