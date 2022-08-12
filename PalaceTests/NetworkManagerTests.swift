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
    AppNetworkManager.fetchPreview(query: testEpubURL) { result in
      switch result {
      case let .success(model):
        XCTAssertNotNil(model.epubData)
      case .failure:
        XCTFail("Failed to fetch epub preview")
      }
    }
  }
}
