//
//  TPPBasicAuthTests.swift
//  PalaceTests
//
//  Tests for basic authentication handling
//

import XCTest
@testable import Palace

final class TPPBasicAuthTests: XCTestCase {
  
  // MARK: - Properties
  
  private var basicAuth: TPPBasicAuth!
  private var credentialsProvider: MockCredentialsProvider!
  
  // MARK: - Setup/Teardown
  
  override func setUpWithError() throws {
    try super.setUpWithError()
    credentialsProvider = MockCredentialsProvider()
    basicAuth = TPPBasicAuth(credentialsProvider: credentialsProvider)
  }
  
  override func tearDownWithError() throws {
    basicAuth = nil
    credentialsProvider = nil
    try super.tearDownWithError()
  }
  
  // MARK: - Initialization Tests
  
  func testInit_createsInstance() {
    XCTAssertNotNil(basicAuth)
  }
  
  // MARK: - HTTP Basic Auth Challenge Tests
  
  func testHandleChallenge_basicAuth_withValidCredentials_usesCredential() {
    credentialsProvider.username = "testuser"
    credentialsProvider.pin = "testpin"
    
    let challenge = createBasicAuthChallenge()
    var resultDisposition: URLSession.AuthChallengeDisposition?
    var resultCredential: URLCredential?
    
    basicAuth.handleChallenge(challenge) { disposition, credential in
      resultDisposition = disposition
      resultCredential = credential
    }
    
    XCTAssertEqual(resultDisposition, .useCredential)
    XCTAssertNotNil(resultCredential)
    XCTAssertEqual(resultCredential?.user, "testuser")
    XCTAssertEqual(resultCredential?.password, "testpin")
  }
  
  func testHandleChallenge_basicAuth_withNilUsername_cancelsChallenge() {
    credentialsProvider.username = nil
    credentialsProvider.pin = "testpin"
    
    let challenge = createBasicAuthChallenge()
    var resultDisposition: URLSession.AuthChallengeDisposition?
    var resultCredential: URLCredential?
    
    basicAuth.handleChallenge(challenge) { disposition, credential in
      resultDisposition = disposition
      resultCredential = credential
    }
    
    XCTAssertEqual(resultDisposition, .cancelAuthenticationChallenge)
    XCTAssertNil(resultCredential)
  }
  
  func testHandleChallenge_basicAuth_withNilPassword_cancelsChallenge() {
    credentialsProvider.username = "testuser"
    credentialsProvider.pin = nil
    
    let challenge = createBasicAuthChallenge()
    var resultDisposition: URLSession.AuthChallengeDisposition?
    var resultCredential: URLCredential?
    
    basicAuth.handleChallenge(challenge) { disposition, credential in
      resultDisposition = disposition
      resultCredential = credential
    }
    
    XCTAssertEqual(resultDisposition, .cancelAuthenticationChallenge)
    XCTAssertNil(resultCredential)
  }
  
  func testHandleChallenge_basicAuth_withEmptyCredentials_usesCredential() {
    credentialsProvider.username = ""
    credentialsProvider.pin = ""
    
    let challenge = createBasicAuthChallenge()
    var resultDisposition: URLSession.AuthChallengeDisposition?
    
    basicAuth.handleChallenge(challenge) { disposition, _ in
      resultDisposition = disposition
    }
    
    // Empty strings are valid credentials (though likely to fail)
    XCTAssertEqual(resultDisposition, .useCredential)
  }
  
  func testHandleChallenge_basicAuth_withPreviousFailure_cancelsChallenge() {
    credentialsProvider.username = "testuser"
    credentialsProvider.pin = "testpin"
    
    let challenge = createBasicAuthChallenge(previousFailureCount: 1)
    var resultDisposition: URLSession.AuthChallengeDisposition?
    
    basicAuth.handleChallenge(challenge) { disposition, _ in
      resultDisposition = disposition
    }
    
    XCTAssertEqual(resultDisposition, .cancelAuthenticationChallenge)
  }
  
