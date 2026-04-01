//
//  AccountDetailsTests.swift
//  PalaceTests
//
//  Tests for Account, AccountDetails, Authentication, and related types.
//  Covers high-priority coverage gaps.
//
//  Copyright 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

// MARK: - LoginKeyboard Tests

final class LoginKeyboardTests: XCTestCase {

    func testInit_WithDefaultString_ReturnsStandard() {
        let keyboard = LoginKeyboard("Default")
        XCTAssertEqual(keyboard, .standard)
    }

    func testInit_WithEmailString_ReturnsEmail() {
        let keyboard = LoginKeyboard("Email address")
        XCTAssertEqual(keyboard, .email)
    }

    func testInit_WithNumberPadString_ReturnsNumeric() {
        let keyboard = LoginKeyboard("Number pad")
        XCTAssertEqual(keyboard, .numeric)
    }

    func testInit_WithNoInputString_ReturnsNone() {
        let keyboard = LoginKeyboard("No input")
        XCTAssertEqual(keyboard, LoginKeyboard.none)
    }

    func testInit_WithNilString_ReturnsNil() {
        let keyboard = LoginKeyboard(nil)
        XCTAssertNil(keyboard)
    }

    func testInit_WithInvalidString_ReturnsNil() {
        let keyboard = LoginKeyboard("invalid")
        XCTAssertNil(keyboard)
    }

    func testInit_WithEmptyString_ReturnsNil() {
        let keyboard = LoginKeyboard("")
        XCTAssertNil(keyboard)
    }

    func testInit_WithCaseSensitiveString_ReturnsNil() {
        // Case-sensitive - "default" != "Default"
        let keyboard = LoginKeyboard("default")
        XCTAssertNil(keyboard)
    }
}

// MARK: - AuthType Tests

final class AuthTypeTests: XCTestCase {

    func testAuthType_BasicRawValue_IsCorrect() {
        XCTAssertEqual(AccountDetails.AuthType.basic.rawValue, "http://opds-spec.org/auth/basic")
    }

    func testAuthType_CoppaRawValue_IsCorrect() {
        XCTAssertEqual(AccountDetails.AuthType.coppa.rawValue, "http://librarysimplified.org/terms/authentication/gate/coppa")
    }

    func testAuthType_AnonymousRawValue_IsCorrect() {
        XCTAssertEqual(AccountDetails.AuthType.anonymous.rawValue, "http://librarysimplified.org/rel/auth/anonymous")
    }

    func testAuthType_OAuthRawValue_IsCorrect() {
        XCTAssertEqual(AccountDetails.AuthType.oauthIntermediary.rawValue, "http://librarysimplified.org/authtype/OAuth-with-intermediary")
    }

    func testAuthType_SamlRawValue_IsCorrect() {
        XCTAssertEqual(AccountDetails.AuthType.saml.rawValue, "http://librarysimplified.org/authtype/SAML-2.0")
    }

    func testAuthType_TokenRawValue_IsCorrect() {
        XCTAssertEqual(AccountDetails.AuthType.token.rawValue, "http://thepalaceproject.org/authtype/basic-token")
    }

    func testAuthType_InitFromInvalidString_ReturnsNil() {
        let authType = AccountDetails.AuthType(rawValue: "invalid")
        XCTAssertNil(authType)
    }
}

// MARK: - Authentication Tests

final class AuthenticationTests: XCTestCase {

    func testNeedsAuth_ForBasicType_ReturnsTrue() {
        let auth = createMockAuthentication(type: .basic)
        XCTAssertTrue(auth.needsAuth)
    }

    func testNeedsAuth_ForOAuthType_ReturnsTrue() {
        let auth = createMockAuthentication(type: .oauthIntermediary)
        XCTAssertTrue(auth.needsAuth)
    }

    func testNeedsAuth_ForSamlType_ReturnsTrue() {
        let auth = createMockAuthentication(type: .saml)
        XCTAssertTrue(auth.needsAuth)
    }

    func testNeedsAuth_ForTokenType_ReturnsTrue() {
        let auth = createMockAuthentication(type: .token)
        XCTAssertTrue(auth.needsAuth)
    }

    func testNeedsAuth_ForAnonymousType_ReturnsFalse() {
        let auth = createMockAuthentication(type: .anonymous)
        XCTAssertFalse(auth.needsAuth)
    }

    func testNeedsAuth_ForCoppaType_ReturnsFalse() {
        let auth = createMockAuthentication(type: .coppa)
        XCTAssertFalse(auth.needsAuth)
    }

