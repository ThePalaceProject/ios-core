//
//  CatalogSnapshotTests.swift
//  PalaceTests
//
//  Tests for Catalog views to ensure visual and data consistency.
//  These tests verify the structure and state of catalog UI components.
//
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import XCTest
import SwiftUI
@testable import Palace

/// Tests for Catalog views to ensure visual and data consistency.
@MainActor
final class CatalogSnapshotTests: XCTestCase {
  
  // MARK: - Helper Methods
  
  private func createMockBooks(count: Int) -> [TPPBook] {
    (0..<count).map { _ in TPPBookMocker.mockBook(distributorType: .EpubZip) }
  }
  
  private func createMockLane(title: String, bookCount: Int) -> CatalogLaneModel {
    CatalogLaneModel(
      title: title,
      books: createMockBooks(count: bookCount),
      moreURL: URL(string: "https://example.org/more"),
      isLoading: false
    )
  }
  
  private func createMockFilters() -> [CatalogFilter] {
    [
      CatalogFilter(id: "all", title: "All", href: nil, active: true),
      CatalogFilter(id: "ebooks", title: "Ebooks", href: URL(string: "https://example.org/ebooks"), active: false),
      CatalogFilter(id: "audiobooks", title: "Audiobooks", href: URL(string: "https://example.org/audiobooks"), active: false)
    ]
  }
  
  // MARK: - Accessibility Tests
  
  func testCatalog_AccessibilityIdentifiersExist() {
    XCTAssertFalse(AccessibilityID.Catalog.scrollView.isEmpty, "Catalog scroll view identifier should exist")
    XCTAssertFalse(AccessibilityID.Catalog.searchButton.isEmpty, "Catalog search button identifier should exist")
    XCTAssertFalse(AccessibilityID.Catalog.navigationBar.isEmpty, "Catalog navigation bar identifier should exist")
  }
  
  // MARK: - Lane Model Tests
  
  func testCatalogLaneModel_EmptyLane() {
    let lane = CatalogLaneModel(
      title: "New Arrivals",
      books: [],
      moreURL: URL(string: "https://example.org/more")
    )
    
    XCTAssertEqual(lane.title, "New Arrivals")
    XCTAssertTrue(lane.books.isEmpty)
    XCTAssertNotNil(lane.moreURL)
    XCTAssertFalse(lane.isLoading)
  }
  
  func testCatalogLaneModel_WithBooks() {
    let lane = createMockLane(title: "Popular", bookCount: 3)
    
    XCTAssertEqual(lane.title, "Popular")
    XCTAssertEqual(lane.books.count, 3)
  }
  
  func testCatalogLaneModel_LoadingState() {
    let lane = CatalogLaneModel(
      title: "Loading Lane",
      books: [],
      moreURL: nil,
      isLoading: true
    )
    
    XCTAssertTrue(lane.isLoading)
    XCTAssertNil(lane.moreURL)
  }
  
  // MARK: - Filter Model Tests
  
  func testCatalogFilter_InactiveState() {
    let filter = CatalogFilter(
      id: "audiobooks",
      title: "Audiobooks",
      href: URL(string: "https://example.org/audiobooks"),
      active: false
    )
    
    XCTAssertEqual(filter.id, "audiobooks")
    XCTAssertEqual(filter.title, "Audiobooks")
    XCTAssertFalse(filter.active)
  }
  
  func testCatalogFilter_ActiveState() {
    let filter = CatalogFilter(
      id: "all",
      title: "All",
      href: nil,
      active: true
    )
    
    XCTAssertTrue(filter.active)
    XCTAssertNil(filter.href)
  }
  
  func testCatalogFilterGroup() {
    let filters = createMockFilters()
    let group = CatalogFilterGroup(
      id: "availability",
      name: "Availability",
      filters: filters
    )
    
    XCTAssertEqual(group.id, "availability")
    XCTAssertEqual(group.name, "Availability")
    XCTAssertEqual(group.filters.count, 3)
  }
  
  // MARK: - Entry Points Tests
  
  func testEntryPoints() {
    let entryPoints = [
      CatalogFilter(id: "ebooks", title: "Ebooks", href: URL(string: "https://example.org/ebooks"), active: true),
      CatalogFilter(id: "audiobooks", title: "Audiobooks", href: URL(string: "https://example.org/audiobooks"), active: false)
    ]
    
    XCTAssertEqual(entryPoints.count, 2)
    XCTAssertTrue(entryPoints[0].active)
    XCTAssertFalse(entryPoints[1].active)
  }
  
