
//
//  ButtonStateTests.swift
//  PalaceTests
//
//  Created by Maurice Carrier on 2/20/23.
//  Copyright © 2023 The Palace Project.
//

import XCTest
@testable import Palace

final class ButtonStateTests: XCTestCase {
  private var testAudiobook: TPPBook {
    TPPBook(dictionary: [
      "acquisitions": [TPPFake.genericAudiobookAcquisition.dictionaryRepresentation()],
      "title": "Tractatus",
      "categories": ["some cat"],
      "id": "123",
      "updated": "2020-10-06T17:13:51Z",
    ]
    )!
  }

  private var testEpub: TPPBook {
    TPPBook(dictionary: [
      "acquisitions": [TPPFake.genericAcquisition.dictionaryRepresentation()],
      "title": "Tractatus",
      "categories": ["some cat"],
      "id": "123",
      "updated": "2020-10-06T17:13:51Z",
    ]
    )!
  }

  // MARK: - Borrowing Tests

  func testCanBorrowEpubWithPreview() {
    let testState = BookButtonState.canBorrow
    let expectedButtons = [BookButtonType.get, .sample]
    let testEpub = testEpub
    testEpub.previewLink = TPPFake.genericSample
    let resultButtons = testState.buttonTypes(book: testEpub, previewEnabled: true)
    XCTAssertEqual(Set(expectedButtons), Set(resultButtons))
  }

  func testCanBorrowEpubWithoutPreview() {
    let testState = BookButtonState.canBorrow
    let expectedButtons = [BookButtonType.get]
    let resultButtons = testState.buttonTypes(book: testEpub, previewEnabled: false)
    XCTAssertEqual(Set(expectedButtons), Set(resultButtons))
  }

  func testCanBorrowAudiobookWithPreview() {
    let testState = BookButtonState.canBorrow
    let expectedButtons = [BookButtonType.get, .audiobookSample]
    let testAudiobook = testAudiobook
    testAudiobook.previewLink = TPPFake.genericAudiobookSample
    let resultButtons = testState.buttonTypes(book: testAudiobook, previewEnabled: true)
    XCTAssertEqual(Set(expectedButtons), Set(resultButtons))
  }

  func testCanBorrowAudiobookWithoutPreview() {
    let testState = BookButtonState.canBorrow
    let expectedButtons = [BookButtonType.get]
    let resultButtons = testState.buttonTypes(book: testAudiobook, previewEnabled: false)
    XCTAssertEqual(Set(expectedButtons), Set(resultButtons))
  }

  // MARK: - Holding Tests

  func testCanHoldEpubWithPreview() {
    let testState = BookButtonState.canHold
    let expectedButtons = [BookButtonType.reserve, .sample]
    let testEpub = testEpub
    testEpub.previewLink = TPPFake.genericSample

    let resultButtons = testState.buttonTypes(book: testEpub, previewEnabled: true)
    XCTAssertEqual(Set(expectedButtons), Set(resultButtons))
  }

  func testCanHoldEpubWithoutPreview() {
    let testState = BookButtonState.canHold
    let expectedButtons = [BookButtonType.reserve]
    let resultButtons = testState.buttonTypes(book: testEpub, previewEnabled: false)
    XCTAssertEqual(Set(expectedButtons), Set(resultButtons))
  }

  func testCanHoldAudiobookWithPreview() {
    let testState = BookButtonState.canHold
    let expectedButtons = [BookButtonType.reserve, .audiobookSample]
    let testAudiobook = testAudiobook
    testAudiobook.previewLink = TPPFake.genericAudiobookSample
    let resultButtons = testState.buttonTypes(book: testAudiobook, previewEnabled: true)
    XCTAssertEqual(Set(expectedButtons), Set(resultButtons))
  }

  func testCanHoldAudiobookWithoutPreview() {
    let testState = BookButtonState.canHold
    let expectedButtons = [BookButtonType.reserve]
    let resultButtons = testState.buttonTypes(book: testAudiobook, previewEnabled: false)
    XCTAssertEqual(Set(expectedButtons), Set(resultButtons))
  }

