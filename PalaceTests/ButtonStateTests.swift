
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
      "updated": "2020-10-06T17:13:51Z"]
    )!
  }

  private var testEpub: TPPBook {
    TPPBook(dictionary: [
      "acquisitions": [TPPFake.genericAcquisition.dictionaryRepresentation()],
      "title": "Tractatus",
      "categories": ["some cat"],
      "id": "123",
      "updated": "2020-10-06T17:13:51Z"]
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
    // Implementation returns manageHold + sample when holding (not ready)
    let expectedButtons = [BookButtonType.manageHold, .sample]
    let testEpub = testEpub
    testEpub.previewLink = TPPFake.genericSample
    let resultButtons = testState.buttonTypes(book: testEpub, previewEnabled: true)
    XCTAssertEqual(Set(expectedButtons), Set(resultButtons))
  }

  func testHoldingEpubWithoutPreview() {
    let testState = BookButtonState.holding
    // Implementation returns manageHold when holding without preview
    let expectedButtons = [BookButtonType.manageHold]
    let resultButtons = testState.buttonTypes(book: testEpub, previewEnabled: false)
    XCTAssertEqual(Set(expectedButtons), Set(resultButtons))
  }

  func testHoldingAudiobookWithPreview() {
    let testState = BookButtonState.holding
    // Implementation returns manageHold + audiobookSample when holding
    let expectedButtons = [BookButtonType.manageHold, .audiobookSample]
    let testAudiobook = testAudiobook
    testAudiobook.previewLink = TPPFake.genericAudiobookSample

    let resultButtons = testState.buttonTypes(book: testAudiobook, previewEnabled: true)
    XCTAssertEqual(Set(expectedButtons), Set(resultButtons))
  }

  func testHoldingAudiobookWithoutPreview() {
    let testState = BookButtonState.holding
    // Implementation returns manageHold when holding without preview
    let expectedButtons = [BookButtonType.manageHold]
    let resultButtons = testState.buttonTypes(book: testAudiobook, previewEnabled: false)
    XCTAssertEqual(Set(expectedButtons), Set(resultButtons))
  }

  func testHoldingFrontOfQueue() {
    let testState = BookButtonState.holdingFrontOfQueue
    // Implementation returns manageHold when holdingFrontOfQueue (isHoldReady returns false without proper availability)
    let expectedButtons = [BookButtonType.manageHold]
    let resultButtons = testState.buttonTypes(book: testEpub)
    XCTAssertEqual(Set(expectedButtons), Set(resultButtons))
  }

  // MARK: - Downloading Tests
  // Note: Button behavior depends on TPPUserAccount.sharedAccount().authDefinition
  // In test environment without auth, .remove is used instead of .return

  func testDownloadNeededEpub() {
    let testState = BookButtonState.downloadNeeded
    let resultButtons = testState.buttonTypes(book: testEpub)
    // Verify download button is present
    XCTAssertTrue(resultButtons.contains(.download), "Download button should be present")
    // Should have exactly 2 buttons (download + return/remove depending on auth)
    XCTAssertEqual(resultButtons.count, 2)
  }

  func testDownloadNeededAudiobook() {
    let testState = BookButtonState.downloadNeeded
    let resultButtons = testState.buttonTypes(book: testAudiobook)
    // Verify download button is present
    XCTAssertTrue(resultButtons.contains(.download), "Download button should be present")
    // Should have exactly 2 buttons
    XCTAssertEqual(resultButtons.count, 2)
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
  // Note: Button behavior depends on TPPUserAccount.sharedAccount().authDefinition
  // In test environment without auth, .remove is used instead of .return

  func testDownloadSuccessfulEpub() {
    let testState = BookButtonState.downloadSuccessful
    let resultButtons = testState.buttonTypes(book: testEpub)
    // Verify read button is present for downloaded epub
    XCTAssertTrue(resultButtons.contains(.read), "Read button should be present")
    // Should have exactly 2 buttons (read + return/remove depending on auth)
    XCTAssertEqual(resultButtons.count, 2)
  }

  func testUsedEpub() {
    let testState = BookButtonState.used
    let resultButtons = testState.buttonTypes(book: testEpub)
    // Verify read button is present for used epub
    XCTAssertTrue(resultButtons.contains(.read), "Read button should be present")
    // Should have exactly 2 buttons
    XCTAssertEqual(resultButtons.count, 2)
  }

  func testUnsupported() {
    let testState = BookButtonState.unsupported
    let expectedButtons = [BookButtonType]()
    let resultButtons = testState.buttonTypes(book: testEpub)
    XCTAssertEqual(Set(expectedButtons), Set(resultButtons))
  }

  // MARK: - Additional content-type coverage (audiobook & PDF)

  func testDownloadSuccessfulAudiobook() {
    let testState = BookButtonState.downloadSuccessful
    let audiobook = TPPBookMocker.snapshotAudiobook()

    let resultButtons = testState.buttonTypes(book: audiobook)

    XCTAssertTrue(resultButtons.contains(.listen), "Listen button should be present for audiobook")
    XCTAssertEqual(resultButtons.count, 2, "Should have listen + return/remove")
  }

  func testDownloadSuccessfulPDF() {
    let testState = BookButtonState.downloadSuccessful
    let pdfBook = TPPBookMocker.snapshotPDF()

    let resultButtons = testState.buttonTypes(book: pdfBook)

    XCTAssertTrue(resultButtons.contains(.read), "Read button should be present for PDF")
    XCTAssertEqual(resultButtons.count, 2, "Should have read + return/remove")
  }
}