  func testHandleChallenge_basicAuth_withMultipleFailures_cancelsChallenge() {
    credentialsProvider.username = "testuser"
    credentialsProvider.pin = "testpin"
    
    let challenge = createBasicAuthChallenge(previousFailureCount: 3)
    var resultDisposition: URLSession.AuthChallengeDisposition?
    
    basicAuth.handleChallenge(challenge) { disposition, _ in
      resultDisposition = disposition
    }
    
    XCTAssertEqual(resultDisposition, .cancelAuthenticationChallenge)
  }
  
  // MARK: - Server Trust Challenge Tests
  
  func testHandleChallenge_serverTrust_performsDefaultHandling() {
    credentialsProvider.username = "testuser"
    credentialsProvider.pin = "testpin"
    
    let challenge = createServerTrustChallenge()
    var resultDisposition: URLSession.AuthChallengeDisposition?
    var resultCredential: URLCredential?
    
    basicAuth.handleChallenge(challenge) { disposition, credential in
      resultDisposition = disposition
      resultCredential = credential
    }
    
    XCTAssertEqual(resultDisposition, .performDefaultHandling)
    XCTAssertNil(resultCredential)
  }
  
  // MARK: - Other Auth Method Tests
  
  func testHandleChallenge_unknownMethod_rejectsProtectionSpace() {
    credentialsProvider.username = "testuser"
    credentialsProvider.pin = "testpin"
    
    let challenge = createChallenge(method: NSURLAuthenticationMethodHTTPDigest)
    var resultDisposition: URLSession.AuthChallengeDisposition?
    
    basicAuth.handleChallenge(challenge) { disposition, _ in
      resultDisposition = disposition
    }
    
    XCTAssertEqual(resultDisposition, .rejectProtectionSpace)
  }
  
  func testHandleChallenge_clientCertificate_rejectsProtectionSpace() {
    let challenge = createChallenge(method: NSURLAuthenticationMethodClientCertificate)
    var resultDisposition: URLSession.AuthChallengeDisposition?
    
    basicAuth.handleChallenge(challenge) { disposition, _ in
      resultDisposition = disposition
    }
    
    XCTAssertEqual(resultDisposition, .rejectProtectionSpace)
  }
  
  // MARK: - Credential Persistence Tests
  
  func testHandleChallenge_credentials_noPersistence() {
    credentialsProvider.username = "testuser"
    credentialsProvider.pin = "testpin"
    
    let challenge = createBasicAuthChallenge()
    var resultCredential: URLCredential?
    
    basicAuth.handleChallenge(challenge) { _, credential in
      resultCredential = credential
    }
    
    // Credentials should not be persisted permanently (forSession or none)
    XCTAssertNotNil(resultCredential)
    if let persistence = resultCredential?.persistence {
      XCTAssertTrue(
        persistence == .none || persistence == .forSession,
        "Credentials should not be permanently persisted"
      )
    }
  }
  
  // MARK: - Helper Methods
  
  private func createBasicAuthChallenge(previousFailureCount: Int = 0) -> URLAuthenticationChallenge {
    return createChallenge(
      method: NSURLAuthenticationMethodHTTPBasic,
      previousFailureCount: previousFailureCount
    )
  }
  
  private func createServerTrustChallenge() -> URLAuthenticationChallenge {
    return createChallenge(method: NSURLAuthenticationMethodServerTrust)
  }
  
  private func createChallenge(
    method: String,
    previousFailureCount: Int = 0
  ) -> URLAuthenticationChallenge {
    let protectionSpace = URLProtectionSpace(
      host: "example.com",
      port: 443,
      protocol: "https",
      realm: "Test Realm",
      authenticationMethod: method
    )
    
    return URLAuthenticationChallenge(
      protectionSpace: protectionSpace,
      proposedCredential: nil,
      previousFailureCount: previousFailureCount,
      failureResponse: nil,
      error: nil,
      sender: MockChallengeSender()
    )
  }
}

// MARK: - Mock Credentials Provider

final class MockCredentialsProvider: NSObject, NYPLBasicAuthCredentialsProvider {
  var username: String?
  var pin: String?
}

// MARK: - Mock Challenge Sender

final class MockChallengeSender: NSObject, URLAuthenticationChallengeSender {
  func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
  func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
  func cancel(_ challenge: URLAuthenticationChallenge) {}
  func performDefaultHandling(for challenge: URLAuthenticationChallenge) {}
  func rejectProtectionSpaceAndContinue(with challenge: URLAuthenticationChallenge) {}
}