  func testHoldingEpubWithPreview() {
    let testState = BookButtonState.holding
    let expectedButtons = [BookButtonType.remove, .sample]
    let testEpub = testEpub
    testEpub.previewLink = TPPFake.genericSample
    let resultButtons = testState.buttonTypes(book: testEpub, previewEnabled: true)
    XCTAssertEqual(Set(expectedButtons), Set(resultButtons))
  }

  func testHoldingEpubWithoutPreview() {
    let testState = BookButtonState.holding
    let expectedButtons = [BookButtonType.remove]
    let resultButtons = testState.buttonTypes(book: testEpub, previewEnabled: false)
    XCTAssertEqual(Set(expectedButtons), Set(resultButtons))
  }

  func testHoldingAudiobookWithPreview() {
    let testState = BookButtonState.holding
    let expectedButtons = [BookButtonType.remove, .audiobookSample]
    let testAudiobook = testAudiobook
    testAudiobook.previewLink = TPPFake.genericAudiobookSample

    let resultButtons = testState.buttonTypes(book: testAudiobook, previewEnabled: true)
    XCTAssertEqual(Set(expectedButtons), Set(resultButtons))
  }

  func testHoldingAudiobookWithoutPreview() {
    let testState = BookButtonState.holding
    let expectedButtons = [BookButtonType.remove]
    let resultButtons = testState.buttonTypes(book: testAudiobook, previewEnabled: false)
    XCTAssertEqual(Set(expectedButtons), Set(resultButtons))
  }

  func testHoldingFrontOfQueue() {
    let testState = BookButtonState.holdingFrontOfQueue
    let expectedButtons = [BookButtonType.get, .remove]
    let resultButtons = testState.buttonTypes(book: testEpub)
    XCTAssertEqual(Set(expectedButtons), Set(resultButtons))
  }

  // MARK: - Downloading Tests

  func testDownloadNeededEpub() {
    let testState = BookButtonState.downloadNeeded
    let expectedButtons = [BookButtonType.download, .remove]
    let resultButtons = testState.buttonTypes(book: testEpub)
    XCTAssertEqual(Set(expectedButtons), Set(resultButtons))
  }

  func testDownloadNeededAudiobook() {
    let testState = BookButtonState.downloadNeeded
    let expectedButtons = [BookButtonType.download, .remove]
    let resultButtons = testState.buttonTypes(book: testAudiobook)
    XCTAssertEqual(Set(expectedButtons), Set(resultButtons))
  }

  func testDownloadInProgress() {
    let testState = BookButtonState.downloadInProgress
    let expectedButtons = [BookButtonType.cancel]
    let resultButtons = testState.buttonTypes(book: testEpub)
    XCTAssertEqual(Set(expectedButtons), Set(resultButtons))
  }

  func testDownloadFailed() {
    let testState = BookButtonState.downloadFailed
    let expectedButtons = [BookButtonType.cancel, .retry]
    let resultButtons = testState.buttonTypes(book: testEpub)
    XCTAssertEqual(Set(expectedButtons), Set(resultButtons))
  }

  // MARK: - Post-Download & Unsupported Tests

  func testDownloadSuccessfulEpub() {
    let testState = BookButtonState.downloadSuccessful
    let expectedButtons = [BookButtonType.read, .remove]
    let resultButtons = testState.buttonTypes(book: testEpub)
    XCTAssertEqual(Set(expectedButtons), Set(resultButtons))
  }

  func testUsedEpub() {
    let testState = BookButtonState.used
    let expectedButtons = [BookButtonType.read, .remove]
    let resultButtons = testState.buttonTypes(book: testEpub)
    XCTAssertEqual(Set(expectedButtons), Set(resultButtons))
  }

  func testUnsupported() {
    let testState = BookButtonState.unsupported
    let expectedButtons = [BookButtonType]()
    let resultButtons = testState.buttonTypes(book: testEpub)
    XCTAssertEqual(Set(expectedButtons), Set(resultButtons))
  }
}
