//
//  BookDetailSnapshotTests.swift
//  PalaceTests
//
//  Visual regression tests for BookDetailView.
//  These tests snapshot REAL app views to detect unintended visual changes.
//
//  NOTE: E2E user flows (get book, read, return) are tested in mobile-integration-tests-new.
//  These tests focus on visual rendering and button state correctness.
//
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import XCTest
import SwiftUI
import SnapshotTesting
@testable import Palace

/// Visual regression tests for BookDetailView UI components.
/// Run on simulator to record/compare snapshots.
@MainActor
final class BookDetailSnapshotTests: XCTestCase {
  
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
  // Use deterministic mocks for consistent snapshot comparisons
  
  private func createMockEPUBBook() -> TPPBook {
    TPPBookMocker.snapshotEPUB()
  }
  
  private func createMockAudiobook() -> TPPBook {
    TPPBookMocker.snapshotAudiobook()
  }
  
  private func createMockPDFBook() -> TPPBook {
    TPPBookMocker.snapshotPDF()
  }
  
  // MARK: - Book Content Type Detection
  // Critical: Ensures correct content type detection for button logic
  
  func testContentType_EPUB() {
    let book = createMockEPUBBook()
    XCTAssertEqual(book.defaultBookContentType, .epub, "EPUB book should have epub content type")
  }
  
  func testContentType_Audiobook() {
    let book = createMockAudiobook()
    XCTAssertEqual(book.defaultBookContentType, .audiobook, "Audiobook should have audiobook content type")
  }
  
  func testContentType_PDF() {
    let book = createMockPDFBook()
    XCTAssertEqual(book.defaultBookContentType, .pdf, "PDF book should have pdf content type")
  }
  
  // MARK: - Button State Logic
  // Critical: Ensures correct buttons appear for each state
  
  func testButtonState_canBorrow_showsGetButton() {
    let book = createMockEPUBBook()
    let buttons = BookButtonState.canBorrow.buttonTypes(book: book, previewEnabled: false)
    
    XCTAssertTrue(buttons.contains(.get), "Can borrow state should show GET button")
    XCTAssertFalse(buttons.contains(.read), "Can borrow state should NOT show READ button")
  }
  
  func testButtonState_canHold_showsReserveButton() {
    let book = createMockEPUBBook()
    let buttons = BookButtonState.canHold.buttonTypes(book: book, previewEnabled: false)
    
    XCTAssertTrue(buttons.contains(.reserve), "Can hold state should show RESERVE button")
  }
  
  func testButtonState_downloadInProgress_showsCancelButton() {
    let book = createMockEPUBBook()
    let buttons = BookButtonState.downloadInProgress.buttonTypes(book: book)
    
    XCTAssertTrue(buttons.contains(.cancel), "Download in progress should show CANCEL button")
  }
  
  func testButtonState_downloadSuccessful_epub_showsReadButton() {
    let book = createMockEPUBBook()
    let buttons = BookButtonState.downloadSuccessful.buttonTypes(book: book)
    
    XCTAssertTrue(buttons.contains(.read), "Downloaded EPUB should show READ button")
    XCTAssertFalse(buttons.contains(.listen), "Downloaded EPUB should NOT show LISTEN button")
  }
  
  func testButtonState_downloadSuccessful_audiobook_showsListenButton() {
    let book = createMockAudiobook()
    let buttons = BookButtonState.downloadSuccessful.buttonTypes(book: book)
    
    XCTAssertTrue(buttons.contains(.listen), "Downloaded audiobook should show LISTEN button")
    XCTAssertFalse(buttons.contains(.read), "Downloaded audiobook should NOT show READ button")
  }
  
  func testButtonState_holding_showsManageHoldButton() {
    let book = createMockEPUBBook()
    let buttons = BookButtonState.holding.buttonTypes(book: book)
    
    XCTAssertTrue(buttons.contains(.manageHold) || buttons.contains(.cancelHold),
                  "Holding state should show manage or cancel hold button")
  }
  
