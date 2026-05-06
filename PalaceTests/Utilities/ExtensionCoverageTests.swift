//
//  ExtensionCoverageTests.swift
//  PalaceTests
//
//  Tests for utility extensions: Float+TPPAdditions, Int+Extensions,
//  Dictionary+Extensions, Array+Extensions, String+Extensions,
//  Data+Base64, URL+Extensions, URLResponse+NYPL, Date+Extensions,
//  String+MD5, UIColor+Extensions.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

// MARK: - Float+TPPAdditions Tests

final class FloatTPPAdditionsCoverageTests: XCTestCase {

    // SRS: Float approximate equality returns true for equal values
    func testFloatApproxEqual_equalValues() {
        let a: Float = 1.0
        let b: Float = 1.0
        XCTAssertTrue(a =~= b)
        // Symmetry: a =~= b implies b =~= a
        XCTAssertTrue(b =~= a)
        // Reflexivity: a =~= a
        XCTAssertTrue(a =~= a)
    }

    // SRS: Float approximate equality returns true for nearly equal values
    func testFloatApproxEqual_nearlyEqualValues() {
        let a: Float = 1.0
        let b: Float = 1.0 + Float.ulpOfOne / 2
        XCTAssertTrue(a =~= b)
        // Symmetry holds for near-equal values too
        XCTAssertTrue(b =~= a)
    }

    // SRS: Float approximate equality returns false for different values
    func testFloatApproxEqual_differentValues() {
        let a: Float = 1.0
        let b: Float = 2.0
        XCTAssertFalse(a =~= b)
        // Symmetry: if a is not ~= b, b is not ~= a
        XCTAssertFalse(b =~= a)
        // Large difference should also be not approximately equal
        XCTAssertFalse(a =~= 100.0)
    }

    // SRS: Float approximate equality returns false for nil
    func testFloatApproxEqual_nilValue() {
        let a: Float = 1.0
        XCTAssertFalse(a =~= nil)
        // Zero is not approximately equal to nil
        XCTAssertFalse((0.0 as Float) =~= nil)
    }

    // SRS: Float roundTo formats correctly
    func testFloatRoundTo_formatsCorrectly() {
        let value: Float = 75.5
        XCTAssertEqual(value.roundTo(decimalPlaces: 1), "75.5%")
        // Should include percent sign
        XCTAssertTrue(value.roundTo(decimalPlaces: 1).hasSuffix("%"))
    }

    // SRS: Float roundTo with zero decimal places
    func testFloatRoundTo_zeroDecimalPlaces() {
        let value: Float = 99.7
        XCTAssertEqual(value.roundTo(decimalPlaces: 0), "100%")
        // Exactly 50.0 with 0 decimal places
        XCTAssertEqual((50.0 as Float).roundTo(decimalPlaces: 0), "50%")
        XCTAssertTrue(value.roundTo(decimalPlaces: 0).hasSuffix("%"))
    }
}

// MARK: - Int+Extensions Tests

final class IntExtensionsCoverageTests: XCTestCase {

    // SRS: Int ordinal returns "1st" for 1
    func testOrdinal_first() {
        XCTAssertEqual(1.ordinal(), "1st")
        XCTAssertTrue(1.ordinal().hasSuffix("st"))
        XCTAssertFalse(1.ordinal().isEmpty)
    }

    // SRS: Int ordinal returns "2nd" for 2
    func testOrdinal_second() {
        XCTAssertEqual(2.ordinal(), "2nd")
        XCTAssertTrue(2.ordinal().hasSuffix("nd"))
    }

    // SRS: Int ordinal returns "3rd" for 3
    func testOrdinal_third() {
        XCTAssertEqual(3.ordinal(), "3rd")
        XCTAssertTrue(3.ordinal().hasSuffix("rd"))
    }

    // SRS: Int ordinal returns "4th" for 4
    func testOrdinal_fourth() {
        XCTAssertEqual(4.ordinal(), "4th")
        XCTAssertTrue(4.ordinal().hasSuffix("th"))
        // 5th, 6th, etc. should also use "th"
        XCTAssertEqual(5.ordinal(), "5th")
    }

