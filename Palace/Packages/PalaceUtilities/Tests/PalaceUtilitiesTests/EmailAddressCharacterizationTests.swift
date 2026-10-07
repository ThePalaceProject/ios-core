//
//  EmailAddressCharacterizationTests.swift
//  PalaceUtilitiesTests
//
//  Pins what `EmailAddress(rawValue:)` accepts and what it stores, including
//  the NSDataDetector quirks (spaces stripped before matching, only a
//  lowercase `mailto:` prefix removed), so a change to how the detector is
//  built or shared cannot change which library help links become emails.
//

import XCTest
@testable import PalaceUtilities

final class EmailAddressCharacterizationTests: XCTestCase {

    /// (input, expected rawValue or nil when the input is rejected)
    static let table: [(input: String, expected: String?)] = [
        // Plain and mailto: forms
        ("user@example.com", "user@example.com"),
        ("mailto:user@example.com", "user@example.com"),
        ("MAILTO:user@example.com", nil),
        ("Mailto:user@example.com", nil),
        ("mailto:", nil),
        ("mailto:mailto:user@example.com", nil),
        ("mailto:user@example.com?subject=Help", "user@example.com?subject=Help"),
        ("mailto:user@example.com,other@example.com", nil),
        ("mailto:user%40example.com", nil),
        // Whitespace: only U+0020 is stripped, anywhere in the string
        (" mailto:user@example.com ", "user@example.com"),
        ("mailto:cpham@sycuanedu.org ", "cpham@sycuanedu.org"),
        ("user @ example . com", "user@example.com"),
        ("Contact user@example.com", "Contactuser@example.com"),
        ("user\t@example.com", nil),
        ("user@example.com\n", nil),
        ("\u{00A0}user@example.com", nil),
        // Empty
        ("", nil),
        (" ", nil),
        // Domain and local-part shape
        ("a@b", nil),
        ("a@b.c", "a@b.c"),
        ("user@example.c", "user@example.c"),
        ("user@example.museum", "user@example.museum"),
        ("user@example.com.", nil),
        ("user@example..com", nil),
        (".user@example.com", nil),
        ("user.@example.com", nil),
        ("user@-example.com", nil),
        ("user@localhost", nil),
        ("user@123.123.123.123", "user@123.123.123.123"),
        ("user.name+tag@sub.example.co.uk", "user.name+tag@sub.example.co.uk"),
        ("USER@EXAMPLE.COM", "USER@EXAMPLE.COM"),
        ("\"quoted\"@example.com", nil),
        // Multiple @ and multiple addresses
        ("user@@example.com", nil),
        ("a@b@example.com", nil),
        ("user@example.com,other@example.com", nil),
        ("user@example.com other@example.com", nil),
        // Unicode
        ("user@exämple.com", "user@exämple.com"),
        ("üser@example.com", "üser@example.com"),
        ("user@例え.jp", "user@例え.jp"),
        ("user@xn--exmple-cua.com", "user@xn--exmple-cua.com"),
        // Non-mailto links and trailing junk
        ("https://example.com/help", nil),
        ("http://user@example.com", nil),
        ("www.example.com", nil),
        ("example.com", nil),
        ("tel:5551234567", nil),
        ("user@example.com/path", nil),
        ("user@example.com.mailto:", nil),
        ("help@library.org?", nil),
        ("<user@example.com>", nil)
    ]

    func testRawValueInit_MatchesCharacterizationTable() {
        for row in Self.table {
            XCTAssertEqual(EmailAddress(rawValue: row.input)?.rawValue, row.expected,
                           "input: \(String(reflecting: row.input))")
        }
    }

    /// Account init runs on detached tasks, so validation must give the same
    /// answers when many threads validate at once.
    func testRawValueInit_ConcurrentCallers_MatchCharacterizationTable() {
        let rows = Self.table
        let iterations = 16
        let lock = NSLock()
        var mismatches: [String] = []

        DispatchQueue.concurrentPerform(iterations: iterations) { _ in
            for row in rows.shuffled() {
                let actual = EmailAddress(rawValue: row.input)?.rawValue
                if actual != row.expected {
                    lock.lock()
                    mismatches.append("\(String(reflecting: row.input)) -> \(String(describing: actual))")
                    lock.unlock()
                }
            }
        }

        XCTAssertEqual(mismatches, [])
    }

    /// `Codable` decodes through `init?(rawValue:)`, so it must reject and
    /// normalise exactly as the table does.
    func testDecode_UsesSameValidation() throws {
        let decoder = JSONDecoder()
        let valid = try decoder.decode(EmailAddress.self, from: Data(#"" mailto:user@example.com""#.utf8))
        XCTAssertEqual(valid.rawValue, "user@example.com")
        XCTAssertThrowsError(try decoder.decode(EmailAddress.self, from: Data(#""https://example.com/help""#.utf8)))
    }
}
