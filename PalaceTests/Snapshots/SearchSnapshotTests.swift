//
//  SearchSnapshotTests.swift
//  PalaceTests
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
  
  // MARK: - CatalogSearchView
  
  func testCatalogSearchView_withBooks() {
    guard canRecordSnapshots else { return }
    
    let books = [
      TPPBookMocker.snapshotEPUB(),
      TPPBookMocker.snapshotAudiobook(),
      TPPBookMocker.snapshotPDF(),
      TPPBookMocker.snapshotHoldBook()
    ]
    
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
  
  // MARK: - BookListView
  
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
