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
