//
//  SearchSnapshotTests.swift
//  PalaceTests
//
//  Visual regression tests for Search functionality.
//  Replaces Appium: Search.feature
//
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import XCTest
import SwiftUI
import SnapshotTesting
@testable import Palace

@MainActor
final class SearchSnapshotTests: XCTestCase {
  
  private var canRecordSnapshots: Bool {
    #if targetEnvironment(simulator)
    return true
    #else
    return false
    #endif
  }
  
  // MARK: - CatalogSearchView Snapshots
  // Uses the REAL CatalogSearchView from the app
  
  func testCatalogSearchView_withBooks() {
    guard canRecordSnapshots else { return }
    
    // Use deterministic snapshot books with TenPrint covers
    let books = [
      TPPBookMocker.snapshotEPUB(),
      TPPBookMocker.snapshotAudiobook(),
      TPPBookMocker.snapshotPDF(),
      TPPBookMocker.snapshotHoldBook()
    ]
    
    // Verify TenPrint covers are pre-loaded
    for book in books {
      XCTAssertNotNil(book.coverImage, "Book '\(book.title)' should have TenPrint cover")
    }
    
    let view = CatalogSearchView(
      books: books,
      onBookSelected: { _ in }
    )
    .frame(width: 390, height: 700)
    .background(Color(UIColor.systemBackground))
    
    assertSnapshot(of: view, as: .image)
  }
  
  func testCatalogSearchView_empty() {
    guard canRecordSnapshots else { return }
    
    let view = CatalogSearchView(
      books: [],
      onBookSelected: { _ in }
    )
    .frame(width: 390, height: 400)
    .background(Color(UIColor.systemBackground))
    
    assertSnapshot(of: view, as: .image)
  }
  
  // MARK: - BookListView Snapshots
  // Uses the REAL BookListView grid
  
  func testBookListView_grid() {
    guard canRecordSnapshots else { return }
    
    let books = [
      TPPBookMocker.snapshotEPUB(),
      TPPBookMocker.snapshotAudiobook()
    ]
    
    let view = BookListView(
      books: books,
      isLoading: .constant(false),
      onSelect: { _ in },
      previewEnabled: false
    )
    .frame(width: 390, height: 500)
    .background(Color(UIColor.systemBackground))
    
    assertSnapshot(of: view, as: .image)
  }
  
  func testBookListView_loading() {
    guard canRecordSnapshots else { return }
    
    let view = BookListView(
      books: [],
      isLoading: .constant(true),
      onSelect: { _ in }
    )
    .frame(width: 390, height: 300)
    .background(Color(UIColor.systemBackground))
    
    assertSnapshot(of: view, as: .image)
  }
  
  // MARK: - Accessibility
  
  func testSearchAccessibilityIdentifiers() {
    XCTAssertFalse(AccessibilityID.Catalog.searchButton.isEmpty)
    XCTAssertFalse(AccessibilityID.Search.searchField.isEmpty)
    XCTAssertFalse(AccessibilityID.Search.clearButton.isEmpty)
    XCTAssertFalse(AccessibilityID.Search.noResultsView.isEmpty)
  }
}
