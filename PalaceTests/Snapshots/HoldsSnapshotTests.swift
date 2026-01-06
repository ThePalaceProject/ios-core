//
//  HoldsSnapshotTests.swift
//  PalaceTests
//
//  Snapshot tests for Holds/Reservations views.
//

import XCTest
import SwiftUI
import SnapshotTesting
@testable import Palace

@MainActor
final class HoldsSnapshotTests: XCTestCase {
  
  private var canRecordSnapshots: Bool {
    ProcessInfo.processInfo.environment["RECORD_SNAPSHOTS"] != nil || isRecording
  }
  
  override func setUp() {
    super.setUp()
    isRecording = false
  }
  
  // MARK: - Empty State Tests
  
  func testHoldsEmptyState() {
    let emptyView = VStack {
      Text(Strings.HoldsView.emptyMessage)
        .multilineTextAlignment(.center)
        .foregroundColor(Color(white: 0.667))
        .font(.system(size: 18))
        .padding(.horizontal, 24)
    }
    .frame(width: 390, height: 400)
    .background(Color(UIColor.systemBackground))
    
    assertSnapshot(of: emptyView, as: .image)
  }
  
  func testHoldsEmptyState_darkMode() {
    let emptyView = VStack {
      Text(Strings.HoldsView.emptyMessage)
        .multilineTextAlignment(.center)
        .foregroundColor(Color(white: 0.667))
        .font(.system(size: 18))
        .padding(.horizontal, 24)
    }
    .frame(width: 390, height: 400)
    .background(Color(UIColor.systemBackground))
    .colorScheme(.dark)
    
    assertSnapshot(of: emptyView, as: .image)
  }
  
  // MARK: - Loading State Tests
  
  func testHoldsLoadingState() {
    let loadingView = BookListSkeletonView(rows: 5)
      .frame(width: 390, height: 600)
      .background(Color(UIColor.systemBackground))
    
    assertSnapshot(of: loadingView, as: .image)
  }
  
  // MARK: - Book List Tests
  
  func testHoldsBookList() {
    let books = [
      TPPBookMocker.snapshotHoldBook(),
      TPPBookMocker.snapshotEPUB(),
      TPPBookMocker.snapshotAudiobook()
    ]
    
    for book in books {
      XCTAssertNotNil(book.coverImage, "Book \(book.title) should have cover image")
    }
    
    let bookListView = BookListView(
      books: books,
      isLoading: .constant(false),
      onSelect: { _ in }
    )
    .frame(width: 390, height: 600)
    .padding(.horizontal, 8)
    .background(Color(UIColor.systemBackground))
    
    assertSnapshot(of: bookListView, as: .image)
  }
  
  func testHoldsBookList_darkMode() {
    let books = [
      TPPBookMocker.snapshotHoldBook(),
      TPPBookMocker.snapshotEPUB()
    ]
    
    let bookListView = BookListView(
      books: books,
      isLoading: .constant(false),
      onSelect: { _ in }
    )
    .frame(width: 390, height: 400)
    .padding(.horizontal, 8)
    .background(Color(UIColor.systemBackground))
    .colorScheme(.dark)
    
    assertSnapshot(of: bookListView, as: .image)
  }
  
  // MARK: - Search Bar Tests
  
  func testHoldsSearchBar_empty() {
    let searchBar = HStack {
      TextField(NSLocalizedString("Search Reservations", comment: ""), text: .constant(""))
        .searchBarStyle()
      Button(action: {}, label: {
        Image(systemName: "xmark.circle.fill")
          .foregroundColor(.gray)
      })
    }
    .padding(.horizontal)
    .frame(width: 390, height: 60)
    .background(Color(UIColor.systemBackground))
    
    assertSnapshot(of: searchBar, as: .image)
  }
  
  func testHoldsSearchBar_withText() {
    let searchBar = HStack {
      TextField(NSLocalizedString("Search Reservations", comment: ""), text: .constant("Harry Potter"))
        .searchBarStyle()
      Button(action: {}, label: {
        Image(systemName: "xmark.circle.fill")
          .foregroundColor(.gray)
      })
    }
    .padding(.horizontal)
    .frame(width: 390, height: 60)
    .background(Color(UIColor.systemBackground))
    
    assertSnapshot(of: searchBar, as: .image)
  }
}

