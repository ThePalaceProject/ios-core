//
//  CatalogViewModelTests.swift
//  PalaceTests
//
//  Tests for CatalogFilter, CatalogFilterGroup, CatalogLaneModel, and MappedCatalog.
//
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class CatalogViewModelTests: XCTestCase {
  
  // MARK: - CatalogFilter Tests
  
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
    
    XCTAssertTrue(activeFilter.active)
  }
  
  // MARK: - CatalogFilterGroup Tests
  
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
  
  // MARK: - CatalogLaneModel Tests
  
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
  
  // MARK: - MappedCatalog Tests
  
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
}
