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

// MARK: - Cross-Domain 401 Tests

/// Tests for cross-domain redirect 401 handling
/// When a request is redirected to a different domain and returns 401,
/// we should NOT mark credentials as stale since the 401 is from a third-party.
final class CrossDomain401Tests: XCTestCase {
  
  private let palaceURL = URL(string: "https://gorgon.palaceproject.io/library/book")!
  private let thirdPartyURL = URL(string: "https://library.biblioboard.com/content/book.epub")!
  private let palaceCDNURL = URL(string: "https://cdn.palaceproject.io/content/book.epub")!
  
  // MARK: - Same Domain Tests (should indicate auth refresh needed)
  
  func test401FromSameDomain_shouldIndicateAuthRefreshNeeded() {
    // Response from same domain as original request
    let response = HTTPURLResponse(
      url: palaceURL,
      statusCode: 401,
      httpVersion: nil,
      headerFields: nil
    )!
    
    // When 401 is from the same domain, credentials ARE likely expired
    XCTAssertTrue(
      response.indicatesAuthenticationNeedsRefresh(with: nil, originalRequestURL: palaceURL),
      "401 from same domain should indicate auth refresh needed"
    )
  }
  
  func test401FromSameSubdomain_shouldIndicateAuthRefreshNeeded() {
    // Original request to gorgon.palaceproject.io, response from same
    let originalURL = URL(string: "https://gorgon.palaceproject.io/library/loans")!
    let response = HTTPURLResponse(
      url: originalURL,
      statusCode: 401,
      httpVersion: nil,
      headerFields: nil
    )!
    
    XCTAssertTrue(
      response.indicatesAuthenticationNeedsRefresh(with: nil, originalRequestURL: originalURL),
      "401 from same subdomain should indicate auth refresh needed"
    )
  }
  
  // MARK: - Cross-Domain Tests (should NOT indicate auth refresh needed)
  
  func test401FromDifferentDomain_shouldNotIndicateAuthRefreshNeeded() {
    // Original request to palaceproject.io, but response from biblioboard.com
    let response = HTTPURLResponse(
      url: thirdPartyURL,
      statusCode: 401,
      httpVersion: nil,
      headerFields: nil
    )!
    
    // When 401 is from a DIFFERENT domain, our credentials are NOT the issue
    XCTAssertFalse(
      response.indicatesAuthenticationNeedsRefresh(with: nil, originalRequestURL: palaceURL),
      "401 from different domain should NOT indicate auth refresh needed"
    )
  }
  
  func test401FromDifferentSubdomain_shouldIndicateAuthRefreshNeeded() {
    // Original request to gorgon.palaceproject.io, response from cdn.palaceproject.io
    // Same base domain (palaceproject.io) - should still indicate refresh needed
    let response = HTTPURLResponse(
      url: palaceCDNURL,
      statusCode: 401,
      httpVersion: nil,
      headerFields: nil
    )!
    
    XCTAssertTrue(
      response.indicatesAuthenticationNeedsRefresh(with: nil, originalRequestURL: palaceURL),
      "401 from same base domain (different subdomain) should indicate auth refresh needed"
    )
  }
  
  func testProblemDocFromDifferentDomain_shouldNotIndicateAuthRefreshNeeded() {
    // Problem document from third-party domain should not trigger re-auth
    let response = HTTPURLResponse(
      url: thirdPartyURL,
      statusCode: 401,
      httpVersion: nil,
      headerFields: ["Content-Type": "application/problem+json"]
    )!
    
    let problemDoc = TPPProblemDocument.forExpiredOrMissingCredentials(hasCredentials: true)
    
    XCTAssertFalse(
      response.indicatesAuthenticationNeedsRefresh(with: problemDoc, originalRequestURL: palaceURL),
      "Problem document from different domain should NOT indicate auth refresh needed"
    )
  }
  
  // MARK: - Nil Original URL Tests (backward compatibility)
  
