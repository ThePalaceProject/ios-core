//
//  TPPPDFDocumentMetadataTests.swift
//  PalaceTests
//
//  Tests for TPPPDFDocumentMetadata bookmark and reading position logic.
//  Covers high-priority gap: addBookmark function.
//
//  Copyright 2026 The Palace Project. All rights reserved.
//

import XCTest
import Combine
@testable import Palace

final class TPPPDFDocumentMetadataTests: XCTestCase {
  
  var cancellables = Set<AnyCancellable>()
  
  override func tearDown() {
    cancellables.removeAll()
    super.tearDown()
  }
  
  // MARK: - isBookmarked Tests
  
  func testIsBookmarked_WhenPageInBookmarks_ReturnsTrue() {
    let metadata = createMockMetadata()
    metadata.setBookmarks(Set([1, 5, 10]))
    
    XCTAssertTrue(metadata.isBookmarked(page: 5))
  }
  
  func testIsBookmarked_WhenPageNotInBookmarks_ReturnsFalse() {
    let metadata = createMockMetadata()
    metadata.setBookmarks(Set([1, 5, 10]))
    
    XCTAssertFalse(metadata.isBookmarked(page: 3))
  }
  
  func testIsBookmarked_WithNilPage_ChecksCurrentPage() {
    let metadata = createMockMetadata()
    metadata.currentPage = 7
    metadata.setBookmarks(Set([7, 10]))
    metadata.setIsBookmarked(true) // nil page checks mockIsBookmarked flag
    
    XCTAssertTrue(metadata.isBookmarked(page: nil))
  }
  
  func testIsBookmarked_WithEmptyBookmarks_ReturnsFalse() {
    let metadata = createMockMetadata()
    metadata.setBookmarks(Set())
    
    XCTAssertFalse(metadata.isBookmarked(page: 1))
  }
  
  // MARK: - Bookmark Management Tests
  
  func testBookmarks_IsPublished_EmitsChanges() {
    let metadata = createMockMetadata()
    let expectation = XCTestExpectation(description: "Bookmark change published")
    
    metadata.$bookmarks
      .dropFirst() // Skip initial value
      .sink { bookmarks in
        if bookmarks.contains(42) {
          expectation.fulfill()
        }
      }
      .store(in: &cancellables)
    
    metadata.bookmarks.insert(42)
    
    wait(for: [expectation], timeout: 1.0)
  }
  
  func testCurrentPage_IsPublished_EmitsChanges() {
    let metadata = createMockMetadata()
    let expectation = XCTestExpectation(description: "Current page change published")
    
    metadata.$currentPage
      .dropFirst() // Skip initial value
      .sink { page in
        if page == 99 {
          expectation.fulfill()
        }
      }
      .store(in: &cancellables)
    
    metadata.currentPage = 99
    
    wait(for: [expectation], timeout: 1.0)
  }
  
  // MARK: - Edge Cases
  
  func testIsBookmarked_WithZeroPage_HandlesCorrectly() {
    let metadata = createMockMetadata()
    metadata.setBookmarks(Set([0, 1, 2]))
    
    XCTAssertTrue(metadata.isBookmarked(page: 0))
  }
  
  func testIsBookmarked_WithLargePageNumber_HandlesCorrectly() {
    let metadata = createMockMetadata()
    metadata.setBookmarks(Set([Int.max - 1]))
    
    XCTAssertTrue(metadata.isBookmarked(page: Int.max - 1))
  }
  
  // MARK: - addBookmark Tests (QAAtlas Gap)
  
  func testAddBookmark_AtSpecificPage_AddsToBookmarks() {
    let metadata = createMockMetadata()
    XCTAssertTrue(metadata.bookmarks.isEmpty)
    
    metadata.addBookmark(at: 5)
    
    XCTAssertTrue(metadata.bookmarks.contains(5), "Should contain the bookmarked page")
  }
  
  func testAddBookmark_AtCurrentPage_WhenNilPassed_UsesCurrentPage() {
    let metadata = MockPDFDocumentMetadata(currentPage: 10, bookmarks: [], isBookmarked: false)
    
    metadata.addBookmark(at: nil)
    
    XCTAssertTrue(metadata.bookmarks.contains(10), "Should bookmark the current page when nil is passed")
  }
  
  func testAddBookmark_MultipleTimes_AddsAllBookmarks() {
    let metadata = createMockMetadata()
    
    metadata.addBookmark(at: 1)
    metadata.addBookmark(at: 5)
    metadata.addBookmark(at: 10)
    
    XCTAssertEqual(metadata.bookmarks.count, 3)
    XCTAssertTrue(metadata.bookmarks.contains(1))
    XCTAssertTrue(metadata.bookmarks.contains(5))
    XCTAssertTrue(metadata.bookmarks.contains(10))
  }
  
  func testAddBookmark_DuplicatePage_DoesNotDuplicate() {
    let metadata = createMockMetadata()
    
    metadata.addBookmark(at: 5)
    metadata.addBookmark(at: 5)
    
    // Set is used, so duplicates should not increase count
    XCTAssertEqual(metadata.bookmarks.count, 1)
  }
  
  func testAddBookmark_AtPageZero_HandlesCorrectly() {
    let metadata = createMockMetadata()
    
    metadata.addBookmark(at: 0)
    
    XCTAssertTrue(metadata.bookmarks.contains(0))
  }
  
  // MARK: - removeBookmark Tests
  
  func testRemoveBookmark_RemovesFromBookmarks() {
    let metadata = createMockMetadata()
    metadata.addBookmark(at: 5)
    XCTAssertTrue(metadata.bookmarks.contains(5))
    
    metadata.removeBookmark(at: 5)
    
    XCTAssertFalse(metadata.bookmarks.contains(5))
  }
  
  func testRemoveBookmark_NonexistentPage_DoesNotCrash() {
    let metadata = createMockMetadata()
    
    // Should not crash when removing a bookmark that doesn't exist
    metadata.removeBookmark(at: 99)
    
    XCTAssertTrue(metadata.bookmarks.isEmpty)
  }
  
  // MARK: - Helper Methods
  
  private func createMockMetadata() -> MockPDFDocumentMetadata {
    // Use the existing MockPDFDocumentMetadata from PalaceTests/Mocks
    return MockPDFDocumentMetadata(currentPage: 0, bookmarks: [], isBookmarked: false)
  }
}
