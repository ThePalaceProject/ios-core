//
//  NetworkManagerTests.swift
//  PalaceTests
//
//  Created by Maurice Carrier on 8/10/22.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

class NetworkManagerTests: XCTestCase {

  let testEpubURL = "https://market.feedbooks.com/item/3877422/preview"

  func testEpubDownload() {
    let expectation = expectation(description: "Should download epub file.")

    AppNetworkManager.fetchPreview(query: testEpubURL) { result in
      switch result {
      case let .success(model):
        XCTAssertNotNil(model.epubData)
        expectation.fulfill()
      case .failure:
        XCTFail("Failed to fetch epub preview")
      }
    }
    
    waitForExpectations(timeout: 1.0)
  }
}