  func test401WithNilOriginalURL_shouldIndicateAuthRefreshNeeded() {
    // When original URL is nil (legacy code path), fall back to old behavior
    let response = HTTPURLResponse(
      url: palaceURL,
      statusCode: 401,
      httpVersion: nil,
      headerFields: nil
    )!
    
    XCTAssertTrue(
      response.indicatesAuthenticationNeedsRefresh(with: nil, originalRequestURL: nil),
      "401 with nil original URL should indicate auth refresh (backward compatible)"
    )
  }
  
  // MARK: - Non-401 Cross-Domain Tests
  
  func test403FromDifferentDomain_shouldNotIndicateAuthRefreshNeeded() {
    // 403 from any domain should not indicate auth refresh
    let response = HTTPURLResponse(
      url: thirdPartyURL,
      statusCode: 403,
      httpVersion: nil,
      headerFields: nil
    )!
    
    XCTAssertFalse(
      response.indicatesAuthenticationNeedsRefresh(with: nil, originalRequestURL: palaceURL),
      "403 should not indicate auth refresh needed"
    )
  }
  
  func test200FromDifferentDomain_shouldNotIndicateAuthRefreshNeeded() {
    // Success response should not indicate auth refresh
    let response = HTTPURLResponse(
      url: thirdPartyURL,
      statusCode: 200,
      httpVersion: nil,
      headerFields: nil
    )!
    
    XCTAssertFalse(
      response.indicatesAuthenticationNeedsRefresh(with: nil, originalRequestURL: palaceURL),
      "200 should not indicate auth refresh needed"
    )
  }
}

// MARK: - Recoverable/Unrecoverable Auth Error Tests

/// Tests for the new problem document category system (PR #3003).
/// Server uses URL path conventions to classify auth errors:
/// - /auth/recoverable/* -> client should re-authenticate
/// - /auth/unrecoverable/* -> client should display error to user
final class AuthErrorCategoryTests: XCTestCase {
  
  private let testURL = URL(string: "https://example.com/api")!
  
  // MARK: - TPPProblemDocument Category Detection
  
  func testProblemDocument_recoverableTokenExpired_isRecoverable() {
    let problemDoc = TPPProblemDocument.fromDictionary([
      "type": "http://palaceproject.io/terms/problem/auth/recoverable/token/expired",
      "title": "Access token expired",
      "status": 401
    ])
    
    XCTAssertTrue(problemDoc.isRecoverableAuthError)
    XCTAssertFalse(problemDoc.isUnrecoverableAuthError)
  }
  
  func testProblemDocument_recoverableSAMLSessionExpired_isRecoverable() {
    let problemDoc = TPPProblemDocument.fromDictionary([
      "type": "http://palaceproject.io/terms/problem/auth/recoverable/saml/session-expired",
      "title": "SAML session expired",
      "status": 401
    ])
    
    XCTAssertTrue(problemDoc.isRecoverableAuthError)
    XCTAssertFalse(problemDoc.isUnrecoverableAuthError)
  }
  
  func testProblemDocument_recoverableSAMLBearerTokenInvalid_isRecoverable() {
    let problemDoc = TPPProblemDocument.fromDictionary([
      "type": "http://palaceproject.io/terms/problem/auth/recoverable/saml/bearer-token-invalid",
      "title": "Invalid SAML bearer token",
      "status": 401
    ])
    
    XCTAssertTrue(problemDoc.isRecoverableAuthError)
    XCTAssertFalse(problemDoc.isUnrecoverableAuthError)
  }
  
  func testProblemDocument_unrecoverableInvalidCredentials_isUnrecoverable() {
    let problemDoc = TPPProblemDocument.fromDictionary([
      "type": "http://palaceproject.io/terms/problem/auth/unrecoverable/credentials/invalid",
      "title": "Invalid credentials",
      "status": 401
    ])
    
    XCTAssertFalse(problemDoc.isRecoverableAuthError)
    XCTAssertTrue(problemDoc.isUnrecoverableAuthError)
  }
  
  func testProblemDocument_unrecoverableNoAccess_isUnrecoverable() {
    let problemDoc = TPPProblemDocument.fromDictionary([
      "type": "http://palaceproject.io/terms/problem/auth/unrecoverable/saml/no-access",
      "title": "No access",
      "status": 401
    ])
    
    XCTAssertFalse(problemDoc.isRecoverableAuthError)
    XCTAssertTrue(problemDoc.isUnrecoverableAuthError)
  }
  
