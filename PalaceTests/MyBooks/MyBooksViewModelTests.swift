//
//  MyBooksViewModelTests.swift
//  PalaceTests
//
//  Tests for Facet enum and AlertModel used in MyBooks functionality.
//
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

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
}
