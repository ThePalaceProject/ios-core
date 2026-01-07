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
  
  private var canRecordSnapshots: Bool {
    #if targetEnvironment(simulator)
    return true
    #else
    return false
    #endif
  }
  
  // Fixed layout traits for consistent snapshots across devices
  private var fixedTraits: UITraitCollection {
    UITraitCollection(traitsFrom: [
      UITraitCollection(displayScale: 2.0),
      UITraitCollection(userInterfaceStyle: .light)
    ])
  }
  
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
    guard canRecordSnapshots else { return }
    
    let book = snapshotEPUB()
    let model = createBookCellModel(book: book, state: .downloadSuccessful)
    
    let view = NormalBookCell(model: model)
      .background(Color(UIColor.systemBackground))
    
    assertSnapshot(
      of: view,
      as: .image(layout: .fixed(width: 390, height: 120), traits: fixedTraits)
    )
  }
  
  func testNormalBookCell_downloadedAudiobook() {
    guard canRecordSnapshots else { return }
    
    let book = snapshotAudiobook()
    let model = createBookCellModel(book: book, state: .downloadSuccessful)
    
    let view = NormalBookCell(model: model)
      .background(Color(UIColor.systemBackground))
    
    assertSnapshot(
      of: view,
      as: .image(layout: .fixed(width: 390, height: 120), traits: fixedTraits)
    )
  }
  
  func testNormalBookCell_downloadNeeded() {
    guard canRecordSnapshots else { return }
    
    let book = snapshotEPUB()
    let model = createBookCellModel(book: book, state: .downloadNeeded)
    
    let view = NormalBookCell(model: model)
      .background(Color(UIColor.systemBackground))
    
    assertSnapshot(
      of: view,
      as: .image(layout: .fixed(width: 390, height: 120), traits: fixedTraits)
    )
  }
  
  // MARK: - DownloadingBookCell
  
  func testDownloadingBookCell() {
    guard canRecordSnapshots else { return }
    
    let book = snapshotEPUB()
    let model = createBookCellModel(book: book, state: .downloading)
    
    let view = DownloadingBookCell(model: model)
      .background(Color(UIColor.systemBackground))
    
    assertSnapshot(
      of: view,
      as: .image(layout: .fixed(width: 390, height: 120), traits: fixedTraits)
    )
  }
  
  // MARK: - Empty State
  
  func testMyBooksEmptyState() {
    guard canRecordSnapshots else { return }
    
    let emptyView = Text(Strings.MyBooksView.emptyViewMessage)
      .multilineTextAlignment(.center)
      .foregroundColor(.gray)
      .palaceFont(.body)
      .accessibilityIdentifier(AccessibilityID.MyBooks.emptyStateView)
      .background(Color(UIColor.systemBackground))
    
    assertSnapshot(
      of: emptyView,
      as: .image(layout: .fixed(width: 390, height: 300), traits: fixedTraits)
    )
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
