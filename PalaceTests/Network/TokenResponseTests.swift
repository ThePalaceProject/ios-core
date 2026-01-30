//
//  TokenResponseTests.swift
//  PalaceTests
//
//  Unit tests for TokenResponse parsing and expiration calculation.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class TokenResponseTests: XCTestCase {

  // MARK: - Initialization Tests

  func testInit_WithValidParameters_StoresValues() {
    let response = TokenResponse(
      accessToken: "test-token-123",
      tokenType: "Bearer",
      expiresIn: 3600
    )

    XCTAssertEqual(response.accessToken, "test-token-123")
    XCTAssertEqual(response.tokenType, "Bearer")
    XCTAssertEqual(response.expiresIn, 3600)
  }

  func testInit_WithEmptyToken_StoresEmptyString() {
    let response = TokenResponse(
      accessToken: "",
      tokenType: "Bearer",
      expiresIn: 3600
    )

    XCTAssertEqual(response.accessToken, "")
  }

  func testInit_WithZeroExpiresIn_StoresZero() {
    let response = TokenResponse(
      accessToken: "token",
      tokenType: "Bearer",
      expiresIn: 0
    )

    XCTAssertEqual(response.expiresIn, 0)
  }

  func testInit_WithNegativeExpiresIn_StoresNegativeValue() {
    // Negative values should be stored (even if semantically invalid)
    let response = TokenResponse(
      accessToken: "token",
      tokenType: "Bearer",
      expiresIn: -100
    )

    XCTAssertEqual(response.expiresIn, -100)
  }

  // MARK: - Expiration Date Tests

  func testExpirationDate_WithPositiveExpiresIn_ReturnsDateInFuture() {
    let beforeCreation = Date()
    let response = TokenResponse(
      accessToken: "token",
      tokenType: "Bearer",
      expiresIn: 3600 // 1 hour
    )
    let afterCreation = Date()

    // Expiration date should be approximately 1 hour from now
    // Add small tolerance for test execution time
    let expectedMinimum = beforeCreation.addingTimeInterval(3600 - 1)
    let expectedMaximum = afterCreation.addingTimeInterval(3600 + 1)

    XCTAssertGreaterThanOrEqual(response.expirationDate, expectedMinimum)
    XCTAssertLessThanOrEqual(response.expirationDate, expectedMaximum)
  }

  func testExpirationDate_WithZeroExpiresIn_ReturnsCurrentTime() {
    let beforeCreation = Date()
    let response = TokenResponse(
      accessToken: "token",
      tokenType: "Bearer",
      expiresIn: 0
    )
    let afterCreation = Date()

    // Expiration date should be approximately now
    // Add small tolerance for test execution time
    XCTAssertGreaterThanOrEqual(response.expirationDate, beforeCreation.addingTimeInterval(-1))
    XCTAssertLessThanOrEqual(response.expirationDate, afterCreation.addingTimeInterval(1))
  }

  func testExpirationDate_WithNegativeExpiresIn_ReturnsDateInPast() {
    let now = Date()
    let response = TokenResponse(
      accessToken: "token",
      tokenType: "Bearer",
      expiresIn: -3600 // 1 hour ago
    )

    // Expiration date should be in the past
    XCTAssertLessThan(response.expirationDate, now)
  }

  func testExpirationDate_CalculatesCorrectInterval() {
    let response = TokenResponse(
      accessToken: "token",
      tokenType: "Bearer",
      expiresIn: 7200 // 2 hours
    )

    let expectedInterval: TimeInterval = 7200
    let actualInterval = response.expirationDate.timeIntervalSinceNow

    // Allow 1 second tolerance for test execution time
    XCTAssertEqual(actualInterval, expectedInterval, accuracy: 1.0)
  }

  // MARK: - JSON Decoding Tests

  func testDecode_WithValidJSON_ParsesCorrectly() throws {
    let json = """
    {
      "access_token": "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9",
      "token_type": "Bearer",
      "expires_in": 3600
    }
    """.data(using: .utf8)!

    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase

    let response = try decoder.decode(TokenResponse.self, from: json)

    XCTAssertEqual(response.accessToken, "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9")
    XCTAssertEqual(response.tokenType, "Bearer")
    XCTAssertEqual(response.expiresIn, 3600)
  }

  func testDecode_WithLargeExpiresIn_ParsesCorrectly() throws {
    let json = """
    {
      "access_token": "token",
      "token_type": "Bearer",
      "expires_in": 31536000
    }
    """.data(using: .utf8)!

    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase

    let response = try decoder.decode(TokenResponse.self, from: json)

    // 31536000 seconds = 1 year
    XCTAssertEqual(response.expiresIn, 31536000)
  }

  func testDecode_WithDifferentTokenType_ParsesCorrectly() throws {
    let json = """
    {
      "access_token": "token",
      "token_type": "MAC",
      "expires_in": 3600
    }
    """.data(using: .utf8)!

    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase

    let response = try decoder.decode(TokenResponse.self, from: json)

    XCTAssertEqual(response.tokenType, "MAC")
  }

  func testDecode_WithMissingAccessToken_ThrowsError() {
    let json = """
    {
      "token_type": "Bearer",
      "expires_in": 3600
    }
    """.data(using: .utf8)!

    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase

    XCTAssertThrowsError(try decoder.decode(TokenResponse.self, from: json))
  }

  func testDecode_WithMissingExpiresIn_ThrowsError() {
    let json = """
    {
      "access_token": "token",
      "token_type": "Bearer"
    }
    """.data(using: .utf8)!

    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase

    XCTAssertThrowsError(try decoder.decode(TokenResponse.self, from: json))
  }

  func testDecode_WithMissingTokenType_ThrowsError() {
    let json = """
    {
      "access_token": "token",
      "expires_in": 3600
    }
    """.data(using: .utf8)!

    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase

    XCTAssertThrowsError(try decoder.decode(TokenResponse.self, from: json))
  }

  func testDecode_WithExtraFields_IgnoresExtraFields() throws {
    let json = """
    {
      "access_token": "token",
      "token_type": "Bearer",
      "expires_in": 3600,
      "refresh_token": "refresh-token",
      "scope": "read write"
    }
    """.data(using: .utf8)!

    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase

    let response = try decoder.decode(TokenResponse.self, from: json)

    XCTAssertEqual(response.accessToken, "token")
    XCTAssertEqual(response.expiresIn, 3600)
  }

  func testDecode_WithWrongTypeForExpiresIn_ThrowsError() {
    let json = """
    {
      "access_token": "token",
      "token_type": "Bearer",
      "expires_in": "3600"
    }
    """.data(using: .utf8)!

    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase

    XCTAssertThrowsError(try decoder.decode(TokenResponse.self, from: json))
  }

  // MARK: - JSON Encoding Tests

  func testEncode_ProducesValidJSON() throws {
    let response = TokenResponse(
      accessToken: "test-token",
      tokenType: "Bearer",
      expiresIn: 3600
    )

    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase

    let data = try encoder.encode(response)
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

    XCTAssertEqual(json?["access_token"] as? String, "test-token")
    XCTAssertEqual(json?["token_type"] as? String, "Bearer")
    XCTAssertEqual(json?["expires_in"] as? Int, 3600)
  }

  func testEncodeDecode_RoundTrip_PreservesValues() throws {
    let original = TokenResponse(
      accessToken: "original-token-xyz",
      tokenType: "Bearer",
      expiresIn: 7200
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

  // MARK: - Edge Cases

  func testAccessToken_WithSpecialCharacters() throws {
    let json = """
    {
      "access_token": "token+with/special=chars&more!",
      "token_type": "Bearer",
      "expires_in": 3600
    }
    """.data(using: .utf8)!

    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase

    let response = try decoder.decode(TokenResponse.self, from: json)

    XCTAssertEqual(response.accessToken, "token+with/special=chars&more!")
  }

  func testAccessToken_WithUnicodeCharacters() throws {
    let json = """
    {
      "access_token": "token-\u{00e9}\u{00e8}\u{00ea}-unicode",
      "token_type": "Bearer",
      "expires_in": 3600
    }
    """.data(using: .utf8)!

    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase

    let response = try decoder.decode(TokenResponse.self, from: json)

    XCTAssertTrue(response.accessToken.contains("\u{00e9}")) // e with acute accent
  }

  func testExpiresIn_WithMaxInt32Value() throws {
    let json = """
    {
      "access_token": "token",
      "token_type": "Bearer",
      "expires_in": 2147483647
    }
    """.data(using: .utf8)!

    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase

    let response = try decoder.decode(TokenResponse.self, from: json)

    // 2147483647 is Int32.max, which should be preserved on 64-bit systems
    XCTAssertEqual(response.expiresIn, 2147483647)
  }
}
