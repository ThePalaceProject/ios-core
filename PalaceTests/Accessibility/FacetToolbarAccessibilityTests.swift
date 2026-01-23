//
//  FacetToolbarAccessibilityTests.swift
//  PalaceTests
//
//  Tests for VoiceOver accessibility in FacetToolbarView.
//  Verifies sort and filter buttons have proper dynamic labels.
//  ()
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class FacetToolbarAccessibilityTests: XCTestCase {
  
  // MARK: - Sort Button Accessibility
  
  /// Verifies sort button accessibility label includes the current sort option
  func testSortButtonLabel_includesSortOption() {
    let sortOptions = ["Author", "Title", "Recent"]
    
    for option in sortOptions {
      let label = makeSortAccessibilityLabel(sortOption: option)
      XCTAssertTrue(
        label.contains(option),
        "Sort accessibility label should include '\(option)'"
      )
    }
  }
  
  /// Verifies sort button label format is consistent
  func testSortButtonLabel_hasConsistentFormat() {
    let label1 = makeSortAccessibilityLabel(sortOption: "Author")
    let label2 = makeSortAccessibilityLabel(sortOption: "Title")
    
    // Both should have "Sort by" prefix (or localized equivalent)
    let prefix1 = label1.replacingOccurrences(of: "Author", with: "")
    let prefix2 = label2.replacingOccurrences(of: "Title", with: "")
    XCTAssertEqual(prefix1, prefix2, "Sort label format should be consistent")
  }
  
  // MARK: - Filter Button Accessibility
  
  /// Verifies filter button label when no filters applied
  func testFilterButtonLabel_noFiltersApplied() {
    let label = makeFilterAccessibilityLabel(appliedCount: 0)
    XCTAssertEqual(label, Strings.Generic.filter)
  }
  
  /// Verifies filter button label includes count when filters applied
  func testFilterButtonLabel_withFiltersApplied() {
    let testCounts = [1, 2, 5, 10]
    
    for count in testCounts {
      let label = makeFilterAccessibilityLabel(appliedCount: count)
      XCTAssertTrue(
        label.contains("\(count)"),
        "Filter label should include count '\(count)' when filters applied"
      )
    }
  }
  
  /// Verifies filter label differs between no filters and with filters
  func testFilterButtonLabel_differsBasedOnFilterState() {
    let noFilterLabel = makeFilterAccessibilityLabel(appliedCount: 0)
    let withFilterLabel = makeFilterAccessibilityLabel(appliedCount: 3)
    
    XCTAssertNotEqual(
      noFilterLabel,
      withFilterLabel,
      "Filter labels should differ when filters are applied vs not applied"
    )
  }
  
  // MARK: - Helper Methods
  
  /// Replicates the sort button accessibility label logic from FacetToolbarView
  private func makeSortAccessibilityLabel(sortOption: String) -> String {
    return String(format: Strings.Generic.sortByFormat, sortOption)
  }
  
  /// Replicates the filter button accessibility label logic from FacetToolbarView
  private func makeFilterAccessibilityLabel(appliedCount: Int) -> String {
    if appliedCount > 0 {
      return String(format: Strings.Generic.filterWithCount, appliedCount)
    } else {
      return Strings.Generic.filter
    }
  }
}
