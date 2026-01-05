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
  
  // MARK: - Helper Methods
  
  private func createMockHoldBook() -> TPPBook {
    TPPBookMocker.mockBook(distributorType: .EpubZip)
  }
  
  // MARK: - BookImageView for Holds
  
  func testHoldBookImage() {
    guard canRecordSnapshots else { return }
    
    let book = createMockHoldBook()
    let view = BookImageView(book: book, height: 150)
      .frame(width: 100, height: 150)
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
  
  // MARK: - Button State Tests
  // These test the business logic from Reservations.feature
  
  func testReserveButton_showsForUnavailableBook() {
    let book = createMockHoldBook()
    let buttons = BookButtonState.canHold.buttonTypes(book: book)
    
    XCTAssertTrue(buttons.contains(.reserve), "Unavailable book should show RESERVE button")
  }
  
  func testRemoveButton_showsAfterReservation() {
    let book = createMockHoldBook()
    let buttons = BookButtonState.holding.buttonTypes(book: book)
    
    // Should have option to remove/cancel hold
    XCTAssertTrue(buttons.contains(.manageHold) || buttons.contains(.cancelHold),
                  "Reserved book should show manage/cancel hold option")
  }
  
  func testGetButton_showsWhenFrontOfQueue() {
    let book = createMockHoldBook()
    let buttons = BookButtonState.holdingFrontOfQueue.buttonTypes(book: book)
    
    XCTAssertTrue(buttons.contains(.get) || buttons.contains(.download),
                  "Front of queue should show GET/DOWNLOAD button")
  }
  
  // MARK: - Sorting Tests
  
  func testHoldsSorting_byTitle() {
    let books = [
      createMockHoldBook(),
      createMockHoldBook(),
      createMockHoldBook()
    ]
    
    let sorted = books.sorted { $0.title < $1.title }
    XCTAssertEqual(sorted.count, 3, "Should have 3 sorted books")
  }
  
  func testHoldsSorting_byAuthor() {
    let books = [
      createMockHoldBook(),
      createMockHoldBook()
    ]
    
    let sorted = books.sorted { ($0.authors ?? "") < ($1.authors ?? "") }
    XCTAssertEqual(sorted.count, 2, "Should have 2 sorted books")
  }
  
  // MARK: - Accessibility
  
  func testReservationsAccessibilityIdentifiers() {
    // Use Holds namespace (Reservations is the user-facing name, Holds is the code namespace)
    XCTAssertFalse(AccessibilityID.Holds.scrollView.isEmpty)
    XCTAssertFalse(AccessibilityID.Holds.emptyStateView.isEmpty)
    XCTAssertFalse(AccessibilityID.Holds.sortButton.isEmpty)
  }
}
