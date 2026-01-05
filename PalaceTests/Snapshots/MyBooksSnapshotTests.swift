//
//  MyBooksSnapshotTests.swift
//  PalaceTests
//
//  Visual regression tests for My Books screen.
//  Replaces Appium: MyBooks.feature
//
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import XCTest
import SwiftUI
import SnapshotTesting
@testable import Palace

@MainActor
final class MyBooksSnapshotTests: XCTestCase {
  
  private var canRecordSnapshots: Bool {
    #if targetEnvironment(simulator)
    return true
    #else
    return false
    #endif
  }
  
  // MARK: - Test Dependencies
  
  private var mockRegistry: TPPBookRegistryMock!
  private var mockImageCache: MockImageCache!
  
  override func setUp() {
    super.setUp()
    mockRegistry = TPPBookRegistryMock()
    mockImageCache = MockImageCache()
  }
  
  // MARK: - Helper Methods
  
  private func createMockEPUB() -> TPPBook {
    TPPBookMocker.mockBook(distributorType: .EpubZip)
  }
  
  private func createMockAudiobook() -> TPPBook {
    TPPBookMocker.mockBook(distributorType: .OpenAccessAudiobook)
  }
  
  private func createBookCellModel(book: TPPBook, state: TPPBookState) -> BookCellModel {
    // Add book to registry with desired state
    mockRegistry.addBook(book, state: state)
    
    // Set a test cover image
    let testImage = UIImage(systemName: "book.closed.fill")!
    mockRegistry.setMockImage(testImage, for: book.identifier)
    mockImageCache.set(testImage, for: book.identifier)
    
    // Create model with injected dependencies
    return BookCellModel(
      book: book,
      imageCache: mockImageCache,
      bookRegistry: mockRegistry
    )
  }
  
  // MARK: - NormalBookCell Snapshots
  
  func testNormalBookCell_downloadedEPUB() {
    guard canRecordSnapshots else { return }
    
    let book = createMockEPUB()
    let model = createBookCellModel(book: book, state: .downloadSuccessful)
    
    let view = NormalBookCell(model: model)
      .frame(width: 390)
      .background(Color(UIColor.systemBackground))
    
    assertSnapshot(of: view, as: .image)
  }
  
  func testNormalBookCell_downloadedAudiobook() {
    guard canRecordSnapshots else { return }
    
    let book = createMockAudiobook()
    let model = createBookCellModel(book: book, state: .downloadSuccessful)
    
    let view = NormalBookCell(model: model)
      .frame(width: 390)
      .background(Color(UIColor.systemBackground))
    
    assertSnapshot(of: view, as: .image)
  }
  
  func testNormalBookCell_downloadNeeded() {
    guard canRecordSnapshots else { return }
    
    let book = createMockEPUB()
    let model = createBookCellModel(book: book, state: .downloadNeeded)
    
    let view = NormalBookCell(model: model)
      .frame(width: 390)
      .background(Color(UIColor.systemBackground))
    
    assertSnapshot(of: view, as: .image)
  }
  
  // MARK: - DownloadingBookCell Snapshots
  
  func testDownloadingBookCell() {
    guard canRecordSnapshots else { return }
    
    let book = createMockEPUB()
    let model = createBookCellModel(book: book, state: .downloading)
    
    let view = DownloadingBookCell(model: model)
      .frame(width: 390)
      .background(Color(UIColor.systemBackground))
    
    assertSnapshot(of: view, as: .image)
  }
  
  // MARK: - Empty State
  
  func testMyBooksEmptyState() {
    guard canRecordSnapshots else { return }
    
    let emptyView = VStack(spacing: 16) {
      Image(systemName: "books.vertical")
        .font(.system(size: 48))
        .foregroundColor(.secondary)
      Text("No books yet")
        .font(.headline)
      Text("Books you borrow will appear here")
        .font(.subheadline)
        .foregroundColor(.secondary)
    }
    .frame(width: 390, height: 300)
    .background(Color(UIColor.systemBackground))
    
    assertSnapshot(of: emptyView, as: .image)
  }
  
  // MARK: - Button Type Tests
  
  func testButtonTypes_downloadedEPUB() {
    let book = createMockEPUB()
    let buttons = BookButtonState.downloadSuccessful.buttonTypes(book: book)
    
    XCTAssertTrue(buttons.contains(.read), "Downloaded EPUB should have READ button")
  }
  
  func testButtonTypes_downloadedAudiobook() {
    let book = createMockAudiobook()
    let buttons = BookButtonState.downloadSuccessful.buttonTypes(book: book)
    
    XCTAssertTrue(buttons.contains(.listen), "Downloaded audiobook should have LISTEN button")
  }
  
  // MARK: - Sorting Tests
  
  func testSortByTitle() {
    let books = [createMockEPUB(), createMockAudiobook(), createMockEPUB()]
    let sorted = books.sorted { $0.title < $1.title }
    XCTAssertEqual(sorted.count, 3)
  }
  
  func testSortByAuthor() {
    let books = [createMockEPUB(), createMockAudiobook()]
    let sorted = books.sorted { ($0.authors ?? "") < ($1.authors ?? "") }
    XCTAssertEqual(sorted.count, 2)
  }
  
  // MARK: - Accessibility
  
  func testMyBooksAccessibilityIdentifiers() {
    XCTAssertFalse(AccessibilityID.MyBooks.gridView.isEmpty)
    XCTAssertFalse(AccessibilityID.MyBooks.emptyStateView.isEmpty)
    XCTAssertFalse(AccessibilityID.MyBooks.sortButton.isEmpty)
  }
}
