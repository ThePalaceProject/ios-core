//
//  ButtonStateTests.swift
//  PalaceTests
//
//  Created by Maurice Carrier on 2/20/23.
//  Copyright © 2023 The Palace Project. All rights reserved.
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
  
  func testCanBorrowEpub() {
    let testState = BookButtonState.canBorrow
    let expectedbuttons = [BookButtonType.get, .sample]
    let resultButtons = testState.buttonTypes(book: testEpub)
    
    XCTAssertTrue(Set(expectedbuttons) == Set(resultButtons))
  }
  
  func testCanBorrowAudiobook() {
    let testState = BookButtonState.canBorrow
    let expectedbuttons = [BookButtonType.get, .audiobookSample]
    let resultButtons = testState.buttonTypes(book: testAudiobook)
    
    XCTAssertTrue(Set(expectedbuttons) == Set(resultButtons))
  }
  
  func testCanHoldEpub() {
    let testState = BookButtonState.canHold
    let expectedbuttons = [BookButtonType.reserve, .sample]
    let resultButtons = testState.buttonTypes(book: testEpub)
    
    XCTAssertTrue(Set(expectedbuttons) == Set(resultButtons))
  }
  
  func testCanHoldAudiobook() {
    let testState = BookButtonState.canHold
    let expectedbuttons = [BookButtonType.reserve, .audiobookSample]
    let resultButtons = testState.buttonTypes(book: testAudiobook)
    
    XCTAssertTrue(Set(expectedbuttons) == Set(resultButtons))
  }
  
  func testHoldingEpub() {
    let testState = BookButtonState.holding
    let expectedbuttons = [BookButtonType.remove, .sample]
    let resultButtons = testState.buttonTypes(book: testEpub)
    
    XCTAssertTrue(Set(expectedbuttons) == Set(resultButtons))
  }
  
  func testHoldingAudiobook() {
    let testState = BookButtonState.holding
    let expectedbuttons = [BookButtonType.remove, .audiobookSample]
    let resultButtons = testState.buttonTypes(book: testAudiobook)
    
    XCTAssertTrue(Set(expectedbuttons) == Set(resultButtons))
  }

  func testHoldingFOQ() {
    let testState = BookButtonState.holdingFrontOfQueue
    let expectedbuttons = [BookButtonType.get, .remove]
    let resultButtons = testState.buttonTypes(book: testEpub)
    
    XCTAssertTrue(Set(expectedbuttons) == Set(resultButtons))
  }
  
  func testDownloadNeeded() {
    let testState = BookButtonState.downloadNeeded
    let expectedbuttons = [BookButtonType.download, .remove]
    let resultButtons = testState.buttonTypes(book: testEpub)
    
    XCTAssertTrue(Set(expectedbuttons) == Set(resultButtons))
  }
  
  func testDownloadNeededOpenAccessAudiobook() {
    let testState = BookButtonState.downloadNeeded
    let expectedbuttons = [BookButtonType.download, .remove]
    let resultButtons = testState.buttonTypes(book: testAudiobook)
    
    XCTAssertTrue(Set(expectedbuttons) == Set(resultButtons))
  }
  
  func testDownloadSuccessfulEpub() {
    let testState = BookButtonState.downloadSuccessful
    let expectedbuttons = [BookButtonType.read, .remove]
    let resultButtons = testState.buttonTypes(book: testEpub)
    
    XCTAssertTrue(Set(expectedbuttons) == Set(resultButtons))
  }
  
  func testUsedEpub() throws {
    let testState = BookButtonState.used
    let expectedbuttons = [BookButtonType.read, .remove]
    let resultButtons = testState.buttonTypes(book: testEpub)
    
    XCTAssertTrue(Set(expectedbuttons) == Set(resultButtons))
  }

  func testDownloadInProgress() throws {
    let testState = BookButtonState.downloadInProgress
    let expectedbuttons = [BookButtonType.cancel]
    let resultButtons = testState.buttonTypes(book: testEpub)
    
    XCTAssertTrue(Set(expectedbuttons) == Set(resultButtons))
  }
  
  func testDownloadFailed() throws {
    let testState = BookButtonState.downloadFailed
    let expectedbuttons = [BookButtonType.cancel, .retry]
    let resultButtons = testState.buttonTypes(book: testEpub)
    
    XCTAssertTrue(Set(expectedbuttons) == Set(resultButtons))
  }
  
  func testUnsupported() throws {
    let testState = BookButtonState.unsupported
    let expectedbuttons = [BookButtonType]()
    let resultButtons = testState.buttonTypes(book: testEpub)
    
    XCTAssertTrue(Set(expectedbuttons) == Set(resultButtons))
  }
}

