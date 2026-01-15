//
//  ReaderAccessibilityTests.swift
//  PalaceTests
//
//  Tests for VoiceOver accessibility in EPUB and PDF readers.
//  Verifies navigation controls and reader-specific UI have proper labels.
//  (PP-3292)
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class ReaderAccessibilityTests: XCTestCase {
  
  // MARK: - Table of Contents Tests
  
  /// Verifies table of contents label is descriptive
  func testTableOfContentsLabel_isDescriptive() {
    let label = Strings.Generic.tableOfContents
    
    XCTAssertFalse(label.isEmpty, "Table of contents label should not be empty")
    let lowercased = label.lowercased()
    XCTAssertTrue(
      lowercased.contains("contents") || lowercased.contains("toc") || lowercased.contains("chapters"),
      "TOC label should indicate table of contents"
    )
  }
  
  // MARK: - PDF Navigation Picker Tests
  
  /// Verifies all PDF picker segment labels are distinct
  func testPDFPickerSegmentLabels_areDistinct() {
    let previewsLabel = Strings.Generic.pagePreviewsTab
    let tocLabel = Strings.Generic.tableOfContents
    let bookmarksLabel = Strings.Generic.bookmarksTab
    
    XCTAssertNotEqual(previewsLabel, tocLabel, "Previews and TOC labels should differ")
    XCTAssertNotEqual(previewsLabel, bookmarksLabel, "Previews and bookmarks labels should differ")
    XCTAssertNotEqual(tocLabel, bookmarksLabel, "TOC and bookmarks labels should differ")
  }
  
  /// Verifies page previews label is descriptive
  func testPagePreviewsLabel_isDescriptive() {
    let label = Strings.Generic.pagePreviewsTab
    
    XCTAssertFalse(label.isEmpty, "Page previews label should not be empty")
    let lowercased = label.lowercased()
    XCTAssertTrue(
      lowercased.contains("preview") || lowercased.contains("thumbnail") || lowercased.contains("page"),
      "Page previews label should indicate visual previews"
    )
  }
  
  /// Verifies bookmarks tab label is descriptive
  func testBookmarksTabLabel_isDescriptive() {
    let label = Strings.Generic.bookmarksTab
    
    XCTAssertFalse(label.isEmpty, "Bookmarks label should not be empty")
    let lowercased = label.lowercased()
    XCTAssertTrue(
      lowercased.contains("bookmark"),
      "Bookmarks label should contain 'bookmark'"
    )
  }
  
  // MARK: - Sample Preview Tests
  
  /// Verifies close sample label is descriptive
  func testCloseSampleLabel_isDescriptive() {
    let label = Strings.Generic.closeSample
    
    XCTAssertFalse(label.isEmpty, "Close sample label should not be empty")
    let lowercased = label.lowercased()
    XCTAssertTrue(
      lowercased.contains("close") || lowercased.contains("dismiss") || lowercased.contains("exit"),
      "Close sample label should indicate closing action"
    )
  }
  
  // MARK: - Bookmark Toggle Tests
  
  /// Verifies bookmark toggle labels are descriptive and distinct
  func testBookmarkToggleLabels_areDistinctAndDescriptive() {
    let addLabel = Strings.TPPBaseReaderViewController.addBookmark
    let removeLabel = Strings.TPPBaseReaderViewController.removeBookmark
    
    XCTAssertFalse(addLabel.isEmpty, "Add bookmark label should not be empty")
    XCTAssertFalse(removeLabel.isEmpty, "Remove bookmark label should not be empty")
    XCTAssertNotEqual(addLabel, removeLabel, "Add and remove labels should differ")
    
    // Add should indicate adding action
    let addLower = addLabel.lowercased()
    XCTAssertTrue(
      addLower.contains("add") || addLower.contains("create") || addLower.contains("save"),
      "Add bookmark label should indicate adding action"
    )
    
    // Remove should indicate removing action
    let removeLower = removeLabel.lowercased()
    XCTAssertTrue(
      removeLower.contains("remove") || removeLower.contains("delete") || removeLower.contains("clear"),
      "Remove bookmark label should indicate removing action"
    )
  }
  
  // MARK: - Chapter Navigation Tests
  
  /// Verifies chapter navigation labels are distinct
  func testChapterNavigationLabels_areDistinct() {
    let previousLabel = Strings.TPPBaseReaderViewController.previousChapter
    let nextLabel = Strings.TPPBaseReaderViewController.nextChapter
    
    XCTAssertNotEqual(previousLabel, nextLabel, "Previous and next chapter labels should differ")
    
    // Previous should indicate backward navigation
    let prevLower = previousLabel.lowercased()
    XCTAssertTrue(
      prevLower.contains("previous") || prevLower.contains("back") || prevLower.contains("before"),
      "Previous chapter label should indicate backward direction"
    )
    
    // Next should indicate forward navigation
    let nextLower = nextLabel.lowercased()
    XCTAssertTrue(
      nextLower.contains("next") || nextLower.contains("forward") || nextLower.contains("after"),
      "Next chapter label should indicate forward direction"
    )
  }
}
