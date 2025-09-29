//
//  TPPBookmarkSpecTests.swift
//  The Palace Project
//
//  Created by Ettore Pasquini on 3/22/21.
//  Copyright © 2021 NYPL Labs. All rights reserved.
//

import XCTest
@testable import Palace

// TODO: SIMPLY-3645
class TPPBookmarkSpecTests: XCTestCase {
  override func setUpWithError() throws {}

  override func tearDownWithError() throws {}

  func testBookmarkMotivationKeyword() throws {
    XCTAssert(
      TPPBookmarkSpec.Motivation.bookmark.rawValue
        .contains(TPPBookmarkSpec.Motivation.bookmarkingKeyword)
    )
  }
}
