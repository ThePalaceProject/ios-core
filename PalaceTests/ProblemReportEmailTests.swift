//
//  ProblemReportEmailTests.swift
//  PalaceTests
//
//  Tests for ProblemReportEmail body generation.
//

import XCTest
@testable import Palace

final class ProblemReportEmailTests: XCTestCase {
  
  private var emailService: ProblemReportEmail!
  
  override func setUp() {
    super.setUp()
    emailService = ProblemReportEmail.sharedInstance
  }
  
  // MARK: - generateBody Tests
  
  func testGenerateBody_withBook_containsBookInfo() {
    let book = TPPBookMocker.mockBook(title: "Test Book Title", authors: "Test Author")
    
    let body = emailService.generateBody(book: book)
    
    XCTAssertTrue(body.contains("Title: Test Book Title"))
    XCTAssertTrue(body.contains("ID: "))
  }
  
  func testGenerateBody_withoutBook_doesNotContainBookInfo() {
    let body = emailService.generateBody(book: nil)
    
    XCTAssertFalse(body.contains("Title:"))
    XCTAssertFalse(body.contains("ID:"))
  }
  
  func testGenerateBody_containsDeviceIdiom() {
    let body = emailService.generateBody(book: nil)
    
    XCTAssertTrue(body.contains("Idiom:"))
    // The idiom should be one of: phone, pad, tv, mac, carPlay, unspecified
    let validIdioms = ["phone", "pad", "tv", "mac", "carPlay", "unspecified"]
    let containsValidIdiom = validIdioms.contains { body.contains("Idiom: \($0)") }
    XCTAssertTrue(containsValidIdiom, "Body should contain a valid idiom")
  }
  
  func testGenerateBody_containsPlatform() {
    let body = emailService.generateBody(book: nil)
    
    XCTAssertTrue(body.contains("Platform: iOS"))
  }
  
  func testGenerateBody_containsOSVersion() {
    let body = emailService.generateBody(book: nil)
    
    XCTAssertTrue(body.contains("OS:"))
    // Should contain the system version number
    let systemVersion = UIDevice.current.systemVersion
    XCTAssertTrue(body.contains("OS: \(systemVersion)"))
  }
  
  func testGenerateBody_containsScreenHeight() {
    let body = emailService.generateBody(book: nil)
    
    XCTAssertTrue(body.contains("Height:"))
    let height = UIScreen.main.nativeBounds.height
    XCTAssertTrue(body.contains("Height: \(height)"))
  }
  
  func testGenerateBody_containsPalaceVersion() {
    let body = emailService.generateBody(book: nil)
    
    XCTAssertTrue(body.contains("Palace Version:"))
  }
  
  func testGenerateBody_containsLibrary() {
    let body = emailService.generateBody(book: nil)
    
    XCTAssertTrue(body.contains("Library:"))
  }
  
  func testGenerateBody_startsWithNewlines() {
    let body = emailService.generateBody(book: nil)
    
    // Body should start with newlines to leave space for user message
    XCTAssertTrue(body.hasPrefix("\n\n"))
  }
  
  func testGenerateBody_containsSeparator() {
    let body = emailService.generateBody(book: nil)
    
    // Body should contain separator line
    XCTAssertTrue(body.contains("---"))
  }
  
  // MARK: - Patron ID Tests (PP-3651)
  
  /// Regression test for PP-3651: Patron ID should be appended to support emails
  func testPP3651_generateBody_withPatronID_containsPatronID() {
    let patronID = "23333098765432"
    
    let body = emailService.generateBody(book: nil, patronIdentifier: patronID)
    
    XCTAssertTrue(body.contains("Patron ID: \(patronID)"),
                  "Email body should contain patron ID when provided")
  }
  
  /// Regression test for PP-3651: Patron ID should be omitted when nil
  func testPP3651_generateBody_withoutPatronID_doesNotContainPatronIDLabel() {
    let body = emailService.generateBody(book: nil, patronIdentifier: nil)
    
    XCTAssertFalse(body.contains("Patron ID:"),
                   "Email body should not contain 'Patron ID:' label when patron ID is nil")
  }
  
  /// Regression test for PP-3651: Patron ID should appear alongside book info
  func testPP3651_generateBody_withBookAndPatronID_containsBothBookAndPatronInfo() {
    let book = TPPBookMocker.mockBook(title: "Test Book", authors: "Test Author")
    let patronID = "12345678901234"
    
    let body = emailService.generateBody(book: book, patronIdentifier: patronID)
    
    XCTAssertTrue(body.contains("Title: Test Book"),
                  "Email body should contain book title")
    XCTAssertTrue(body.contains("Patron ID: \(patronID)"),
                  "Email body should contain patron ID alongside book info")
  }
  
  /// Regression test for PP-3651: Patron ID should appear in the device info section (after the separator)
  func testPP3651_generateBody_patronID_appearsAfterSeparator() {
    let patronID = "99887766554433"
    
    let body = emailService.generateBody(book: nil, patronIdentifier: patronID)
    
    // The patron ID should appear after the "---" separator along with other device info
    guard let separatorRange = body.range(of: "---") else {
      XCTFail("Body should contain separator")
      return
    }
    let afterSeparator = String(body[separatorRange.upperBound...])
    XCTAssertTrue(afterSeparator.contains("Patron ID: \(patronID)"),
                  "Patron ID should appear in the device info section after the separator")
  }
}

