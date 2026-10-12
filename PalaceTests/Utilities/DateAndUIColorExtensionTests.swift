//
//  DateAndUIColorExtensionTests.swift
//  PalaceTests
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace
import PalaceBookModel
import PalaceUtilities

// MARK: - Date+Extensions

@MainActor
final class DateExtensionsTests: XCTestCase {

    func testMonthDayYearString_formatsFullMonthNameDayAndYear() {
        var components = DateComponents()
        components.year = 2024
        components.month = 3
        components.day = 15
        let date = Calendar(identifier: .gregorian).date(from: components)!

        XCTAssertEqual(date.monthDayYearString, "March 15, 2024")
    }

    func testTimeUntil_threeDaysAhead_reportsPluralDays() {
        let future = Date().addingTimeInterval(3 * 86400)

        let result = future.timeUntil()

        XCTAssertTrue((2...3).contains(result.value), "got \(result.value)")
        XCTAssertEqual(result.unit, "days")
    }

    func testTimeUntil_justOverOneDayAhead_reportsSingularDay() {
        let future = Date().addingTimeInterval(86400 + 60)

        let result = future.timeUntil()

        XCTAssertEqual(result.value, 1)
        XCTAssertEqual(result.unit, "day")
    }

    func testTimeUntil_threeHoursAhead_reportsPluralHours() {
        let future = Date().addingTimeInterval(3 * 3600)

        let result = future.timeUntil()

        XCTAssertTrue((2...3).contains(result.value), "got \(result.value)")
        XCTAssertEqual(result.unit, "hours")
    }

    func testTimeUntil_pastDate_reportsExpiredWithZeroValue() {
        let past = Date().addingTimeInterval(-3600)

        let result = past.timeUntil()

        XCTAssertEqual(result.unit, "expired")
        XCTAssertEqual(result.value, 0)
    }
}

// MARK: - UIColor+Extensions

@MainActor
final class UIColorExtensionsTests: XCTestCase {

    func testDefaultLabelColor_isSystemLabelColor() {
        XCTAssertEqual(UIColor.defaultLabelColor(), UIColor.label)
    }

    func testHexString_red_isUppercaseHashPrefixedRGB() {
        let color = UIColor(red: 1, green: 0, blue: 0, alpha: 1)

        XCTAssertEqual(color.hexString, "#FF0000")
    }

    func testHexString_whiteAndBlack_formatAllChannels() {
        XCTAssertEqual(UIColor(red: 1, green: 1, blue: 1, alpha: 1).hexString, "#FFFFFF")
        XCTAssertEqual(UIColor(red: 0, green: 0, blue: 0, alpha: 1).hexString, "#000000")
    }

    func testInitFromHex_red_decodesChannelsWithOpaqueAlpha() {
        let color = UIColor(hexString: "#FF0000")

        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        XCTAssertEqual(r, 1.0, accuracy: 0.01)
        XCTAssertEqual(g, 0.0, accuracy: 0.01)
        XCTAssertEqual(b, 0.0, accuracy: 0.01)
        XCTAssertEqual(a, 1.0, accuracy: 0.01)
    }

    func testIsLight_white_isTrue() {
        XCTAssertTrue(UIColor(red: 1, green: 1, blue: 1, alpha: 1).isLight)
    }

    func testIsLight_black_isFalse() {
        XCTAssertFalse(UIColor(red: 0, green: 0, blue: 0, alpha: 1).isLight)
    }
}
