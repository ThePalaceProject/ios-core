//
//  MockPDFDocument.swift
//  PalaceTests
//
//  Mock implementation of PDFDocumentProviding for snapshot testing.
//

import UIKit
@testable import Palace

/// Mock PDF document for testing PDF views without real PDF data.
class MockPDFDocument: PDFDocumentProviding {
  
  /// Number of pages in the mock document.
  var pageCount: Int
  
  /// Thumbnail image to return for all pages.
  var mockThumbnail: UIImage
  
  /// Whether to return cached thumbnails.
  var hasCachedThumbnails: Bool
  
  /// Creates a mock PDF document with configurable properties.
  /// - Parameters:
  ///   - pageCount: Total number of pages in the document.
  ///   - thumbnail: Thumbnail image to use for all pages (defaults to gray placeholder).
  ///   - hasCachedThumbnails: Whether cachedThumbnail returns the thumbnail.
  init(
    pageCount: Int = 10,
    thumbnail: UIImage? = nil,
    hasCachedThumbnails: Bool = true
  ) {
    self.pageCount = pageCount
    self.mockThumbnail = thumbnail ?? MockPDFDocument.createPlaceholderThumbnail()
    self.hasCachedThumbnails = hasCachedThumbnails
  }
  
  func thumbnail(for page: Int) -> UIImage? {
    guard page >= 0 && page < pageCount else { return nil }
    return mockThumbnail
  }
  
  func cachedThumbnail(for page: Int) -> UIImage? {
    guard hasCachedThumbnails, page >= 0 && page < pageCount else { return nil }
    return mockThumbnail
  }
  
  func makeThumbnails() {
    // No-op for tests
  }
  
  /// Creates a simple gray placeholder thumbnail for testing.
  private static func createPlaceholderThumbnail(size: CGSize = CGSize(width: 60, height: 80)) -> UIImage {
    let renderer = UIGraphicsImageRenderer(size: size)
    return renderer.image { context in
      UIColor.systemGray4.setFill()
      context.fill(CGRect(origin: .zero, size: size))
      
      // Add a simple page number indicator
      UIColor.systemGray2.setFill()
      let rect = CGRect(x: 5, y: 5, width: size.width - 10, height: 3)
      UIBezierPath(roundedRect: rect, cornerRadius: 1).fill()
    }
  }
  
  /// Creates a mock document with numbered page thumbnails for visual distinction.
  static func withNumberedPages(count: Int) -> MockPDFDocument {
    let doc = MockPDFDocument(pageCount: count)
    // Use the default placeholder - numbered pages would require more complex rendering
    return doc
  }
}

