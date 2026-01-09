//
//  PDFViewsSnapshotTests.swift
//  PalaceTests
//
//  Snapshot tests for PDF reader UI components.
//

import XCTest
import SwiftUI
import SnapshotTesting
@testable import Palace

@MainActor
final class PDFViewsSnapshotTests: XCTestCase {
  
  // MARK: - TPPPDFPreviewThumbnail Tests
  
  func testPDFPreviewThumbnail_defaultSize() {
    let mockDocument = MockPDFDocument(pageCount: 10)
    let size = CGSize(width: 60, height: 80)
    
    let view = TPPPDFPreviewThumbnail(document: mockDocument, index: 0, size: size)
      .frame(width: size.width, height: size.height)
      .padding()
      .background(Color(UIColor.systemBackground))
    
    assertFixedSizeSnapshot(of: view, width: 100, height: 120)
  }
  
  func testPDFPreviewThumbnail_largerSize() {
    let mockDocument = MockPDFDocument(pageCount: 10)
    let size = CGSize(width: 90, height: 120)
    
    let view = TPPPDFPreviewThumbnail(document: mockDocument, index: 5, size: size)
      .frame(width: size.width, height: size.height)
      .padding()
      .background(Color(UIColor.systemBackground))
    
    assertFixedSizeSnapshot(of: view, width: 130, height: 160)
  }
  
  func testPDFPreviewThumbnail_smallSize() {
    let mockDocument = MockPDFDocument(pageCount: 10)
    let size = CGSize(width: 18, height: 24)
    
    let view = TPPPDFPreviewThumbnail(document: mockDocument, index: 0, size: size)
      .frame(width: size.width, height: size.height)
      .padding()
      .background(Color(UIColor.systemBackground))
    
    assertFixedSizeSnapshot(of: view, width: 58, height: 64)
  }
  
  // MARK: - TPPPDFPreviewBar Tests
  
  func testPDFPreviewBar_atFirstPage() {
    let mockDocument = MockPDFDocument(pageCount: 20)
    
    let view = TPPPDFPreviewBar(document: mockDocument, currentPage: .constant(0))
      .frame(width: 390, height: 60)
      .background(Color(UIColor.systemBackground))
    
    assertMultiDeviceSnapshot(of: view)
  }
  
  func testPDFPreviewBar_atMiddlePage() {
    let mockDocument = MockPDFDocument(pageCount: 20)
    
    let view = TPPPDFPreviewBar(document: mockDocument, currentPage: .constant(10))
      .frame(width: 390, height: 60)
      .background(Color(UIColor.systemBackground))
    
    assertMultiDeviceSnapshot(of: view)
  }
  
  func testPDFPreviewBar_atLastPage() {
    let mockDocument = MockPDFDocument(pageCount: 20)
    
    let view = TPPPDFPreviewBar(document: mockDocument, currentPage: .constant(19))
      .frame(width: 390, height: 60)
      .background(Color(UIColor.systemBackground))
    
    assertMultiDeviceSnapshot(of: view)
  }
  
  func testPDFPreviewBar_compactWidth() {
    let mockDocument = MockPDFDocument(pageCount: 10)
    
    let view = TPPPDFPreviewBar(document: mockDocument, currentPage: .constant(5))
      .frame(width: 320, height: 60)
      .background(Color(UIColor.systemBackground))
    
    assertFixedSizeSnapshot(of: view, width: 320, height: 60)
  }
  
  // MARK: - TPPPDFNavigation Tests
  
  func testPDFNavigation_readerMode_notBookmarked() {
    let metadata: TPPPDFDocumentMetadata = MockPDFDocumentMetadata(currentPage: 5, bookmarks: [], isBookmarked: false)
    
    let view = TPPPDFNavigation(readerMode: .constant(.reader)) { mode in
      Text("Content for \(String(describing: mode))")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .environmentObject(metadata)
    .frame(width: 390, height: 100)
    .background(Color(UIColor.systemBackground))
    
    assertMultiDeviceSnapshot(of: view)
  }
  
  func testPDFNavigation_readerMode_bookmarked() {
    let metadata: TPPPDFDocumentMetadata = MockPDFDocumentMetadata(currentPage: 5, bookmarks: [5], isBookmarked: true)
    
    let view = TPPPDFNavigation(readerMode: .constant(.reader)) { mode in
      Text("Content for \(String(describing: mode))")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .environmentObject(metadata)
    .frame(width: 390, height: 100)
    .background(Color(UIColor.systemBackground))
    
    assertMultiDeviceSnapshot(of: view)
  }
  
  func testPDFNavigation_previewsMode() {
    let metadata: TPPPDFDocumentMetadata = MockPDFDocumentMetadata(currentPage: 0, bookmarks: [], isBookmarked: false)
    
    let view = TPPPDFNavigation(readerMode: .constant(.previews)) { mode in
      Text("Previews Content")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .environmentObject(metadata)
    .frame(width: 390, height: 100)
    .background(Color(UIColor.systemBackground))
    
    assertMultiDeviceSnapshot(of: view)
  }
  
  func testPDFNavigation_tocMode() {
    let metadata: TPPPDFDocumentMetadata = MockPDFDocumentMetadata(currentPage: 0, bookmarks: [], isBookmarked: false)
    
    let view = TPPPDFNavigation(readerMode: .constant(.toc)) { mode in
      Text("Table of Contents")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .environmentObject(metadata)
    .frame(width: 390, height: 100)
    .background(Color(UIColor.systemBackground))
    
    assertMultiDeviceSnapshot(of: view)
  }
  
  func testPDFNavigation_bookmarksMode() {
    let metadata: TPPPDFDocumentMetadata = MockPDFDocumentMetadata(currentPage: 0, bookmarks: [1, 5, 10], isBookmarked: false)
    
    let view = TPPPDFNavigation(readerMode: .constant(.bookmarks)) { mode in
      Text("Bookmarks List")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .environmentObject(metadata)
    .frame(width: 390, height: 100)
    .background(Color(UIColor.systemBackground))
    
    assertMultiDeviceSnapshot(of: view)
  }
  
  func testPDFNavigation_searchMode() {
    let metadata: TPPPDFDocumentMetadata = MockPDFDocumentMetadata(currentPage: 0, bookmarks: [], isBookmarked: false)
    
    let view = TPPPDFNavigation(readerMode: .constant(.search)) { mode in
      Text("Search Results")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .environmentObject(metadata)
    .frame(width: 390, height: 100)
    .background(Color(UIColor.systemBackground))
    
    assertMultiDeviceSnapshot(of: view)
  }
  
  // MARK: - Dark Mode Tests
  
  func testPDFPreviewThumbnail_darkMode() {
    let mockDocument = MockPDFDocument(pageCount: 10)
    let size = CGSize(width: 60, height: 80)
    
    let view = TPPPDFPreviewThumbnail(document: mockDocument, index: 0, size: size)
      .frame(width: size.width, height: size.height)
      .padding()
      .background(Color(UIColor.systemBackground))
      .environment(\.colorScheme, .dark)
    
    assertFixedSizeSnapshot(of: view, width: 100, height: 120, userInterfaceStyle: .dark)
  }
  
  func testPDFPreviewBar_darkMode() {
    let mockDocument = MockPDFDocument(pageCount: 20)
    
    let view = TPPPDFPreviewBar(document: mockDocument, currentPage: .constant(10))
      .frame(width: 390, height: 60)
      .background(Color(UIColor.systemBackground))
      .environment(\.colorScheme, .dark)
    
    assertFixedSizeSnapshot(of: view, width: 390, height: 60, userInterfaceStyle: .dark)
  }
}