    // SRS: Int ordinal returns "11th" for 11
    func testOrdinal_eleventh() {
        XCTAssertEqual(11.ordinal(), "11th")
        // 12th and 13th are also "th" exceptions
        XCTAssertEqual(12.ordinal(), "12th")
        XCTAssertEqual(13.ordinal(), "13th")
    }

    // SRS: Int ordinal returns "21st" for 21
    func testOrdinal_twentyFirst() {
        XCTAssertEqual(21.ordinal(), "21st")
        XCTAssertEqual(22.ordinal(), "22nd")
        XCTAssertEqual(23.ordinal(), "23rd")
    }
}

// MARK: - Dictionary+Extensions Tests

final class DictionaryExtensionsCoverageTests: XCTestCase {

    // SRS: Dictionary mapKeys transforms keys correctly
    func testMapKeys_transformsKeys() {
        let dict = ["a": 1, "b": 2, "c": 3]
        let result = dict.mapKeys { $0.uppercased() }
        XCTAssertEqual(result["A"], 1)
        XCTAssertEqual(result["B"], 2)
        XCTAssertEqual(result["C"], 3)
    }

    // SRS: Dictionary mapKeys preserves values
    func testMapKeys_preservesValues() {
        let dict = [1: "one", 2: "two"]
        let result = dict.mapKeys { $0 * 10 }
        XCTAssertEqual(result[10], "one")
        XCTAssertEqual(result[20], "two")
    }

    // SRS: Dictionary mapKeys handles empty dictionary
    func testMapKeys_emptyDictionary() {
        let dict = [String: Int]()
        let result = dict.mapKeys { $0.uppercased() }
        XCTAssertTrue(result.isEmpty)
        // Must also be distinct from a non-empty result
        let nonEmpty = ["a": 1].mapKeys { $0.uppercased() }
        XCTAssertFalse(nonEmpty.isEmpty, "Non-empty dict must produce a non-empty result")
        XCTAssertEqual(nonEmpty["A"], 1, "Key must be transformed to uppercase")
    }
}

// MARK: - Array+Extensions Tests

final class ArrayExtensionsCoverageTests: XCTestCase {

    // SRS: Array safe subscript returns element at valid index
    func testSafeSubscript_validIndex() {
        let arr = [10, 20, 30]
        XCTAssertEqual(arr[safe: 1], 20)
        // First and last elements must also be accessible
        XCTAssertEqual(arr[safe: 0], 10, "First element must be reachable at index 0")
        XCTAssertEqual(arr[safe: 2], 30, "Last element must be reachable at the count-1 index")
    }

    // SRS: Array safe subscript returns nil for negative index
    func testSafeSubscript_negativeIndex() {
        let arr = [10, 20, 30]
        XCTAssertNil(arr[safe: -1])
        // Any negative index must be nil, not crash
        XCTAssertNil(arr[safe: -100], "Large negative index must also return nil")
    }

    // SRS: Array safe subscript returns nil for out of bounds index
    func testSafeSubscript_outOfBounds() {
        let arr = [10, 20, 30]
        XCTAssertNil(arr[safe: 5])
        // The boundary just past the end (index == count) must be nil
        XCTAssertNil(arr[safe: arr.count], "Index equal to count must be out of bounds")
    }

    // SRS: Array safe subscript returns nil for empty array
    func testSafeSubscript_emptyArray() {
        let arr = [Int]()
        XCTAssertNil(arr[safe: 0])
        // Any index into an empty array must be nil
        XCTAssertNil(arr[safe: -1], "Negative index into empty array must also return nil")
    }

    // SRS: Array safe subscript set modifies value at valid index
    func testSafeSubscript_setValidIndex() {
        var arr = [10, 20, 30]
        arr[safe: 1] = 99
        XCTAssertEqual(arr[1], 99)
        // The other elements must be unchanged
        XCTAssertEqual(arr[0], 10, "Elements at other indices must not be affected")
        XCTAssertEqual(arr.count, 3, "Array size must not change after a valid set")
    }

    // SRS: Array safe subscript set ignores out of bounds index
    func testSafeSubscript_setOutOfBounds() {
        var arr = [10, 20, 30]
        arr[safe: 5] = 99
        XCTAssertEqual(arr.count, 3)
        // All original values must be preserved
        XCTAssertEqual(arr[0], 10, "Out-of-bounds set must not alter any existing element")
    }