    func testNeedsAgeCheck_ForCoppaType_ReturnsTrue() {
        let auth = createMockAuthentication(type: .coppa)
        XCTAssertTrue(auth.needsAgeCheck)
    }

    func testNeedsAgeCheck_ForBasicType_ReturnsFalse() {
        let auth = createMockAuthentication(type: .basic)
        XCTAssertFalse(auth.needsAgeCheck)
    }

    func testIsBasic_ForBasicType_ReturnsTrue() {
        let auth = createMockAuthentication(type: .basic)
        XCTAssertTrue(auth.isBasic)
    }

    func testIsOauth_ForOAuthType_ReturnsTrue() {
        let auth = createMockAuthentication(type: .oauthIntermediary)
        XCTAssertTrue(auth.isOauth)
    }

    func testIsSaml_ForSamlType_ReturnsTrue() {
        let auth = createMockAuthentication(type: .saml)
        XCTAssertTrue(auth.isSaml)
    }

    func testIsToken_ForTokenType_ReturnsTrue() {
        let auth = createMockAuthentication(type: .token)
        XCTAssertTrue(auth.isToken)
    }

    func testCatalogRequiresAuthentication_ForOAuthType_ReturnsTrue() {
        let auth = createMockAuthentication(type: .oauthIntermediary)
        XCTAssertTrue(auth.catalogRequiresAuthentication)
    }

    func testCatalogRequiresAuthentication_ForBasicType_ReturnsFalse() {
        let auth = createMockAuthentication(type: .basic)
        XCTAssertFalse(auth.catalogRequiresAuthentication)
    }

    func testCoppaURL_WhenOfAge_ReturnsOverUrl() {
        let auth = createMockAuthenticationWithCoppaUrls()
        let url = auth.coppaURL(isOfAge: true)
        XCTAssertEqual(url?.absoluteString, "https://example.com/over13")
    }

    func testCoppaURL_WhenUnderAge_ReturnsUnderUrl() {
        let auth = createMockAuthenticationWithCoppaUrls()
        let url = auth.coppaURL(isOfAge: false)
        XCTAssertEqual(url?.absoluteString, "https://example.com/under13")
    }

    // MARK: - Helper Methods

    private func createMockAuthentication(type: AccountDetails.AuthType) -> AccountDetails.Authentication {
        return makeTestAuthentication(authType: type)
    }

    private func createMockAuthenticationWithCoppaUrls() -> AccountDetails.Authentication {
        return makeTestAuthentication(
            authType: .coppa,
            coppaUnderUrl: URL(string: "https://example.com/under13"),
            coppaOverUrl: URL(string: "https://example.com/over13")
        )
    }
}

// MARK: - URLType Tests

final class URLTypeTests: XCTestCase {

    func testURLType_HasAllExpectedCases() {
        // Verify all cases exist
        XCTAssertNotNil(URLType.acknowledgements)
        XCTAssertNotNil(URLType.contentLicenses)
        XCTAssertNotNil(URLType.eula)
        XCTAssertNotNil(URLType.privacyPolicy)
        XCTAssertNotNil(URLType.annotations)
    }

    func testURLType_RawValues_AreDistinct() {
        let rawValues: Set<Int> = [
            URLType.acknowledgements.rawValue,
            URLType.contentLicenses.rawValue,
            URLType.eula.rawValue,
            URLType.privacyPolicy.rawValue,
            URLType.annotations.rawValue
        ]
        XCTAssertEqual(rawValues.count, 5, "All URLType cases should have distinct raw values")
    }
}

// MARK: - Test Helper

/// Creates Authentication instances via JSON/Codable for testing.
private func makeTestAuthentication(
    authType: AccountDetails.AuthType,
    coppaUnderUrl: URL? = nil,
    coppaOverUrl: URL? = nil
) -> AccountDetails.Authentication {
    var dict: [String: Any] = [
        "authType": authType.rawValue,
        "authPasscodeLength": 4,
        "patronIDKeyboard": LoginKeyboard.standard.rawValue,
        "pinKeyboard": LoginKeyboard.numeric.rawValue,
        "supportsBarcodeScanner": false,
        "supportsBarcodeDisplay": false
    ]
    if let url = coppaUnderUrl {
        dict["coppaUnderUrl"] = url.absoluteString
    }
    if let url = coppaOverUrl {
        dict["coppaOverUrl"] = url.absoluteString
    }
    let data = try! JSONSerialization.data(withJSONObject: dict)
    return try! JSONDecoder().decode(AccountDetails.Authentication.self, from: data)
}
