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
  func testEpubBookPreviewExtraction() throws {
    let acquisitions = [TPPFake.genericAcquisition.dictionaryRepresentation()]
    let sampleLink = TPPFake.genericSample

    let book = TPPBook(dictionary: [
      "acquisitions": acquisitions,
      "preview-url": sampleLink.dictionaryRepresentation(),
      "categories": ["Fantasy"],
      "id": "123",
      "title": "The Lord of the Rings",
      "updated": "2020-09-08T09:22:45Z"
    ])

    XCTAssertNotNil(book?.acquisitions)
    XCTAssertNotNil(book?.previewLink)
    XCTAssertEqual(book!.previewLink?.hrefURL, sampleLink.hrefURL)
  }

  func testOverdriveWebAudiobookExtraction() throws {
    let acquisitions = [TPPFake.genericAudiobookAcquisition.dictionaryRepresentation()]
    let sampleLink = TPPFake.overdriveWebAudiobookSample

    let book = TPPBook(dictionary: [
      "acquisitions": acquisitions,
      "preview-url": sampleLink.dictionaryRepresentation(),
      "categories": ["Fantasy"],
      "id": "123",
      "title": "The Lord of the Rings",
      "updated": "2020-09-08T09:22:45Z"
    ])

    XCTAssertNotNil(book?.acquisitions)
    XCTAssertNotNil(book?.previewLink)
    XCTAssertEqual(book!.previewLink?.hrefURL, sampleLink.hrefURL)
  }

  func testOverdriveWaveAudiobookExtraction() throws {
    let acquisitions = [TPPFake.genericAudiobookAcquisition.dictionaryRepresentation()]
    let sampleLink = TPPFake.overdriveAudiobookWaveFile

    let book = TPPBook(dictionary: [
      "acquisitions": acquisitions,
      "preview-url": sampleLink.dictionaryRepresentation(),
      "categories": ["Fantasy"],
      "id": "123",
      "title": "The Lord of the Rings",
      "updated": "2020-09-08T09:22:45Z"
    ])

    XCTAssertNotNil(book?.acquisitions)
    XCTAssertNotNil(book?.previewLink)
    XCTAssertEqual(book!.previewLink?.hrefURL, sampleLink.hrefURL)
  }

  func testOverdriveMPEGAudiobookExtraction() throws {
    let acquisitions = [TPPFake.genericAudiobookAcquisition.dictionaryRepresentation()]
    let sampleLink = TPPFake.overdriveAudiobookMPEG

    let book = TPPBook(dictionary: [
      "acquisitions": acquisitions,
      "preview-url": sampleLink.dictionaryRepresentation(),
      "categories": ["Fantasy"],
      "id": "123",
      "title": "The Lord of the Rings",
      "updated": "2020-09-08T09:22:45Z"
    ])

    XCTAssertNotNil(book?.acquisitions)
    XCTAssertNotNil(book?.previewLink)
    XCTAssertEqual(book!.previewLink?.hrefURL, sampleLink.hrefURL)
  }
}
