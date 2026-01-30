//
//  PDFDocumentProviding.swift
//  Palace
//
//  Created for testability and dependency injection.
//  Copyright © 2025 The Palace Project. All rights reserved.
//

import UIKit

/// Protocol for PDF document providers, enabling dependency injection for testing.
protocol PDFDocumentProviding: AnyObject {
  /// Total number of pages in the document.
  var pageCount: Int { get }
  
  /// Returns a thumbnail image for the specified page.
  /// - Parameter page: Page number (0-indexed).
  /// - Returns: Rendered thumbnail image, or nil if unavailable.
  func thumbnail(for page: Int) -> UIImage?
  
  /// Returns a cached thumbnail if available, without rendering.
  /// - Parameter page: Page number (0-indexed).
  /// - Returns: Cached thumbnail image, or nil if not cached.
  func cachedThumbnail(for page: Int) -> UIImage?
  
  /// Initiates background thumbnail generation for all pages.
  func makeThumbnails()
}

// MARK: - TPPEncryptedPDFDocument Conformance

extension TPPEncryptedPDFDocument: PDFDocumentProviding {}

