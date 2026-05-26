//
//  String+NYPLAdditionsTests.swift
//  The Palace Project
//
//  Created by Ettore Pasquini on 4/8/20.
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

import XCTest
@testable import Palace

class String_NYPLAdditionsTests: XCTestCase {
    func testURLEncodingQueryParam() {
        let multiASCIIWord = "Pinco Pallino".stringURLEncodedAsQueryParamValue()
        XCTAssertEqual(multiASCIIWord, "Pinco%20Pallino")

        let queryCharsSeparators = "?=&".stringURLEncodedAsQueryParamValue()
        XCTAssertEqual(queryCharsSeparators, "%3F%3D%26")

        let accentedVowels = "àèîóú".stringURLEncodedAsQueryParamValue()
        XCTAssertEqual(accentedVowels, "%C3%A0%C3%A8%C3%AE%C3%B3%C3%BA")

        let legacyEscapes = ";/?:@&=$+{}<>,".stringURLEncodedAsQueryParamValue()
        XCTAssertEqual(legacyEscapes, "%3B%2F%3F%3A%40%26%3D%24%2B%7B%7D%3C%3E%2C")

        let noEscapes = "-_".stringURLEncodedAsQueryParamValue()
        XCTAssertEqual(noEscapes, "-_")

        let otherEscapes = "~`!#%^*()[]|\\".stringURLEncodedAsQueryParamValue()
        XCTAssertEqual(otherEscapes, "~%60!%23%25%5E*()%5B%5D%7C%5C")
    }

    func testMD5() {
        XCTAssertEqual("password".md5hex(), "5f4dcc3b5aa765d61d8327deb882cf99")
        XCTAssertEqual("password".md5String(), "5f4dcc3b5aa765d61d8327deb882cf99")
    }

    /// fileSystemSafeBase64Encoded/Decoded must round-trip — encoding then
    /// decoding must yield the original. Pin both directions in one body
    /// AND assert the encoded form has none of the file-system-unsafe
    /// characters that the variant exists to avoid (`/`, `+`, `=`).
    /// A mutant that produces correctly-decoded but file-system-unsafe
    /// output fails on the unsafe-char absence check.
    func testFileSystemSafeBase64_encodeAndDecodeRoundTripWithoutUnsafeChars() {
        let original = "ynJZEsWMnTudEGg646Tmua" as NSString
        let encoded = original.fileSystemSafeBase64EncodedString(
            usingEncoding: String.Encoding.utf8.rawValue)

        // Canonical encoded form
        XCTAssertEqual(encoded, "eW5KWkVzV01uVHVkRUdnNjQ2VG11YQ")

        // File-system-safe variant must NOT contain `/`, `+`, or `=` —
        // that's the entire reason for this method's existence vs the
        // standard base64 encoder.
        XCTAssertFalse(encoded?.contains("/") ?? true,
                       "fileSystemSafeBase64 must NOT contain '/' — not safe in path components")
        XCTAssertFalse(encoded?.contains("+") ?? true,
                       "fileSystemSafeBase64 must NOT contain '+'")
        XCTAssertFalse(encoded?.contains("=") ?? true,
                       "fileSystemSafeBase64 must NOT contain '=' padding")

        // Round-trip back to the original — proves encode and decode are
        // mutual inverses, not just both producing the canonical strings.
        let decoded = (encoded! as NSString).fileSystemSafeBase64DecodedString(
            usingEncoding: String.Encoding.utf8.rawValue)
        XCTAssertEqual(decoded, original as String,
                       "encode→decode must round-trip back to original")
    }

    func testSHA256() {
        XCTAssertEqual(("967824¬Ó¨⁄€™®©♟♞♝♜♛♚♙♘♗♖♕♔" as NSString).sha256(),
                       "269b80eff0cd705e4b1de9fdbb2e1b0bccf30e6124cdc3487e8d74620eedf254")
    }
}
