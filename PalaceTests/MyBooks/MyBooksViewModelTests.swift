//
//  MyBooksViewModelTests.swift
//  PalaceTests
//
//  Tests for MyBooksViewModel, Facet enum and AlertModel.
//
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import XCTest
import Combine
@testable import Palace

// MARK: - Facet & AlertModel Tests

final class MyBooksViewModelTests: XCTestCase {
  
  // MARK: - Facet Enum Tests
  
  func testFacet_AuthorLocalizedString() {
    let facet = Facet.author
    XCTAssertEqual(facet.localizedString, Strings.FacetView.author)
  }
  
  func testFacet_TitleLocalizedString() {
    let facet = Facet.title
    XCTAssertEqual(facet.localizedString, Strings.FacetView.title)
  }
  
  func testFacet_RawValues() {
    XCTAssertEqual(Facet.author.rawValue, "author")
    XCTAssertEqual(Facet.title.rawValue, "title")
  }
  
  // MARK: - AlertModel Tests
  
  func testAlertModel_CreationWithMessage() {
    let alert = AlertModel(
      title: "Error",
      message: "Something went wrong"
    )
    
    XCTAssertEqual(alert.title, "Error")
    XCTAssertEqual(alert.message, "Something went wrong")
  }
  
  func testAlertModel_SyncingAlert() {
    let title = Strings.MyBooksView.accountSyncingAlertTitle
    let message = Strings.MyBooksView.accountSyncingAlertMessage
    
    let alert = AlertModel(title: title, message: message)
    
    XCTAssertNotNil(alert.title)
    XCTAssertNotNil(alert.message)
  }
  
  // MARK: - Group Enum Tests
  
  func testGroupRawValue() {
    XCTAssertEqual(Group.groupSortBy.rawValue, 0)
  }
}

// MARK: - MyBooksViewModel Tests

@MainActor
final class MyBooksViewModelExtendedTests: XCTestCase {
  
  private var cancellables: Set<AnyCancellable> = []
  
  override func setUp() {
    super.setUp()
    cancellables = []
  }
  
  override func tearDown() {
    cancellables.removeAll()
    super.tearDown()
  }
  
  // MARK: - Initialization Tests
  
  func testInitialState() {
    let viewModel = MyBooksViewModel()
    
    XCTAssertFalse(viewModel.isLoading)
    XCTAssertNil(viewModel.alert)
    XCTAssertEqual(viewModel.searchQuery, "")
    XCTAssertFalse(viewModel.showSearchSheet)
    XCTAssertFalse(viewModel.selectNewLibrary)
    XCTAssertFalse(viewModel.showLibraryAccountView)
    XCTAssertNil(viewModel.selectedBook)
  }
  
  func testInitialFacetSort() {
    let viewModel = MyBooksViewModel()
    // activeFacetSort is initially .author but immediately gets updated
    // by the publisher from facetViewModel.$activeSort which is .title (first in [.title, .author])
    XCTAssertEqual(viewModel.activeFacetSort, .title)
  }
  
  func testFacetViewModelInitialized() {
    let viewModel = MyBooksViewModel()
    
    XCTAssertNotNil(viewModel.facetViewModel)
    XCTAssertEqual(viewModel.facetViewModel.facets, [.title, .author])
    XCTAssertEqual(viewModel.facetViewModel.groupName, Strings.MyBooksView.sortBy)
  }
  
  // MARK: - Published Properties Tests
  
  func testSearchQueryPublishes() {
    let viewModel = MyBooksViewModel()
    
    let expectation = XCTestExpectation(description: "searchQuery should publish")
    
    viewModel.$searchQuery
      .dropFirst()
      .sink { newValue in
        XCTAssertEqual(newValue, "Test Query")
        expectation.fulfill()
      }
      .store(in: &cancellables)
    
    viewModel.searchQuery = "Test Query"
    
    wait(for: [expectation], timeout: 1.0)
  }
  
  func testShowSearchSheetPublishes() {
    let viewModel = MyBooksViewModel()
    
    let expectation = XCTestExpectation(description: "showSearchSheet should publish")
    
    viewModel.$showSearchSheet
      .dropFirst()
      .sink { newValue in
        XCTAssertTrue(newValue)
        expectation.fulfill()
      }
      .store(in: &cancellables)
    
    viewModel.showSearchSheet = true
    
    wait(for: [expectation], timeout: 1.0)
  }
  
  func testSelectedBookPublishes() {
    let viewModel = MyBooksViewModel()
    let mockBook = TPPBookMocker.mockBook(identifier: "test-book", title: "Test Book")
    
    let expectation = XCTestExpectation(description: "selectedBook should publish")
    
    viewModel.$selectedBook
      .dropFirst()
      .sink { newBook in
        XCTAssertNotNil(newBook)
        XCTAssertEqual(newBook?.identifier, "test-book")
        expectation.fulfill()
      }
      .store(in: &cancellables)
    
    viewModel.selectedBook = mockBook
    
    wait(for: [expectation], timeout: 1.0)
  }
  
  // MARK: - UI State Toggle Tests
  
  func testShowSearchSheetToggle() {
    let viewModel = MyBooksViewModel()
    
    XCTAssertFalse(viewModel.showSearchSheet)
    viewModel.showSearchSheet = true
    XCTAssertTrue(viewModel.showSearchSheet)
    viewModel.showSearchSheet = false
    XCTAssertFalse(viewModel.showSearchSheet)
  }
  
  func testSelectNewLibraryToggle() {
    let viewModel = MyBooksViewModel()
    
    XCTAssertFalse(viewModel.selectNewLibrary)
    viewModel.selectNewLibrary = true
    XCTAssertTrue(viewModel.selectNewLibrary)
  }
  
  func testShowLibraryAccountViewToggle() {
    let viewModel = MyBooksViewModel()
    
    XCTAssertFalse(viewModel.showLibraryAccountView)
    viewModel.showLibraryAccountView = true
    XCTAssertTrue(viewModel.showLibraryAccountView)
  }
  
  // MARK: - Facet Sort Binding Tests
  
  func testActiveFacetSortUpdatesWhenFacetViewModelChanges() {
    let viewModel = MyBooksViewModel()
    
    let expectation = XCTestExpectation(description: "activeFacetSort should update")
    
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
      viewModel.facetViewModel.activeSort = .title
      
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
        XCTAssertEqual(viewModel.activeFacetSort, .title)
        expectation.fulfill()
      }
    }
    
    wait(for: [expectation], timeout: 1.0)
  }
  
  // MARK: - Device Type Tests
  
  func testIsPadProperty() {
    let viewModel = MyBooksViewModel()
    XCTAssertEqual(viewModel.isPad, UIDevice.current.isIpad)
  }
}