  func testButtonState_holdingFrontOfQueue_showsManageHold() {
    // Note: holdingFrontOfQueue only shows .get if the book's availability is "ready"
    // Our mock book has standard availability, so it shows .manageHold
    let book = createMockEPUBBook()
    let buttons = BookButtonState.holdingFrontOfQueue.buttonTypes(book: book)
    
    XCTAssertTrue(buttons.contains(.manageHold),
                  "Front of queue with standard availability should show MANAGE HOLD button")
  }
  
  // MARK: - BookImageView Visual Snapshots
  // Uses the REAL BookImageView with TenPrint covers
  
  func testBookImageView_epub_snapshot() {
    guard canRecordSnapshots else { return }
    
    let book = createMockEPUBBook()
    // Verify TenPrint cover is pre-loaded
    XCTAssertNotNil(book.coverImage, "Book should have pre-loaded TenPrint cover")
    
    let view = BookImageView(book: book, height: 200)
      .frame(width: 140, height: 200)
      .background(Color(UIColor.systemBackground))
    
    assertSnapshot(of: view, as: .image)
  }
  
  func testBookImageView_audiobook_snapshot() {
    guard canRecordSnapshots else { return }
    
    let book = createMockAudiobook()
    // Verify TenPrint cover is pre-loaded
    XCTAssertNotNil(book.coverImage, "Audiobook should have pre-loaded TenPrint cover")
    
    let view = BookImageView(book: book, height: 200)
      .frame(width: 140, height: 200)
      .background(Color(UIColor.systemBackground))
    
    assertSnapshot(of: view, as: .image)
  }
  
  func testBookImageView_pdf_snapshot() {
    guard canRecordSnapshots else { return }
    
    let book = createMockPDFBook()
    // Verify TenPrint cover is pre-loaded
    XCTAssertNotNil(book.coverImage, "PDF should have pre-loaded TenPrint cover")
    
    let view = BookImageView(book: book, height: 200)
      .frame(width: 140, height: 200)
      .background(Color(UIColor.systemBackground))
    
    assertSnapshot(of: view, as: .image)
  }
  
  func testBookImageView_holdBook_snapshot() {
    guard canRecordSnapshots else { return }
    
    let book = TPPBookMocker.snapshotHoldBook()
    // Verify TenPrint cover is pre-loaded
    XCTAssertNotNil(book.coverImage, "Hold book should have pre-loaded TenPrint cover")
    
    let view = BookImageView(book: book, height: 200)
      .frame(width: 140, height: 200)
      .background(Color(UIColor.systemBackground))
    
    assertSnapshot(of: view, as: .image)
  }
  
  func testBookImageView_allTypes_grid() {
    guard canRecordSnapshots else { return }
    
    let books = [
      createMockEPUBBook(),
      createMockAudiobook(),
      createMockPDFBook(),
      TPPBookMocker.snapshotHoldBook()
    ]
    
    let view = HStack(spacing: 12) {
      ForEach(books, id: \.identifier) { book in
        VStack {
          BookImageView(book: book, height: 150)
            .frame(width: 100, height: 150)
          Text(book.title)
            .font(.caption)
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .frame(width: 100)
        }
      }
    }
    .padding()
    .background(Color(UIColor.systemBackground))
    
    assertSnapshot(of: view, as: .image)
  }
  
  // MARK: - BookButtonsView Visual Snapshots
  // Tests the REAL button rendering using a mock provider
  
  func testBookButtonsView_canBorrow() {
    guard canRecordSnapshots else { return }
    
    let book = createMockEPUBBook()
    let provider = MockBookButtonProvider(
      book: book,
      buttonTypes: [.get]
    )
    
    let view = BookButtonsView(provider: provider, backgroundColor: .white) { _ in }
      .frame(width: 300)
      .padding()
      .background(Color(UIColor.systemBackground))
    
    assertSnapshot(of: view, as: .image)
  }
  
