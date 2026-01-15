//
//  AccessibilityLabelTests.swift
//  PalaceTests
//
//  Tests for VoiceOver accessibility labels throughout the app.
//  Ensures all interactive UI elements have proper accessibility labels
//  for users relying on VoiceOver. (PP-3292)
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class AccessibilityLabelTests: XCTestCase {
  
  // MARK: - Localized Strings Tests
  
  /// Verifies all new accessibility strings are non-empty
  func testAccessibilityStrings_areNotEmpty() {
    // Search Actions
    XCTAssertFalse(Strings.Generic.clearSearch.isEmpty, "clearSearch should not be empty")
    XCTAssertFalse(Strings.Generic.goBack.isEmpty, "goBack should not be empty")
    
    // Sort/Filter
    XCTAssertFalse(Strings.Generic.filter.isEmpty, "filter should not be empty")
    
    // Catalog
    XCTAssertFalse(Strings.Generic.expandSection.isEmpty, "expandSection should not be empty")
    XCTAssertFalse(Strings.Generic.collapseSection.isEmpty, "collapseSection should not be empty")
    
    // Reader Navigation
    XCTAssertFalse(Strings.Generic.tableOfContents.isEmpty, "tableOfContents should not be empty")
    XCTAssertFalse(Strings.Generic.searchInBook.isEmpty, "searchInBook should not be empty")
    XCTAssertFalse(Strings.Generic.pagePreviewsTab.isEmpty, "pagePreviewsTab should not be empty")
    XCTAssertFalse(Strings.Generic.bookmarksTab.isEmpty, "bookmarksTab should not be empty")
    XCTAssertFalse(Strings.Generic.closeSample.isEmpty, "closeSample should not be empty")
    
    // Audiobook
    XCTAssertFalse(Strings.Generic.playAudiobook.isEmpty, "playAudiobook should not be empty")
    XCTAssertFalse(Strings.Generic.pauseAudiobook.isEmpty, "pauseAudiobook should not be empty")
    XCTAssertFalse(Strings.Generic.skipBack30.isEmpty, "skipBack30 should not be empty")
  }
  
  /// Verifies format strings work correctly
  func testAccessibilityStrings_formatStringsWork() {
    // Sort by format
    let sortLabel = String(format: Strings.Generic.sortByFormat, "Title")
    XCTAssertTrue(sortLabel.contains("Title"), "Sort label should contain the sort option")
    
    // Filter with count
    let filterLabel = String(format: Strings.Generic.filterWithCount, 3)
    XCTAssertTrue(filterLabel.contains("3"), "Filter label should contain the count")
    
    // More books in lane
    let moreLabel = String(format: Strings.Generic.moreBooksInLane, "Mystery")
    XCTAssertTrue(moreLabel.contains("Mystery"), "More label should contain the lane title")
  }
  
  /// Verifies existing accessibility strings still work
  func testExistingAccessibilityStrings_areNotEmpty() {
    XCTAssertFalse(Strings.Generic.audiobook.isEmpty, "audiobook should not be empty")
    XCTAssertFalse(Strings.Generic.switchLibrary.isEmpty, "switchLibrary should not be empty")
    XCTAssertFalse(Strings.Generic.searchBooks.isEmpty, "searchBooks should not be empty")
    XCTAssertFalse(Strings.Generic.searchCatalog.isEmpty, "searchCatalog should not be empty")
    XCTAssertFalse(Strings.Generic.scanBarcode.isEmpty, "scanBarcode should not be empty")
  }
  
  // MARK: - Dynamic Label Tests
  
  /// Verifies sort button label changes with sort option
  func testSortButtonLabel_changesWithSortOption() {
    let authorLabel = String(format: Strings.Generic.sortByFormat, "Author")
    let titleLabel = String(format: Strings.Generic.sortByFormat, "Title")
    
    XCTAssertNotEqual(authorLabel, titleLabel, "Sort labels should differ based on option")
    XCTAssertTrue(authorLabel.contains("Author"))
    XCTAssertTrue(titleLabel.contains("Title"))
  }
  
  /// Verifies filter button label changes with filter count
  func testFilterButtonLabel_changesWithCount() {
    let noFilterLabel = Strings.Generic.filter
    let withFilterLabel = String(format: Strings.Generic.filterWithCount, 2)
    
    XCTAssertNotEqual(noFilterLabel, withFilterLabel, "Filter labels should differ based on count")
    XCTAssertTrue(withFilterLabel.contains("2"))
  }
  
  /// Verifies expand/collapse labels are different
  func testExpandCollapseLabels_areDifferent() {
    XCTAssertNotEqual(
      Strings.Generic.expandSection,
      Strings.Generic.collapseSection,
      "Expand and collapse labels should be different"
    )
  }
  
  /// Verifies play/pause labels are different
  func testPlayPauseLabels_areDifferent() {
    XCTAssertNotEqual(
      Strings.Generic.playAudiobook,
      Strings.Generic.pauseAudiobook,
      "Play and pause labels should be different"
    )
  }
  
  // MARK: - Reader Accessibility Tests
  
  /// Verifies bookmark accessibility labels from TPPBaseReaderViewController
  func testBookmarkLabels_existAndAreDifferent() {
    let addLabel = Strings.TPPBaseReaderViewController.addBookmark
    let removeLabel = Strings.TPPBaseReaderViewController.removeBookmark
    
    XCTAssertFalse(addLabel.isEmpty, "Add bookmark label should not be empty")
    XCTAssertFalse(removeLabel.isEmpty, "Remove bookmark label should not be empty")
    XCTAssertNotEqual(addLabel, removeLabel, "Add and remove bookmark labels should be different")
  }
  
  /// Verifies chapter navigation labels exist
  func testChapterNavigationLabels_exist() {
    XCTAssertFalse(Strings.TPPBaseReaderViewController.previousChapter.isEmpty)
    XCTAssertFalse(Strings.TPPBaseReaderViewController.nextChapter.isEmpty)
  }
}