    // SRS: Array safe subscript set ignores nil value
    func testSafeSubscript_setNil() {
        var arr = [10, 20, 30]
        arr[safe: 1] = nil
        XCTAssertEqual(arr[1], 20, "Setting nil should not modify the array")
        // Count must be unchanged — nil set is a no-op
        XCTAssertEqual(arr.count, 3, "Setting nil must not change the array size")
    }
}

// MARK: - String+Extensions Tests

final class StringExtensionsCoverageTests: XCTestCase {

    // SRS: String.isDate returns true when date1 + delay > date2
    func testIsDate_moreRecentWithDelay() {
        let date1 = "2024-01-15T10:00:00Z"
        let date2 = "2024-01-15T10:00:05Z"
        // date1 + 10 seconds > date2 (which is 5 seconds later)
        XCTAssertTrue(String.isDate(date1, moreRecentThan: date2, with: 10))
        // Insufficient delay — date1 + 3s is not > date2 (5s later)
        XCTAssertFalse(String.isDate(date1, moreRecentThan: date2, with: 3))
    }

    // SRS: String.isDate returns false when date1 + delay < date2
    func testIsDate_notMoreRecentWithDelay() {
        let date1 = "2024-01-15T10:00:00Z"
        let date2 = "2024-01-15T10:00:30Z"
        // date1 + 10 seconds < date2 (which is 30 seconds later)
        XCTAssertFalse(String.isDate(date1, moreRecentThan: date2, with: 10))
        // With large enough delay it should pass
        XCTAssertTrue(String.isDate(date1, moreRecentThan: date2, with: 31))
    }

    // SRS: String.isDate returns false for invalid date strings
    func testIsDate_invalidDateStrings() {
        XCTAssertFalse(String.isDate("not-a-date", moreRecentThan: "also-not", with: 0))
        // One valid, one invalid
        XCTAssertFalse(String.isDate("not-a-date", moreRecentThan: "2024-01-15T10:00:00Z", with: 0))
        XCTAssertFalse(String.isDate("2024-01-15T10:00:00Z", moreRecentThan: "not-a-date", with: 0))
    }

    // SRS: String.isDate with zero delay compares directly
    func testIsDate_zeroDelay() {
        let earlier = "2024-01-15T10:00:00Z"
        let later = "2024-01-15T10:00:01Z"
        XCTAssertFalse(String.isDate(earlier, moreRecentThan: later, with: 0))
        XCTAssertTrue(String.isDate(later, moreRecentThan: earlier, with: 0))
        // Equal timestamps with zero delay are NOT more recent (strictly greater)
        XCTAssertFalse(String.isDate(earlier, moreRecentThan: earlier, with: 0))
    }
}

// MARK: - Data+Base64 Tests

final class DataBase64CoverageTests: XCTestCase {

    // SRS: Data URL-safe base64 replaces + with -
    func testBase64UrlSafe_replacesPlusWithDash() {
        // Create data that will produce + in base64
        // ">>>" base64 is "Pj4+"
        let data = Data([0x3E, 0x3E, 0x3E])
        let result = data.base64EncodedStringUrlSafe()
        XCTAssertFalse(result.contains("+"), "URL-safe base64 should not contain +")
        // The replacement character should be "-"
        XCTAssertTrue(result.contains("-"), "URL-safe base64 should use '-' instead of '+'")
        XCTAssertFalse(result.isEmpty)
    }

    // SRS: Data URL-safe base64 replaces / with _
    func testBase64UrlSafe_replacesSlashWithUnderscore() {
        // "???" base64 is "Pz8/"
        let data = Data([0x3F, 0x3F, 0x3F])
        let result = data.base64EncodedStringUrlSafe()
        XCTAssertFalse(result.contains("/"), "URL-safe base64 should not contain /")
        XCTAssertTrue(result.contains("_"))
        XCTAssertFalse(result.contains("+"), "Should also not contain + sign")
    }

    // SRS: Data URL-safe base64 removes newlines
    func testBase64UrlSafe_removesNewlines() {
        // Large enough data to potentially produce newlines
        let data = Data(repeating: 0xFF, count: 100)
        let result = data.base64EncodedStringUrlSafe()
        XCTAssertFalse(result.contains("\n"))
        XCTAssertFalse(result.contains("\r"))
        XCTAssertFalse(result.isEmpty)
    }

