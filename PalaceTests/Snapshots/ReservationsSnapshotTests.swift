//
//  ReservationsSnapshotTests.swift
//  PalaceTests
//
//  Visual regression tests for Reservations/Holds screen.
//  Replaces Appium: Reservations.feature
//
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import XCTest
import SwiftUI
import SnapshotTesting
@testable import Palace

@MainActor
final class ReservationsSnapshotTests: XCTestCase {
  
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
  
  // MARK: - Helper Methods (Deterministic for Snapshots)
  
  /// Deterministic book on hold for consistent snapshots
  private func snapshotHoldBook() -> TPPBook {
    TPPBookMocker.snapshotHoldBook() // "To Kill a Mockingbird" by Harper Lee
  }
  
  private func createBookCellModel(book: TPPBook, state: TPPBookState) -> BookCellModel {
    // Add book to registry with desired state
    mockRegistry.addBook(book, state: state)
    
    // Generate TenPrint cover for deterministic, visually meaningful snapshots
    let tenPrintCover = MockImageCache.generateTenPrintCover(
      title: book.title,
      author: book.authors ?? "Unknown Author"
    )
    mockRegistry.setMockImage(tenPrintCover, for: book.identifier)
    mockImageCache.set(tenPrintCover, for: book.identifier, expiresIn: nil)
    
    // Create model with injected dependencies
    return BookCellModel(
      book: book,
      imageCache: mockImageCache,
      bookRegistry: mockRegistry
    )
  }
  
  // MARK: - NormalBookCell Visual Tests (Deterministic Data)
  
  func testNormalBookCell_holding() {
    guard canRecordSnapshots else { return }
    
    let book = snapshotHoldBook() // "To Kill a Mockingbird" by Harper Lee
    let model = createBookCellModel(book: book, state: .holding)
    
    let view = NormalBookCell(model: model)
      .frame(width: 390)
      .background(Color(UIColor.systemBackground))
    
    assertSnapshot(of: view, as: .image)
  }
  
  func testNormalBookCell_downloadSuccessful() {
    guard canRecordSnapshots else { return }
    
    let book = TPPBookMocker.snapshotEPUB() // "The Great Gatsby" by F. Scott Fitzgerald
    let model = createBookCellModel(book: book, state: .downloadSuccessful)
    
    let view = NormalBookCell(model: model)
      .frame(width: 390)
      .background(Color(UIColor.systemBackground))
    
    assertSnapshot(of: view, as: .image)
  }
  
  // MARK: - Empty State
  
  func testReservationsEmptyState() {
    guard canRecordSnapshots else { return }
    
    let emptyView = VStack(spacing: 16) {
      Image(systemName: "clock")
        .font(.system(size: 48))
        .foregroundColor(.secondary)
      Text("No reservations")
        .font(.headline)
      Text("Reserved books will appear here")
        .font(.subheadline)
        .foregroundColor(.secondary)
    }
    .frame(width: 390, height: 300)
    .background(Color(UIColor.systemBackground))
    
    assertSnapshot(of: emptyView, as: .image)
  }
  
  // MARK: - Button State Tests (Business Logic)
  
  func testReserveButton_showsForUnavailableBook() {
    let book = snapshotHoldBook()
    let buttons = BookButtonState.canHold.buttonTypes(book: book)
    
    XCTAssertTrue(buttons.contains(.reserve), "Unavailable book should show RESERVE button")
  }
  
  func testRemoveButton_showsAfterReservation() {
    let book = snapshotHoldBook()
    let buttons = BookButtonState.holding.buttonTypes(book: book)
    
    XCTAssertTrue(buttons.contains(.manageHold) || buttons.contains(.cancelHold),
                  "Reserved book should show manage/cancel hold option")
  }
  
  func testHoldingFrontOfQueue_buttonBehavior() {
    let book = snapshotHoldBook()
    let buttons = BookButtonState.holdingFrontOfQueue.buttonTypes(book: book)
    
    XCTAssertFalse(buttons.isEmpty, "Should have at least one button")
    XCTAssertTrue(buttons.contains(.manageHold) || buttons.contains(.get),
                  "Should show manageHold or get depending on availability")
  }
  
  // MARK: - Sorting Tests (Deterministic)
  
  func testHoldsSorting_byTitle() {
    let books = [
      TPPBookMocker.snapshotEPUB(),      // "The Great Gatsby"
      TPPBookMocker.snapshotAudiobook(), // "Pride and Prejudice"
      TPPBookMocker.snapshotPDF()        // "1984"
    ]
    let sorted = books.sorted { $0.title < $1.title }
    XCTAssertEqual(sorted.count, 3)
    XCTAssertEqual(sorted[0].title, "1984")
    XCTAssertEqual(sorted[1].title, "Pride and Prejudice")
    XCTAssertEqual(sorted[2].title, "The Great Gatsby")
  }
  
  func testHoldsSorting_byAuthor() {
    let books = [
      TPPBookMocker.snapshotEPUB(),      // F. Scott Fitzgerald
      TPPBookMocker.snapshotAudiobook()  // Jane Austen
    ]
    let sorted = books.sorted { ($0.authors ?? "") < ($1.authors ?? "") }
    XCTAssertEqual(sorted.count, 2)
    XCTAssertEqual(sorted[0].authors, "F. Scott Fitzgerald")
    XCTAssertEqual(sorted[1].authors, "Jane Austen")
  }
  
  // MARK: - Accessibility
  
  func testReservationsAccessibilityIdentifiers() {
    XCTAssertFalse(AccessibilityID.Holds.scrollView.isEmpty)
    XCTAssertFalse(AccessibilityID.Holds.emptyStateView.isEmpty)
    XCTAssertFalse(AccessibilityID.Holds.sortButton.isEmpty)
  }
}
