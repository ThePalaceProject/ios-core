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
import PalaceCatalog
@testable import Palace

// MARK: - LoginKeyboard Tests

final class LoginKeyboardTests: XCTestCase {

    func testInit_WithDefaultString_ReturnsStandard() {
        let keyboard = LoginKeyboard("Default")
        XCTAssertEqual(keyboard, .standard)
        XCTAssertNotNil(keyboard)
        XCTAssertNotEqual(keyboard, .email)
    }

    func testInit_WithEmailString_ReturnsEmail() {
        let keyboard = LoginKeyboard("Email address")
        XCTAssertEqual(keyboard, .email)
        XCTAssertNotNil(keyboard)
        XCTAssertNotEqual(keyboard, .standard)
    }

    func testInit_WithNumberPadString_ReturnsNumeric() {
        let keyboard = LoginKeyboard("Number pad")
        XCTAssertEqual(keyboard, .numeric)
        XCTAssertNotNil(keyboard)
        XCTAssertNotEqual(keyboard, .standard)
    }

    func testInit_WithNoInputString_ReturnsNone() {
        let keyboard = LoginKeyboard("No input")
        XCTAssertEqual(keyboard, LoginKeyboard.none)
        XCTAssertNotNil(keyboard)
        XCTAssertNotEqual(keyboard, .standard)
    }

    func testInit_WithNilString_ReturnsNil() {
        let keyboard = LoginKeyboard(nil)
        XCTAssertNil(keyboard)
        // All named strings must still produce non-nil
        XCTAssertNotNil(LoginKeyboard("Default"))
    }

    func testInit_WithInvalidString_ReturnsNil() {
        let keyboard = LoginKeyboard("invalid")
        XCTAssertNil(keyboard)
        XCTAssertNotNil(LoginKeyboard("Default"), "Only known strings should succeed")
    }

    func testInit_WithEmptyString_ReturnsNil() {
        let keyboard = LoginKeyboard("")
        XCTAssertNil(keyboard)
        XCTAssertNotNil(LoginKeyboard("Default"), "Non-empty known string must succeed")
    }

    func testInit_WithCaseSensitiveString_ReturnsNil() {
        // Case-sensitive - "default" != "Default"
        let keyboard = LoginKeyboard("default")
        XCTAssertNil(keyboard)
        XCTAssertNotNil(LoginKeyboard("Default"), "Exact-case string must succeed")
    }
}

// MARK: - AuthType Tests

final class AuthTypeTests: XCTestCase {

    func testAuthType_BasicRawValue_IsCorrect() {
        XCTAssertEqual(AccountDetails.AuthType.basic.rawValue, "http://opds-spec.org/auth/basic")
        XCTAssertEqual(AccountDetails.AuthType(rawValue: "http://opds-spec.org/auth/basic"), .basic)
    }

    func testAuthType_CoppaRawValue_IsCorrect() {
        XCTAssertEqual(AccountDetails.AuthType.coppa.rawValue, "http://librarysimplified.org/terms/authentication/gate/coppa")
        XCTAssertEqual(AccountDetails.AuthType(rawValue: "http://librarysimplified.org/terms/authentication/gate/coppa"), .coppa)
    }

    func testAuthType_AnonymousRawValue_IsCorrect() {
        XCTAssertEqual(AccountDetails.AuthType.anonymous.rawValue, "http://librarysimplified.org/rel/auth/anonymous")
        XCTAssertEqual(AccountDetails.AuthType(rawValue: "http://librarysimplified.org/rel/auth/anonymous"), .anonymous)
    }

    func testAuthType_OAuthRawValue_IsCorrect() {
        XCTAssertEqual(AccountDetails.AuthType.oauthIntermediary.rawValue, "http://librarysimplified.org/authtype/OAuth-with-intermediary")
        XCTAssertEqual(AccountDetails.AuthType(rawValue: "http://librarysimplified.org/authtype/OAuth-with-intermediary"), .oauthIntermediary)
    }

    func testAuthType_SamlRawValue_IsCorrect() {
        XCTAssertEqual(AccountDetails.AuthType.saml.rawValue, "http://librarysimplified.org/authtype/SAML-2.0")
        XCTAssertEqual(AccountDetails.AuthType(rawValue: "http://librarysimplified.org/authtype/SAML-2.0"), .saml)
    }

    func testAuthType_TokenRawValue_IsCorrect() {
        XCTAssertEqual(AccountDetails.AuthType.token.rawValue, "http://thepalaceproject.org/authtype/basic-token")
        XCTAssertEqual(AccountDetails.AuthType(rawValue: "http://thepalaceproject.org/authtype/basic-token"), .token)
    }