    // SRS: Data URL-safe base64 empty data
    func testBase64UrlSafe_emptyData() {
        let data = Data()
        XCTAssertEqual(data.base64EncodedStringUrlSafe(), "")
        // Single byte produces 4-character base64
        let singleByte = Data([0x00])
        XCTAssertEqual(singleByte.base64EncodedStringUrlSafe().count, 4)
    }
}

// MARK: - URL+Extensions Tests

final class URLExtensionsCoverageTests: XCTestCase {

    // SRS: URL replacingScheme changes http to https
    func testReplacingScheme_httpToHttps() {
        let url = URL(string: "http://example.com/path")!
        let result = url.replacingScheme(with: "https")
        XCTAssertEqual(result.scheme, "https")
        XCTAssertEqual(result.host, "example.com")
        XCTAssertEqual(result.path, "/path")
        // Original URL scheme should be unchanged
        XCTAssertEqual(url.scheme, "http", "Original URL must not be mutated")
    }

    // SRS: URL replacingScheme preserves query parameters
    func testReplacingScheme_preservesQuery() {
        let url = URL(string: "http://example.com/path?key=value")!
        let result = url.replacingScheme(with: "https")
        XCTAssertEqual(result.query, "key=value")
        // Host and path should also be preserved
        XCTAssertEqual(result.host, "example.com")
        XCTAssertEqual(result.path, "/path")
    }

    // SRS: URL replacingScheme to custom scheme
    func testReplacingScheme_customScheme() {
        let url = URL(string: "https://example.com")!
        let result = url.replacingScheme(with: "palace")
        XCTAssertEqual(result.scheme, "palace")
        // Host must be preserved when only scheme changes
        XCTAssertEqual(result.host, "example.com")
    }
}

// MARK: - URLResponse+NYPL Tests

final class URLResponseNYPLCoverageTests: XCTestCase {

    // SRS: URLResponse isProblemDocument for application/problem+json
    func testIsProblemDocument_problemJson() {
        let url = URL(string: "https://example.com")!
        let response = HTTPURLResponse(url: url, mimeType: "application/problem+json", expectedContentLength: 0, textEncodingName: nil)
        XCTAssertTrue(response.isProblemDocument())
        // Regular JSON should not be a problem document
        let regularResponse = HTTPURLResponse(url: url, mimeType: "application/json", expectedContentLength: 0, textEncodingName: nil)
        XCTAssertFalse(regularResponse.isProblemDocument())
    }

    // SRS: URLResponse isProblemDocument for application/api-problem+json
    func testIsProblemDocument_apiProblemJson() {
        let url = URL(string: "https://example.com")!
        let response = HTTPURLResponse(url: url, mimeType: "application/api-problem+json", expectedContentLength: 0, textEncodingName: nil)
        XCTAssertTrue(response.isProblemDocument())
        // Both problem MIME types should be recognized
        let standardProblem = HTTPURLResponse(url: url, mimeType: "application/problem+json", expectedContentLength: 0, textEncodingName: nil)
        XCTAssertTrue(standardProblem.isProblemDocument())
    }

    // SRS: URLResponse isProblemDocument false for regular JSON
    func testIsProblemDocument_regularJson() {
        let url = URL(string: "https://example.com")!
        let response = HTTPURLResponse(url: url, mimeType: "application/json", expectedContentLength: 0, textEncodingName: nil)
        XCTAssertFalse(response.isProblemDocument())
        // Also false for HTML
        let htmlResponse = HTTPURLResponse(url: url, mimeType: "text/html", expectedContentLength: 0, textEncodingName: nil)
        XCTAssertFalse(htmlResponse.isProblemDocument())
    }

    // SRS: HTTPURLResponse isSuccess for 200
    func testIsSuccess_200() {
        let url = URL(string: "https://example.com")!
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        XCTAssertTrue(response.isSuccess())
        XCTAssertEqual(response.statusCode, 200)
    }

