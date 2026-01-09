//
//  URLResponseAuthenticationTests.swift
//  PalaceTests
//
//  Tests for URLResponse+TPPAuthentication extension.
//

import XCTest
@testable import Palace

final class URLResponseAuthenticationTests: XCTestCase {
  
  private let testURL = URL(string: "https://example.com/api")!
  
  // MARK: - URLResponse Tests
  
  func testURLResponse_withInvalidCredentialsProblemDoc_returnsTrue() {
    let response = URLResponse(
      url: testURL,
      mimeType: "application/problem+json",
      expectedContentLength: 0,
      textEncodingName: nil
    )
    
    let problemDoc = TPPProblemDocument.forExpiredOrMissingCredentials(hasCredentials: true)
    
    XCTAssertTrue(response.indicatesAuthenticationNeedsRefresh(with: problemDoc))
  }
  
  func testURLResponse_withNilProblemDoc_returnsFalse() {
    let response = URLResponse(
      url: testURL,
      mimeType: "application/problem+json",
      expectedContentLength: 0,
      textEncodingName: nil
    )
    
    XCTAssertFalse(response.indicatesAuthenticationNeedsRefresh(with: nil))
  }
  
  func testURLResponse_withNonProblemMimeType_returnsFalse() {
    let response = URLResponse(
      url: testURL,
      mimeType: "application/json",
      expectedContentLength: 0,
      textEncodingName: nil
    )
    
    let problemDoc = TPPProblemDocument.forExpiredOrMissingCredentials(hasCredentials: true)
    
    XCTAssertFalse(response.indicatesAuthenticationNeedsRefresh(with: problemDoc))
  }
  
  // MARK: - HTTPURLResponse Tests
  
  func testHTTPURLResponse_with401StatusCode_returnsTrue() {
    let response = HTTPURLResponse(
      url: testURL,
      statusCode: 401,
      httpVersion: nil,
      headerFields: nil
    )!
    
    XCTAssertTrue(response.indicatesAuthenticationNeedsRefresh(with: nil))
  }
  
  func testHTTPURLResponse_with403StatusCode_returnsFalse() {
    let response = HTTPURLResponse(
      url: testURL,
      statusCode: 403,
      httpVersion: nil,
      headerFields: nil
    )!
    
    XCTAssertFalse(response.indicatesAuthenticationNeedsRefresh(with: nil))
  }
  
  func testHTTPURLResponse_with200StatusCode_returnsFalse() {
    let response = HTTPURLResponse(
      url: testURL,
      statusCode: 200,
      httpVersion: nil,
      headerFields: nil
    )!
    
    XCTAssertFalse(response.indicatesAuthenticationNeedsRefresh(with: nil))
  }
  
  func testHTTPURLResponse_withOPDSAuthMimeType_andNon2xxStatus_returnsTrue() {
    let response = HTTPURLResponse(
      url: testURL,
      statusCode: 400,
      httpVersion: nil,
      headerFields: ["Content-Type": "application/vnd.opds.authentication.v1.0+json"]
    )!
    
    XCTAssertTrue(response.indicatesAuthenticationNeedsRefresh(with: nil))
  }
  
  func testHTTPURLResponse_withOPDSAuthMimeType_and200Status_returnsFalse() {
    let response = HTTPURLResponse(
      url: testURL,
      statusCode: 200,
      httpVersion: nil,
      headerFields: ["Content-Type": "application/vnd.opds.authentication.v1.0+json"]
    )!
    
    XCTAssertFalse(response.indicatesAuthenticationNeedsRefresh(with: nil))
  }
  
  func testHTTPURLResponse_withInvalidCredentialsProblemDoc_returnsTrue() {
    let response = HTTPURLResponse(
      url: testURL,
      statusCode: 200,
      httpVersion: nil,
      headerFields: ["Content-Type": "application/problem+json"]
    )!
    
    let problemDoc = TPPProblemDocument.forExpiredOrMissingCredentials(hasCredentials: true)
    
    XCTAssertTrue(response.indicatesAuthenticationNeedsRefresh(with: problemDoc))
  }
  
  func testHTTPURLResponse_withApiProblemMimeType_andInvalidCredentials_returnsTrue() {
    let response = HTTPURLResponse(
      url: testURL,
      statusCode: 400,
      httpVersion: nil,
      headerFields: ["Content-Type": "application/api-problem+json"]
    )!
    
    let problemDoc = TPPProblemDocument.forExpiredOrMissingCredentials(hasCredentials: true)
    
    XCTAssertTrue(response.indicatesAuthenticationNeedsRefresh(with: problemDoc))
  }
}

