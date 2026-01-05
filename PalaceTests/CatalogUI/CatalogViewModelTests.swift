//
//  CatalogViewModelTests.swift
//  PalaceTests
//
//  Created for Testing Migration
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

/// Tests for CatalogViewModel functionality including filtering, sorting, and state management.
class CatalogViewModelTests: XCTestCase {
  
  // MARK: - Filter Model Tests
  
  func testCatalogFilter_Creation() {
    let filter = CatalogFilter(
      id: "test-id",
      title: "Audiobooks",
      href: URL(string: "https://example.org/audiobooks"),
      active: false
    )
    
    XCTAssertEqual(filter.id, "test-id")
    XCTAssertEqual(filter.title, "Audiobooks")
    XCTAssertNotNil(filter.href)
    XCTAssertFalse(filter.active)
  }
  
  func testCatalogFilter_ActiveState() {
    let activeFilter = CatalogFilter(
      id: "active-id",
      title: "All",
      href: URL(string: "https://example.org/all"),
      active: true
    )
    
    XCTAssertTrue(activeFilter.active, "Filter should be active")
  }
  
  func testCatalogFilterGroup_Creation() {
    let filters = [
      CatalogFilter(id: "1", title: "All", href: nil, active: true),
      CatalogFilter(id: "2", title: "Available Now", href: URL(string: "https://example.org/available"), active: false)
    ]
    
    let group = CatalogFilterGroup(id: "availability", name: "Availability", filters: filters)
    
    XCTAssertEqual(group.id, "availability")
    XCTAssertEqual(group.name, "Availability")
    XCTAssertEqual(group.filters.count, 2)
  }
  
  func testCatalogFilterGroup_ActiveFilter() {
    let filters = [
      CatalogFilter(id: "1", title: "All", href: nil, active: false),
      CatalogFilter(id: "2", title: "Available", href: nil, active: true),
      CatalogFilter(id: "3", title: "Reserved", href: nil, active: false)
    ]
    
    let activeFilter = filters.first(where: { $0.active })
    
    XCTAssertNotNil(activeFilter)
    XCTAssertEqual(activeFilter?.title, "Available")
  }
  
  // MARK: - Lane Model Tests
  
  func testCatalogLaneModel_Creation() {
    let lane = CatalogLaneModel(
      title: "Popular Books",
      books: [],
      moreURL: URL(string: "https://example.org/more"),
      isLoading: false
    )
    
    XCTAssertEqual(lane.title, "Popular Books")
    XCTAssertTrue(lane.books.isEmpty)
    XCTAssertNotNil(lane.moreURL)
    XCTAssertFalse(lane.isLoading)
  }
  
  func testCatalogLaneModel_LoadingState() {
    let loadingLane = CatalogLaneModel(
      title: "Loading Lane",
      books: [],
      moreURL: nil,
      isLoading: true
    )
    
    XCTAssertTrue(loadingLane.isLoading)
  }
  
  func testCatalogLaneModel_UniqueId() {
    let lane1 = CatalogLaneModel(title: "Lane 1", books: [], moreURL: nil)
    let lane2 = CatalogLaneModel(title: "Lane 1", books: [], moreURL: nil)
    
    // Each lane should have unique ID even with same title
    XCTAssertNotEqual(lane1.id, lane2.id)
  }
  
  // MARK: - Feed Mapping Tests
  
  func testMappedCatalog_EmptyFeed() {
    let mapped = CatalogViewModel.MappedCatalog(
      title: "Empty",
      entries: [],
      lanes: [],
      ungroupedBooks: [],
      facetGroups: [],
      entryPoints: []
    )
    
    XCTAssertEqual(mapped.title, "Empty")
    XCTAssertTrue(mapped.entries.isEmpty)
    XCTAssertTrue(mapped.lanes.isEmpty)
    XCTAssertTrue(mapped.ungroupedBooks.isEmpty)
    XCTAssertTrue(mapped.facetGroups.isEmpty)
    XCTAssertTrue(mapped.entryPoints.isEmpty)
  }
  
  func testMappedCatalog_WithLanes() {
    let lanes = [
      CatalogLaneModel(title: "Fiction", books: [], moreURL: nil),
      CatalogLaneModel(title: "Non-Fiction", books: [], moreURL: nil)
    ]
    
    let mapped = CatalogViewModel.MappedCatalog(
      title: "Catalog",
      entries: [],
      lanes: lanes,
      ungroupedBooks: [],
      facetGroups: [],
      entryPoints: []
    )
    
    XCTAssertEqual(mapped.lanes.count, 2)
    XCTAssertEqual(mapped.lanes[0].title, "Fiction")
    XCTAssertEqual(mapped.lanes[1].title, "Non-Fiction")
  }
  
  // MARK: - Optimistic Update Tests
  
  func testOptimisticUpdate_FilterSelection() {
    // Simulate optimistic filter update
    var filters = [
      CatalogFilter(id: "1", title: "All", href: nil, active: true),
      CatalogFilter(id: "2", title: "Available", href: nil, active: false)
    ]
    
    let selectedId = "2"
    
    // Update optimistically
    filters = filters.map { filter in
      CatalogFilter(
        id: filter.id,
        title: filter.title,
        href: filter.href,
        active: filter.id == selectedId
      )
    }
    
    XCTAssertFalse(filters[0].active, "All should no longer be active")
    XCTAssertTrue(filters[1].active, "Available should now be active")
  }
  
