//
//  TPPUserFriendlyErrorTests.swift
//  PalaceTests
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class TPPUserFriendlyErrorTests: XCTestCase {

  // MARK: - Protocol Default Implementation

  func testDefaultImplementation_titleIsNil() {
    struct TestError: TPPUserFriendlyError {}
    let error = TestError()
    XCTAssertNil(error.userFriendlyTitle)
  }

  func testDefaultImplementation_messageIsNil() {
    struct TestError: TPPUserFriendlyError {}
    let error = TestError()
    XCTAssertNil(error.userFriendlyMessage)
  }

  // MARK: - NSError Extension - Problem Document

  func testNSError_withProblemDocument_hasFriendlyTitle() {
    let problemDoc = TPPProblemDocument.fromDictionary([
      "title": "Loan Limit Reached",
      "detail": "You have reached your checkout limit."
    ])

    let error = NSError.makeFromProblemDocument(
      problemDoc,
      domain: "TestDomain",
      code: 403,
      userInfo: nil
    )

    XCTAssertEqual(error.userFriendlyTitle, "Loan Limit Reached")
  }

  func testNSError_withProblemDocument_hasFriendlyMessage() {
    let problemDoc = TPPProblemDocument.fromDictionary([
      "title": "Error",
      "detail": "You have reached your checkout limit."
    ])

    let error = NSError.makeFromProblemDocument(
      problemDoc,
      domain: "TestDomain",
      code: 403,
      userInfo: nil
    )

    XCTAssertEqual(error.userFriendlyMessage, "You have reached your checkout limit.")
  }

  func testNSError_withoutProblemDocument_titleIsNil() {
    let error = NSError(domain: "TestDomain", code: 1, userInfo: nil)
    XCTAssertNil(error.userFriendlyTitle)
  }

  func testNSError_withoutProblemDocument_messageIsLocalizedDescription() {
    let error = NSError(
      domain: "TestDomain",
      code: 1,
      userInfo: [NSLocalizedDescriptionKey: "Something went wrong"]
    )

    XCTAssertEqual(error.userFriendlyMessage, "Something went wrong")
  }

  func testNSError_withoutProblemDocument_noUserInfo_messageIsNil() {
    let error = NSError(domain: "TestDomain", code: 1, userInfo: nil)
    XCTAssertNil(error.userFriendlyMessage)
  }

  // MARK: - makeFromProblemDocument

  func testMakeFromProblemDocument_setsDomainAndCode() {
    let problemDoc = TPPProblemDocument.fromDictionary([
      "title": "Test",
      "detail": "Test detail"
    ])

    let error = NSError.makeFromProblemDocument(
      problemDoc,
      domain: "com.palace.test",
      code: 500,
      userInfo: nil
    )

    XCTAssertEqual(error.domain, "com.palace.test")
    XCTAssertEqual(error.code, 500)
  }

  func testMakeFromProblemDocument_preservesExistingUserInfo() {
    let problemDoc = TPPProblemDocument.fromDictionary([
      "title": "Test",
      "detail": "Test detail"
    ])

    let error = NSError.makeFromProblemDocument(
      problemDoc,
      domain: "TestDomain",
      code: 1,
      userInfo: ["customKey": "customValue"]
    )

    XCTAssertEqual(error.userInfo["customKey"] as? String, "customValue")
    XCTAssertNotNil(error.problemDocument, "Should also contain the problem document")
  }

  func testMakeFromProblemDocument_storesProblemDocument() {
    let problemDoc = TPPProblemDocument.fromDictionary([
      "title": "Stored Document",
      "status": 403,
      "detail": "Stored detail"
    ])

    let error = NSError.makeFromProblemDocument(
      problemDoc,
      domain: "TestDomain",
      code: 403,
      userInfo: nil
    )

    XCTAssertNotNil(error.problemDocument)
    XCTAssertEqual(error.problemDocument?.title, "Stored Document")
  }

  // MARK: - Problem Document Access

  func testProblemDocument_accessor_returnsStoredDocument() {
    let problemDoc = TPPProblemDocument.fromDictionary([
      "type": "http://example.com/error",
      "title": "Access Test",
      "detail": "Testing accessor"
    ])

    let error = NSError.makeFromProblemDocument(
      problemDoc,
      domain: "TestDomain",
      code: 1,
      userInfo: nil
    )

    XCTAssertNotNil(error.problemDocument)
    XCTAssertEqual(error.problemDocument?.title, "Access Test")
  }
}
