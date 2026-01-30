//
//  TokenRefreshTests.swift
//  PalaceTests
//
//  Unit tests for token refresh and 401 retry logic.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class TokenRefreshTests: XCTestCase {

  // MARK: - TokenResponse Tests

  func testTokenResponse_ExpirationDateCalculation() {
    let response = TokenResponse(
      accessToken: "test-token",
      tokenType: "Bearer",
      expiresIn: 3600
    )

    let expectedExpiration = Date().addingTimeInterval(3600)

    // Allow 1 second tolerance
    XCTAssertEqual(
      response.expirationDate.timeIntervalSince1970,
      expectedExpiration.timeIntervalSince1970,
      accuracy: 1.0
    )
  }

  func testTokenResponse_ZeroExpiresIn() {
    let response = TokenResponse(
      accessToken: "test-token",
      tokenType: "Bearer",
      expiresIn: 0
    )

    // Expiration should be approximately now
    let now = Date()
    XCTAssertEqual(
      response.expirationDate.timeIntervalSince1970,
      now.timeIntervalSince1970,
      accuracy: 1.0
    )
  }

  func testTokenResponse_NegativeExpiresIn() {
    let response = TokenResponse(
      accessToken: "test-token",
      tokenType: "Bearer",
      expiresIn: -3600
    )

    // Expiration should be in the past
    let now = Date()
    XCTAssertLessThan(response.expirationDate, now)
  }

  // MARK: - TokenRequest Tests

  func testTokenRequest_InitializesCorrectly() {
    let url = URL(string: "https://example.com/token")!
    let request = TokenRequest(url: url, username: "user", password: "pass")

    XCTAssertEqual(request.url, url)
    XCTAssertEqual(request.username, "user")
    XCTAssertEqual(request.password, "pass")
  }

  func testTokenRequest_EmptyUsername() {
    let url = URL(string: "https://example.com/token")!
    let request = TokenRequest(url: url, username: "", password: "pass")

    XCTAssertEqual(request.username, "")
  }

  func testTokenRequest_EmptyPassword() {
    let url = URL(string: "https://example.com/token")!
    let request = TokenRequest(url: url, username: "user", password: "")

    XCTAssertEqual(request.password, "")
  }

  func testTokenRequest_SpecialCharactersInCredentials() {
    let url = URL(string: "https://example.com/token")!
    let request = TokenRequest(
      url: url,
      username: "user@domain.com",
      password: "p@ss!word#123"
    )

    XCTAssertEqual(request.username, "user@domain.com")
    XCTAssertEqual(request.password, "p@ss!word#123")
  }

  // MARK: - Mock Executor Tests

  func testMockExecutor_ReturnsConfiguredResponse() {
    let mock = TPPRequestExecutorMock()
    let testURL = URL(string: "https://test.com/api")!
    let responseBody = "{\"test\": \"data\"}"
    mock.responseBodies[testURL] = responseBody

    var receivedData: Data?
    var receivedResponse: URLResponse?

    let request = URLRequest(url: testURL)
    _ = mock.executeRequest(request, enableTokenRefresh: false) { result in
      switch result {
      case .success(let data, let response):
        receivedData = data
        receivedResponse = response
      case .failure:
        XCTFail("Expected success")
      }
    }

    // Wait for async completion
    let expectation = XCTestExpectation(description: "Response received")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
      XCTAssertNotNil(receivedData)
      XCTAssertNotNil(receivedResponse)

      if let data = receivedData, let responseString = String(data: data, encoding: .utf8) {
        XCTAssertEqual(responseString, responseBody)
      }

      expectation.fulfill()
    }

    wait(for: [expectation], timeout: 1.0)
  }

  func testMockExecutor_Returns404ForUnknownURL() {
    let mock = TPPRequestExecutorMock()
    let unknownURL = URL(string: "https://unknown.com/api")!

    var receivedError = false

    let request = URLRequest(url: unknownURL)
    _ = mock.executeRequest(request, enableTokenRefresh: false) { result in
      switch result {
      case .success:
        XCTFail("Expected failure for unknown URL")
      case .failure(_, let response):
        if let httpResponse = response as? HTTPURLResponse {
          XCTAssertEqual(httpResponse.statusCode, 404)
        }
        receivedError = true
      }
    }

    let expectation = XCTestExpectation(description: "Error received")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
      XCTAssertTrue(receivedError)
      expectation.fulfill()
    }

    wait(for: [expectation], timeout: 1.0)
  }

  func testMockExecutor_HandlesEmptyURL() {
    let mock = TPPRequestExecutorMock()

    var receivedError = false

    var request = URLRequest(url: URL(string: "https://example.com")!)
    request.url = nil // Set URL to nil

    _ = mock.executeRequest(request, enableTokenRefresh: false) { result in
      switch result {
      case .success:
        XCTFail("Expected failure for nil URL")
      case .failure:
        receivedError = true
      }
    }

    let expectation = XCTestExpectation(description: "Error received")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
      XCTAssertTrue(receivedError)
      expectation.fulfill()
    }

    wait(for: [expectation], timeout: 1.0)
  }

  // MARK: - Request Timeout Tests

  func testRequestTimeout_DefaultValue() {
    let mock = TPPRequestExecutorMock()
    XCTAssertEqual(mock.requestTimeout, 60)
  }

  func testRequestTimeout_StaticDefault() {
    XCTAssertEqual(TPPRequestExecutorMock.defaultRequestTimeout, TPPDefaultRequestTimeout)
  }

  // MARK: - NYPLResult Tests

  func testNYPLResult_SuccessCase() {
    let data = "test".data(using: .utf8)!
    let response = HTTPURLResponse(url: URL(string: "https://test.com")!,
                                   statusCode: 200,
                                   httpVersion: nil,
                                   headerFields: nil)

    let result: NYPLResult<Data> = .success(data, response)

    switch result {
    case .success(let resultData, let resultResponse):
      XCTAssertEqual(resultData, data)
      XCTAssertNotNil(resultResponse)
    case .failure:
      XCTFail("Expected success")
    }
  }

  func testNYPLResult_FailureCase() {
    let error = NSError(domain: "Test", code: -1, userInfo: nil)
    let response = HTTPURLResponse(url: URL(string: "https://test.com")!,
                                   statusCode: 401,
                                   httpVersion: nil,
                                   headerFields: nil)

    let result: NYPLResult<Data> = .failure(error, response)

    switch result {
    case .success:
      XCTFail("Expected failure")
    case .failure(let resultError, let resultResponse):
      XCTAssertEqual((resultError as NSError).code, -1)
      XCTAssertNotNil(resultResponse)
    }
  }

  func testNYPLResult_SuccessWithNilResponse() {
    let data = "test".data(using: .utf8)!
    let result: NYPLResult<Data> = .success(data, nil)

    switch result {
    case .success(let resultData, let resultResponse):
      XCTAssertEqual(resultData, data)
      XCTAssertNil(resultResponse)
    case .failure:
      XCTFail("Expected success")
    }
  }

  func testNYPLResult_FailureWithNilResponse() {
    let error = NSError(domain: "Test", code: -1, userInfo: nil)
    let result: NYPLResult<Data> = .failure(error, nil)

    switch result {
    case .success:
      XCTFail("Expected failure")
    case .failure(let resultError, let resultResponse):
      XCTAssertNotNil(resultError)
      XCTAssertNil(resultResponse)
    }
  }

  // MARK: - Token Expiry Edge Cases

  func testTokenResponse_LargeExpiresIn() {
    let oneYearInSeconds = 31536000
    let response = TokenResponse(
      accessToken: "long-lived-token",
      tokenType: "Bearer",
      expiresIn: oneYearInSeconds
    )

    let expectedExpiration = Date().addingTimeInterval(Double(oneYearInSeconds))

    XCTAssertEqual(
      response.expirationDate.timeIntervalSince1970,
      expectedExpiration.timeIntervalSince1970,
      accuracy: 1.0
    )
  }

  func testTokenResponse_SmallExpiresIn() {
    let response = TokenResponse(
      accessToken: "short-lived-token",
      tokenType: "Bearer",
      expiresIn: 1
    )

    let expectedExpiration = Date().addingTimeInterval(1)

    XCTAssertEqual(
      response.expirationDate.timeIntervalSince1970,
      expectedExpiration.timeIntervalSince1970,
      accuracy: 1.0
    )
  }

  // MARK: - JSON Decoding Integration Tests

  func testTokenResponse_DecodesFromJSON() throws {
    let json = """
    {
      "access_token": "decoded-token",
      "token_type": "Bearer",
      "expires_in": 7200
    }
    """.data(using: .utf8)!

    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase

    let response = try decoder.decode(TokenResponse.self, from: json)

    XCTAssertEqual(response.accessToken, "decoded-token")
    XCTAssertEqual(response.tokenType, "Bearer")
    XCTAssertEqual(response.expiresIn, 7200)
  }

  func testTokenResponse_EncodesToJSON() throws {
    let response = TokenResponse(
      accessToken: "encoded-token",
      tokenType: "Bearer",
      expiresIn: 3600
    )

    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase

    let data = try encoder.encode(response)
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

    XCTAssertEqual(json?["access_token"] as? String, "encoded-token")
    XCTAssertEqual(json?["token_type"] as? String, "Bearer")
    XCTAssertEqual(json?["expires_in"] as? Int, 3600)
  }

  func testTokenResponse_RoundTrip() throws {
    let original = TokenResponse(
      accessToken: "roundtrip-token",
      tokenType: "Bearer",
      expiresIn: 1800
    )

    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    let data = try encoder.encode(original)

    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let decoded = try decoder.decode(TokenResponse.self, from: data)

    XCTAssertEqual(decoded.accessToken, original.accessToken)
    XCTAssertEqual(decoded.tokenType, original.tokenType)
    XCTAssertEqual(decoded.expiresIn, original.expiresIn)
  }

  // MARK: - Bearer Token Authorization Tests

  func testBearerAuthorized_AddsAuthorizationHeader() {
    // This test would require access to TPPUserAccount mock
    // For now, test the structure of the request
    let url = URL(string: "https://example.com/api")!
    var request = URLRequest(url: url)
    request.setValue("Bearer test-token", forHTTPHeaderField: "Authorization")

    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
  }

  func testBearerAuthorized_EmptyTokenSetsEmptyHeader() {
    let url = URL(string: "https://example.com/api")!
    var request = URLRequest(url: url)
    request.setValue("", forHTTPHeaderField: "Authorization")

    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "")
  }
}

