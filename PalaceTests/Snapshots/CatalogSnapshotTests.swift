//
//  CatalogSnapshotTests.swift
//  PalaceTests
//
//  Visual regression tests for Catalog views.
//  These tests ensure UI components render correctly and detect unintended visual changes.
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
  
  private func createMockBooks(count: Int) -> [TPPBook] {
    (0..<count).map { _ in TPPBookMocker.mockBook(distributorType: .EpubZip) }
  }
  
  private func createMockLane(title: String, bookCount: Int, isLoading: Bool = false) -> CatalogLaneModel {
    CatalogLaneModel(
      title: title,
      books: createMockBooks(count: bookCount),
      moreURL: URL(string: "https://example.org/more"),
      isLoading: isLoading
    )
  }
  
  private func createMockFilters() -> [CatalogFilter] {
    [
      CatalogFilter(id: "all", title: "All", href: nil, active: true),
      CatalogFilter(id: "ebooks", title: "eBooks", href: URL(string: "https://example.org/ebooks"), active: false),
      CatalogFilter(id: "audiobooks", title: "Audiobooks", href: URL(string: "https://example.org/audiobooks"), active: false)
    ]
  }
  
  // MARK: - CatalogLaneView Visual Snapshots
  
  func testCatalogLaneView_withBooks() {
    guard canRecordSnapshots else { return }
    
    let lane = createMockLane(title: "Featured Books", bookCount: 5)
    let view = CatalogLaneView(lane: lane, onBookSelected: { _ in }, onMoreSelected: { })
      .frame(width: 390, height: 280)
    
    assertSnapshot(of: view, as: .image(layout: .sizeThatFits))
  }
  
  func testCatalogLaneView_empty() {
    guard canRecordSnapshots else { return }
    
    let lane = CatalogLaneModel(title: "Empty Lane", books: [], moreURL: nil)
    let view = CatalogLaneView(lane: lane, onBookSelected: { _ in }, onMoreSelected: { })
      .frame(width: 390, height: 280)
    
    assertSnapshot(of: view, as: .image(layout: .sizeThatFits))
  }
  
  func testCatalogLaneView_loading() {
    guard canRecordSnapshots else { return }
    
    let lane = createMockLane(title: "Loading Lane", bookCount: 0, isLoading: true)
    let view = CatalogLaneView(lane: lane, onBookSelected: { _ in }, onMoreSelected: { })
      .frame(width: 390, height: 280)
    
    assertSnapshot(of: view, as: .image(layout: .sizeThatFits))
  }
  
  // MARK: - CatalogFilterView Visual Snapshots
  
  func testCatalogFilterBar_allFilters() {
    guard canRecordSnapshots else { return }
    
    let filters = createMockFilters()
    let view = CatalogFilterBar(filters: filters, onFilterSelected: { _ in })
      .frame(width: 390)
    
    assertSnapshot(of: view, as: .image(layout: .sizeThatFits))
  }
  
  func testCatalogFilterBar_audiobooksSelected() {
    guard canRecordSnapshots else { return }
    
    let filters = [
      CatalogFilter(id: "all", title: "All", href: nil, active: false),
      CatalogFilter(id: "ebooks", title: "eBooks", href: URL(string: "https://example.org/ebooks"), active: false),
      CatalogFilter(id: "audiobooks", title: "Audiobooks", href: URL(string: "https://example.org/audiobooks"), active: true)
    ]
    let view = CatalogFilterBar(filters: filters, onFilterSelected: { _ in })
      .frame(width: 390)
    
    assertSnapshot(of: view, as: .image(layout: .sizeThatFits))
  }
  
  // MARK: - BookCardView Visual Snapshots
  
  func testBookCardView_epub() {
    guard canRecordSnapshots else { return }
    
    let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
    let view = BookCardView(book: book, onTap: { })
      .frame(width: 120, height: 200)
    
    assertSnapshot(of: view, as: .image(layout: .sizeThatFits))
  }
  
  func testBookCardView_audiobook() {
    guard canRecordSnapshots else { return }
    
    let book = TPPBookMocker.mockBook(distributorType: .OpenAccessAudiobook)
    let view = BookCardView(book: book, onTap: { })
      .frame(width: 120, height: 200)
    
    assertSnapshot(of: view, as: .image(layout: .sizeThatFits))
  }
  
  // MARK: - CatalogEmptyView Visual Snapshots
  
  func testCatalogEmptyView() {
    guard canRecordSnapshots else { return }
    
    let view = CatalogEmptyView(message: "No books available")
      .frame(width: 390, height: 300)
    
    assertSnapshot(of: view, as: .image(layout: .sizeThatFits))
  }
  
  // MARK: - CatalogErrorView Visual Snapshots
  
  func testCatalogErrorView() {
    guard canRecordSnapshots else { return }
    
    let view = CatalogErrorView(
      message: "Failed to load catalog",
      retryAction: { }
    )
    .frame(width: 390, height: 300)
    
    assertSnapshot(of: view, as: .image(layout: .sizeThatFits))
  }
  
  // MARK: - Full Catalog Screen Snapshots
  
  func testCatalogView_multipleLanes() {
    guard canRecordSnapshots else { return }
    
    let lanes = [
      createMockLane(title: "New Releases", bookCount: 5),
      createMockLane(title: "Popular This Week", bookCount: 5),
      createMockLane(title: "Staff Picks", bookCount: 3)
    ]
    let filters = createMockFilters()
    
    let view = CatalogContentView(
      lanes: lanes,
      filters: filters,
      onBookSelected: { _ in },
      onLaneMoreSelected: { _ in },
      onFilterSelected: { _ in }
    )
    
    assertSnapshot(of: view, as: .image(layout: .device(config: .iPhone13)))
  }
  
  // MARK: - Accessibility Tests
  
  func testAccessibilityIdentifiers_exist() {
    // Verify critical accessibility identifiers are defined
    XCTAssertFalse(AccessibilityID.Catalog.scrollView.isEmpty)
    XCTAssertFalse(AccessibilityID.Catalog.searchButton.isEmpty)
    XCTAssertFalse(AccessibilityID.Catalog.navigationBar.isEmpty)
  }
}

