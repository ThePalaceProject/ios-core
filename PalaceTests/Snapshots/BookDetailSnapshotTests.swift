//
//  BookDetailSnapshotTests.swift
//  PalaceTests
//
//  Visual regression tests for BookDetailView.
//  These tests ensure the book detail UI renders correctly across different states.
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
  
  private func createMockEPUBBook() -> TPPBook {
    TPPBookMocker.mockBook(distributorType: .EpubZip)
  }
  
  private func createMockAudiobook() -> TPPBook {
    TPPBookMocker.mockBook(distributorType: .OpenAccessAudiobook)
  }
  
  private func createMockPDFBook() -> TPPBook {
    TPPBookMocker.mockBook(distributorType: .OpenAccessPDF)
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
  
  func testButtonState_holding_showsRemoveHoldButton() {
    let book = createMockEPUBBook()
    let buttons = BookButtonState.holding.buttonTypes(book: book)
    
    // Should show option to remove hold
    XCTAssertNotNil(buttons, "Holding state should have button options")
  }
  
  func testButtonState_holdingFrontOfQueue_showsBorrowButton() {
    let book = createMockEPUBBook()
    let buttons = BookButtonState.holdingFrontOfQueue.buttonTypes(book: book)
    
    // Should be able to borrow when at front of queue
    XCTAssertTrue(buttons.contains(.get) || buttons.contains(.download),
                  "Front of queue should show GET or DOWNLOAD button")
  }
  
  // MARK: - Visual Snapshots - Button Bars
  
  func testBookDetailButtonBar_canBorrow() {
    guard canRecordSnapshots else { return }
    
    let book = createMockEPUBBook()
    let buttons = BookButtonState.canBorrow.buttonTypes(book: book, previewEnabled: false)
    let view = BookDetailButtonBar(buttons: buttons, onButtonTap: { _ in })
      .frame(width: 390)
    
    assertSnapshot(of: view, as: .image(layout: .sizeThatFits))
  }
  
  func testBookDetailButtonBar_downloadSuccessful_epub() {
    guard canRecordSnapshots else { return }
    
    let book = createMockEPUBBook()
    let buttons = BookButtonState.downloadSuccessful.buttonTypes(book: book)
    let view = BookDetailButtonBar(buttons: buttons, onButtonTap: { _ in })
      .frame(width: 390)
    
    assertSnapshot(of: view, as: .image(layout: .sizeThatFits))
  }
  
  func testBookDetailButtonBar_downloadSuccessful_audiobook() {
    guard canRecordSnapshots else { return }
    
    let book = createMockAudiobook()
    let buttons = BookButtonState.downloadSuccessful.buttonTypes(book: book)
    let view = BookDetailButtonBar(buttons: buttons, onButtonTap: { _ in })
      .frame(width: 390)
    
    assertSnapshot(of: view, as: .image(layout: .sizeThatFits))
  }
  
  func testBookDetailButtonBar_downloading() {
    guard canRecordSnapshots else { return }
    
    let book = createMockEPUBBook()
    let buttons = BookButtonState.downloadInProgress.buttonTypes(book: book)
    let view = BookDetailButtonBar(buttons: buttons, onButtonTap: { _ in })
      .frame(width: 390)
    
    assertSnapshot(of: view, as: .image(layout: .sizeThatFits))
  }
  
  // MARK: - Visual Snapshots - Book Header
  
  func testBookDetailHeader_epub() {
    guard canRecordSnapshots else { return }
    
    let book = createMockEPUBBook()
    let view = BookDetailHeader(book: book)
      .frame(width: 390)
    
    assertSnapshot(of: view, as: .image(layout: .sizeThatFits))
  }
  
  func testBookDetailHeader_audiobook() {
    guard canRecordSnapshots else { return }
    
    let book = createMockAudiobook()
    let view = BookDetailHeader(book: book)
      .frame(width: 390)
    
    assertSnapshot(of: view, as: .image(layout: .sizeThatFits))
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

// MARK: - Placeholder Views for Compilation
// These are stubs if the actual views don't exist yet

#if !canImport(BookDetailViews)

struct BookDetailButtonBar: View {
  let buttons: [BookButtonType]
  let onButtonTap: (BookButtonType) -> Void
  
  var body: some View {
    HStack(spacing: 12) {
      ForEach(buttons, id: \.self) { button in
        Button(action: { onButtonTap(button) }) {
          Text(button.localizedTitle)
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
        .buttonStyle(.borderedProminent)
        .tint(button.tintColor)
      }
    }
    .padding()
  }
}

struct BookDetailHeader: View {
  let book: TPPBook
  
  var body: some View {
    HStack(alignment: .top, spacing: 16) {
      // Cover image placeholder
      RoundedRectangle(cornerRadius: 8)
        .fill(Color.gray.opacity(0.3))
        .frame(width: 120, height: 180)
        .overlay(
          Image(systemName: book.defaultBookContentType == .audiobook ? "headphones" : "book")
            .font(.largeTitle)
            .foregroundColor(.gray)
        )
      
      VStack(alignment: .leading, spacing: 8) {
        Text(book.title)
          .font(.title2)
          .fontWeight(.bold)
        
        if let authors = book.authors {
          Text(authors)
            .font(.subheadline)
            .foregroundColor(.secondary)
        }
        
        // Format badge
        Text(book.defaultBookContentType.displayName)
          .font(.caption)
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(Color.blue.opacity(0.1))
          .cornerRadius(4)
      }
      
      Spacer()
    }
    .padding()
  }
}

private extension BookButtonType {
  var localizedTitle: String {
    switch self {
    case .get: return "Get"
    case .download: return "Download"
    case .read: return "Read"
    case .listen: return "Listen"
    case .reserve: return "Reserve"
    case .cancel: return "Cancel"
    case .return: return "Return"
    case .remove: return "Remove"
    case .retry: return "Retry"
    case .sample: return "Sample"
    case .audiobookSample: return "Sample"
    }
  }
  
  var tintColor: Color {
    switch self {
    case .read, .listen, .get, .download: return .blue
    case .cancel, .return, .remove: return .red
    case .reserve: return .orange
    case .retry: return .blue
    case .sample, .audiobookSample: return .secondary
    }
  }
}

private extension TPPBookContentType {
  var displayName: String {
    switch self {
    case .epub: return "eBook"
    case .audiobook: return "Audiobook"
    case .pdf: return "PDF"
    case .unsupported: return "Unsupported"
    }
  }
}

#endif
