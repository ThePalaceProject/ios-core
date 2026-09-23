//
//  StringExtensionTests.swift
//  PalaceTests
//
//  Tests for String extension methods
//

import XCTest
@testable import Palace

@MainActor
final class StringExtensionTests: XCTestCase {

    // MARK: - MD5 Hash Tests

    func testMd5hex_returnsConsistentHash() {
        let input = "test@example.com"
        let hash1 = input.md5hex()
        let hash2 = input.md5hex()

        XCTAssertEqual(hash1, hash2)
        // MD5 is always 32 hex characters
        XCTAssertEqual(hash1.count, 32)
        // Only hex characters should appear
        XCTAssertTrue(hash1.allSatisfy { $0.isHexDigit }, "MD5 hex output should only contain hex digits")
    }

    func testMd5hex_differsByInput() {
        let input1 = "test1@example.com"
        let input2 = "test2@example.com"

        XCTAssertNotEqual(input1.md5hex(), input2.md5hex())
        // Both should still produce valid 32-char hashes
        XCTAssertEqual(input1.md5hex().count, 32)
        XCTAssertEqual(input2.md5hex().count, 32)
    }

    func testMd5hex_emptyString() {
        let input = ""
        let hash = input.md5hex()

        XCTAssertNotNil(hash)
        XCTAssertFalse(hash.isEmpty)
        // Empty string MD5 is a well-known constant
        XCTAssertEqual(hash, "d41d8cd98f00b204e9800998ecf8427e")
        XCTAssertEqual(hash.count, 32)
    }

    func testMd5hex_length() {
        let input = "test"
        let hash = input.md5hex()

        // MD5 produces 32 character hex string
        XCTAssertEqual(hash.count, 32)
        // The hash should be lowercase hex
        XCTAssertEqual(hash, hash.lowercased(), "MD5 hex output should be lowercase")
    }

    // MARK: - HTML Entity Tests

    func testParseJSONString_validJSON() {
        let jsonString = "{\"key\":\"value\"}"
        let parsed = jsonString.parseJSONString

        XCTAssertNotNil(parsed)

        if let dict = parsed as? [String: Any] {
            XCTAssertEqual(dict["key"] as? String, "value")
        } else {
            XCTFail("Expected dictionary")
        }
    }

    func testParseJSONString_invalidJSON() {
        let invalidJSON = "not valid json"
        let parsed = invalidJSON.parseJSONString

        XCTAssertNil(parsed)
        // A valid JSON string on the other hand must parse successfully
        let validJSON = "{\"key\": \"value\"}"
        let validParsed = validJSON.parseJSONString
        XCTAssertNotNil(validParsed, "Valid JSON must parse to a non-nil result")
    }

    func testParseJSONString_emptyString() {
        let empty = ""
        let parsed = empty.parseJSONString

        XCTAssertNil(parsed)
        // Whitespace-only strings must also fail to parse
        let whitespace = "   "
        XCTAssertNil(whitespace.parseJSONString,
                     "Whitespace-only string must return nil from parseJSONString")
    }

    func testParseJSONString_arrayJSON() {
        let jsonArray = "[1, 2, 3]"
        let parsed = jsonArray.parseJSONString

        XCTAssertNotNil(parsed)

        if let array = parsed as? [Int] {
            XCTAssertEqual(array, [1, 2, 3])
        }
    }
}

// MARK: - Additional String Tests

@MainActor
final class StringNYPLAdditionsTests: XCTestCase {

    func testStringIsEmpty_withWhitespace() {
        let whitespace = "   "
        XCTAssertFalse(whitespace.isEmpty)
        XCTAssertTrue(whitespace.trimmingCharacters(in: .whitespaces).isEmpty)
        // Mixed whitespace should also trim to empty
        let mixed = "\t\n  \r"
        XCTAssertTrue(mixed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    func testStringContains_caseInsensitive() {
        let input = "Hello World"

        XCTAssertTrue(input.lowercased().contains("hello"))
        XCTAssertTrue(input.lowercased().contains("world"))
        // Case-sensitive check: original still has uppercase
        XCTAssertFalse(input.contains("hello"), "Case-sensitive contains should not find 'hello' in 'Hello World'")
    }

    func testStringPrefix_matching() {
        let input = "https://example.com/path"

        XCTAssertTrue(input.hasPrefix("https://"))
        XCTAssertFalse(input.hasPrefix("http://"))
        // No prefix should also work correctly
        XCTAssertFalse(input.hasPrefix("ftp://"))
        XCTAssertTrue(input.hasPrefix("https"), "Partial prefix should still match")
    }

    func testStringSuffix_matching() {
        let input = "document.pdf"

        XCTAssertTrue(input.hasSuffix(".pdf"))
        XCTAssertFalse(input.hasSuffix(".epub"))
        // Case sensitivity check
        XCTAssertFalse(input.hasSuffix(".PDF"), "hasSuffix is case-sensitive")
        XCTAssertTrue(input.hasSuffix("pdf"), "Partial suffix (without dot) should still match")
    }
}