  func testBookButtonsView_downloadSuccessful_epub() {
    guard canRecordSnapshots else { return }
    
    let book = createMockEPUBBook()
    let provider = MockBookButtonProvider(
      book: book,
      buttonTypes: [.read, .return]
    )
    
    let view = BookButtonsView(provider: provider, backgroundColor: .white) { _ in }
      .frame(width: 300)
      .padding()
      .background(Color(UIColor.systemBackground))
    
    assertSnapshot(of: view, as: .image)
  }
  
  func testBookButtonsView_downloadSuccessful_audiobook() {
    guard canRecordSnapshots else { return }
    
    let book = createMockAudiobook()
    let provider = MockBookButtonProvider(
      book: book,
      buttonTypes: [.listen, .return]
    )
    
    let view = BookButtonsView(provider: provider, backgroundColor: .white) { _ in }
      .frame(width: 300)
      .padding()
      .background(Color(UIColor.systemBackground))
    
    assertSnapshot(of: view, as: .image)
  }
  
  // MARK: - Full BookDetailView Snapshots
  // Tests the complete BookDetailView with TenPrint covers
  
  func testBookDetailView_epub() {
    guard canRecordSnapshots else { return }
    
    let book = createMockEPUBBook()
    XCTAssertNotNil(book.coverImage, "EPUB should have TenPrint cover for snapshot")
    
    let view = BookDetailView(book: book)
      .frame(width: 390, height: 844)
    
    assertSnapshot(of: view, as: .image)
  }
  
  func testBookDetailView_audiobook() {
    guard canRecordSnapshots else { return }
    
    let book = createMockAudiobook()
    XCTAssertNotNil(book.coverImage, "Audiobook should have TenPrint cover for snapshot")
    
    let view = BookDetailView(book: book)
      .frame(width: 390, height: 844)
    
    assertSnapshot(of: view, as: .image)
  }
  
  func testBookDetailView_pdf() {
    guard canRecordSnapshots else { return }
    
    let book = createMockPDFBook()
    XCTAssertNotNil(book.coverImage, "PDF should have TenPrint cover for snapshot")
    
    let view = BookDetailView(book: book)
      .frame(width: 390, height: 844)
    
    assertSnapshot(of: view, as: .image)
  }
  
  func testBookDetailView_holdBook() {
    guard canRecordSnapshots else { return }
    
    let book = TPPBookMocker.snapshotHoldBook()
    XCTAssertNotNil(book.coverImage, "Hold book should have TenPrint cover for snapshot")
    
    let view = BookDetailView(book: book)
      .frame(width: 390, height: 844)
    
    assertSnapshot(of: view, as: .image)
  }
  
  // MARK: - Accessibility Tests
  
  func testAccessibilityIdentifiers_exist() {
    XCTAssertFalse(AccessibilityID.BookDetail.coverImage.isEmpty)
    XCTAssertFalse(AccessibilityID.BookDetail.title.isEmpty)
    XCTAssertFalse(AccessibilityID.BookDetail.author.isEmpty)
    XCTAssertFalse(AccessibilityID.BookDetail.getButton.isEmpty)
    XCTAssertFalse(AccessibilityID.BookDetail.readButton.isEmpty)
    XCTAssertFalse(AccessibilityID.BookDetail.listenButton.isEmpty)
    XCTAssertFalse(AccessibilityID.BookDetail.reserveButton.isEmpty)
  }
  
  // MARK: - TPPBookState Coverage
  
  func testAllBookStates_haveStringValue() {
    for state in TPPBookState.allCases {
      XCTAssertFalse(state.stringValue().isEmpty, "State \(state) should have a string value")
    }
  }
}

// MARK: - Mock Book Button Provider

/// Mock provider for testing BookButtonsView without full ViewModel dependencies
@MainActor
final class MockBookButtonProvider: BookButtonProvider, ObservableObject {
  let book: TPPBook
  @Published var buttonTypes: [BookButtonType]
  
  init(book: TPPBook, buttonTypes: [BookButtonType]) {
    self.book = book
    self.buttonTypes = buttonTypes
  }
  
  func handleAction(for type: BookButtonType) {
    // No-op for tests
  }
  
  func isProcessing(for type: BookButtonType) -> Bool {
    false
  }
}
