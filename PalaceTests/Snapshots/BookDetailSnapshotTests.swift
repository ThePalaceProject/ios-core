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
  
  func testButtonState_holding_showsManageHoldButton() {
    let book = createMockEPUBBook()
    let buttons = BookButtonState.holding.buttonTypes(book: book)
    
    XCTAssertTrue(buttons.contains(.manageHold) || buttons.contains(.cancelHold),
                  "Holding state should show manage or cancel hold button")
  }
  
  func testButtonState_holdingFrontOfQueue_showsBorrowButton() {
    let book = createMockEPUBBook()
    let buttons = BookButtonState.holdingFrontOfQueue.buttonTypes(book: book)
    
    XCTAssertTrue(buttons.contains(.get) || buttons.contains(.download),
                  "Front of queue should show GET or DOWNLOAD button")
  }
  
  // MARK: - BookImageView Visual Snapshots
  // Uses the REAL BookImageView from the app
  
  func testBookImageView_epub_snapshot() {
    guard canRecordSnapshots else { return }
    
    let book = createMockEPUBBook()
    let view = BookImageView(book: book, height: 200)
      .frame(width: 140, height: 200)
      .background(Color(UIColor.systemBackground))
    
    assertSnapshot(of: view, as: .image)
  }
  
  func testBookImageView_audiobook_snapshot() {
    guard canRecordSnapshots else { return }
    
    let book = createMockAudiobook()
    let view = BookImageView(book: book, height: 200)
      .frame(width: 140, height: 200)
      .background(Color(UIColor.systemBackground))
    
    assertSnapshot(of: view, as: .image)
  }
  
  // MARK: - BookButtonsView Visual Snapshots
  // Tests the REAL button rendering
  
  func testBookButtonsView_canBorrow() {
    guard canRecordSnapshots else { return }
    
    let book = createMockEPUBBook()
    let mockRegistry = TPPBookRegistryMock()
    mockRegistry.addBook(book, state: .unregistered)
    
    let viewModel = BookDetailViewModel(
      book: book,
      bookRegistry: mockRegistry,
      bookDownloadsCenter: TPPMyBooksDownloadsCenterMock(),
      networkExecutor: TPPRequestExecutorMock(),
      drmAuthorizer: TPPDRMAuthorizingMock()
    )
    
    let view = BookButtonsView(provider: viewModel, backgroundColor: .white) { _ in }
      .frame(width: 300)
      .padding()
      .background(Color(UIColor.systemBackground))
    
    assertSnapshot(of: view, as: .image)
  }
  
  func testBookButtonsView_downloadSuccessful_epub() {
    guard canRecordSnapshots else { return }
    
    let book = createMockEPUBBook()
    let mockRegistry = TPPBookRegistryMock()
    mockRegistry.addBook(book, state: .downloadSuccessful)
    
    let viewModel = BookDetailViewModel(
      book: book,
      bookRegistry: mockRegistry,
      bookDownloadsCenter: TPPMyBooksDownloadsCenterMock(),
      networkExecutor: TPPRequestExecutorMock(),
      drmAuthorizer: TPPDRMAuthorizingMock()
    )
    
    let view = BookButtonsView(provider: viewModel, backgroundColor: .white) { _ in }
      .frame(width: 300)
      .padding()
      .background(Color(UIColor.systemBackground))
    
    assertSnapshot(of: view, as: .image)
  }
  
  func testBookButtonsView_downloadSuccessful_audiobook() {
    guard canRecordSnapshots else { return }
    
    let book = createMockAudiobook()
    let mockRegistry = TPPBookRegistryMock()
    mockRegistry.addBook(book, state: .downloadSuccessful)
    
    let viewModel = BookDetailViewModel(
      book: book,
      bookRegistry: mockRegistry,
      bookDownloadsCenter: TPPMyBooksDownloadsCenterMock(),
      networkExecutor: TPPRequestExecutorMock(),
      drmAuthorizer: TPPDRMAuthorizingMock()
    )
    
    let view = BookButtonsView(provider: viewModel, backgroundColor: .white) { _ in }
      .frame(width: 300)
      .padding()
      .background(Color(UIColor.systemBackground))
    
    assertSnapshot(of: view, as: .image)
  }
  
  // MARK: - Full BookDetailView Snapshots (if feasible)
  // Note: Full view may require more setup due to navigation/environment
  
  func testBookDetailView_epub_initialState() {
    guard canRecordSnapshots else { return }
    
    let book = createMockEPUBBook()
    let view = BookDetailView(book: book)
      .frame(width: 390, height: 844)
    
    // This may need NavigationStack wrapper depending on view requirements
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