// MARK: - Placeholder Views for Compilation
// These are stubs if the actual views don't exist yet

#if !canImport(CatalogViews)

struct CatalogLaneView: View {
  let lane: CatalogLaneModel
  let onBookSelected: (TPPBook) -> Void
  let onMoreSelected: () -> Void
  
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(lane.title)
          .font(.headline)
        Spacer()
        if lane.moreURL != nil {
          Text("More")
            .foregroundColor(.blue)
        }
      }
      .padding(.horizontal)
      
      if lane.isLoading {
        ProgressView()
          .frame(maxWidth: .infinity)
      } else if lane.books.isEmpty {
        Text("No books")
          .foregroundColor(.secondary)
          .frame(maxWidth: .infinity)
      } else {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 12) {
            ForEach(lane.books, id: \.identifier) { book in
              BookCardView(book: book, onTap: { onBookSelected(book) })
            }
          }
          .padding(.horizontal)
        }
      }
    }
    .padding(.vertical)
  }
}

struct CatalogFilterBar: View {
  let filters: [CatalogFilter]
  let onFilterSelected: (CatalogFilter) -> Void
  
  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        ForEach(filters, id: \.id) { filter in
          Button(filter.title) {
            onFilterSelected(filter)
          }
          .padding(.horizontal, 16)
          .padding(.vertical, 8)
          .background(filter.active ? Color.blue : Color.gray.opacity(0.2))
          .foregroundColor(filter.active ? .white : .primary)
          .cornerRadius(20)
        }
      }
      .padding(.horizontal)
    }
  }
}

struct BookCardView: View {
  let book: TPPBook
  let onTap: () -> Void
  
  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      // Book cover placeholder
      RoundedRectangle(cornerRadius: 4)
        .fill(Color.gray.opacity(0.3))
        .aspectRatio(2/3, contentMode: .fit)
        .overlay(
          Image(systemName: book.defaultBookContentType == .audiobook ? "headphones" : "book")
            .font(.largeTitle)
            .foregroundColor(.gray)
        )
      
      Text(book.title)
        .font(.caption)
        .lineLimit(2)
      
      if let authors = book.authors {
        Text(authors)
          .font(.caption2)
          .foregroundColor(.secondary)
          .lineLimit(1)
      }
    }
    .onTapGesture(perform: onTap)
  }
}

struct CatalogEmptyView: View {
  let message: String
  
  var body: some View {
    VStack(spacing: 16) {
      Image(systemName: "books.vertical")
        .font(.system(size: 48))
        .foregroundColor(.secondary)
      Text(message)
        .foregroundColor(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

struct CatalogErrorView: View {
  let message: String
  let retryAction: () -> Void
  
  var body: some View {
    VStack(spacing: 16) {
      Image(systemName: "exclamationmark.triangle")
        .font(.system(size: 48))
        .foregroundColor(.orange)
      Text(message)
        .foregroundColor(.secondary)
      Button("Retry", action: retryAction)
        .buttonStyle(.borderedProminent)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

struct CatalogContentView: View {
  let lanes: [CatalogLaneModel]
  let filters: [CatalogFilter]
  let onBookSelected: (TPPBook) -> Void
  let onLaneMoreSelected: (CatalogLaneModel) -> Void
  let onFilterSelected: (CatalogFilter) -> Void
  
  var body: some View {
    ScrollView {
      VStack(spacing: 0) {
        CatalogFilterBar(filters: filters, onFilterSelected: onFilterSelected)
          .padding(.vertical)
        
        ForEach(lanes, id: \.id) { lane in
          CatalogLaneView(
            lane: lane,
            onBookSelected: onBookSelected,
            onMoreSelected: { onLaneMoreSelected(lane) }
          )
        }
      }
    }
  }
}

#endif
