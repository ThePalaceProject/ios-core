//
//  CatalogAccessibilityTests.swift
//  PalaceTests
//
//  Tests for VoiceOver accessibility in catalog-related UI elements.
//  Verifies lane navigation and filter controls have proper labels.
//  ()
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class CatalogAccessibilityTests: XCTestCase {
  
  // MARK: - Lane "More" Button Tests
  
  /// Verifies "More books in lane" label includes lane title
  func testMoreBooksInLaneLabel_includesLaneTitle() {
    let testLanes = ["Mystery", "Romance", "Science Fiction", "New Releases", "Staff Picks"]
    
    for laneTitle in testLanes {
      let label = makeMoreBooksLabel(forLane: laneTitle)
      XCTAssertTrue(
        label.contains(laneTitle),
        "More books label should include lane title '\(laneTitle)'"
      )
    }
  }
  
  /// Verifies "More books" label indicates navigation action
  func testMoreBooksLabel_indicatesNavigation() {
    let label = makeMoreBooksLabel(forLane: "Test")
    let lowercased = label.lowercased()
    
    XCTAssertTrue(
      lowercased.contains("more") || lowercased.contains("see") || lowercased.contains("view") || lowercased.contains("browse"),
      "More books label should indicate navigation to see more"
    )
  }
  
  /// Verifies different lane titles produce different labels
  func testMoreBooksLabel_differsForDifferentLanes() {
    let label1 = makeMoreBooksLabel(forLane: "Mystery")
    let label2 = makeMoreBooksLabel(forLane: "Romance")
    
    XCTAssertNotEqual(label1, label2, "Labels for different lanes should be different")
  }
  
  // MARK: - Expand/Collapse Section Tests
  
  /// Verifies expand section label is descriptive
  func testExpandSectionLabel_isDescriptive() {
    let label = Strings.Generic.expandSection
    
    XCTAssertFalse(label.isEmpty, "Expand section label should not be empty")
    let lowercased = label.lowercased()
    XCTAssertTrue(
      lowercased.contains("expand") || lowercased.contains("show") || lowercased.contains("open"),
      "Expand label should indicate expansion action"
    )
  }
  
  /// Verifies collapse section label is descriptive
  func testCollapseSectionLabel_isDescriptive() {
    let label = Strings.Generic.collapseSection
    
    XCTAssertFalse(label.isEmpty, "Collapse section label should not be empty")
    let lowercased = label.lowercased()
    XCTAssertTrue(
      lowercased.contains("collapse") || lowercased.contains("hide") || lowercased.contains("close"),
      "Collapse label should indicate collapsing action"
    )
  }
  
  /// Verifies expand and collapse labels are different
  func testExpandCollapseLabels_areDifferent() {
    let expandLabel = Strings.Generic.expandSection
    let collapseLabel = Strings.Generic.collapseSection
    
    XCTAssertNotEqual(
      expandLabel,
      collapseLabel,
      "Expand and collapse labels should be different to indicate state"
    )
  }
  
  /// Verifies expand/collapse label changes based on state
  func testExpandCollapseLabel_changesWithState() {
    // Simulate what CatalogFiltersSheetView does
    let isExpanded = true
    let labelWhenExpanded = isExpanded ? Strings.Generic.collapseSection : Strings.Generic.expandSection
    
    let isCollapsed = false
    let labelWhenCollapsed = isCollapsed ? Strings.Generic.collapseSection : Strings.Generic.expandSection
    
    XCTAssertNotEqual(
      labelWhenExpanded,
      labelWhenCollapsed,
      "Label should change based on expanded state"
    )
    XCTAssertEqual(labelWhenExpanded, Strings.Generic.collapseSection)
    XCTAssertEqual(labelWhenCollapsed, Strings.Generic.expandSection)
  }
  
  // MARK: - Library Switch Button Tests
  
  /// Verifies switch library label is descriptive
  func testSwitchLibraryLabel_isDescriptive() {
    let label = Strings.Generic.switchLibrary
    
    XCTAssertFalse(label.isEmpty, "Switch library label should not be empty")
    let lowercased = label.lowercased()
    XCTAssertTrue(
      lowercased.contains("library") || lowercased.contains("account"),
      "Switch library label should mention library"
    )
    XCTAssertTrue(
      lowercased.contains("switch") || lowercased.contains("change") || lowercased.contains("select"),
      "Switch library label should indicate switching action"
    )
  }
  
  // MARK: - Helper Methods
  
  /// Replicates the "More books in lane" label logic from CatalogLaneRowView
  private func makeMoreBooksLabel(forLane laneTitle: String) -> String {
    return String(format: Strings.Generic.moreBooksInLane, laneTitle)
  }
}
