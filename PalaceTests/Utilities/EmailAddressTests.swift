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
        XCTAssertEqual(email?.rawValue, "user@example.com", "Simple address must parse and preserve rawValue")
        XCTAssertNil(EmailAddress(rawValue: "user"), "Local-part-only must not parse as valid")
        XCTAssertNil(EmailAddress(rawValue: ""), "Empty string must not parse as valid")
    }

    func testValidEmail_withSubdomain() {
        let email = EmailAddress(rawValue: "user@mail.example.com")
        XCTAssertEqual(email?.rawValue, "user@mail.example.com", "Subdomain address must parse and preserve rawValue")
        XCTAssertNil(EmailAddress(rawValue: "user@"), "Missing domain must still fail")
    }

    func testValidEmail_withPlus() {
        let email = EmailAddress(rawValue: "user+tag@example.com")
        XCTAssertEqual(email?.rawValue, "user+tag@example.com", "Plus-tagged address must parse and preserve rawValue")
        XCTAssertNil(EmailAddress(rawValue: "usertagexample.com"), "No-@ variant must fail")
    }

    func testValidEmail_withDots() {
        let email = EmailAddress(rawValue: "first.last@example.com")
        XCTAssertEqual(email?.rawValue, "first.last@example.com", "Dotted local-part must parse and preserve rawValue")
        XCTAssertNil(EmailAddress(rawValue: "firstlastexample.com"), "No-@ variant must fail")
    }

    func testValidEmail_withNumbers() {
        let email = EmailAddress(rawValue: "user123@example456.com")
        XCTAssertEqual(email?.rawValue, "user123@example456.com", "Numeric local-part must parse and preserve rawValue")
        XCTAssertNil(EmailAddress(rawValue: "user123"), "Bare local part without domain must fail")
    }

    // MARK: - Invalid Emails

    func testInvalidEmail_emptyString() {
        let email = EmailAddress(rawValue: "")
        XCTAssertNil(email)
        // Valid email must succeed; empty must not
        XCTAssertNotNil(EmailAddress(rawValue: "valid@example.com"))
    }

    func testInvalidEmail_noAtSign() {
        let email = EmailAddress(rawValue: "userexample.com")
        XCTAssertNil(email)
        XCTAssertNotNil(EmailAddress(rawValue: "user@example.com"), "Adding @ should make it valid")
    }

    func testInvalidEmail_noDomain() {
        let email = EmailAddress(rawValue: "user@")
        XCTAssertNil(email)
        XCTAssertNotNil(EmailAddress(rawValue: "user@example.com"), "Full domain should be valid")
    }

    func testInvalidEmail_noLocalPart() {
        let email = EmailAddress(rawValue: "@example.com")
        XCTAssertNil(email)
        XCTAssertNotNil(EmailAddress(rawValue: "user@example.com"), "Local part required")
    }

    func testInvalidEmail_justText() {
        let email = EmailAddress(rawValue: "not an email")
        XCTAssertNil(email)
        XCTAssertNotNil(EmailAddress(rawValue: "valid@example.com"), "Properly formatted email must succeed")
    }

    func testInvalidEmail_multipleAtSigns() {
        let email = EmailAddress(rawValue: "user@@example.com")
        XCTAssertNil(email)
        XCTAssertNotNil(EmailAddress(rawValue: "user@example.com"), "Single @ must succeed")
    }

    // MARK: - Whitespace Handling

    func testEmail_withLeadingWhitespace_isTrimmed() {
        let email = EmailAddress(rawValue: "  user@example.com")
        // NSDataDetector should still detect the email after trimming
        XCTAssertNotNil(email)
        XCTAssertEqual(email?.rawValue, "user@example.com", "Leading whitespace should be trimmed from rawValue")
    }

    func testEmail_withTrailingWhitespace_isTrimmed() {
        let email = EmailAddress(rawValue: "user@example.com  ")
        XCTAssertEqual(email?.rawValue, "user@example.com", "Trailing whitespace should be trimmed from rawValue")
        XCTAssertNil(EmailAddress(rawValue: "   "), "Whitespace-only string should not produce a valid address")
    }

    // MARK: - RawRepresentable

    func testRawValue_matchesInput() {
        let email = EmailAddress(rawValue: "test@example.com")
        XCTAssertEqual(email?.rawValue, "test@example.com")
        XCTAssertNotEqual(email?.rawValue, "other@example.com", "rawValue must not mutate the input address")
        XCTAssertNil(EmailAddress(rawValue: "not-an-email"), "Invalid input must not produce a valid address")
    }

    // MARK: - Equality (NSObject identity — no custom isEqual override)

    func testEquality_sameRawValue_haveSameRawValue() {
        let a = EmailAddress(rawValue: "user@example.com")
        let b = EmailAddress(rawValue: "user@example.com")
        XCTAssertEqual(a?.rawValue, b?.rawValue)
        XCTAssertNotNil(a)
        XCTAssertNotNil(b)
    }

    func testEquality_differentRawValue_haveDifferentRawValue() {
        let a = EmailAddress(rawValue: "user1@example.com")
        let b = EmailAddress(rawValue: "user2@example.com")
        XCTAssertNotEqual(a?.rawValue, b?.rawValue)
        XCTAssertNotNil(a)
        XCTAssertNotNil(b)
    }
}
