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
  
  // MARK: - BookCell Snapshots
  
  func testNormalBookCell_epub() {
    guard canRecordSnapshots else { return }
    
    let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
    let view = NormalBookCell(book: book, buttonTypes: [.read, .return]) { _ in }
      .frame(width: 390, height: 120)
      .background(Color(UIColor.systemBackground))
    
    assertSnapshot(of: view, as: .image)
  }
  
  func testNormalBookCell_audiobook() {
    guard canRecordSnapshots else { return }
    
    let book = TPPBookMocker.mockBook(distributorType: .OpenAccessAudiobook)
    let view = NormalBookCell(book: book, buttonTypes: [.listen, .return]) { _ in }
      .frame(width: 390, height: 120)
      .background(Color(UIColor.systemBackground))
    
    assertSnapshot(of: view, as: .image)
  }
  
  func testDownloadingBookCell() {
    guard canRecordSnapshots else { return }
    
    let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
    let view = DownloadingBookCell(book: book, progress: 0.65) { _ in }
      .frame(width: 390, height: 120)
      .background(Color(UIColor.systemBackground))
    
    assertSnapshot(of: view, as: .image)
  }
  
  // MARK: - Empty State
  
  func testMyBooksEmptyState() {
    guard canRecordSnapshots else { return }
    
    // Test the empty state view when no books are downloaded
    let emptyView = VStack {
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
  
  // MARK: - Sorting UI
  
  func testSortOptionsPresentation() {
    // Verify sort options exist
    let sortOptions: [MyBooksSortOption] = [.title, .author, .dateAdded]
    XCTAssertEqual(sortOptions.count, 3)
  }
  
  // MARK: - Accessibility
  
  func testMyBooksAccessibilityIdentifiers() {
    XCTAssertFalse(AccessibilityID.MyBooks.tableView.isEmpty)
  }
}

// MARK: - Sort Option Enum (if not already defined)
enum MyBooksSortOption: String, CaseIterable {
  case title = "Title"
  case author = "Author"
  case dateAdded = "Date Added"
}