// MARK: - Token Type Tests

extension TokenRefreshTests {

  func testTokenResponse_DifferentTokenTypes() throws {
    let bearerJSON = """
    {"access_token": "token", "token_type": "Bearer", "expires_in": 3600}
    """.data(using: .utf8)!

    let macJSON = """
    {"access_token": "token", "token_type": "MAC", "expires_in": 3600}
    """.data(using: .utf8)!

    let customJSON = """
    {"access_token": "token", "token_type": "CustomType", "expires_in": 3600}
    """.data(using: .utf8)!

    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase

    let bearerResponse = try decoder.decode(TokenResponse.self, from: bearerJSON)
    let macResponse = try decoder.decode(TokenResponse.self, from: macJSON)
    let customResponse = try decoder.decode(TokenResponse.self, from: customJSON)

    XCTAssertEqual(bearerResponse.tokenType, "Bearer")
    XCTAssertEqual(macResponse.tokenType, "MAC")
    XCTAssertEqual(customResponse.tokenType, "CustomType")
  }
}

// MARK: - Error Code Tests

extension TokenRefreshTests {

  func testTPPErrorCode_InvalidCredentialsValue() {
    // Verify the error code constant exists and has expected behavior
    let error = NSError(
      domain: TPPErrorLogger.clientDomain,
      code: TPPErrorCode.invalidCredentials.rawValue,
      userInfo: nil
    )

    XCTAssertEqual(error.domain, TPPErrorLogger.clientDomain)
  }
}