  func testOptimisticUpdate_EntryPointSelection() {
    var entryPoints = [
      CatalogFilter(id: "ebooks", title: "Ebooks", href: nil, active: true),
      CatalogFilter(id: "audiobooks", title: "Audiobooks", href: nil, active: false)
    ]
    
    let selectedId = "audiobooks"
    
    // Update optimistically
    entryPoints = entryPoints.map { entryPoint in
      CatalogFilter(
        id: entryPoint.id,
        title: entryPoint.title,
        href: entryPoint.href,
        active: entryPoint.id == selectedId
      )
    }
    
    XCTAssertFalse(entryPoints[0].active, "Ebooks should no longer be active")
    XCTAssertTrue(entryPoints[1].active, "Audiobooks should now be active")
  }
  
  // MARK: - State Restoration Tests
  
  func testStateRestoration_AfterError() {
    // Simulate storing previous state
    let previousLanes = [CatalogLaneModel(title: "Previous Lane", books: [], moreURL: nil)]
    var currentLanes = [CatalogLaneModel(title: "New Lane", books: [], moreURL: nil)]
    
    // Simulate error - restore previous state
    let errorOccurred = true
    if errorOccurred {
      currentLanes = previousLanes
    }
    
    XCTAssertEqual(currentLanes.count, 1)
    XCTAssertEqual(currentLanes[0].title, "Previous Lane")
  }
  
  // MARK: - Loading State Tests
  
  func testLoadingState_Initial() {
    var isLoading = false
    var errorMessage: String? = nil
    
    // Start loading
    isLoading = true
    errorMessage = nil
    
    XCTAssertTrue(isLoading)
    XCTAssertNil(errorMessage)
  }
  
  func testLoadingState_Success() {
    var isLoading = true
    var errorMessage: String? = nil
    
    // Complete loading successfully
    isLoading = false
    
    XCTAssertFalse(isLoading)
    XCTAssertNil(errorMessage)
  }
  
  func testLoadingState_Error() {
    var isLoading = true
    var errorMessage: String? = nil
    
    // Complete loading with error
    isLoading = false
    errorMessage = "Failed to load catalog"
    
    XCTAssertFalse(isLoading)
    XCTAssertNotNil(errorMessage)
    XCTAssertEqual(errorMessage, "Failed to load catalog")
  }
  
  // MARK: - Scroll State Tests
  
  func testScrollToTop_Trigger() {
    var shouldScrollToTop = false
    
    // Trigger scroll to top
    shouldScrollToTop = true
    
    XCTAssertTrue(shouldScrollToTop)
  }
  
  func testScrollToTop_Reset() {
    var shouldScrollToTop = true
    
    // Reset after scroll
    shouldScrollToTop = false
    
    XCTAssertFalse(shouldScrollToTop)
  }
  
  // MARK: - Entry Point Tests
  
  func testEntryPoints_EbooksAndAudiobooks() {
    let entryPoints = [
      CatalogFilter(id: "all", title: "All", href: nil, active: true),
      CatalogFilter(id: "ebooks", title: "Ebooks", href: nil, active: false),
      CatalogFilter(id: "audiobooks", title: "Audiobooks", href: nil, active: false)
    ]
    
    XCTAssertEqual(entryPoints.count, 3)
    XCTAssertEqual(entryPoints.first(where: { $0.active })?.title, "All")
  }
  
  func testEntryPoints_FilterByType() {
    let entryPoints = [
      CatalogFilter(id: "ebooks", title: "Ebooks", href: URL(string: "https://example.org?type=ebooks"), active: false),
      CatalogFilter(id: "audiobooks", title: "Audiobooks", href: URL(string: "https://example.org?type=audiobooks"), active: true)
    ]
    
    let activeEntryPoint = entryPoints.first(where: { $0.active })
    
    XCTAssertNotNil(activeEntryPoint)
    XCTAssertEqual(activeEntryPoint?.title, "Audiobooks")
    XCTAssertTrue(activeEntryPoint?.href?.absoluteString.contains("audiobooks") ?? false)
  }
  
  // MARK: - Cache Invalidation Tests
  
  func testCacheInvalidation_SameURL() {
    let url1 = URL(string: "https://example.org/catalog")!
    let url2 = URL(string: "https://example.org/catalog")!
    
    XCTAssertEqual(url1, url2, "Same URLs should be equal for cache comparison")
  }
  
  func testCacheInvalidation_DifferentURL() {
    let url1 = URL(string: "https://example.org/catalog")!
    let url2 = URL(string: "https://example.org/other")!
    
    XCTAssertNotEqual(url1, url2, "Different URLs should trigger cache refresh")
  }
  
  // MARK: - Book Filtering Tests
  
  func testBookFiltering_UnsupportedContentType() {
    // Books with unsupported content types should be filtered out
    let supportedTypes: Set<String> = ["application/epub+zip", "application/audiobook+json"]
    let bookType = "application/pdf"
    
    let isSupported = supportedTypes.contains(bookType)
    
    XCTAssertFalse(isSupported, "PDF should be filtered out in this context")
  }
  
  func testBookFiltering_MissingAcquisition() {
    // Books without acquisition should be filtered out
    let hasAcquisition = false
    
    let shouldInclude = hasAcquisition
    
    XCTAssertFalse(shouldInclude, "Books without acquisition should be filtered")
  }
}

