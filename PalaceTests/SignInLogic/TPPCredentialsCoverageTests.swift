//
//  TPPCredentialsCoverageTests.swift
//  PalaceTests
//
//  Tests for TPPCredentials Codable encoding/decoding across all credential types,
//  and the String keychain variable extension.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class TPPCredentialsCoverageTests: XCTestCase {

    // MARK: - Token Credentials

    // SRS: TPPCredentials.token stores all fields
    func testToken_storesFields() {
        let expiration = Date(timeIntervalSince1970: 1700000000)
        let cred = TPPCredentials.token(authToken: "abc123", barcode: "1234", pin: "5678", expirationDate: expiration)
        switch cred {
        case .token(let token, let barcode, let pin, let expirationDate):
            XCTAssertEqual(token, "abc123")
            XCTAssertEqual(barcode, "1234")
            XCTAssertEqual(pin, "5678")
            XCTAssertEqual(expirationDate, expiration)
        default:
            XCTFail("Expected .token")
        }
    }

    // SRS: TPPCredentials.token defaults for optional fields
    func testToken_optionalDefaults() {
        let cred = TPPCredentials.token(authToken: "tok")
        switch cred {
        case .token(let token, let barcode, let pin, let expirationDate):
            XCTAssertEqual(token, "tok")
            XCTAssertNil(barcode)
            XCTAssertNil(pin)
            XCTAssertNil(expirationDate)
        default:
            XCTFail("Expected .token")
        }
    }

    // SRS: TPPCredentials.token Codable round-trip
    func testToken_codableRoundTrip() throws {
        let expiration = Date(timeIntervalSince1970: 1700000000)
        let original = TPPCredentials.token(authToken: "myToken", barcode: "BC", pin: "1234", expirationDate: expiration)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TPPCredentials.self, from: data)

        switch decoded {
        case .token(let token, let barcode, let pin, _):
            XCTAssertEqual(token, "myToken")
            XCTAssertEqual(barcode, "BC")
            XCTAssertEqual(pin, "1234")
        default:
            XCTFail("Expected .token after decoding")
        }
    }

    // SRS: TPPCredentials.token with nil barcode/pin round-trips
    func testToken_nilOptionals_codableRoundTrip() throws {
        let original = TPPCredentials.token(authToken: "onlyToken")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TPPCredentials.self, from: data)

        switch decoded {
        case .token(let token, let barcode, let pin, _):
            XCTAssertEqual(token, "onlyToken")
            XCTAssertNil(barcode)
            XCTAssertNil(pin)
        default:
            XCTFail("Expected .token after decoding")
        }
    }

    // MARK: - BarcodeAndPin Credentials

    // SRS: TPPCredentials.barcodeAndPin stores fields
    func testBarcodeAndPin_storesFields() {
        let cred = TPPCredentials.barcodeAndPin(barcode: "BC123", pin: "9999")
        switch cred {
        case .barcodeAndPin(let barcode, let pin):
            XCTAssertEqual(barcode, "BC123")
            XCTAssertEqual(pin, "9999")
        default:
            XCTFail("Expected .barcodeAndPin")
        }
    }

    // SRS: TPPCredentials.barcodeAndPin Codable round-trip
    func testBarcodeAndPin_codableRoundTrip() throws {
        let original = TPPCredentials.barcodeAndPin(barcode: "12345", pin: "pass")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TPPCredentials.self, from: data)

        switch decoded {
        case .barcodeAndPin(let barcode, let pin):
            XCTAssertEqual(barcode, "12345")
            XCTAssertEqual(pin, "pass")
        default:
            XCTFail("Expected .barcodeAndPin after decoding")
        }
    }

    // MARK: - Cookie Credentials

    // SRS: TPPCredentials.cookies stores cookies
    func testCookies_storesCookies() {
        let cookie = HTTPCookie(properties: [
            .name: "session",
            .value: "abc123",
            .domain: "example.com",
            .path: "/"
        ])!
        let cred = TPPCredentials.cookies([cookie])
        switch cred {
        case .cookies(let cookies):
            XCTAssertEqual(cookies.count, 1)
            XCTAssertEqual(cookies.first?.name, "session")
        default:
            XCTFail("Expected .cookies")
        }
    }

    // SRS: TPPCredentials.cookies Codable round-trip
    func testCookies_codableRoundTrip() throws {
        let cookie = HTTPCookie(properties: [
            .name: "auth",
            .value: "token456",
            .domain: "library.org",
            .path: "/api"
        ])!
        let original = TPPCredentials.cookies([cookie])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TPPCredentials.self, from: data)

        switch decoded {
        case .cookies(let cookies):
            XCTAssertEqual(cookies.count, 1)
            XCTAssertEqual(cookies.first?.name, "auth")
            XCTAssertEqual(cookies.first?.value, "token456")
        default:
            XCTFail("Expected .cookies after decoding")
        }
    }

    // MARK: - TypeID

    // SRS: TypeID raw values match expected order
    func testTypeID_rawValues() {
        XCTAssertEqual(TPPCredentials.TypeID.token.rawValue, 0)
        XCTAssertEqual(TPPCredentials.TypeID.barcodeAndPin.rawValue, 1)
        XCTAssertEqual(TPPCredentials.TypeID.cookies.rawValue, 2)
    }
}
