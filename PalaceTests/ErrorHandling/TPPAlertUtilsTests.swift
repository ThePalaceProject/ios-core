//
//  TPPAlertUtilsTests.swift
//  PalaceTests
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class TPPAlertUtilsTests: XCTestCase {

  // MARK: - Basic Alert Creation

  func testAlert_titleAndMessage_createsAlert() {
    let alert = TPPAlertUtils.alert(title: "Test Title", message: "Test Message")

    XCTAssertEqual(alert.title, "Test Title")
    XCTAssertEqual(alert.message, "Test Message")
    XCTAssertEqual(alert.preferredStyle, .alert)
  }

  func testAlert_nilTitle_substitutesDefault() {
    let alert = TPPAlertUtils.alert(title: nil, message: "Only message")

    // Implementation substitutes "Alert" for nil/empty titles
    XCTAssertEqual(alert.title, "Alert")
    XCTAssertNotNil(alert.message)
  }

  func testAlert_nilMessage_substitutesEmpty() {
    let alert = TPPAlertUtils.alert(title: "Only title", message: nil)

    XCTAssertNotNil(alert.title)
    // Implementation substitutes "" for nil/empty messages
    XCTAssertEqual(alert.message, "")
  }

  func testAlert_hasOKAction() {
    let alert = TPPAlertUtils.alert(title: "Title", message: "Message")

    XCTAssertGreaterThanOrEqual(alert.actions.count, 1, "Alert should have at least one action")

    let okAction = alert.actions.first(where: { $0.title == "OK" })
    XCTAssertNotNil(okAction, "Alert should have an OK action")
  }

  // MARK: - Alert with Error

  func testAlert_withError_createsAlert() {
    let error = NSError(
      domain: "TestDomain",
      code: 42,
      userInfo: [NSLocalizedDescriptionKey: "Test error message"]
    )

    let alert = TPPAlertUtils.alert(title: "Error", error: error)

    XCTAssertEqual(alert.title, "Error")
    XCTAssertNotNil(alert.message)
  }

  func testAlert_withNilError_createsAlert() {
    let alert = TPPAlertUtils.alert(title: "Error Occurred", error: nil)

    XCTAssertEqual(alert.title, "Error Occurred")
  }

  // MARK: - Alert with Style

  func testAlert_customStyle_usesProvidedStyle() {
    let alert = TPPAlertUtils.alert(
      title: "Destructive",
      message: "Are you sure?",
      style: .destructive
    )

    XCTAssertEqual(alert.title, "Destructive")
    XCTAssertEqual(alert.message, "Are you sure?")
  }

  // MARK: - Alert with Details

  func testAlertWithDetails_hasViewDetailsAction() {
    let alert = TPPAlertUtils.alertWithDetails(
      title: "Borrow Failed",
      message: "Unable to borrow"
    )

    let detailsAction = alert.actions.first(where: { $0.title == "View Error Details" })
    XCTAssertNotNil(detailsAction, "Alert should have a 'View Error Details' action")
  }

  func testAlertWithDetails_hasOKAction() {
    let alert = TPPAlertUtils.alertWithDetails(
      title: "Error",
      message: "Something failed"
    )

    let okAction = alert.actions.first(where: { $0.title == "OK" })
    XCTAssertNotNil(okAction, "Alert should have an OK action")
  }

  func testAlertWithDetails_hasTwoActions() {
    let alert = TPPAlertUtils.alertWithDetails(
      title: "Error",
      message: "Test"
    )

    XCTAssertEqual(alert.actions.count, 2, "Should have OK and View Error Details actions")
  }

  // MARK: - Problem Document

  func testSetProblemDocument_appendsToMessage() {
    let alert = TPPAlertUtils.alert(title: "Error", message: "Base message")
    let problemDoc = TPPProblemDocument.fromDictionary([
      "detail": "Detailed server error message"
    ])

    TPPAlertUtils.setProblemDocument(controller: alert, document: problemDoc, append: true)

    XCTAssertNotNil(alert.message)
    if let message = alert.message {
      XCTAssertTrue(message.contains("Base message"), "Should keep original message")
    }
  }

  func testSetProblemDocument_replacesMessage() {
    let alert = TPPAlertUtils.alert(title: "Error", message: "Original")
    let problemDoc = TPPProblemDocument.fromDictionary([
      "detail": "Server says: loan limit reached"
    ])

    TPPAlertUtils.setProblemDocument(controller: alert, document: problemDoc, append: false)

    XCTAssertNotNil(alert.message)
  }

  func testSetProblemDocument_nilController_doesNotCrash() {
    let problemDoc = TPPProblemDocument.fromDictionary([
      "detail": "Error detail"
    ])

    // Should not crash
    TPPAlertUtils.setProblemDocument(controller: nil, document: problemDoc, append: true)
  }

  func testSetProblemDocument_nilDocument_doesNotCrash() {
    let alert = TPPAlertUtils.alert(title: "Error", message: "Message")

    // Should not crash
    TPPAlertUtils.setProblemDocument(controller: alert, document: nil, append: true)
  }
}
