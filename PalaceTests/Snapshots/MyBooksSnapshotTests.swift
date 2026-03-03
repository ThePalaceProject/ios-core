//
//  MyBooksSnapshotTests.swift
//  PalaceTests
//
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import XCTest
import SwiftUI
import SnapshotTesting
@testable import Palace

@MainActor
final class MyBooksSnapshotTests: XCTestCase {
  
  private var mockRegistry: TPPBookRegistryMock!
  private var mockImageCache: MockImageCache!
  
  override func setUp() {
    super.setUp()
    mockRegistry = TPPBookRegistryMock()
    mockImageCache = MockImageCache()
  }
  
  // MARK: - Helpers
  
  private func snapshotEPUB() -> TPPBook {
    TPPBookMocker.snapshotEPUB()
  }
  
  private func snapshotAudiobook() -> TPPBook {
    TPPBookMocker.snapshotAudiobook()
  }
  
  private func createBookCellModel(book: TPPBook, state: TPPBookState) -> BookCellModel {
    mockRegistry.addBook(book, state: state)
    
    let tenPrintCover = MockImageCache.generateTenPrintCover(
      title: book.title,
      author: book.authors ?? "Unknown Author"
    )
    mockRegistry.setMockImage(tenPrintCover, for: book.identifier)
    mockImageCache.set(tenPrintCover, for: book.identifier, expiresIn: nil)
    
    return BookCellModel(
      book: book,
      imageCache: mockImageCache,
      bookRegistry: mockRegistry
    )
  }
  
  // MARK: - NormalBookCell
  
  func testNormalBookCell_downloadedEPUB() {
    let book = snapshotEPUB()
    let model = createBookCellModel(book: book, state: .downloadSuccessful)
    
    let view = NormalBookCell(model: model)
      .background(Color(UIColor.systemBackground))
    
    assertFixedSizeSnapshot(of: view, width: 390, height: 120)
  }
  
  func testNormalBookCell_downloadedAudiobook() {
    let book = snapshotAudiobook()
    let model = createBookCellModel(book: book, state: .downloadSuccessful)
    
    let view = NormalBookCell(model: model)
      .background(Color(UIColor.systemBackground))
    
    assertFixedSizeSnapshot(of: view, width: 390, height: 120)
  }
  
  func testNormalBookCell_downloadNeeded() {
    let book = snapshotEPUB()
    let model = createBookCellModel(book: book, state: .downloadNeeded)
    
    let view = NormalBookCell(model: model)
      .background(Color(UIColor.systemBackground))
    
    assertFixedSizeSnapshot(of: view, width: 390, height: 120)
  }
  
  // MARK: - DownloadingBookCell
  
  func testDownloadingBookCell() {
    let book = snapshotEPUB()
    let model = createBookCellModel(book: book, state: .downloading)
    
    let view = DownloadingBookCell(model: model)
      .background(Color(UIColor.systemBackground))
    
    assertFixedSizeSnapshot(of: view, width: 390, height: 120)
  }
  
  // MARK: - Empty State
  
  func testMyBooksEmptyState() {
    let emptyView = Text(Strings.MyBooksView.emptyViewMessage)
      .multilineTextAlignment(.center)
      .foregroundColor(.gray)
      .palaceFont(.body)
      .accessibilityIdentifier(AccessibilityID.MyBooks.emptyStateView)
      .background(Color(UIColor.systemBackground))
    
    assertFixedSizeSnapshot(of: emptyView, width: 390, height: 300)
  }
  
  // MARK: - Button Types
  
  func testButtonTypes_downloadedEPUB() {
    let book = snapshotEPUB()
    let buttons = BookButtonState.downloadSuccessful.buttonTypes(book: book)
    XCTAssertTrue(buttons.contains(.read))
  }
  
  func testButtonTypes_downloadedAudiobook() {
    let book = snapshotAudiobook()
    let buttons = BookButtonState.downloadSuccessful.buttonTypes(book: book)
    XCTAssertTrue(buttons.contains(.listen))
  }
  
  // MARK: - Sorting
  
  func testSortByTitle() {
    let books = [snapshotEPUB(), snapshotAudiobook(), TPPBookMocker.snapshotPDF()]
    let sorted = books.sorted { $0.title < $1.title }
    XCTAssertEqual(sorted.count, 3)
    XCTAssertEqual(sorted[0].title, "1984")
  }
  
  func testSortByAuthor() {
    let books = [snapshotEPUB(), snapshotAudiobook()]
    let sorted = books.sorted { ($0.authors ?? "") < ($1.authors ?? "") }
    XCTAssertEqual(sorted.count, 2)
    XCTAssertEqual(sorted[0].authors, "F. Scott Fitzgerald")
  }
  
  // MARK: - Accessibility
  
  func testMyBooksAccessibilityIdentifiers() {
    XCTAssertFalse(AccessibilityID.MyBooks.gridView.isEmpty)
    XCTAssertFalse(AccessibilityID.MyBooks.emptyStateView.isEmpty)
    XCTAssertFalse(AccessibilityID.MyBooks.sortButton.isEmpty)
  }
}