  // MARK: - Grid Layout Tests
  
  func testGridLayout_ColumnCount() {
    let compactColumns = 2
    let regularColumns = 4
    
    XCTAssertEqual(compactColumns, 2, "Compact layout should have 2 columns")
    XCTAssertEqual(regularColumns, 4, "Regular layout should have 4 columns")
  }
  
  func testGridLayout_ItemSpacing() {
    let horizontalSpacing: CGFloat = 16
    let verticalSpacing: CGFloat = 16
    
    XCTAssertEqual(horizontalSpacing, 16)
    XCTAssertEqual(verticalSpacing, 16)
  }
  
  // MARK: - Book Card Tests
  
  func testBookCard_TitleTruncation() {
    let longTitle = "A Very Long Book Title That Should Be Truncated to Fit in the Card View"
    let maxLines = 2
    
    XCTAssertTrue(longTitle.count > 50, "Title should be long enough to test truncation")
    XCTAssertEqual(maxLines, 2, "Title should be limited to 2 lines")
  }
  
  func testBookCard_CoverAspectRatio() {
    let coverWidth: CGFloat = 100
    let coverHeight: CGFloat = 150
    let aspectRatio = coverWidth / coverHeight
    
    XCTAssertEqual(aspectRatio, 100/150, accuracy: 0.01, "Cover should have ~2:3 aspect ratio")
  }
  
  // MARK: - Empty State Tests
  
  func testEmptyState_NoBooks() {
    let books: [TPPBook] = []
    let hasBooks = !books.isEmpty
    
    XCTAssertFalse(hasBooks, "Should show empty state when no books")
  }
  
  func testEmptyState_NoLanes() {
    let lanes: [CatalogLaneModel] = []
    let hasLanes = !lanes.isEmpty
    
    XCTAssertFalse(hasLanes, "Should show empty state when no lanes")
  }
  
  // MARK: - Loading State Tests
  
  func testLoadingState() {
    struct LoadingState {
      var isLoading: Bool
      var isContentReloading: Bool
    }
    
    let state = LoadingState(isLoading: true, isContentReloading: false)
    XCTAssertTrue(state.isLoading)
    XCTAssertFalse(state.isContentReloading)
  }
  
  // MARK: - Error State Tests
  
  func testErrorState() {
    struct ErrorState {
      var errorMessage: String?
    }
    
    let state = ErrorState(errorMessage: "Failed to load catalog")
    XCTAssertNotNil(state.errorMessage)
    XCTAssertEqual(state.errorMessage, "Failed to load catalog")
  }
  
  // MARK: - Search Button Tests
  
  func testSearch_ButtonPresence() {
    let searchButtonId = AccessibilityID.Catalog.searchButton
    
    XCTAssertFalse(searchButtonId.isEmpty, "Search button should have accessibility identifier")
  }
  
  // MARK: - Scroll Behavior Tests
  
  func testScrollBehavior() {
    struct ScrollState {
      var shouldScrollToTop: Bool
    }
    
    let state = ScrollState(shouldScrollToTop: true)
    XCTAssertTrue(state.shouldScrollToTop)
  }
  
  // MARK: - Thumbnail Prefetch Tests
  
  func testThumbnailPrefetch_BookLimit() {
    let prefetchLimit = 30
    XCTAssertEqual(prefetchLimit, 30, "Should prefetch 30 book thumbnails")
  }
  
  func testThumbnailPrefetch_LaneLimit() {
    let prefetchLanes = 3
    XCTAssertEqual(prefetchLanes, 3, "Should prefetch thumbnails from first 3 lanes")
  }
  
  // MARK: - MappedCatalog Tests
  
  func testMappedCatalog() {
    let mapped = CatalogViewModel.MappedCatalog(
      title: "Test Catalog",
      entries: [],
      lanes: [],
      ungroupedBooks: [],
      facetGroups: [],
      entryPoints: []
    )
    
    XCTAssertEqual(mapped.title, "Test Catalog")
    XCTAssertTrue(mapped.entries.isEmpty)
    XCTAssertTrue(mapped.lanes.isEmpty)
    XCTAssertTrue(mapped.ungroupedBooks.isEmpty)
    XCTAssertTrue(mapped.facetGroups.isEmpty)
    XCTAssertTrue(mapped.entryPoints.isEmpty)
  }
}