    // SRS: HTTPURLResponse isSuccess for 204
    func testIsSuccess_204() {
        let url = URL(string: "https://example.com")!
        let response = HTTPURLResponse(url: url, statusCode: 204, httpVersion: nil, headerFields: nil)!
        XCTAssertTrue(response.isSuccess())
        // 201 Created is also a success
        let created = HTTPURLResponse(url: url, statusCode: 201, httpVersion: nil, headerFields: nil)!
        XCTAssertTrue(created.isSuccess())
    }

    // SRS: HTTPURLResponse isSuccess false for 404
    func testIsSuccess_404() {
        let url = URL(string: "https://example.com")!
        let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!
        XCTAssertFalse(response.isSuccess())
        // 400 Bad Request is also not a success
        let badRequest = HTTPURLResponse(url: url, statusCode: 400, httpVersion: nil, headerFields: nil)!
        XCTAssertFalse(badRequest.isSuccess())
    }

    // SRS: HTTPURLResponse isSuccess false for 500
    func testIsSuccess_500() {
        let url = URL(string: "https://example.com")!
        let response = HTTPURLResponse(url: url, statusCode: 500, httpVersion: nil, headerFields: nil)!
        XCTAssertFalse(response.isSuccess())
        // 503 Service Unavailable is also not a success
        let unavailable = HTTPURLResponse(url: url, statusCode: 503, httpVersion: nil, headerFields: nil)!
        XCTAssertFalse(unavailable.isSuccess())
    }

    // SRS: HTTPURLResponse isSuccess false for 301
    func testIsSuccess_301() {
        let url = URL(string: "https://example.com")!
        let response = HTTPURLResponse(url: url, statusCode: 301, httpVersion: nil, headerFields: nil)!
        XCTAssertFalse(response.isSuccess())
        // 302 Found is also a redirect, not success
        let redirect302 = HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: nil)!
        XCTAssertFalse(redirect302.isSuccess())
    }
}

// MARK: - Date+Extensions Tests

final class DateExtensionsCoverageTests: XCTestCase {

    // SRS: Date monthDayYearString formats correctly
    func testMonthDayYearString() {
        var components = DateComponents()
        components.year = 2024
        components.month = 3
        components.day = 15
        let date = Calendar(identifier: .gregorian).date(from: components)!
        XCTAssertEqual(date.monthDayYearString, "March 15, 2024")
        XCTAssertTrue(date.monthDayYearString.contains("2024"))
        XCTAssertTrue(date.monthDayYearString.contains("March"))
    }

    // SRS: Date timeUntil returns days for future date
    func testTimeUntil_futureDays() {
        let future = Date().addingTimeInterval(3 * 86400) // 3 days
        let result = future.timeUntil()
        XCTAssertTrue(result.value >= 2 && result.value <= 3)
        XCTAssertEqual(result.unit, "days")
        XCTAssertGreaterThan(result.value, 0)
    }

    // SRS: Date timeUntil returns singular day
    func testTimeUntil_oneDay() {
        let future = Date().addingTimeInterval(86400 + 60) // 1 day + buffer
        let result = future.timeUntil()
        XCTAssertEqual(result.value, 1)
        XCTAssertEqual(result.unit, "day")
        // Singular, not plural
        XCTAssertNotEqual(result.unit, "days")
    }

    // SRS: Date timeUntil returns hours for less than a day
    func testTimeUntil_hours() {
        let future = Date().addingTimeInterval(3 * 3600) // 3 hours
        let result = future.timeUntil()
        XCTAssertTrue(result.value >= 2 && result.value <= 3)
        XCTAssertTrue(result.unit == "hours")
        XCTAssertGreaterThan(result.value, 0)
    }

    // SRS: Date timeUntil returns expired for past date
    func testTimeUntil_expired() {
        let past = Date().addingTimeInterval(-3600) // 1 hour ago
        let result = past.timeUntil()
        XCTAssertEqual(result.unit, "expired")
        XCTAssertEqual(result.value, 0)
        // Expired unit should not be "days" or "hours"
        XCTAssertNotEqual(result.unit, "days")
        XCTAssertNotEqual(result.unit, "hours")
    }
}

// MARK: - String+MD5 Tests

final class StringMD5Tests: XCTestCase {

