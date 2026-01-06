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
  
  private var canRecordSnapshots: Bool {
    #if targetEnvironment(simulator)
    return true
    #else
    return false
    #endif
  }
  
  // MARK: - TPPPDFPreviewThumbnail Tests
  
  func testPDFPreviewThumbnail_defaultSize() {
    guard canRecordSnapshots else { return }
    
    let mockDocument = MockPDFDocument(pageCount: 10)
    let size = CGSize(width: 60, height: 80)
    
    let view = TPPPDFPreviewThumbnail(document: mockDocument, index: 0, size: size)
      .frame(width: size.width, height: size.height)
      .padding()
      .background(Color(UIColor.systemBackground))
    
    assertSnapshot(of: view, as: .image)
  }
  
  func testPDFPreviewThumbnail_largerSize() {
    guard canRecordSnapshots else { return }
    
    let mockDocument = MockPDFDocument(pageCount: 10)
    let size = CGSize(width: 90, height: 120)
    
    let view = TPPPDFPreviewThumbnail(document: mockDocument, index: 5, size: size)
      .frame(width: size.width, height: size.height)
      .padding()
      .background(Color(UIColor.systemBackground))
    
    assertSnapshot(of: view, as: .image)
  }
  
  func testPDFPreviewThumbnail_smallSize() {
    guard canRecordSnapshots else { return }
    
    let mockDocument = MockPDFDocument(pageCount: 10)
    let size = CGSize(width: 18, height: 24)
    
    let view = TPPPDFPreviewThumbnail(document: mockDocument, index: 0, size: size)
      .frame(width: size.width, height: size.height)
      .padding()
      .background(Color(UIColor.systemBackground))
    
    assertSnapshot(of: view, as: .image)
  }
  
  // MARK: - TPPPDFPreviewBar Tests
  
  func testPDFPreviewBar_atFirstPage() {
    guard canRecordSnapshots else { return }
    
    let mockDocument = MockPDFDocument(pageCount: 20)
    
    let view = TPPPDFPreviewBar(document: mockDocument, currentPage: .constant(0))
      .frame(width: 390, height: 60)
      .background(Color(UIColor.systemBackground))
    
    assertSnapshot(of: view, as: .image)
  }
  
  func testPDFPreviewBar_atMiddlePage() {
    guard canRecordSnapshots else { return }
    
    let mockDocument = MockPDFDocument(pageCount: 20)
    
    let view = TPPPDFPreviewBar(document: mockDocument, currentPage: .constant(10))
      .frame(width: 390, height: 60)
      .background(Color(UIColor.systemBackground))
    
    assertSnapshot(of: view, as: .image)
  }
  
  func testPDFPreviewBar_atLastPage() {
    guard canRecordSnapshots else { return }
    
    let mockDocument = MockPDFDocument(pageCount: 20)
    
    let view = TPPPDFPreviewBar(document: mockDocument, currentPage: .constant(19))
      .frame(width: 390, height: 60)
      .background(Color(UIColor.systemBackground))
    
    assertSnapshot(of: view, as: .image)
  }
  
  func testPDFPreviewBar_compactWidth() {
    guard canRecordSnapshots else { return }
    
    let mockDocument = MockPDFDocument(pageCount: 10)
    
    let view = TPPPDFPreviewBar(document: mockDocument, currentPage: .constant(5))
      .frame(width: 320, height: 60)
      .background(Color(UIColor.systemBackground))
    
    assertSnapshot(of: view, as: .image)
  }
  
  // MARK: - TPPPDFNavigation Tests
  
  func testPDFNavigation_readerMode_notBookmarked() {
    guard canRecordSnapshots else { return }
    
    let metadata = MockPDFDocumentMetadata(currentPage: 5, bookmarks: [], isBookmarked: false)
    
    let view = TPPPDFNavigation(readerMode: .constant(.reader)) { mode in
      Text("Content for \(String(describing: mode))")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .environmentObject(metadata)
    .frame(width: 390, height: 100)
    .background(Color(UIColor.systemBackground))
    
    assertSnapshot(of: view, as: .image)
  }
  
  func testPDFNavigation_readerMode_bookmarked() {
    guard canRecordSnapshots else { return }
    
    let metadata = MockPDFDocumentMetadata(currentPage: 5, bookmarks: [5], isBookmarked: true)
    
    let view = TPPPDFNavigation(readerMode: .constant(.reader)) { mode in
      Text("Content for \(String(describing: mode))")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .environmentObject(metadata)
    .frame(width: 390, height: 100)
    .background(Color(UIColor.systemBackground))
    
    assertSnapshot(of: view, as: .image)
  }
  
  func testPDFNavigation_previewsMode() {
    guard canRecordSnapshots else { return }
    
    let metadata = MockPDFDocumentMetadata(currentPage: 0, bookmarks: [], isBookmarked: false)
    
    let view = TPPPDFNavigation(readerMode: .constant(.previews)) { mode in
      Text("Previews Content")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .environmentObject(metadata)
    .frame(width: 390, height: 100)
    .background(Color(UIColor.systemBackground))
    
    assertSnapshot(of: view, as: .image)
  }
  
  func testPDFNavigation_tocMode() {
    guard canRecordSnapshots else { return }
    
    let metadata = MockPDFDocumentMetadata(currentPage: 0, bookmarks: [], isBookmarked: false)
    
    let view = TPPPDFNavigation(readerMode: .constant(.toc)) { mode in
      Text("Table of Contents")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .environmentObject(metadata)
    .frame(width: 390, height: 100)
    .background(Color(UIColor.systemBackground))
    
    assertSnapshot(of: view, as: .image)
  }
  
  func testPDFNavigation_bookmarksMode() {
    guard canRecordSnapshots else { return }
    
    let metadata = MockPDFDocumentMetadata(currentPage: 0, bookmarks: [1, 5, 10], isBookmarked: false)
    
    let view = TPPPDFNavigation(readerMode: .constant(.bookmarks)) { mode in
      Text("Bookmarks List")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .environmentObject(metadata)
    .frame(width: 390, height: 100)
    .background(Color(UIColor.systemBackground))
    
    assertSnapshot(of: view, as: .image)
  }
  
  func testPDFNavigation_searchMode() {
    guard canRecordSnapshots else { return }
    
    let metadata = MockPDFDocumentMetadata(currentPage: 0, bookmarks: [], isBookmarked: false)
    
    let view = TPPPDFNavigation(readerMode: .constant(.search)) { mode in
      Text("Search Results")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .environmentObject(metadata)
    .frame(width: 390, height: 100)
    .background(Color(UIColor.systemBackground))
    
    assertSnapshot(of: view, as: .image)
  }
  
  // MARK: - Dark Mode Tests
  
  func testPDFPreviewThumbnail_darkMode() {
    guard canRecordSnapshots else { return }
    
    let mockDocument = MockPDFDocument(pageCount: 10)
    let size = CGSize(width: 60, height: 80)
    
    let view = TPPPDFPreviewThumbnail(document: mockDocument, index: 0, size: size)
      .frame(width: size.width, height: size.height)
      .padding()
      .background(Color(UIColor.systemBackground))
      .environment(\.colorScheme, .dark)
    
    assertSnapshot(of: view, as: .image)
  }
  
  func testPDFPreviewBar_darkMode() {
    guard canRecordSnapshots else { return }
    
    let mockDocument = MockPDFDocument(pageCount: 20)
    
    let view = TPPPDFPreviewBar(document: mockDocument, currentPage: .constant(10))
      .frame(width: 390, height: 60)
      .background(Color(UIColor.systemBackground))
      .environment(\.colorScheme, .dark)
    
    assertSnapshot(of: view, as: .image)
  }
}

