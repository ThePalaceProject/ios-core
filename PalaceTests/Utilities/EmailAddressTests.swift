//
//  EmailAddressTests.swift
//  PalaceTests
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class EmailAddressTests: XCTestCase {

  // MARK: - Valid Emails

  func testValidEmail_simpleAddress() {
    let email = EmailAddress(rawValue: "user@example.com")
    XCTAssertNotNil(email)
    XCTAssertEqual(email?.rawValue, "user@example.com")
  }

  func testValidEmail_withSubdomain() {
    let email = EmailAddress(rawValue: "user@mail.example.com")
    XCTAssertNotNil(email)
  }

  func testValidEmail_withPlus() {
    let email = EmailAddress(rawValue: "user+tag@example.com")
    XCTAssertNotNil(email)
  }

  func testValidEmail_withDots() {
    let email = EmailAddress(rawValue: "first.last@example.com")
    XCTAssertNotNil(email)
  }

  func testValidEmail_withNumbers() {
    let email = EmailAddress(rawValue: "user123@example456.com")
    XCTAssertNotNil(email)
  }

  // MARK: - Invalid Emails

  func testInvalidEmail_emptyString() {
    let email = EmailAddress(rawValue: "")
    XCTAssertNil(email)
  }

  func testInvalidEmail_noAtSign() {
    let email = EmailAddress(rawValue: "userexample.com")
    XCTAssertNil(email)
  }

  func testInvalidEmail_noDomain() {
    let email = EmailAddress(rawValue: "user@")
    XCTAssertNil(email)
  }

  func testInvalidEmail_noLocalPart() {
    let email = EmailAddress(rawValue: "@example.com")
    XCTAssertNil(email)
  }

  func testInvalidEmail_justText() {
    let email = EmailAddress(rawValue: "not an email")
    XCTAssertNil(email)
  }

  func testInvalidEmail_multipleAtSigns() {
    let email = EmailAddress(rawValue: "user@@example.com")
    XCTAssertNil(email)
  }

  // MARK: - Whitespace Handling

  func testEmail_withLeadingWhitespace_isTrimmed() {
    let email = EmailAddress(rawValue: "  user@example.com")
    // NSDataDetector should still detect the email after trimming
    XCTAssertNotNil(email)
  }

  func testEmail_withTrailingWhitespace_isTrimmed() {
    let email = EmailAddress(rawValue: "user@example.com  ")
    XCTAssertNotNil(email)
  }

  // MARK: - RawRepresentable

  func testRawValue_matchesInput() {
    let email = EmailAddress(rawValue: "test@example.com")
    XCTAssertEqual(email?.rawValue, "test@example.com")
  }

  // MARK: - Equality (NSObject identity — no custom isEqual override)

  func testEquality_sameRawValue_haveSameRawValue() {
    let a = EmailAddress(rawValue: "user@example.com")
    let b = EmailAddress(rawValue: "user@example.com")
    XCTAssertEqual(a?.rawValue, b?.rawValue)
  }

  func testEquality_differentRawValue_haveDifferentRawValue() {
    let a = EmailAddress(rawValue: "user1@example.com")
    let b = EmailAddress(rawValue: "user2@example.com")
    XCTAssertNotEqual(a?.rawValue, b?.rawValue)
  }
}
