//
//  CatalogSnapshotTests.swift
//  PalaceTests
//
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import XCTest
import SwiftUI
import SnapshotTesting
@testable import Palace

@MainActor
final class CatalogSnapshotTests: XCTestCase {
  
  // MARK: - Helpers
  
  private func createMockBooks(count: Int) -> [TPPBook] {
    let allBooks = [
      TPPBookMocker.snapshotEPUB(),
      TPPBookMocker.snapshotAudiobook(),
      TPPBookMocker.snapshotPDF(),
      TPPBookMocker.snapshotHoldBook()
    ]
    return Array(allBooks.prefix(count))
  }
  
  // MARK: - CatalogLaneRowView
  
  func testCatalogLaneRowView_withBooks() {
    let books = createMockBooks(count: 4)
    let view = CatalogLaneRowView(
      title: "Featured Books",
      books: books,
      moreURL: URL(string: "https://example.org/more"),
      onSelect: { _ in },
      onMoreTapped: { _, _ in }
    )
    .frame(width: 390, height: 220)
    .background(Color(UIColor.systemBackground))
    
    assertMultiDeviceSnapshot(of: view)
  }
  
  func testCatalogLaneRowView_empty() {
    let view = CatalogLaneRowView(
      title: "Empty Lane",
      books: [],
      moreURL: nil,
      onSelect: { _ in },
      onMoreTapped: nil
    )
    .frame(width: 390, height: 220)
    .background(Color(UIColor.systemBackground))
    
    assertMultiDeviceSnapshot(of: view)
  }
  
  func testCatalogLaneRowView_loading() {
    let view = CatalogLaneRowView(
      title: "Loading Lane",
      books: [],
      moreURL: nil,
      onSelect: { _ in },
      onMoreTapped: nil,
      isLoading: true
    )
    .frame(width: 390, height: 220)
    .background(Color(UIColor.systemBackground))
    
    assertMultiDeviceSnapshot(of: view)
  }
  
  func testCatalogLaneRowView_noHeader() {
    let books = createMockBooks(count: 3)
    let view = CatalogLaneRowView(
      title: "Hidden Header",
      books: books,
      moreURL: nil,
      onSelect: { _ in },
      onMoreTapped: nil,
      showHeader: false
    )
    .frame(width: 390, height: 180)
    .background(Color(UIColor.systemBackground))
    
    assertMultiDeviceSnapshot(of: view)
  }
  
  // MARK: - BookImageView
  
  func testBookImageView_epub() {
    let book = TPPBookMocker.snapshotEPUB()
    let view = BookImageView(book: book, height: 150)
      .frame(width: 100, height: 150)
      .background(Color(UIColor.systemBackground))
    
    assertFixedSizeSnapshot(of: view, width: 100, height: 150)
  }
  
  func testBookImageView_audiobook() {
    let book = TPPBookMocker.snapshotAudiobook()
    let view = BookImageView(book: book, height: 150)
      .frame(width: 100, height: 150)
      .background(Color(UIColor.systemBackground))
    
    assertFixedSizeSnapshot(of: view, width: 100, height: 150)
  }
  
  // MARK: - FacetToolbarView
  
  func testFacetToolbarView_withSort() {
    let view = FacetToolbarView(
      title: "Fiction",
      showFilter: true,
      onSort: { },
      onFilter: { },
      currentSortTitle: "Author"
    )
    .frame(width: 390, height: 50)
    .background(Color(UIColor.systemBackground))
    
    assertMultiDeviceSnapshot(of: view)
  }
  
  func testFacetToolbarView_noSort() {
    let view = FacetToolbarView(
      title: "All Books",
      showFilter: false,
      onSort: nil,
      onFilter: { },
      currentSortTitle: nil
    )
    .frame(width: 390, height: 50)
    .background(Color(UIColor.systemBackground))
    
    assertMultiDeviceSnapshot(of: view)
  }
  
  // MARK: - CatalogLaneSkeletonView
  
  func testCatalogLaneSkeletonView() {
    let view = CatalogLaneSkeletonView()
      .frame(width: 390, height: 200)
      .background(Color(UIColor.systemBackground))
    
    assertMultiDeviceSnapshot(of: view)
  }
  
  // MARK: - Accessibility
  
  func testAccessibilityIdentifiers_exist() {
    XCTAssertFalse(AccessibilityID.Catalog.scrollView.isEmpty)
    XCTAssertFalse(AccessibilityID.Catalog.searchButton.isEmpty)
    XCTAssertFalse(AccessibilityID.Catalog.navigationBar.isEmpty)
  }
}
