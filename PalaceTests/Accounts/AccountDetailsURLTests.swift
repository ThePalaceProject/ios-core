//
//  AccountDetailsURLTests.swift
//  PalaceTests
//
//  Tests for AccountDetails URL management: setURL and getLicenseURL.
//  Covers QAAtlas high-priority gaps: getLicenseURL, setURL.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class AccountDetailsURLTests: XCTestCase {
  
  private var sut: AccountDetails!
  private let testUUID = "test-account-url-\(UUID().uuidString)"
  
  override func setUp() {
    super.setUp()
    // Clean any existing defaults for our test UUID
    UserDefaults.standard.removeObject(forKey: testUUID)
    sut = makeAccountDetails(uuid: testUUID)
  }
  
  override func tearDown() {
    UserDefaults.standard.removeObject(forKey: testUUID)
    sut = nil
    super.tearDown()
  }
  
  // MARK: - setURL Tests
  
  func testSetURL_ForEULA_StoresURL() {
    let url = URL(string: "https://example.com/eula")!
    sut.setURL(url, forLicense: .eula)
    
    let retrieved = sut.getLicenseURL(.eula)
    XCTAssertEqual(retrieved, url)
  }
  
  func testSetURL_ForPrivacyPolicy_StoresURL() {
    let url = URL(string: "https://example.com/privacy")!
    sut.setURL(url, forLicense: .privacyPolicy)
    
    let retrieved = sut.getLicenseURL(.privacyPolicy)
    XCTAssertEqual(retrieved, url)
  }
  
  func testSetURL_ForContentLicenses_StoresURL() {
    let url = URL(string: "https://example.com/licenses")!
    sut.setURL(url, forLicense: .contentLicenses)
    
    let retrieved = sut.getLicenseURL(.contentLicenses)
    XCTAssertEqual(retrieved, url)
  }
  
  func testSetURL_ForAcknowledgements_StoresURL() {
    let url = URL(string: "https://example.com/acknowledgements")!
    sut.setURL(url, forLicense: .acknowledgements)
    
    let retrieved = sut.getLicenseURL(.acknowledgements)
    XCTAssertEqual(retrieved, url)
  }
  
  func testSetURL_ForAnnotations_StoresURL() {
    let url = URL(string: "https://example.com/annotations")!
    sut.setURL(url, forLicense: .annotations)
    
    let retrieved = sut.getLicenseURL(.annotations)
    XCTAssertEqual(retrieved, url)
  }
  
  // MARK: - getLicenseURL Tests
  
  func testGetLicenseURL_WhenNotSet_ReturnsNil() {
    XCTAssertNil(sut.getLicenseURL(.eula))
    XCTAssertNil(sut.getLicenseURL(.privacyPolicy))
    XCTAssertNil(sut.getLicenseURL(.contentLicenses))
    XCTAssertNil(sut.getLicenseURL(.acknowledgements))
    XCTAssertNil(sut.getLicenseURL(.annotations))
  }
  
  func testGetLicenseURL_AfterSettingMultipleTypes_ReturnsCorrectURLs() {
    let eulaURL = URL(string: "https://example.com/eula")!
    let privacyURL = URL(string: "https://example.com/privacy")!
    let annotationsURL = URL(string: "https://example.com/annotations")!
    
    sut.setURL(eulaURL, forLicense: .eula)
    sut.setURL(privacyURL, forLicense: .privacyPolicy)
    sut.setURL(annotationsURL, forLicense: .annotations)
    
    XCTAssertEqual(sut.getLicenseURL(.eula), eulaURL)
    XCTAssertEqual(sut.getLicenseURL(.privacyPolicy), privacyURL)
    XCTAssertEqual(sut.getLicenseURL(.annotations), annotationsURL)
    XCTAssertNil(sut.getLicenseURL(.contentLicenses))
  }
  
  func testSetURL_OverwritesPreviousURL() {
    let url1 = URL(string: "https://example.com/old-eula")!
    let url2 = URL(string: "https://example.com/new-eula")!
    
    sut.setURL(url1, forLicense: .eula)
    XCTAssertEqual(sut.getLicenseURL(.eula), url1)
    
    sut.setURL(url2, forLicense: .eula)
    XCTAssertEqual(sut.getLicenseURL(.eula), url2)
  }
  
  func testSetURL_PersistsToUserDefaults() {
    let url = URL(string: "https://example.com/persisted")!
    sut.setURL(url, forLicense: .eula)
    
    // Verify UserDefaults was updated
    let savedDict = UserDefaults.standard.value(forKey: testUUID) as? [String: AnyObject]
    XCTAssertNotNil(savedDict)
    XCTAssertEqual(savedDict?["urlEULA"] as? String, "https://example.com/persisted")
  }
  
  // MARK: - AccountDetails Property Tests
  
  func testEulaIsAccepted_DefaultIsFalse() {
    XCTAssertFalse(sut.eulaIsAccepted)
  }
  
  func testEulaIsAccepted_CanBeSetToTrue() {
    sut.eulaIsAccepted = true
    XCTAssertTrue(sut.eulaIsAccepted)
  }
  
  func testSyncPermissionGranted_DefaultIsTrue() {
    XCTAssertTrue(sut.syncPermissionGranted)
  }
  
  func testSyncPermissionGranted_CanBeSetToFalse() {
    sut.syncPermissionGranted = false
    XCTAssertFalse(sut.syncPermissionGranted)
  }
  
  func testUserAboveAgeLimit_DefaultIsFalse() {
    XCTAssertFalse(sut.userAboveAgeLimit)
  }
  
  func testUserAboveAgeLimit_CanBeSetToTrue() {
    sut.userAboveAgeLimit = true
    XCTAssertTrue(sut.userAboveAgeLimit)
  }
  
  func testDebugDescription_ContainsSyncInfo() {
    XCTAssertTrue(sut.debugDescription.contains("supportsSimplyESync"))
    XCTAssertTrue(sut.debugDescription.contains("supportsReservations"))
  }
  
  // MARK: - AccountDetails defaultAuth Tests
  
  func testDefaultAuth_WithSingleAuth_ReturnsThatAuth() {
    XCTAssertNotNil(sut.auths.isEmpty == false ? sut.defaultAuth : nil)
  }
  
  // MARK: - Helpers
  
  private func makeAccountDetails(uuid: String) -> AccountDetails {
    // Create minimal auth document JSON and parse it
    let json: [String: Any] = [
      "id": uuid,
      "title": "Test Library",
      "authentication": [
        [
          "type": "http://opds-spec.org/auth/basic",
          "inputs": [
            "login": ["keyboard": "Default"],
            "password": ["keyboard": "Default", "maximum_length": 4]
          ],
          "labels": [
            "login": "Barcode",
            "password": "PIN"
          ]
        ]
      ],
      "features": ["enabled": [], "disabled": []]
    ]
    
    let data = try! JSONSerialization.data(withJSONObject: json)
    let doc = try! OPDS2AuthenticationDocument.fromData(data)
    return AccountDetails(authenticationDocument: doc, uuid: uuid)
  }
}
