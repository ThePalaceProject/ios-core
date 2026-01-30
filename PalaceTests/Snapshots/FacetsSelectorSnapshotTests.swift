//
//  FacetsSelectorSnapshotTests.swift
//  PalaceTests
//
//  Snapshot tests for FacetsSelectorView and EntryPointsSelectorView.
//  Tests run across multiple device configurations for comprehensive coverage.
//

import XCTest
import SwiftUI
import SnapshotTesting
@testable import Palace

@MainActor
final class FacetsSelectorSnapshotTests: XCTestCase {
  
  override func setUp() {
    super.setUp()
    // Snapshots are recorded via RECORD_SNAPSHOTS environment variable
    // or by running ./scripts/record-snapshots.sh
  }
  
  // MARK: - Helper Methods
  
  private func createMockFilter(title: String, active: Bool = false) -> CatalogFilter {
    CatalogFilter(
      id: UUID().uuidString,
      title: title,
      href: URL(string: "https://example.com/filter/\(title.lowercased())"),
      active: active
    )
  }
  
  private func createMockFilterGroup(name: String, filters: [CatalogFilter]) -> CatalogFilterGroup {
    CatalogFilterGroup(
      id: UUID().uuidString,
      name: name,
      filters: filters
    )
  }
  
  // MARK: - FacetsSelectorView Tests
  
  func testFacetsSelectorView_singleGroup() {
    let filters = [
      createMockFilter(title: "All", active: true),
      createMockFilter(title: "Fiction"),
      createMockFilter(title: "Non-Fiction")
    ]
    let group = createMockFilterGroup(name: "Category", filters: filters)
    
    let view = FacetsSelectorView(
      facetGroups: [group],
      onSelect: { _ in }
    )
    .background(Color(UIColor.systemBackground))
    
    assertMultiDeviceSnapshot(of: view)
  }
  
  func testFacetsSelectorView_multipleGroups() {
    let categoryFilters = [
      createMockFilter(title: "All", active: true),
      createMockFilter(title: "Fiction"),
      createMockFilter(title: "Non-Fiction")
    ]
    let sortFilters = [
      createMockFilter(title: "Title"),
      createMockFilter(title: "Author", active: true),
      createMockFilter(title: "Date Added")
    ]
    
    let groups = [
      createMockFilterGroup(name: "Category", filters: categoryFilters),
      createMockFilterGroup(name: "Sort By", filters: sortFilters)
    ]
    
    let view = FacetsSelectorView(
      facetGroups: groups,
      onSelect: { _ in }
    )
    .background(Color(UIColor.systemBackground))
    
    assertMultiDeviceSnapshot(of: view)
  }
  
  func testFacetsSelectorView_manyFilters() {
    let filters = [
      createMockFilter(title: "All", active: true),
      createMockFilter(title: "Available Now"),
      createMockFilter(title: "Coming Soon"),
      createMockFilter(title: "On Hold"),
      createMockFilter(title: "Borrowed")
    ]
    let group = createMockFilterGroup(name: "Availability", filters: filters)
    
    let view = FacetsSelectorView(
      facetGroups: [group],
      onSelect: { _ in }
    )
    .background(Color(UIColor.systemBackground))
    
    assertMultiDeviceSnapshot(of: view)
  }
  
  func testFacetsSelectorView_darkMode() {
    let filters = [
      createMockFilter(title: "All", active: true),
      createMockFilter(title: "Fiction"),
      createMockFilter(title: "Non-Fiction")
    ]
    let group = createMockFilterGroup(name: "Category", filters: filters)
    
    let view = FacetsSelectorView(
      facetGroups: [group],
      onSelect: { _ in }
    )
    .background(Color(UIColor.systemBackground))
    .colorScheme(.dark)
    
    assertMultiDeviceSnapshot(of: view)
  }
  
  func testFacetsSelectorView_noActiveFilter() {
    let filters = [
      createMockFilter(title: "All"),
      createMockFilter(title: "Fiction"),
      createMockFilter(title: "Non-Fiction")
    ]
    let group = createMockFilterGroup(name: "Category", filters: filters)
    
    let view = FacetsSelectorView(
      facetGroups: [group],
      onSelect: { _ in }
    )
    .background(Color(UIColor.systemBackground))
    
    assertMultiDeviceSnapshot(of: view)
  }
  
  // MARK: - EntryPointsSelectorView Tests
  
  func testEntryPointsSelectorView_twoTabs() {
    let entryPoints = [
      createMockFilter(title: "Books", active: true),
      createMockFilter(title: "Audiobooks")
    ]
    
    let view = EntryPointsSelectorView(
      entryPoints: entryPoints,
      onSelect: { _ in }
    )
    .background(Color(UIColor.systemBackground))
    
    assertMultiDeviceSnapshot(of: view)
  }
  
  func testEntryPointsSelectorView_threeTabs() {
    let entryPoints = [
      createMockFilter(title: "All"),
      createMockFilter(title: "Books", active: true),
      createMockFilter(title: "Audiobooks")
    ]
    
    let view = EntryPointsSelectorView(
      entryPoints: entryPoints,
      onSelect: { _ in }
    )
    .background(Color(UIColor.systemBackground))
    
    assertMultiDeviceSnapshot(of: view)
  }
  
  func testEntryPointsSelectorView_darkMode() {
    let entryPoints = [
      createMockFilter(title: "Books", active: true),
      createMockFilter(title: "Audiobooks")
    ]
    
    let view = EntryPointsSelectorView(
      entryPoints: entryPoints,
      onSelect: { _ in }
    )
    .background(Color(UIColor.systemBackground))
    .colorScheme(.dark)
    
    assertMultiDeviceSnapshot(of: view)
  }
  
  // MARK: - Empty State Tests
  
  func testFacetsSelectorView_emptyGroups() {
    let view = FacetsSelectorView(
      facetGroups: [],
      onSelect: { _ in }
    )
    .background(Color(UIColor.systemBackground))
    
    assertMultiDeviceSnapshot(of: view)
  }
}
