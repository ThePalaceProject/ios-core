//
//  TPPOpenSearchDescriptionTests.swift
//  The Palace Project
//
//  Created by Ettore Pasquini on 2/20/20.
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

import XCTest
// @testable import Palace

class TPPOpenSearchDescriptionTests: XCTestCase {
  var searchDescr: TPPOpenSearchDescription!

  override func setUp() {
    super.setUp()
    searchDescr = TPPOpenSearchDescription(title: "title", books: nil)
    searchDescr.opdsurlTemplate = "https://circulation.librarysimplified.org/NYNYPL/search/?entrypoint=All&q={searchTerms}"
  }

  override func tearDown() {
    searchDescr = nil
  }

  func testOPDSURLSearch() {
    let searchURL = searchDescr.opdsurl(forSearching: "Arnold Schönberg & +etc")
    XCTAssertNotNil(searchURL)
    XCTAssertEqual(
      searchURL,
      URL(
        string: "https://circulation.librarysimplified.org/NYNYPL/search/?entrypoint=All&q=Arnold%20Sch%C3%B6nberg%20%26%20%2Betc"
      )!
    )
  }
}