    func testAuthType_InitFromInvalidString_ReturnsNil() {
        let authType = AccountDetails.AuthType(rawValue: "invalid")
        XCTAssertNil(authType)
        XCTAssertNotNil(AccountDetails.AuthType(rawValue: "http://opds-spec.org/auth/basic"), "Valid raw value must succeed")
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

// MARK: - AccountDetails / Account needsAuth aggregate tests (BUG-004)

/// Tests for the library-level `needsAuth` aggregate exposed on
/// `AccountDetails` and the `Account` passthrough. This signal drives the
/// BUG-004 holds-fetch suppression — when an anonymous library
/// (Palace Bookshelf) is selected, holds must not be fetched and the error
/// banner must not appear.
final class AccountDetailsNeedsAuthAggregateTests: XCTestCase {

    func testAccountDetails_NeedsAuth_BasicOnly_ReturnsTrue() {
        let details = makeAccountDetails(authTypes: ["http://opds-spec.org/auth/basic"])
        XCTAssertTrue(details.needsAuth,
                      "Basic auth library must report needsAuth=true so loans/holds fetches are gated by credentials, not skipped")
    }

    func testAccountDetails_NeedsAuth_SamlOnly_ReturnsTrue() {
        let details = makeAccountDetails(authTypes: ["http://librarysimplified.org/authtype/SAML-2.0"])
        XCTAssertTrue(details.needsAuth,
                      "SAML library must report needsAuth=true")
    }

    func testAccountDetails_NeedsAuth_AnonymousOnly_ReturnsFalse() {
        // The Palace Bookshelf shape: a single anonymous auth method, no patron concept.
        let details = makeAccountDetails(authTypes: ["http://librarysimplified.org/rel/auth/anonymous"])
        XCTAssertFalse(details.needsAuth,
                       "Anonymous-only library (Palace Bookshelf) must report needsAuth=false — this is the BUG-004 guard")
    }

    func testAccountDetails_NeedsAuth_CoppaOnly_ReturnsFalse() {
        // COPPA gate is age-restriction, not credential-based — should not trigger holds fetch.
        let details = makeAccountDetails(authTypes: ["http://librarysimplified.org/terms/authentication/gate/coppa"])
        XCTAssertFalse(details.needsAuth,
                       "COPPA-only library must report needsAuth=false (age gate, not credentials)")
    }

    func testAccountDetails_NeedsAuth_AnonymousMixedWithBasic_ReturnsTrue() {
        // If ANY auth method requires credentials, the library as a whole needs auth —
        // anonymous "guest mode" alongside credentialed access still means holds are
        // a real concept for signed-in patrons.
        let details = makeAccountDetails(authTypes: [
            "http://librarysimplified.org/rel/auth/anonymous",
            "http://opds-spec.org/auth/basic"
        ])
        XCTAssertTrue(details.needsAuth,
                      "Mixed anonymous+basic library must report needsAuth=true — credentialed patrons exist here")
    }

    func testAccountDetails_NeedsAuth_OAuthOnly_ReturnsTrue() {
        let details = makeAccountDetails(authTypes: ["http://librarysimplified.org/authtype/OAuth-with-intermediary"])
        XCTAssertTrue(details.needsAuth, "OAuth library must report needsAuth=true")
    }

    func testAccountDetails_NeedsAuth_OidcOnly_ReturnsTrue() {
        let details = makeAccountDetails(authTypes: ["http://palaceproject.io/authtype/OpenIDConnect"])
        XCTAssertTrue(details.needsAuth, "OIDC library must report needsAuth=true")
    }

    // MARK: - Account passthrough

    /// `Account.needsAuth` must return `nil` before the auth document is
    /// loaded (no `details`). Critical-path callers default-deny to avoid
    /// suppressing real failures during the hydration window.
    func testAccount_NeedsAuth_BeforeAuthDocLoaded_ReturnsNil() {
        let account = makeAccountWithoutAuthDoc()
        XCTAssertNil(account.details, "Precondition: auth document not loaded yet")
        XCTAssertNil(account.needsAuth,
                     "Account.needsAuth must be nil while auth doc is still loading — callers default-deny in this window")
    }

    /// `Account.needsAuth` must reflect `details.needsAuth` once the auth
    /// document has been parsed. This is the property that the BUG-004
    /// holds-fetch guard consults.
    func testAccount_NeedsAuth_AnonymousDetailsLoaded_ReturnsFalse() {
        let account = makeAccountWithoutAuthDoc()
        account.authenticationDocument = makeAuthDocument(authTypes: ["http://librarysimplified.org/rel/auth/anonymous"])
        XCTAssertNotNil(account.details, "Precondition: details now populated")
        XCTAssertEqual(account.needsAuth, false,
                       "Account.needsAuth must reflect details.needsAuth=false for anonymous library (BUG-004 contract)")
    }

    func testAccount_NeedsAuth_BasicDetailsLoaded_ReturnsTrue() {
        let account = makeAccountWithoutAuthDoc()
        account.authenticationDocument = makeAuthDocument(authTypes: ["http://opds-spec.org/auth/basic"])
        XCTAssertEqual(account.needsAuth, true,
                       "Account.needsAuth must reflect details.needsAuth=true for credentialed library")
    }

    // MARK: - Helpers

    private func makeAccountDetails(authTypes: [String]) -> AccountDetails {
        let doc = makeAuthDocument(authTypes: authTypes)
        let uuid = "needsauth-test-\(UUID().uuidString)"
        return AccountDetails(authenticationDocument: doc, uuid: uuid)
    }

    private func makeAuthDocument(authTypes: [String]) -> OPDS2AuthenticationDocument {
        let auths: [[String: Any]] = authTypes.map { type in
            [
                "type": type,
                "inputs": [
                    "login": ["keyboard": "Default"],
                    "password": ["keyboard": "Default"]
                ],
                "labels": ["login": "Login", "password": "Password"]
            ]
        }
        let json: [String: Any] = [
            "id": "urn:uuid:needsauth-test",
            "title": "NeedsAuth Test Library",
            "authentication": auths,
            "features": ["enabled": [], "disabled": []]
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! OPDS2AuthenticationDocument.fromData(data)
    }

    private func makeAccountWithoutAuthDoc() -> Account {
        let publication = OPDS2Publication(
            links: [],
            metadata: OPDS2Publication.Metadata(
                updated: Date(),
                description: nil,
                id: "urn:uuid:needsauth-account-test",
                title: "NeedsAuth Account Test"
            ),
            images: nil
        )
        return Account(publication: publication, imageCache: MockImageCache())
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
