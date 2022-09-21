//
//  BookPreviewTests.swift
//  PalaceTests
//
//  Created by Maurice Carrier on 8/10/22.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

class BookPreviewTests: XCTestCase {
  let testEpubURL = "https://market.feedbooks.com/item/3877422/preview"

  func testEpubDownload() {
    let expectation = expectation(description: "Should download epub file.")

    TPPNetworkExecutor.shared.GET(URL(string: testEpubURL)!) { result in
      switch result {
      case let .success(data, _):
        XCTAssertNotNil(data)
        expectation.fulfill()
      case .failure:
        XCTFail("Failed to fetch epub preview")
      }
    }

    waitForExpectations(timeout: 3.0)
  }

  func testBookPreviewExtraction() throws {
    let acquisitions = [TPPFake.genericAcquisition.dictionaryRepresentation(), TPPFake.genericSample.dictionaryRepresentation()]

    let book = TPPBook(dictionary: [
      "acquisitions": acquisitions,
      "categories" : ["Fantasy"],
      "id": "123",
      "title": "The Lord of the Rings",
      "updated": "2020-09-08T09:22:45Z"
    ])

    XCTAssertNotNil(book?.acquisitions)
    XCTAssertNotNil(book?.sample)
  }
}
