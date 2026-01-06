//
//  BookDetailSnapshotTests.swift
//  PalaceTests
//
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import XCTest
import SwiftUI
import SnapshotTesting
@testable import Palace

@MainActor
final class BookDetailSnapshotTests: XCTestCase {
  
  private var canRecordSnapshots: Bool {
    #if targetEnvironment(simulator)
    return true
    #else
    return false
    #endif
  }
  
  // MARK: - Helpers
  
  private func createMockEPUBBook() -> TPPBook {
    TPPBookMocker.snapshotEPUB()
  }
  
  private func createMockAudiobook() -> TPPBook {
    TPPBookMocker.snapshotAudiobook()
  }
  
  private func createMockPDFBook() -> TPPBook {
    TPPBookMocker.snapshotPDF()
  }
  
  private func createMockHoldBook() -> TPPBook {
    TPPBookMocker.snapshotHoldBook()
  }
  
  // MARK: - BookImageView
  
  func testBookImageView_epub_snapshot() {
    guard canRecordSnapshots else { return }
    
    let book = createMockEPUBBook()
    let view = BookImageView(book: book, height: 280)
      .frame(width: 200, height: 280)
      .background(Color(UIColor.systemBackground))
    
    assertSnapshot(of: view, as: .image)
  }
  
  func testBookImageView_audiobook_snapshot() {
    guard canRecordSnapshots else { return }
    
    let book = createMockAudiobook()
    let view = BookImageView(book: book, height: 280)
      .frame(width: 200, height: 280)
      .background(Color(UIColor.systemBackground))
    
    assertSnapshot(of: view, as: .image)
  }
  
  func testBookImageView_pdf_snapshot() {
    guard canRecordSnapshots else { return }
    
    let book = createMockPDFBook()
    let view = BookImageView(book: book, height: 280)
      .frame(width: 200, height: 280)
      .background(Color(UIColor.systemBackground))
    
    assertSnapshot(of: view, as: .image)
  }
  
  func testBookImageView_holdBook_snapshot() {
    guard canRecordSnapshots else { return }
    
    let book = createMockHoldBook()
    let view = BookImageView(book: book, height: 280)
      .frame(width: 200, height: 280)
      .background(Color(UIColor.systemBackground))
    
    assertSnapshot(of: view, as: .image)
  }
  
  func testBookImageView_allTypes_grid() {
    guard canRecordSnapshots else { return }
    
    let books = [
      createMockEPUBBook(),
      createMockAudiobook(),
      createMockPDFBook(),
      createMockHoldBook()
    ]
    
    let view = HStack(spacing: 12) {
      ForEach(books, id: \.identifier) { book in
        BookImageView(book: book, height: 150)
          .frame(width: 100, height: 150)
      }
    }
    .padding()
    .background(Color(UIColor.systemBackground))
    
    assertSnapshot(of: view, as: .image)
  }
  
  // MARK: - BookDetailView
  
  func testBookDetailView_epub() {
    guard canRecordSnapshots else { return }
    
    let book = createMockEPUBBook()
    let view = BookDetailView(book: book)
      .frame(width: 390, height: 700)
    
    assertSnapshot(of: view, as: .image)
  }
  
  func testBookDetailView_audiobook() {
    guard canRecordSnapshots else { return }
    
    let book = createMockAudiobook()
    let view = BookDetailView(book: book)
      .frame(width: 390, height: 700)
    
    assertSnapshot(of: view, as: .image)
  }
  
  func testBookDetailView_pdf() {
    guard canRecordSnapshots else { return }
    
    let book = createMockPDFBook()
    let view = BookDetailView(book: book)
      .frame(width: 390, height: 700)
    
    assertSnapshot(of: view, as: .image)
  }
  
  func testBookDetailView_holdBook() {
    guard canRecordSnapshots else { return }
    
    let book = createMockHoldBook()
    let view = BookDetailView(book: book)
      .frame(width: 390, height: 700)
    
    assertSnapshot(of: view, as: .image)
  }
  
  // MARK: - BookButtonsView
  
  func testBookButtonsView_canBorrow() {
    guard canRecordSnapshots else { return }
    
    let book = createMockEPUBBook()
    let provider = MockBookButtonProvider(book: book, state: .canBorrow)
    
    let view = BookButtonsView(provider: provider)
      .frame(width: 390)
      .padding()
      .background(Color(UIColor.systemBackground))
    
    assertSnapshot(of: view, as: .image)
  }
  
  func testBookButtonsView_downloadSuccessful_epub() {
    guard canRecordSnapshots else { return }
    
    let book = createMockEPUBBook()
    let provider = MockBookButtonProvider(book: book, state: .downloadSuccessful)
    
    let view = BookButtonsView(provider: provider)
      .frame(width: 390)
      .padding()
      .background(Color(UIColor.systemBackground))
    
    assertSnapshot(of: view, as: .image)
  }
  
  func testBookButtonsView_downloadSuccessful_audiobook() {
    guard canRecordSnapshots else { return }
    
    let book = createMockAudiobook()
    let provider = MockBookButtonProvider(book: book, state: .downloadSuccessful)
    
    let view = BookButtonsView(provider: provider)
      .frame(width: 390)
      .padding()
      .background(Color(UIColor.systemBackground))
    
    assertSnapshot(of: view, as: .image)
  }
  
  // MARK: - Button State Logic
  
  func testButtonState_canBorrow_showsBorrowButton() {
    let book = createMockEPUBBook()
    let buttons = BookButtonState.canBorrow.buttonTypes(book: book)
    XCTAssertTrue(buttons.contains(.get))
  }
  
  func testButtonState_downloadSuccessful_epub_showsReadButton() {
    let book = createMockEPUBBook()
    let buttons = BookButtonState.downloadSuccessful.buttonTypes(book: book)
    XCTAssertTrue(buttons.contains(.read))
  }
  
  func testButtonState_downloadSuccessful_audiobook_showsListenButton() {
    let book = createMockAudiobook()
    let buttons = BookButtonState.downloadSuccessful.buttonTypes(book: book)
    XCTAssertTrue(buttons.contains(.listen))
  }
  
  func testButtonState_holdingFrontOfQueue_showsManageHold() {
    let book = createMockHoldBook()
    let buttons = BookButtonState.holdingFrontOfQueue.buttonTypes(book: book)
    XCTAssertTrue(buttons.contains(.manageHold))
  }
  
  // MARK: - Accessibility
  
  func testBookDetailAccessibilityIdentifiers() {
    XCTAssertFalse(AccessibilityID.BookDetail.coverImage.isEmpty)
    XCTAssertFalse(AccessibilityID.BookDetail.title.isEmpty)
    XCTAssertFalse(AccessibilityID.BookDetail.author.isEmpty)
    XCTAssertFalse(AccessibilityID.BookDetail.getButton.isEmpty)
  }
}

// MARK: - MockBookButtonProvider

private class MockBookButtonProvider: BookButtonProvider {
  let book: TPPBook
  let state: BookButtonState
  
  init(book: TPPBook, state: BookButtonState) {
    self.book = book
    self.state = state
  }
  
  var buttonTypes: [BookButtonType] {
    state.buttonTypes(book: book)
  }
  
  func handleAction(for type: BookButtonType) {}
  
  func isProcessing(for type: BookButtonType) -> Bool { false }
}
