//
//  TPPCredentialsTests.swift
//  PalaceTests
//
//  Unit tests for TPPCredentials encoding/decoding.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class TPPCredentialsTests: XCTestCase {

  // MARK: - Token Credential Tests

  func testToken_WithAllProperties_StoresValues() {
    let expirationDate = Date().addingTimeInterval(3600)
    let credentials = TPPCredentials.token(
      authToken: "test-token",
      barcode: "12345",
      pin: "1234",
      expirationDate: expirationDate
    )

    if case let .token(authToken, barcode, pin, date) = credentials {
      XCTAssertEqual(authToken, "test-token")
      XCTAssertEqual(barcode, "12345")
      XCTAssertEqual(pin, "1234")
      XCTAssertEqual(date?.timeIntervalSince1970 ?? 0, expirationDate.timeIntervalSince1970, accuracy: 1)
    } else {
      XCTFail("Expected token credentials")
    }
  }

  func testToken_WithOnlyAuthToken_StoresNilOptionals() {
    let credentials = TPPCredentials.token(authToken: "test-token")

    if case let .token(authToken, barcode, pin, date) = credentials {
      XCTAssertEqual(authToken, "test-token")
      XCTAssertNil(barcode)
      XCTAssertNil(pin)
      XCTAssertNil(date)
    } else {
      XCTFail("Expected token credentials")
    }
  }

  func testToken_WithEmptyAuthToken_StoresEmptyString() {
    let credentials = TPPCredentials.token(authToken: "")

    if case let .token(authToken, _, _, _) = credentials {
      XCTAssertEqual(authToken, "")
    } else {
      XCTFail("Expected token credentials")
    }
  }

  // MARK: - BarcodeAndPin Credential Tests

  func testBarcodeAndPin_WithValidData_StoresValues() {
    let credentials = TPPCredentials.barcodeAndPin(barcode: "123456789", pin: "5678")

    if case let .barcodeAndPin(barcode, pin) = credentials {
      XCTAssertEqual(barcode, "123456789")
      XCTAssertEqual(pin, "5678")
    } else {
      XCTFail("Expected barcodeAndPin credentials")
    }
  }

  func testBarcodeAndPin_WithEmptyValues_StoresEmptyStrings() {
    let credentials = TPPCredentials.barcodeAndPin(barcode: "", pin: "")

    if case let .barcodeAndPin(barcode, pin) = credentials {
      XCTAssertEqual(barcode, "")
      XCTAssertEqual(pin, "")
    } else {
      XCTFail("Expected barcodeAndPin credentials")
    }
  }

  func testBarcodeAndPin_WithSpecialCharacters_PreservesCharacters() {
    let credentials = TPPCredentials.barcodeAndPin(
      barcode: "abc-123+special",
      pin: "pin!@#$%"
    )

    if case let .barcodeAndPin(barcode, pin) = credentials {
      XCTAssertEqual(barcode, "abc-123+special")
      XCTAssertEqual(pin, "pin!@#$%")
    } else {
      XCTFail("Expected barcodeAndPin credentials")
    }
  }

  // MARK: - Cookies Credential Tests

  func testCookies_WithValidCookies_StoresCookies() {
    let properties: [HTTPCookiePropertyKey: Any] = [
      .name: "session",
      .value: "abc123",
      .domain: "example.com",
      .path: "/"
    ]
    guard let cookie = HTTPCookie(properties: properties) else {
      XCTFail("Failed to create test cookie")
      return
    }

    let credentials = TPPCredentials.cookies([cookie])

    if case let .cookies(cookies) = credentials {
      XCTAssertEqual(cookies.count, 1)
      XCTAssertEqual(cookies.first?.name, "session")
      XCTAssertEqual(cookies.first?.value, "abc123")
    } else {
      XCTFail("Expected cookies credentials")
    }
  }

  func testCookies_WithEmptyArray_StoresEmptyArray() {
    let credentials = TPPCredentials.cookies([])

    if case let .cookies(cookies) = credentials {
      XCTAssertTrue(cookies.isEmpty)
    } else {
      XCTFail("Expected cookies credentials")
    }
  }

  func testCookies_WithMultipleCookies_StoresAllCookies() {
    let props1: [HTTPCookiePropertyKey: Any] = [.name: "cookie1", .value: "value1", .domain: "example.com", .path: "/"]
    let props2: [HTTPCookiePropertyKey: Any] = [.name: "cookie2", .value: "value2", .domain: "example.com", .path: "/"]

    guard let cookie1 = HTTPCookie(properties: props1),
          let cookie2 = HTTPCookie(properties: props2) else {
      XCTFail("Failed to create test cookies")
      return
    }

    let credentials = TPPCredentials.cookies([cookie1, cookie2])

    if case let .cookies(cookies) = credentials {
      XCTAssertEqual(cookies.count, 2)
    } else {
      XCTFail("Expected cookies credentials")
    }
  }

  // MARK: - Token Encoding/Decoding Tests

  func testEncodeDecode_Token_WithAllProperties() throws {
    let expirationDate = Date().addingTimeInterval(3600)
    let original = TPPCredentials.token(
      authToken: "test-token-xyz",
      barcode: "barcode123",
      pin: "pin456",
      expirationDate: expirationDate
    )

    let encoder = JSONEncoder()
    let data = try encoder.encode(original)

    let decoder = JSONDecoder()
    let decoded = try decoder.decode(TPPCredentials.self, from: data)

    if case let .token(authToken, barcode, pin, date) = decoded {
      XCTAssertEqual(authToken, "test-token-xyz")
      XCTAssertEqual(barcode, "barcode123")
      XCTAssertEqual(pin, "pin456")
      XCTAssertEqual(date?.timeIntervalSince1970 ?? 0, expirationDate.timeIntervalSince1970, accuracy: 1)
    } else {
      XCTFail("Expected token credentials after decode")
    }
  }

  func testEncodeDecode_Token_WithNilOptionals() throws {
    let original = TPPCredentials.token(authToken: "only-token")

    let encoder = JSONEncoder()
    let data = try encoder.encode(original)

    let decoder = JSONDecoder()
    let decoded = try decoder.decode(TPPCredentials.self, from: data)

    if case let .token(authToken, barcode, pin, date) = decoded {
      XCTAssertEqual(authToken, "only-token")
      XCTAssertNil(barcode)
      XCTAssertNil(pin)
      XCTAssertNil(date)
    } else {
      XCTFail("Expected token credentials after decode")
    }
  }

  func testEncodeDecode_Token_WithEmptyAuthToken() throws {
    let original = TPPCredentials.token(authToken: "")

    let encoder = JSONEncoder()
    let data = try encoder.encode(original)

    let decoder = JSONDecoder()
    let decoded = try decoder.decode(TPPCredentials.self, from: data)

    if case let .token(authToken, _, _, _) = decoded {
      XCTAssertEqual(authToken, "")
    } else {
      XCTFail("Expected token credentials after decode")
    }
  }

  func testEncodeDecode_Token_WithSpecialCharacters() throws {
    let original = TPPCredentials.token(
      authToken: "token+with/special=chars&more!",
      barcode: "bar-code_123",
      pin: nil,
      expirationDate: nil
    )

    let encoder = JSONEncoder()
    let data = try encoder.encode(original)

    let decoder = JSONDecoder()
    let decoded = try decoder.decode(TPPCredentials.self, from: data)

    if case let .token(authToken, barcode, _, _) = decoded {
      XCTAssertEqual(authToken, "token+with/special=chars&more!")
      XCTAssertEqual(barcode, "bar-code_123")
    } else {
      XCTFail("Expected token credentials after decode")
    }
  }

  // MARK: - BarcodeAndPin Encoding/Decoding Tests

  func testEncodeDecode_BarcodeAndPin_PreservesValues() throws {
    let original = TPPCredentials.barcodeAndPin(barcode: "123456", pin: "7890")

    let encoder = JSONEncoder()
    let data = try encoder.encode(original)

    let decoder = JSONDecoder()
    let decoded = try decoder.decode(TPPCredentials.self, from: data)

    if case let .barcodeAndPin(barcode, pin) = decoded {
      XCTAssertEqual(barcode, "123456")
      XCTAssertEqual(pin, "7890")
    } else {
      XCTFail("Expected barcodeAndPin credentials after decode")
    }
  }

  func testEncodeDecode_BarcodeAndPin_WithEmptyStrings() throws {
    let original = TPPCredentials.barcodeAndPin(barcode: "", pin: "")

    let encoder = JSONEncoder()
    let data = try encoder.encode(original)

    let decoder = JSONDecoder()
    let decoded = try decoder.decode(TPPCredentials.self, from: data)

    if case let .barcodeAndPin(barcode, pin) = decoded {
      XCTAssertEqual(barcode, "")
      XCTAssertEqual(pin, "")
    } else {
      XCTFail("Expected barcodeAndPin credentials after decode")
    }
  }

  func testEncodeDecode_BarcodeAndPin_WithLongStrings() throws {
    let longBarcode = String(repeating: "1234567890", count: 100)
    let longPin = String(repeating: "abcd", count: 50)
    let original = TPPCredentials.barcodeAndPin(barcode: longBarcode, pin: longPin)

    let encoder = JSONEncoder()
    let data = try encoder.encode(original)

    let decoder = JSONDecoder()
    let decoded = try decoder.decode(TPPCredentials.self, from: data)

    if case let .barcodeAndPin(barcode, pin) = decoded {
      XCTAssertEqual(barcode, longBarcode)
      XCTAssertEqual(pin, longPin)
    } else {
      XCTFail("Expected barcodeAndPin credentials after decode")
    }
  }

  // MARK: - Cookies Encoding/Decoding Tests

  func testEncodeDecode_Cookies_WithValidCookies() throws {
    let properties: [HTTPCookiePropertyKey: Any] = [
      .name: "test-cookie",
      .value: "cookie-value",
      .domain: "example.com",
      .path: "/"
    ]
    guard let cookie = HTTPCookie(properties: properties) else {
      XCTFail("Failed to create test cookie")
      return
    }

    let original = TPPCredentials.cookies([cookie])

    let encoder = JSONEncoder()
    let data = try encoder.encode(original)

    let decoder = JSONDecoder()
    let decoded = try decoder.decode(TPPCredentials.self, from: data)

    if case let .cookies(cookies) = decoded {
      XCTAssertEqual(cookies.count, 1)
      XCTAssertEqual(cookies.first?.name, "test-cookie")
      XCTAssertEqual(cookies.first?.value, "cookie-value")
    } else {
      XCTFail("Expected cookies credentials after decode")
    }
  }

  func testEncodeDecode_Cookies_WithEmptyArray() throws {
    let original = TPPCredentials.cookies([])

    let encoder = JSONEncoder()
    let data = try encoder.encode(original)

    let decoder = JSONDecoder()
    let decoded = try decoder.decode(TPPCredentials.self, from: data)

    if case let .cookies(cookies) = decoded {
      XCTAssertTrue(cookies.isEmpty)
    } else {
      XCTFail("Expected cookies credentials after decode")
    }
  }

  func testEncodeDecode_Cookies_WithMultipleCookies() throws {
    let props1: [HTTPCookiePropertyKey: Any] = [.name: "first", .value: "1", .domain: "a.com", .path: "/"]
    let props2: [HTTPCookiePropertyKey: Any] = [.name: "second", .value: "2", .domain: "b.com", .path: "/"]

    guard let cookie1 = HTTPCookie(properties: props1),
          let cookie2 = HTTPCookie(properties: props2) else {
      XCTFail("Failed to create test cookies")
      return
    }

    let original = TPPCredentials.cookies([cookie1, cookie2])

    let encoder = JSONEncoder()
    let data = try encoder.encode(original)

    let decoder = JSONDecoder()
    let decoded = try decoder.decode(TPPCredentials.self, from: data)

    if case let .cookies(cookies) = decoded {
      XCTAssertEqual(cookies.count, 2)
      let names = cookies.map { $0.name }
      XCTAssertTrue(names.contains("first"))
      XCTAssertTrue(names.contains("second"))
    } else {
      XCTFail("Expected cookies credentials after decode")
    }
  }

  // MARK: - TypeID Tests

  func testTypeID_TokenHasCorrectRawValue() throws {
    // TypeID.token should have raw value 0
    let credentials = TPPCredentials.token(authToken: "test")

    // Encode and check the type field
    let encoder = JSONEncoder()
    let data = try encoder.encode(credentials)
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

    XCTAssertEqual(json?["type"] as? Int, 0)
  }

  func testTypeID_BarcodeAndPinHasCorrectRawValue() throws {
    let credentials = TPPCredentials.barcodeAndPin(barcode: "123", pin: "456")

    let encoder = JSONEncoder()
    let data = try encoder.encode(credentials)
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

    XCTAssertEqual(json?["type"] as? Int, 1)
  }

  func testTypeID_CookiesHasCorrectRawValue() throws {
    let credentials = TPPCredentials.cookies([])

    let encoder = JSONEncoder()
    let data = try encoder.encode(credentials)
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

    XCTAssertEqual(json?["type"] as? Int, 2)
  }

  // MARK: - Edge Cases

  func testEncodeDecode_Token_WithUnicodeCharacters() throws {
    let original = TPPCredentials.token(
      authToken: "token-\u{00e9}\u{00e8}\u{00ea}-unicode",
      barcode: "\u{4e2d}\u{6587}", // Chinese characters
      pin: nil,
      expirationDate: nil
    )

    let encoder = JSONEncoder()
    let data = try encoder.encode(original)

    let decoder = JSONDecoder()
    let decoded = try decoder.decode(TPPCredentials.self, from: data)

    if case let .token(authToken, barcode, _, _) = decoded {
      XCTAssertTrue(authToken.contains("\u{00e9}"))
      XCTAssertEqual(barcode, "\u{4e2d}\u{6587}")
    } else {
      XCTFail("Expected token credentials after decode")
    }
  }

  func testDecode_WithInvalidTypeID_ThrowsError() {
    // JSON with invalid type ID (999)
    let invalidJSON = """
    {
      "type": 999
    }
    """.data(using: .utf8)!

    let decoder = JSONDecoder()
    XCTAssertThrowsError(try decoder.decode(TPPCredentials.self, from: invalidJSON))
  }

  func testDecode_WithMissingType_ThrowsError() {
    let invalidJSON = """
    {
      "associatedBarcodeAndPinData": {
        "barcode": "123",
        "pin": "456"
      }
    }
    """.data(using: .utf8)!

    let decoder = JSONDecoder()
    XCTAssertThrowsError(try decoder.decode(TPPCredentials.self, from: invalidJSON))
  }

  func testEncodeDecode_Token_ExpirationDatePrecision() throws {
    // Test that expiration date precision is maintained
    let preciseDate = Date(timeIntervalSince1970: 1704067200.123456)
    let original = TPPCredentials.token(
      authToken: "test",
      barcode: nil,
      pin: nil,
      expirationDate: preciseDate
    )

    let encoder = JSONEncoder()
    let data = try encoder.encode(original)

    let decoder = JSONDecoder()
    let decoded = try decoder.decode(TPPCredentials.self, from: data)

    if case let .token(_, _, _, date) = decoded {
      // Allow small tolerance for floating point precision
      XCTAssertEqual(date?.timeIntervalSince1970 ?? 0, preciseDate.timeIntervalSince1970, accuracy: 0.001)
    } else {
      XCTFail("Expected token credentials after decode")
    }
  }
}
