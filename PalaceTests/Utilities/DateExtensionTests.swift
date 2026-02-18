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
  }
  
  func testRfc339String_includesTimezone() {
    let date = Date()
    let rfc339 = date.rfc339String
    
    // RFC339 should include timezone indicator
    XCTAssertTrue(rfc339.contains("Z") || rfc339.contains("+") || rfc339.contains("-"))
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
  }
  
  func testSubtractingDays_decreasesDate() {
    let calendar = Calendar.current
    let date = Date()
    let pastDate = calendar.date(byAdding: .day, value: -7, to: date)!
    
    XCTAssertLessThan(pastDate, date)
  }
  
  // MARK: - Relative Date Tests
  
  func testTimeIntervalSinceNow_positive() {
    let futureDate = Date(timeIntervalSinceNow: 3600) // 1 hour from now
    XCTAssertGreaterThan(futureDate.timeIntervalSinceNow, 0)
  }
  
  func testTimeIntervalSinceNow_negative() {
    let pastDate = Date(timeIntervalSinceNow: -3600) // 1 hour ago
    XCTAssertLessThan(pastDate.timeIntervalSinceNow, 0)
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
  }
  
  func testLongDateFormat() {
    let date = Date()
    let formatter = DateFormatter()
    formatter.dateStyle = .long
    
    let formatted = formatter.string(from: date)
    XCTAssertFalse(formatted.isEmpty)
  }
  
  func testTimeFormat() {
    let date = Date()
    let formatter = DateFormatter()
    formatter.timeStyle = .short
    
    let formatted = formatter.string(from: date)
    XCTAssertFalse(formatted.isEmpty)
  }
  
  func testCustomFormat() {
    let date = Date()
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    
    let formatted = formatter.string(from: date)
    XCTAssertTrue(formatted.contains("-"))
    
    // Parse back
    let parsed = formatter.date(from: formatted)
    XCTAssertNotNil(parsed)
  }
}

