//
//  PDFSearchEmptyStateTests.swift
//  PalaceTests
//
//  PP-4747: pins when the PDF search screen shows its ContentUnavailableView
//  "no results" state. It must only appear for a committed query (>= 3 chars,
//  matching SearchDelegate's own search threshold) that returned nothing — so
//  the screen never flashes "No Results" before the patron has typed enough.
//

import XCTest
@testable import Palace

@MainActor
final class PDFSearchEmptyStateTests: XCTestCase {

  func testShowsNoResults_committedQueryWithZeroMatches_showsEmptyState() {
    XCTAssertTrue(TPPPDFSearchView.showsNoResults(searchText: "zebra", resultCount: 0))
  }

  func testShowsNoResults_committedQueryWithMatches_hidesEmptyState() {
    XCTAssertFalse(TPPPDFSearchView.showsNoResults(searchText: "zebra", resultCount: 3))
  }

  func testShowsNoResults_shortQuery_neverShowsEmptyState() {
    // Below the 3-char search threshold no search has run, so an empty
    // result set is "not searched yet", not "no results".
    XCTAssertFalse(TPPPDFSearchView.showsNoResults(searchText: "ab", resultCount: 0))
    XCTAssertFalse(TPPPDFSearchView.showsNoResults(searchText: "", resultCount: 0))
  }

  func testShowsNoResults_thresholdBoundary_isThreeChars() {
    XCTAssertTrue(TPPPDFSearchView.showsNoResults(searchText: "abc", resultCount: 0),
                  "Exactly 3 chars is the committed-query boundary and must match SearchDelegate.search.")
  }
}
