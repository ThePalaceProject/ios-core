//
//  TPPBookCreationTests.swift
//  The Palace Project
//
//  Created by Ettore Pasquini on 10/27/20.
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

import XCTest
@testable import Palace

class TPPBookCreationTests: XCTestCase {
  var opdsEntry: TPPOPDSEntry!
  var opdsEntryMinimal: TPPOPDSEntry!

  override func setUpWithError() throws {
    try super.setUpWithError()
    opdsEntry = TPPFake.opdsEntry
    opdsEntryMinimal = TPPFake.opdsEntryMinimal
  }

  override func tearDownWithError() throws {
    try super.tearDownWithError()
    opdsEntry = nil
    opdsEntryMinimal = nil
  }

  func testBookCreationViaDictionary() throws {
    let acquisitions = [TPPFake.genericAcquisition.dictionaryRepresentation()]

    let book = TPPBook(dictionary: [
      "acquisitions": acquisitions,
      "categories": ["Fantasy"],
      "id": "666",
      "title": "The Lord of the Rings",
      "updated": "2020-09-08T09:22:45Z"
    ])
    XCTAssertNotNil(book)
    XCTAssertNotNil(book?.acquisitions)
    XCTAssertNotNil(book?.categoryStrings)
    XCTAssertNotNil(book?.identifier)
    XCTAssertNotNil(book?.title)
    XCTAssertNotNil(book?.updated)
    XCTAssertNoThrow(book?.loggableShortString())
    XCTAssertNoThrow(book?.loggableDictionary())

    let bookNoUpdatedDate = TPPBook(dictionary: [
      "acquisitions": acquisitions,
      "categories": ["Fantasy"],
      "id": "666",
      "title": "The Lord of the Rings"
    ])
    XCTAssertNil(bookNoUpdatedDate)

    let bookNoTitle = TPPBook(dictionary: [
      "acquisitions": acquisitions,
      "categories": ["Fantasy"],
      "id": "666",
      "updated": "2020-09-08T09:22:45Z"
    ])
    XCTAssertNil(bookNoTitle)

    let bookNoId = TPPBook(dictionary: [
      "acquisitions": acquisitions,
      "categories": ["Fantasy"],
      "title": "The Lord of the Rings",
      "updated": "2020-09-08T09:22:45Z"
    ])
    XCTAssertNil(bookNoId)

    let bookNoCategories = TPPBook(dictionary: [
      "acquisitions": acquisitions,
      "id": "666",
      "title": "The Lord of the Rings",
      "updated": "2020-09-08T09:22:45Z"
    ])
    XCTAssertNil(bookNoCategories)

    /*
     Note that we do not test the absence of acquisitions. The current code
     for the dictionary initializer *allows* object creation for a dictionary
     with no acquisitions. However this is not something we must necessarily
     ensure because
     (1) the TPPBook(entry:) initializer does NOT allow it,
     (2) a book with no acquisitions is a book the user won't be able to read,
     so useful only to look at the metadata
     */
  }

  func testBookCreationViaFactoryMethod() {
    let bookWithNoCategories = TPPBook(entry: opdsEntryMinimal)
    XCTAssertNotNil(bookWithNoCategories)
    XCTAssertNotNil(bookWithNoCategories?.acquisitions)
    XCTAssertNotNil(bookWithNoCategories?.categoryStrings)
    XCTAssertNotNil(bookWithNoCategories?.identifier)
    XCTAssertNotNil(bookWithNoCategories?.title)
    XCTAssertNotNil(bookWithNoCategories?.updated)
  }

  // for completeness only. This test is not strictly necessary because the
  // member-wise initializer is not public
  func testBookCreationViaMemberWiseInitializer() {
    let book = TPPBook(
      acquisitions: opdsEntry.acquisitions,
      authors: nil,
      categoryStrings: ["Test String 1", "Test String 2"],
      distributor: nil,
      identifier: "666",
      imageURL: nil,
      imageThumbnailURL: nil,
      published: nil,
      publisher: nil,
      subtitle: nil,
      summary: nil,
      title: "The Lord of the Rings",
      updated: Date(),
      annotationsURL: nil,
      analyticsURL: nil,
      alternateURL: nil,
      relatedWorksURL: nil,
      previewLink: nil,
      seriesURL: nil,
      revokeURL: nil,
      reportURL: nil,
      timeTrackingURL: nil,
      contributors: nil,
      bookDuration: nil,
      imageCache: MockImageCache()
    )

    XCTAssertNotNil(book)
    XCTAssertNotNil(book.acquisitions)
    XCTAssertNotNil(book.categoryStrings)
    XCTAssertNotNil(book.identifier)
    XCTAssertNotNil(book.title)
    XCTAssertNotNil(book.updated)
  }
}
