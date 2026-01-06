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
}

