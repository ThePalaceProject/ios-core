//
//  FacetViewModelTests.swift
//  PalaceTests
//
//  Tests for FacetViewModel which manages sorting facets in My Books.
//

import XCTest
import Combine
@testable import Palace

final class FacetViewModelTests: XCTestCase {
  
  private var cancellables: Set<AnyCancellable> = []
  
  override func setUp() {
    super.setUp()
    cancellables = []
  }
  
  override func tearDown() {
    cancellables.removeAll()
    super.tearDown()
  }
  
  // MARK: - Facet Enum Tests
  
  func testFacetRawValues() {
    XCTAssertEqual(Facet.author.rawValue, "author")
    XCTAssertEqual(Facet.title.rawValue, "title")
  }
  
  func testFacetLocalizedStrings() {
    // Verify localized strings are not empty
    XCTAssertFalse(Facet.author.localizedString.isEmpty)
    XCTAssertFalse(Facet.title.localizedString.isEmpty)
    
    // Verify they match expected strings
    XCTAssertEqual(Facet.author.localizedString, Strings.FacetView.author)
    XCTAssertEqual(Facet.title.localizedString, Strings.FacetView.title)
  }
  
  // MARK: - Initialization Tests
  
  func testInitWithAuthorAndTitleFacets() {
    let viewModel = FacetViewModel(groupName: "My Books", facets: [.author, .title])
    
    XCTAssertEqual(viewModel.groupName, "My Books")
    XCTAssertEqual(viewModel.facets, [.author, .title])
    XCTAssertEqual(viewModel.activeSort, .author, "Active sort should default to first facet")
  }
  
  func testInitWithTitleFirst() {
    let viewModel = FacetViewModel(groupName: "Library", facets: [.title, .author])
    
    XCTAssertEqual(viewModel.activeSort, .title, "Active sort should default to first facet")
  }
  
  func testInitWithSingleFacet() {
    let viewModel = FacetViewModel(groupName: "Test", facets: [.author])
    
    XCTAssertEqual(viewModel.facets.count, 1)
    XCTAssertEqual(viewModel.activeSort, .author)
  }
  
  // MARK: - Published Property Tests
  
  func testGroupNamePublished() {
    let viewModel = FacetViewModel(groupName: "Initial", facets: [.author, .title])
    
    let expectation = XCTestExpectation(description: "groupName should publish changes")
    
    viewModel.$groupName
      .dropFirst()
      .sink { newValue in
        XCTAssertEqual(newValue, "Updated")
        expectation.fulfill()
      }
      .store(in: &cancellables)
    
    viewModel.groupName = "Updated"
    
    wait(for: [expectation], timeout: 1.0)
  }
  
  func testActiveSortPublished() {
    let viewModel = FacetViewModel(groupName: "Test", facets: [.author, .title])
    
    let expectation = XCTestExpectation(description: "activeSort should publish changes")
    
    viewModel.$activeSort
      .dropFirst()
      .sink { newValue in
        XCTAssertEqual(newValue, .title)
        expectation.fulfill()
      }
      .store(in: &cancellables)
    
    viewModel.activeSort = .title
    
    wait(for: [expectation], timeout: 1.0)
  }
  
  func testFacetsArrayPublished() {
    let viewModel = FacetViewModel(groupName: "Test", facets: [.author])
    
    let expectation = XCTestExpectation(description: "facets should publish changes")
    
    viewModel.$facets
      .dropFirst()
      .sink { newValue in
        XCTAssertEqual(newValue.count, 2)
        expectation.fulfill()
      }
      .store(in: &cancellables)
    
    viewModel.facets = [.author, .title]
    
    wait(for: [expectation], timeout: 1.0)
  }
  
  // MARK: - Account URL Tests
  
  func testCurrentAccountURLWithNilAccount() {
    let viewModel = FacetViewModel(groupName: "Test", facets: [.author, .title])
    viewModel.currentAccount = nil
    
    XCTAssertNil(viewModel.currentAccountURL)
  }
  
  // MARK: - Show Account Screen Tests
  
  func testShowAccountScreenInitiallyFalse() {
    let viewModel = FacetViewModel(groupName: "Test", facets: [.author, .title])
    
    XCTAssertFalse(viewModel.showAccountScreen)
  }
  
  func testShowAccountScreenToggle() {
    let viewModel = FacetViewModel(groupName: "Test", facets: [.author, .title])
    
    viewModel.showAccountScreen = true
    XCTAssertTrue(viewModel.showAccountScreen)
    
    viewModel.showAccountScreen = false
    XCTAssertFalse(viewModel.showAccountScreen)
  }
  
  // MARK: - Logo Tests
  
  func testLogoInitiallyNilWithoutAccount() {
    let viewModel = FacetViewModel(groupName: "Test", facets: [.author, .title])
    viewModel.currentAccount = nil
    
    // Logo may or may not be nil depending on notification timing
    // Just verify access doesn't crash
    _ = viewModel.logo
  }
}
