//
//  DateExtensionTests.swift
//  PalaceTests
//
//  Tests for Date extension methods
//

import XCTest
@testable import Palace

final class DateExtensionTests: XCTestCase {

    // MARK: - RFC339 Format Tests

    func testRfc339String_producesValidFormat() {
        let date = Date(timeIntervalSince1970: 0) // Jan 1, 1970
        let rfc339 = date.rfc339String

        XCTAssertNotNil(rfc339)
        XCTAssertTrue(rfc339.contains("1970"))
        XCTAssertFalse(rfc339.isEmpty)
        // Should contain separators typical of date-time format
        XCTAssertTrue(rfc339.contains("-") || rfc339.contains(":"))
    }

    func testRfc339String_includesTimezone() {
        let date = Date()
        let rfc339 = date.rfc339String

        // RFC339 should include timezone indicator
        XCTAssertTrue(rfc339.contains("Z") || rfc339.contains("+") || rfc339.contains("-"))
        // The string should be non-trivially long (at least "YYYY-MM-DD")
        XCTAssertGreaterThanOrEqual(rfc339.count, 10)
        XCTAssertFalse(rfc339.isEmpty)
    }

    // MARK: - ISO8601 Tests

    func testISO8601_roundTrip() {
        let originalDate = Date()

        let formatter = ISO8601DateFormatter()
        let dateString = formatter.string(from: originalDate)
        let parsedDate = formatter.date(from: dateString)

        XCTAssertNotNil(parsedDate)

        // Should be within 1 second (sub-second precision may be lost)
        let difference = abs(originalDate.timeIntervalSince(parsedDate!))
        XCTAssertLessThan(difference, 1.0)
    }

    // MARK: - Date Comparison Tests

    func testDateComparison_sameDay() {
        let calendar = Calendar.current
        // Use noon to avoid midnight boundary issues
        var components = calendar.dateComponents([.year, .month, .day], from: Date())
        components.hour = 12
        components.minute = 0
        let date1 = calendar.date(from: components)!
        let date2 = calendar.date(byAdding: .hour, value: 1, to: date1)!

        let isSameDay = calendar.isDate(date1, inSameDayAs: date2)
        XCTAssertTrue(isSameDay)
    }

    func testDateComparison_differentDay() {
        let calendar = Calendar.current
        let date1 = Date()
        let date2 = calendar.date(byAdding: .day, value: 1, to: date1)!

        let isSameDay = calendar.isDate(date1, inSameDayAs: date2)
        XCTAssertFalse(isSameDay)
    }

    // MARK: - Date Arithmetic Tests

    func testAddingDays_increasesDate() {
        let calendar = Calendar.current
        let date = Date()
        let futureDate = calendar.date(byAdding: .day, value: 7, to: date)!

        XCTAssertGreaterThan(futureDate, date)
        // Difference should be approximately 7 days (604800 seconds)
        let diff = futureDate.timeIntervalSince(date)
        XCTAssertEqual(diff, 604800, accuracy: 3600, "7 days should be ~604800 seconds")
    }

    func testSubtractingDays_decreasesDate() {
        let calendar = Calendar.current
        let date = Date()
        let pastDate = calendar.date(byAdding: .day, value: -7, to: date)!

        XCTAssertLessThan(pastDate, date)
        // Difference should be approximately -7 days
        let diff = pastDate.timeIntervalSince(date)
        XCTAssertLessThan(diff, 0, "Subtracting days should produce a past date")
        XCTAssertEqual(abs(diff), 604800, accuracy: 3600)
    }

    // MARK: - Relative Date Tests

    func testTimeIntervalSinceNow_positive() {
        let futureDate = Date(timeIntervalSinceNow: 3600) // 1 hour from now
        XCTAssertGreaterThan(futureDate.timeIntervalSinceNow, 0)
        // Should be close to 3600 seconds (allow a few seconds for test execution)
        XCTAssertGreaterThan(futureDate.timeIntervalSinceNow, 3590)
    }

    func testTimeIntervalSinceNow_negative() {
        let pastDate = Date(timeIntervalSinceNow: -3600) // 1 hour ago
        XCTAssertLessThan(pastDate.timeIntervalSinceNow, 0)
        // Should be close to -3600 seconds
        XCTAssertLessThan(pastDate.timeIntervalSinceNow, -3590)
    }
}

// MARK: - Date Formatting Tests

final class DateFormattingTests: XCTestCase {

    func testShortDateFormat() {
        let date = Date()
        let formatter = DateFormatter()
        formatter.dateStyle = .short

        let formatted = formatter.string(from: date)
        XCTAssertFalse(formatted.isEmpty)
        // Short format should be parseable back to a date
        let reparsed = formatter.date(from: formatted)
        XCTAssertNotNil(reparsed)
    }

    func testLongDateFormat() {
        let date = Date()
        let formatter = DateFormatter()
        formatter.dateStyle = .long

        let formatted = formatter.string(from: date)
        XCTAssertFalse(formatted.isEmpty)
        // Long format should be longer than short format
        let shortFormatter = DateFormatter()
        shortFormatter.dateStyle = .short
        let short = shortFormatter.string(from: date)
        XCTAssertGreaterThanOrEqual(formatted.count, short.count)
    }

    func testTimeFormat() {
        let date = Date()
        let formatter = DateFormatter()
        formatter.timeStyle = .short

        let formatted = formatter.string(from: date)
        XCTAssertFalse(formatted.isEmpty)
        // Time string should contain a colon separating hours and minutes
        XCTAssertTrue(formatted.contains(":"), "Short time format should contain ':'")
    }

    func testCustomFormat() {
        let date = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"

        let formatted = formatter.string(from: date)
        XCTAssertTrue(formatted.contains("-"))
        // Must have exactly two dashes (YYYY-MM-DD pattern)
        let dashCount = formatted.filter { $0 == "-" }.count
        XCTAssertEqual(dashCount, 2, "yyyy-MM-dd format should produce exactly 2 dashes")
        // Parse back
        let parsed = formatter.date(from: formatted)
        XCTAssertNotNil(parsed)
    }
}
