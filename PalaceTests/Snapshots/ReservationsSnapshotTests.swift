//
//  ReservationsSnapshotTests.swift
//  PalaceTests
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
  
  private func snapshotHoldBook() -> TPPBook {
    TPPBookMocker.snapshotHoldBook()
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
  
  func testNormalBookCell_holding() {
    guard canRecordSnapshots else { return }
    
    let book = snapshotHoldBook()
    let model = createBookCellModel(book: book, state: .holding)
    
    let view = NormalBookCell(model: model)
      .background(Color(UIColor.systemBackground))
    
    assertSnapshot(
      of: view,
      as: .image(layout: .fixed(width: 390, height: 120), traits: fixedTraits)
    )
  }
  
  func testNormalBookCell_downloadSuccessful() {
    guard canRecordSnapshots else { return }
    
    let book = TPPBookMocker.snapshotEPUB()
    let model = createBookCellModel(book: book, state: .downloadSuccessful)
    
    let view = NormalBookCell(model: model)
      .background(Color(UIColor.systemBackground))
    
    assertSnapshot(
      of: view,
      as: .image(layout: .fixed(width: 390, height: 120), traits: fixedTraits)
    )
  }
  
  // MARK: - Empty State
  
  func testReservationsEmptyState() {
    guard canRecordSnapshots else { return }
    
    let emptyView = Text(Strings.HoldsView.emptyMessage)
      .multilineTextAlignment(.center)
      .foregroundColor(Color(white: 0.667))
      .font(.system(size: 18))
      .padding(.horizontal, 24)
      .padding(.top, 100)
      .accessibilityIdentifier(AccessibilityID.Holds.emptyStateView)
      .background(Color(TPPConfiguration.backgroundColor()))
    
    assertSnapshot(
      of: emptyView,
      as: .image(layout: .fixed(width: 390, height: 400), traits: fixedTraits)
    )
  }
  
  // MARK: - Button States
  
  func testReserveButton_showsForUnavailableBook() {
    let book = snapshotHoldBook()
    let buttons = BookButtonState.canHold.buttonTypes(book: book)
    XCTAssertTrue(buttons.contains(.reserve))
  }
  
  func testRemoveButton_showsAfterReservation() {
    let book = snapshotHoldBook()
    let buttons = BookButtonState.holding.buttonTypes(book: book)
    XCTAssertTrue(buttons.contains(.manageHold) || buttons.contains(.cancelHold))
  }
  
  func testHoldingFrontOfQueue_buttonBehavior() {
    let book = snapshotHoldBook()
    let buttons = BookButtonState.holdingFrontOfQueue.buttonTypes(book: book)
    XCTAssertFalse(buttons.isEmpty)
    XCTAssertTrue(buttons.contains(.manageHold) || buttons.contains(.get))
  }
  
  // MARK: - Sorting
  
  func testHoldsSorting_byTitle() {
    let books = [
      TPPBookMocker.snapshotEPUB(),
      TPPBookMocker.snapshotAudiobook(),
      TPPBookMocker.snapshotPDF()
    ]
    let sorted = books.sorted { $0.title < $1.title }
    XCTAssertEqual(sorted.count, 3)
    XCTAssertEqual(sorted[0].title, "1984")
    XCTAssertEqual(sorted[1].title, "Pride and Prejudice")
    XCTAssertEqual(sorted[2].title, "The Great Gatsby")
  }
  
  func testHoldsSorting_byAuthor() {
    let books = [
      TPPBookMocker.snapshotEPUB(),
      TPPBookMocker.snapshotAudiobook()
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
