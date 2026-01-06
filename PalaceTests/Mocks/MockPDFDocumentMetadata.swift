//
//  MockPDFDocumentMetadata.swift
//  PalaceTests
//
//  Mock implementation of TPPPDFDocumentMetadata for snapshot testing.
//

import Foundation
@testable import Palace

/// Mock PDF document metadata for testing PDF views without real book dependencies.
class MockPDFDocumentMetadata: TPPPDFDocumentMetadata {
  
  private var mockIsBookmarked: Bool = false
  private var mockBookmarks: Set<Int> = []
  private var mockCurrentPage: Int = 0
  
  /// Creates a mock metadata instance with controllable test data.
  /// - Parameters:
  ///   - currentPage: Initial current page number.
  ///   - bookmarks: Set of bookmarked page numbers.
  ///   - isBookmarked: Whether the current page is bookmarked.
  convenience init(
    currentPage: Int = 0,
    bookmarks: Set<Int> = [],
    isBookmarked: Bool = false
  ) {
    // Create a minimal mock book for the parent initializer
    let mockBook = TPPBookMocker.mockBook(distributorType: .OpenAccessPDF)
    self.init(with: mockBook)
    
    self.mockCurrentPage = currentPage
    self.mockBookmarks = bookmarks
    self.mockIsBookmarked = isBookmarked
    
    // Override published properties
    self.currentPage = currentPage
    self.bookmarks = bookmarks
  }
  
  /// Sets whether the current page is bookmarked for testing.
  func setIsBookmarked(_ value: Bool) {
    mockIsBookmarked = value
  }
  
  /// Sets the bookmarks for testing.
  func setBookmarks(_ pages: Set<Int>) {
    mockBookmarks = pages
    self.bookmarks = pages
  }
  
  /// Sets the current page for testing.
  override func setCurrentPage(_ page: Int) {
    mockCurrentPage = page
    self.currentPage = page
  }
  
  override func isBookmarked(page: Int? = nil) -> Bool {
    if let page = page {
      return mockBookmarks.contains(page)
    }
    return mockIsBookmarked
  }
  
  override func fetchBookmarks() {
    // No-op for tests - don't make network calls
  }
  
  override func fetchReadingPosition() {
    // No-op for tests - don't make network calls
  }
  
  override func addBookmark(at pageNumber: Int? = nil) {
    let page = pageNumber ?? mockCurrentPage
    mockBookmarks.insert(page)
    self.bookmarks = mockBookmarks
  }
  
  override func removeBookmark(at pageNumber: Int? = nil) {
    let page = pageNumber ?? mockCurrentPage
    mockBookmarks.remove(page)
    self.bookmarks = mockBookmarks
  }
}

