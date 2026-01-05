//
//  CatalogSnapshotTests.swift
//  PalaceTests
//
//  Visual regression tests for Catalog views.
//  These tests snapshot REAL app views to detect unintended visual changes.
//
//  NOTE: E2E user flows (navigation, search, filtering) are tested in mobile-integration-tests-new.
//  These tests focus on component rendering and state visualization.
//
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import XCTest
import SwiftUI
import SnapshotTesting
@testable import Palace

/// Visual regression tests for Catalog UI components.
/// Run on simulator to record/compare snapshots.
@MainActor
final class CatalogSnapshotTests: XCTestCase {
  
  // MARK: - Configuration
  
  private var canRecordSnapshots: Bool {
    #if targetEnvironment(simulator)
    return true
    #else
    return false
    #endif
  }
  
  override func setUp() {
    super.setUp()
    // Set to true to record new reference snapshots
    // isRecording = true
  }
  
  // MARK: - Helper Methods
  // Use deterministic mocks with pre-loaded TenPrint covers
  
  /// Returns a fixed set of deterministic books with TenPrint covers for lane/grid snapshots
  private func createMockBooks(count: Int) -> [TPPBook] {
    let allBooks = [
      TPPBookMocker.snapshotEPUB(),
      TPPBookMocker.snapshotAudiobook(),
      TPPBookMocker.snapshotPDF(),
      TPPBookMocker.snapshotHoldBook()
    ]
    let books = Array(allBooks.prefix(count))
    
    // Verify all books have TenPrint covers pre-loaded
    for book in books {
      assert(book.coverImage != nil, "Book '\(book.title)' missing TenPrint cover")
    }
    
    return books
  }
  
  // MARK: - CatalogLaneRowView Visual Snapshots
  // Uses the REAL CatalogLaneRowView with TenPrint covers
  
  func testCatalogLaneRowView_withBooks() {
    guard canRecordSnapshots else { return }
    
    let books = createMockBooks(count: 4)
    
    // Verify TenPrint covers are pre-loaded
    for book in books {
      XCTAssertNotNil(book.coverImage, "Book '\(book.title)' should have TenPrint cover")
      XCTAssertNotNil(book.thumbnailImage, "Book '\(book.title)' should have thumbnail")
    }
    
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
  
  // MARK: - BookImageView Visual Snapshots
  // Uses the REAL BookImageView with deterministic data
  
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
  
  // MARK: - FacetToolbarView Visual Snapshots
  
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
  
  // MARK: - CatalogLaneSkeletonView Visual Snapshots
  
  func testCatalogLaneSkeletonView() {
    guard canRecordSnapshots else { return }
    
    let view = CatalogLaneSkeletonView()
      .frame(width: 390, height: 200)
      .background(Color(UIColor.systemBackground))
    
    assertSnapshot(of: view, as: .image)
  }
  
  // MARK: - Accessibility Tests
  
  func testAccessibilityIdentifiers_exist() {
    // Verify critical accessibility identifiers are defined
    XCTAssertFalse(AccessibilityID.Catalog.scrollView.isEmpty)
    XCTAssertFalse(AccessibilityID.Catalog.searchButton.isEmpty)
    XCTAssertFalse(AccessibilityID.Catalog.navigationBar.isEmpty)
  }
}
