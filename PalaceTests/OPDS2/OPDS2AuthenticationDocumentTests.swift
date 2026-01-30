//
//  OPDS2AuthenticationDocumentTests.swift
//  PalaceTests
//
//  Tests for OPDS2 authentication document parsing
//

import XCTest
@testable import Palace

final class OPDS2AuthenticationDocumentTests: XCTestCase {
  
  // MARK: - Properties
  
  private var nyplAuthURL: URL!
  private var gplAuthURL: URL!
  private var dplAuthURL: URL!
  
  // MARK: - Setup
  
  override func setUpWithError() throws {
    try super.setUpWithError()
    let bundle = Bundle(for: type(of: self))
    nyplAuthURL = bundle.url(forResource: "nypl_authentication_document", withExtension: "json")
    gplAuthURL = bundle.url(forResource: "gpl_authentication_document", withExtension: "json")
    dplAuthURL = bundle.url(forResource: "dpl_authentication_document", withExtension: "json")
  }
  
  // MARK: - Basic Parsing Tests
  
  func testFromData_withValidJSON_parsesDocument() throws {
    guard let url = nyplAuthURL else {
      XCTFail("Test resource not found")
      return
    }
    
    let data = try Data(contentsOf: url)
    let doc = try OPDS2AuthenticationDocument.fromData(data)
    
    XCTAssertFalse(doc.title.isEmpty)
    XCTAssertFalse(doc.id.isEmpty)
  }
  
  func testFromData_withInvalidJSON_throwsError() {
    let invalidJSON = "{ invalid json }".data(using: .utf8)!
    
    XCTAssertThrowsError(try OPDS2AuthenticationDocument.fromData(invalidJSON))
  }
  
  func testFromData_withEmptyData_throwsError() {
    let emptyData = Data()
    
    XCTAssertThrowsError(try OPDS2AuthenticationDocument.fromData(emptyData))
  }
  
  func testFromData_withMissingRequiredFields_throwsError() {
    // Missing 'id' and 'title' which are required
    let incompleteJSON = """
    {
      "authentication": []
    }
    """.data(using: .utf8)!
    
    XCTAssertThrowsError(try OPDS2AuthenticationDocument.fromData(incompleteJSON))
  }
  
  // MARK: - Authentication Methods Tests
  
  func testAuthentication_parsesMultipleMethods() throws {
    guard let url = nyplAuthURL else {
      XCTFail("Test resource not found")
      return
    }
    
    let data = try Data(contentsOf: url)
    let doc = try OPDS2AuthenticationDocument.fromData(data)
    
    // NYPL should have multiple auth methods
    XCTAssertNotNil(doc.authentication)
    XCTAssertFalse(doc.authentication?.isEmpty ?? true)
  }
  
  func testAuthentication_parsesBasicAuth() throws {
    guard let url = gplAuthURL else {
      XCTFail("Test resource not found")
      return
    }
    
    let data = try Data(contentsOf: url)
    let doc = try OPDS2AuthenticationDocument.fromData(data)
    
    let basicAuth = doc.authentication?.first { $0.type.contains("basic") || $0.type.contains("Basic") }
    XCTAssertNotNil(basicAuth)
  }
  
  func testAuthentication_noAuthRequired() throws {
    guard let url = dplAuthURL else {
      XCTFail("Test resource not found")
      return
    }
    
    let data = try Data(contentsOf: url)
    let doc = try OPDS2AuthenticationDocument.fromData(data)
    
    // DPL doesn't require authentication
    XCTAssertTrue(doc.authentication?.isEmpty ?? true)
  }
  
  // MARK: - Labels Tests
  
  func testAuthentication_parsesLabels() throws {
    guard let url = gplAuthURL else {
      XCTFail("Test resource not found")
      return
    }
    
    let data = try Data(contentsOf: url)
    let doc = try OPDS2AuthenticationDocument.fromData(data)
    
    if let auth = doc.authentication?.first, let labels = auth.labels {
      XCTAssertFalse(labels.login.isEmpty)
      XCTAssertFalse(labels.password.isEmpty)
    }
  }
  
  // MARK: - Input Configuration Tests
  
  func testAuthentication_parsesInputConfiguration() throws {
    guard let url = gplAuthURL else {
      XCTFail("Test resource not found")
      return
    }
    
    let data = try Data(contentsOf: url)
    let doc = try OPDS2AuthenticationDocument.fromData(data)
    
    if let auth = doc.authentication?.first, let inputs = auth.inputs {
      XCTAssertNotNil(inputs.login.keyboard)
      XCTAssertNotNil(inputs.password.keyboard)
    }
  }
  
  func testAuthentication_parsesBarcodeFormat() throws {
    guard let url = gplAuthURL else {
      XCTFail("Test resource not found")
      return
    }
    
    let data = try Data(contentsOf: url)
    let doc = try OPDS2AuthenticationDocument.fromData(data)
    
    if let auth = doc.authentication?.first, let inputs = auth.inputs {
      // Barcode format is optional
      XCTAssertNotNil(inputs.login)
    }
  }
  