  func testProblemDocument_nonAuthType_isNeitherCategory() {
    let problemDoc = TPPProblemDocument.fromDictionary([
      "type": "http://librarysimplified.org/terms/problem/loan-limit-reached",
      "title": "Loan limit reached",
      "status": 403
    ])
    
    XCTAssertFalse(problemDoc.isRecoverableAuthError)
    XCTAssertFalse(problemDoc.isUnrecoverableAuthError)
  }
  
  func testProblemDocument_nilType_isNeitherCategory() {
    let problemDoc = TPPProblemDocument.fromDictionary([
      "title": "Some error",
      "status": 500
    ])
    
    XCTAssertFalse(problemDoc.isRecoverableAuthError)
    XCTAssertFalse(problemDoc.isUnrecoverableAuthError)
  }
  
  // MARK: - Authentication Refresh Detection with Categories
  
  func testHTTPURLResponse_withRecoverableError_shouldIndicateAuthRefresh() {
    let response = HTTPURLResponse(
      url: testURL,
      statusCode: 401,
      httpVersion: nil,
      headerFields: nil
    )!
    
    let problemDoc = TPPProblemDocument.fromDictionary([
      "type": "http://palaceproject.io/terms/problem/auth/recoverable/token/expired",
      "title": "Access token expired"
    ])
    
    XCTAssertTrue(
      response.indicatesAuthenticationNeedsRefresh(with: problemDoc),
      "Recoverable auth error should indicate auth refresh needed"
    )
  }
  
  func testHTTPURLResponse_withUnrecoverableError_shouldNotIndicateAuthRefresh() {
    let response = HTTPURLResponse(
      url: testURL,
      statusCode: 401,
      httpVersion: nil,
      headerFields: nil
    )!
    
    let problemDoc = TPPProblemDocument.fromDictionary([
      "type": "http://palaceproject.io/terms/problem/auth/unrecoverable/credentials/invalid",
      "title": "Invalid credentials"
    ])
    
    XCTAssertFalse(
      response.indicatesAuthenticationNeedsRefresh(with: problemDoc),
      "Unrecoverable auth error should NOT indicate auth refresh needed"
    )
  }
  
  func testHTTPURLResponse_withUnrecoverableNoAccess_shouldNotIndicateAuthRefresh() {
    let response = HTTPURLResponse(
      url: testURL,
      statusCode: 401,
      httpVersion: nil,
      headerFields: nil
    )!
    
    let problemDoc = TPPProblemDocument.fromDictionary([
      "type": "http://palaceproject.io/terms/problem/auth/unrecoverable/saml/no-access",
      "title": "No access",
      "detail": "Patron does not have access based on their attributes."
    ])
    
    XCTAssertFalse(
      response.indicatesAuthenticationNeedsRefresh(with: problemDoc),
      "Unrecoverable no-access error should NOT indicate auth refresh needed"
    )
  }
  
  // MARK: - Backward Compatibility Tests
  
  func testHTTPURLResponse_withOldCredentialsInvalidType_shouldIndicateAuthRefresh() {
    // Old servers may still use the legacy credentials-invalid type
    let response = HTTPURLResponse(
      url: testURL,
      statusCode: 401,
      httpVersion: nil,
      headerFields: ["Content-Type": "application/problem+json"]
    )!
    
    let problemDoc = TPPProblemDocument.forExpiredOrMissingCredentials(hasCredentials: true)
    
    XCTAssertTrue(
      response.indicatesAuthenticationNeedsRefresh(with: problemDoc),
      "Old credentials-invalid type should still indicate auth refresh (backward compatibility)"
    )
  }
  
  func testHTTPURLResponse_bare401WithoutProblemDoc_shouldIndicateAuthRefresh() {
    // Bare 401 without problem document (older servers or edge cases)
    let response = HTTPURLResponse(
      url: testURL,
      statusCode: 401,
      httpVersion: nil,
      headerFields: nil
    )!
    
    XCTAssertTrue(
      response.indicatesAuthenticationNeedsRefresh(with: nil),
      "Bare 401 without problem doc should indicate auth refresh (fallback)"
    )
  }
}