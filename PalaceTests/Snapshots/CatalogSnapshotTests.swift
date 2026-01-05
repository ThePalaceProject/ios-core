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
  
  private var canRecordSnapshots: Bool {
    #if targetEnvironment(simulator)
    return true
    #else
    return false
    #endif
  }
  
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
    guard canRecordSnapshots else { return }
    
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
    
    assertSnapshot(of: view, as: .image)
  }
  
  func testCatalogLaneRowView_empty() {
    guard canRecordSnapshots else { return }
    
    let view = CatalogLaneRowView(
      title: "Empty Lane",
      books: [],
      moreURL: nil,
      onSelect: { _ in },
      onMoreTapped: nil
    )
    .frame(width: 390, height: 220)
    .background(Color(UIColor.systemBackground))
    
    assertSnapshot(of: view, as: .image)
  }
  
  func testCatalogLaneRowView_loading() {
    guard canRecordSnapshots else { return }
    
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
    
    assertSnapshot(of: view, as: .image)
  }
  
  func testCatalogLaneRowView_noHeader() {
    guard canRecordSnapshots else { return }
    
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
    
    assertSnapshot(of: view, as: .image)
  }
  
  // MARK: - BookImageView
  
  func testBookImageView_epub() {
    guard canRecordSnapshots else { return }
    
    let book = TPPBookMocker.snapshotEPUB()
    let view = BookImageView(book: book, height: 150)
      .frame(width: 100, height: 150)
      .background(Color(UIColor.systemBackground))
    
    assertSnapshot(of: view, as: .image)
  }
  
  func testBookImageView_audiobook() {
    guard canRecordSnapshots else { return }
    
    let book = TPPBookMocker.snapshotAudiobook()
    let view = BookImageView(book: book, height: 150)
      .frame(width: 100, height: 150)
      .background(Color(UIColor.systemBackground))
    
    assertSnapshot(of: view, as: .image)
  }
  
  // MARK: - FacetToolbarView
  
  func testFacetToolbarView_withSort() {
    guard canRecordSnapshots else { return }
    
    let view = FacetToolbarView(
      title: "Fiction",
      showFilter: true,
      onSort: { },
      onFilter: { },
      currentSortTitle: "Author"
    )
    .frame(width: 390, height: 50)
    .background(Color(UIColor.systemBackground))
    
    assertSnapshot(of: view, as: .image)
  }
  
  func testFacetToolbarView_noSort() {
    guard canRecordSnapshots else { return }
    
    let view = FacetToolbarView(
      title: "All Books",
      showFilter: false,
      onSort: nil,
      onFilter: { },
      currentSortTitle: nil
    )
    .frame(width: 390, height: 50)
    .background(Color(UIColor.systemBackground))
    
    assertSnapshot(of: view, as: .image)
  }
  
  // MARK: - CatalogLaneSkeletonView
  
  func testCatalogLaneSkeletonView() {
    guard canRecordSnapshots else { return }
    
    let view = CatalogLaneSkeletonView()
      .frame(width: 390, height: 200)
      .background(Color(UIColor.systemBackground))
    
    assertSnapshot(of: view, as: .image)
  }
  
  // MARK: - Accessibility
  
  func testAccessibilityIdentifiers_exist() {
    XCTAssertFalse(AccessibilityID.Catalog.scrollView.isEmpty)
    XCTAssertFalse(AccessibilityID.Catalog.searchButton.isEmpty)
    XCTAssertFalse(AccessibilityID.Catalog.navigationBar.isEmpty)
  }
}
