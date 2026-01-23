//
//  SearchAccessibilityTests.swift
//  PalaceTests
//
//  Tests for VoiceOver accessibility in search-related UI elements.
//  Verifies clear search buttons and navigation have proper labels.
//  ()
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class SearchAccessibilityTests: XCTestCase {
  
  // MARK: - Clear Search Button Tests
  
  /// Verifies clear search label is descriptive
  func testClearSearchLabel_isDescriptive() {
    let label = Strings.Generic.clearSearch
    
    XCTAssertFalse(label.isEmpty, "Clear search label should not be empty")
    // The label should convey the action (clear/remove) and context (search)
    let lowercased = label.lowercased()
    XCTAssertTrue(
      lowercased.contains("clear") || lowercased.contains("remove") || lowercased.contains("delete"),
      "Clear search label should indicate clearing action"
    )
  }
  
  /// Verifies clear search label is localized
  func testClearSearchLabel_isLocalized() {
    // NSLocalizedString returns the key if not found in localization
    // A properly localized string should not equal its programmatic key
    let label = Strings.Generic.clearSearch
    XCTAssertNotEqual(label, "clearSearch", "Label should be localized, not a raw key")
  }
  
  // MARK: - Back Button Tests
  
  /// Verifies go back label is descriptive
  func testGoBackLabel_isDescriptive() {
    let label = Strings.Generic.goBack
    
    XCTAssertFalse(label.isEmpty, "Go back label should not be empty")
    let lowercased = label.lowercased()
    XCTAssertTrue(
      lowercased.contains("back") || lowercased.contains("return") || lowercased.contains("previous"),
      "Go back label should indicate navigation backward"
    )
  }
  
  // MARK: - Search Navigation Tests
  
  /// Verifies search in book label is descriptive for reader context
  func testSearchInBookLabel_isDescriptive() {
    let label = Strings.Generic.searchInBook
    
    XCTAssertFalse(label.isEmpty, "Search in book label should not be empty")
    let lowercased = label.lowercased()
    XCTAssertTrue(
      lowercased.contains("search"),
      "Search in book label should contain 'search'"
    )
  }
  
  /// Verifies search catalog label exists and differs from search in book
  func testSearchCatalogLabel_differsFromSearchInBook() {
    let catalogLabel = Strings.Generic.searchCatalog
    let bookLabel = Strings.Generic.searchInBook
    
    XCTAssertNotEqual(
      catalogLabel,
      bookLabel,
      "Search catalog and search in book labels should be different for context"
    )
  }
  
  /// Verifies search books label exists (for My Books)
  func testSearchBooksLabel_exists() {
    let label = Strings.Generic.searchBooks
    XCTAssertFalse(label.isEmpty, "Search books label should not be empty")
  }
}