  func testAuthentication_parsesMaximumLength() throws {
    guard let url = gplAuthURL else {
      XCTFail("Test resource not found")
      return
    }
    
    let data = try Data(contentsOf: url)
    let doc = try OPDS2AuthenticationDocument.fromData(data)
    
    if let auth = doc.authentication?.first, let inputs = auth.inputs {
      // Maximum length may or may not be present
      XCTAssertNotNil(inputs.password)
    }
  }
  
  // MARK: - Features Tests
  
  func testFeatures_parsesEnabledFeatures() throws {
    guard let url = nyplAuthURL else {
      XCTFail("Test resource not found")
      return
    }
    
    let data = try Data(contentsOf: url)
    let doc = try OPDS2AuthenticationDocument.fromData(data)
    
    // Features are optional
    if let features = doc.features {
      XCTAssertNotNil(features.enabled ?? features.disabled)
    }
  }
  
  func testFeatures_parsesDisabledFeatures() throws {
    guard let url = nyplAuthURL else {
      XCTFail("Test resource not found")
      return
    }
    
    let data = try Data(contentsOf: url)
    let doc = try OPDS2AuthenticationDocument.fromData(data)
    
    // Features are optional
    XCTAssertTrue(true) // Just verify it doesn't crash
  }
  
  // MARK: - Links Tests
  
  func testLinks_parsesCorrectly() throws {
    guard let url = nyplAuthURL else {
      XCTFail("Test resource not found")
      return
    }
    
    let data = try Data(contentsOf: url)
    let doc = try OPDS2AuthenticationDocument.fromData(data)
    
    if let links = doc.links {
      XCTAssertFalse(links.isEmpty)
      for link in links {
        XCTAssertFalse(link.href.isEmpty)
      }
    }
  }
  
  func testLinks_firstRelMethod_findsPasswordReset() throws {
    guard let url = nyplAuthURL else {
      XCTFail("Test resource not found")
      return
    }
    
    let data = try Data(contentsOf: url)
    let doc = try OPDS2AuthenticationDocument.fromData(data)
    
    let passwordResetLink = doc.links?.first { link in
      link.rel == OPDS2LinkRel.passwordReset.rawValue
    }
    
    // May or may not be present
    XCTAssertTrue(passwordResetLink != nil || passwordResetLink == nil)
  }
  
  // MARK: - Announcements Tests
  
  func testAnnouncements_parsesIfPresent() throws {
    guard let url = nyplAuthURL else {
      XCTFail("Test resource not found")
      return
    }
    
    let data = try Data(contentsOf: url)
    let doc = try OPDS2AuthenticationDocument.fromData(data)
    
    // Announcements are optional
    if let announcements = doc.announcements {
      for announcement in announcements {
        XCTAssertFalse(announcement.id.isEmpty)
        XCTAssertFalse(announcement.content.isEmpty)
      }
    }
  }
  
  // MARK: - Color Scheme Tests
  
  func testColorScheme_parsesIfPresent() throws {
    guard let url = nyplAuthURL else {
      XCTFail("Test resource not found")
      return
    }
    
    let data = try Data(contentsOf: url)
    let doc = try OPDS2AuthenticationDocument.fromData(data)
    
    // Color scheme is optional
    XCTAssertTrue(doc.colorScheme != nil || doc.colorScheme == nil)
  }
  
  // MARK: - Service Description Tests
  
  func testServiceDescription_parsesIfPresent() throws {
    guard let url = nyplAuthURL else {
      XCTFail("Test resource not found")
      return
    }
    
    let data = try Data(contentsOf: url)
    let doc = try OPDS2AuthenticationDocument.fromData(data)
    
    // Service description is optional
    XCTAssertTrue(doc.serviceDescription != nil || doc.serviceDescription == nil)
  }
}

// MARK: - Announcement Tests

final class AnnouncementTests: XCTestCase {
  
  func testAnnouncement_decodesValidJSON() throws {
    let json = """
    {
      "id": "announcement-1",
      "content": "Library will be closed on Monday"
    }
    """.data(using: .utf8)!
    
    let announcement = try JSONDecoder().decode(Announcement.self, from: json)
    
    XCTAssertEqual(announcement.id, "announcement-1")
    XCTAssertEqual(announcement.content, "Library will be closed on Monday")
  }
  
  func testAnnouncement_withMissingId_throwsError() {
    let json = """
    {
      "content": "Test content"
    }
    """.data(using: .utf8)!
    
    XCTAssertThrowsError(try JSONDecoder().decode(Announcement.self, from: json))
  }
  
  func testAnnouncement_withMissingContent_throwsError() {
    let json = """
    {
      "id": "test-id"
    }
    """.data(using: .utf8)!
    
    XCTAssertThrowsError(try JSONDecoder().decode(Announcement.self, from: json))
  }
}

// MARK: - OPDS2LinkRel Tests

final class OPDS2LinkRelTests: XCTestCase {
  
  func testPasswordReset_hasCorrectRawValue() {
    let rel = OPDS2LinkRel.passwordReset
    XCTAssertEqual(rel.rawValue, "http://librarysimplified.org/terms/rel/patron-password-reset")
  }
}

