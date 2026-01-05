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
  
  // MARK: - Search Results UI
  // Uses deterministic mocks for consistent snapshot comparisons
  
  func testSearchResults_withBooks() {
    guard canRecordSnapshots else { return }
    
    // Use deterministic snapshot books for consistent comparisons
    let books = [
      TPPBookMocker.snapshotEPUB(),
      TPPBookMocker.snapshotAudiobook()
    ]
    
    // Create a search results view
    let view = ScrollView {
      LazyVStack(spacing: 12) {
        ForEach(books, id: \.identifier) { book in
          BookImageView(book: book, height: 100)
        }
      }
      .padding()
    }
    .frame(width: 390, height: 400)
    .background(Color(UIColor.systemBackground))
    
    assertSnapshot(of: view, as: .image)
  }
  
  func testSearchResults_noResults() {
    guard canRecordSnapshots else { return }
    
    let view = VStack(spacing: 16) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 48))
        .foregroundColor(.secondary)
      Text("No results found")
        .font(.headline)
      Text("Try a different search term")
        .font(.subheadline)
        .foregroundColor(.secondary)
    }
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
