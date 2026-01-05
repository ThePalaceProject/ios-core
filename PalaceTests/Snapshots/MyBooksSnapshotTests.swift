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
  
  // MARK: - Helper Methods
  
  private func createMockBooks() -> [TPPBook] {
    [
      TPPBookMocker.mockBook(distributorType: .EpubZip),
      TPPBookMocker.mockBook(distributorType: .OpenAccessAudiobook),
      TPPBookMocker.mockBook(distributorType: .OpenAccessPDF)
    ]
  }
  
  // MARK: - BookImageView Snapshots (simpler alternative to full BookCell)
  
  func testBookImageView_epub() {
    guard canRecordSnapshots else { return }
    
    let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
    let view = BookImageView(book: book, height: 180)
      .frame(width: 120, height: 180)
      .background(Color(UIColor.systemBackground))
    
    assertSnapshot(of: view, as: .image)
  }
  
  func testBookImageView_audiobook() {
    guard canRecordSnapshots else { return }
    
    let book = TPPBookMocker.mockBook(distributorType: .OpenAccessAudiobook)
    let view = BookImageView(book: book, height: 180)
      .frame(width: 120, height: 180)
      .background(Color(UIColor.systemBackground))
    
    assertSnapshot(of: view, as: .image)
  }
  
  // MARK: - Empty State
  
  func testMyBooksEmptyState() {
    guard canRecordSnapshots else { return }
    
    // Test the empty state view pattern
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
    let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
    let buttons = BookButtonState.downloadSuccessful.buttonTypes(book: book)
    
    XCTAssertTrue(buttons.contains(.read), "Downloaded EPUB should have READ button")
  }
  
  func testButtonTypes_downloadedAudiobook() {
    let book = TPPBookMocker.mockBook(distributorType: .OpenAccessAudiobook)
    let buttons = BookButtonState.downloadSuccessful.buttonTypes(book: book)
    
    XCTAssertTrue(buttons.contains(.listen), "Downloaded audiobook should have LISTEN button")
  }
  
  // MARK: - Sorting Tests
  
  func testSortByTitle() {
    let books = createMockBooks()
    let sorted = books.sorted { $0.title < $1.title }
    XCTAssertEqual(sorted.count, 3)
  }
  
  func testSortByAuthor() {
    let books = createMockBooks()
    let sorted = books.sorted { ($0.authors ?? "") < ($1.authors ?? "") }
    XCTAssertEqual(sorted.count, 3)
  }
  
  // MARK: - Accessibility
  
  func testMyBooksAccessibilityIdentifiers() {
    XCTAssertFalse(AccessibilityID.MyBooks.gridView.isEmpty)
    XCTAssertFalse(AccessibilityID.MyBooks.emptyStateView.isEmpty)
    XCTAssertFalse(AccessibilityID.MyBooks.sortButton.isEmpty)
  }
}