    // SRS: String md5 produces correct hash for known input
    func testMD5_knownInput() {
        let hash = "hello".md5hex()
        XCTAssertEqual(hash, "5d41402abc4b2a76b9719d911017c592")
        XCTAssertEqual(hash.count, 32)
        XCTAssertTrue(hash.allSatisfy { $0.isHexDigit })
    }

    // SRS: String md5 produces different hashes for different inputs
    func testMD5_differentInputs() {
        let hash1 = "abc".md5hex()
        let hash2 = "def".md5hex()
        XCTAssertNotEqual(hash1, hash2)
        // Both should be valid 32-char hashes
        XCTAssertEqual(hash1.count, 32)
        XCTAssertEqual(hash2.count, 32)
    }

    // SRS: String md5 returns Data of correct length
    func testMD5_dataLength() {
        let data = "test".md5()
        XCTAssertEqual(data.count, 16) // MD5 is 128 bits = 16 bytes
        // Data should not be empty
        XCTAssertFalse(data.isEmpty)
    }

    // SRS: String md5hex returns 32-character hex string
    func testMD5Hex_length() {
        let hex = "test".md5hex()
        XCTAssertEqual(hex.count, 32)
        // Should be lowercase hex
        XCTAssertEqual(hex, hex.lowercased())
    }

    // SRS: NSString md5String works
    func testNSStringMD5() {
        let nsString: NSString = "hello"
        let result = nsString.md5String()
        XCTAssertEqual(result as String, "5d41402abc4b2a76b9719d911017c592")
        // Swift String md5 and NSString md5 should agree
        XCTAssertEqual(result as String, "hello".md5hex())
    }

    // SRS: String md5 empty string
    func testMD5_emptyString() {
        let hash = "".md5hex()
        XCTAssertEqual(hash, "d41d8cd98f00b204e9800998ecf8427e")
        XCTAssertEqual(hash.count, 32)
    }
}

// MARK: - UIColor+Extensions Tests

final class UIColorExtensionsTests: XCTestCase {

    // SRS: UIColor defaultLabelColor returns a color
    func testDefaultLabelColor_returnsColor() {
        let color = UIColor.defaultLabelColor()
        XCTAssertNotNil(color)
        // Should be a usable color — can extract RGBA without crash
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        let success = color.getRed(&r, green: &g, blue: &b, alpha: &a)
        XCTAssertTrue(success, "defaultLabelColor should be RGBA-extractable")
    }

    // SRS: UIColor hexString formats correctly
    func testHexString_red() {
        let color = UIColor(red: 1, green: 0, blue: 0, alpha: 1)
        XCTAssertEqual(color.hexString, "#FF0000")
        // Hex string must start with '#'
        XCTAssertTrue(color.hexString.hasPrefix("#"))
        XCTAssertEqual(color.hexString.count, 7)
    }

    // SRS: UIColor hexString for white
    func testHexString_white() {
        let color = UIColor(red: 1, green: 1, blue: 1, alpha: 1)
        XCTAssertEqual(color.hexString, "#FFFFFF")
        // White and black should be different
        let black = UIColor(red: 0, green: 0, blue: 0, alpha: 1)
        XCTAssertNotEqual(color.hexString, black.hexString)
    }

    // SRS: UIColor init from hex string
    func testInitFromHex_red() {
        let color = UIColor(hexString: "#FF0000")
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        XCTAssertEqual(r, 1.0, accuracy: 0.01)
        XCTAssertEqual(g, 0.0, accuracy: 0.01)
        XCTAssertEqual(b, 0.0, accuracy: 0.01)
        XCTAssertEqual(a, 1.0, accuracy: 0.01, "Alpha should be fully opaque")
    }

    // SRS: UIColor isLight for white
    func testIsLight_white() {
        let color = UIColor(red: 1, green: 1, blue: 1, alpha: 1)
        XCTAssertTrue(color.isLight)
        // Light colors should not be confused with dark
        let black = UIColor(red: 0, green: 0, blue: 0, alpha: 1)
        XCTAssertNotEqual(color.isLight, black.isLight)
    }

    // SRS: UIColor isLight false for black
    func testIsLight_black() {
        let color = UIColor(red: 0, green: 0, blue: 0, alpha: 1)
        XCTAssertFalse(color.isLight)
        // Black hex string should be "#000000"
        XCTAssertEqual(color.hexString, "#000000")
    }
}
