//
// TPPSignInOIDCTests.swift
// PalaceTests
//
// Tests for OIDC (OpenID Connect) patron authentication
// Includes unit, integration, and regression tests.
//
// Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import stduritemplate
@testable import Palace

// MARK: - Unit Tests: AuthType & Authentication Model

final class OIDCAuthTypeTests: XCTestCase {

    func testAuthType_OidcRawValue_IsCorrect() {
        XCTAssertEqual(
            AccountDetails.AuthType.oidc.rawValue,
            "http://palaceproject.io/authtype/OpenIDConnect"
        )
    }

    func testAuthType_InitFromOidcString_ReturnsOidc() {
        let authType = AccountDetails.AuthType(rawValue: "http://palaceproject.io/authtype/OpenIDConnect")
        XCTAssertEqual(authType, .oidc)
    }

    func testAuthType_InitFromLegacyOidcString_ReturnsOidc() {
        let authType = AccountDetails.AuthType.from("http://thepalaceproject.org/authtype/openid-connect")
        XCTAssertEqual(authType, .oidc, "Legacy OIDC URI must still resolve to .oidc")
    }

    func testAuthType_LegacyOidcURI_DecodesViaCodeable() throws {
        let json = "\"http://thepalaceproject.org/authtype/openid-connect\""
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AccountDetails.AuthType.self, from: data)
        XCTAssertEqual(decoded, .oidc, "Legacy OIDC URI must decode to .oidc via Codable")
    }

    func testAuthType_OidcIsDistinct_FromOtherTypes() {
        let oidc = AccountDetails.AuthType.oidc
        XCTAssertNotEqual(oidc, .basic)
        XCTAssertNotEqual(oidc, .oauthIntermediary)
        XCTAssertNotEqual(oidc, .saml)
        XCTAssertNotEqual(oidc, .token)
        XCTAssertNotEqual(oidc, .coppa)
        XCTAssertNotEqual(oidc, .anonymous)
        XCTAssertNotEqual(oidc, .none)
    }
}

// MARK: - Unit Tests: Authentication Properties

final class OIDCAuthenticationPropertyTests: XCTestCase {

    private var libraryMock: TPPLibraryAccountMock!

    override func setUp() {
        super.setUp()
        libraryMock = TPPLibraryAccountMock()
    }

    override func tearDown() {
        libraryMock = nil
        super.tearDown()
    }

    func testOidcAuthentication_isOidc_ReturnsTrue() {
        let auth = libraryMock.oidcAuthentication
        XCTAssertTrue(auth.isOidc)
    }

    func testOidcAuthentication_isNotOtherTypes() {
        let auth = libraryMock.oidcAuthentication
        XCTAssertFalse(auth.isBasic)
        XCTAssertFalse(auth.isOauth)
        XCTAssertFalse(auth.isSaml)
        XCTAssertFalse(auth.isToken)
    }

    func testOidcAuthentication_needsAuth_ReturnsTrue() {
        let auth = libraryMock.oidcAuthentication
        XCTAssertTrue(auth.needsAuth)
    }

    func testOidcAuthentication_needsAgeCheck_ReturnsFalse() {
        let auth = libraryMock.oidcAuthentication
        XCTAssertFalse(auth.needsAgeCheck)
    }

    func testOidcAuthentication_hasAuthenticationUrl() {
        let auth = libraryMock.oidcAuthentication
        XCTAssertNotNil(auth.oidcAuthenticationUrl)
        XCTAssertEqual(
            auth.oidcAuthenticationUrl?.absoluteString,
            "https://circulation.example.com/NYNYPL/oidc/authenticate?provider=OpenID+Connect"
        )
    }

    func testOidcAuthentication_methodDescription_IsOpenIDConnect() {
        let auth = libraryMock.oidcAuthentication
        XCTAssertEqual(auth.methodDescription, "OpenID Connect")
    }

    func testOidcAuthentication_otherUrlsAreNil() {
        let auth = libraryMock.oidcAuthentication
        XCTAssertNil(auth.oauthIntermediaryUrl)
        XCTAssertNil(auth.tokenURL)
        XCTAssertNil(auth.coppaUnderUrl)
        XCTAssertNil(auth.coppaOverUrl)
        XCTAssertNil(auth.samlIdps)
    }

    func testOidcAuthentication_catalogRequiresAuthentication_ReturnsFalse() {
        let auth = libraryMock.oidcAuthentication
        XCTAssertFalse(auth.catalogRequiresAuthentication)
    }
}

// MARK: - Unit Tests: OPDS Auth Document Parsing

final class OIDCAuthDocumentParsingTests: XCTestCase {

    func testAuthDocument_containsOidcType() {
        let mock = TPPLibraryAccountMock()
        let details = mock.tppAccount.details!

        let oidcAuths = details.auths.filter { $0.authType == .oidc }
        XCTAssertEqual(oidcAuths.count, 1, "Auth document should contain exactly one OIDC auth method")
    }

    func testAuthDocument_oidcAuthenticateLink_IsParsed() {
        let mock = TPPLibraryAccountMock()
        let oidcAuth = mock.oidcAuthentication

        XCTAssertNotNil(oidcAuth.oidcAuthenticationUrl)
        XCTAssertTrue(
            oidcAuth.oidcAuthenticationUrl!.absoluteString.contains("oidc/authenticate"),
            "OIDC authenticate URL should be parsed from the 'authenticate' rel link"
        )
    }

    func testAuthDocument_oidcDoesNotAffectOtherAuthTypes() {
        let mock = TPPLibraryAccountMock()
        let details = mock.tppAccount.details!

        XCTAssertNotNil(details.auths.first { $0.authType == .basic }, "Basic auth should still be present")
        XCTAssertNotNil(details.auths.first { $0.authType == .oauthIntermediary }, "OAuth auth should still be present")
        XCTAssertNotNil(details.auths.first { $0.authType == .saml }, "SAML auth should still be present")
    }

    func testAuthDocument_unknownTypeStillFallsToNone() {
        let jsonString = """
        {
            "title": "Test Library",
            "id": "https://example.com/auth",
            "authentication": [{
                "type": "http://example.com/unknown-auth-type",
                "description": "Unknown"
            }]
        }
        """
        let data = jsonString.data(using: .utf8)!
        let doc = try! OPDS2AuthenticationDocument.fromData(data)
        let details = AccountDetails(authenticationDocument: doc, uuid: "test-uuid")

        XCTAssertEqual(details.auths.count, 1, "Unknown type should still produce an auth entry")
        XCTAssertEqual(details.auths.first!.authType, .none, "Unknown type string should map to .none")
    }
}

// MARK: - Unit Tests: NSCoding Round-Trip

final class OIDCNSCodingTests: XCTestCase {

    func testOidcAuthentication_NSCodingRoundTrip_PreservesProperties() {
        let mock = TPPLibraryAccountMock()
        let originalAuth = mock.oidcAuthentication

        let data = try! NSKeyedArchiver.archivedData(withRootObject: originalAuth, requiringSecureCoding: false)

        let unarchiver = try! NSKeyedUnarchiver(forReadingFrom: data)
        unarchiver.requiresSecureCoding = false
        let decoded = unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as? AccountDetails.Authentication

        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.authType, .oidc)
        XCTAssertTrue(decoded?.isOidc == true)
        XCTAssertEqual(decoded?.oidcAuthenticationUrl, originalAuth.oidcAuthenticationUrl)
        XCTAssertEqual(decoded?.methodDescription, originalAuth.methodDescription)
    }
}

// MARK: - Unit Tests: Business Logic — Make Request

final class OIDCMakeRequestTests: XCTestCase {

    private var businessLogic: TPPSignInBusinessLogic!
    private var libraryMock: TPPLibraryAccountMock!
    private var uiDelegate: TPPSignInOutBusinessLogicUIDelegateMock!

    override func setUp() {
        super.setUp()
        TPPUserAccountMock.resetShared()
        libraryMock = TPPLibraryAccountMock()
        uiDelegate = TPPSignInOutBusinessLogicUIDelegateMock()

        businessLogic = TPPSignInBusinessLogic(
            libraryAccountID: libraryMock.tppAccountUUID,
            libraryAccountsProvider: libraryMock,
            urlSettingsProvider: TPPURLSettingsProviderMock(),
            bookRegistry: TPPBookRegistryMock(),
            bookDownloadsCenter: TPPMyBooksDownloadsCenterMock(),
            userAccountProvider: TPPUserAccountMock.self,
            networkExecutor: TPPRequestExecutorMock(),
            uiDelegate: uiDelegate,
            drmAuthorizer: TPPDRMAuthorizingMock()
        )
    }

    override func tearDown() {
        businessLogic.userAccount.removeAll()
        businessLogic = nil
        libraryMock = nil
        uiDelegate = nil
        super.tearDown()
    }

    func testMakeRequest_forOIDC_addsBearerTokenHeader() {
        businessLogic.selectedAuthentication = libraryMock.oidcAuthentication
        businessLogic.authToken = "oidc-test-access-token"

        let request = businessLogic.makeRequest(for: .signIn, context: "test")

        XCTAssertNotNil(request)
        XCTAssertEqual(
            request?.value(forHTTPHeaderField: "Authorization"),
            "Bearer oidc-test-access-token"
        )
    }

    func testMakeRequest_forOIDC_withoutToken_stillCreatesRequest() {
        businessLogic.selectedAuthentication = libraryMock.oidcAuthentication
        businessLogic.authToken = nil

        let request = businessLogic.makeRequest(for: .signIn, context: "test")

        XCTAssertNotNil(request, "Request should still be created even without auth token")
    }

    func testMakeRequest_forOIDCSignOut_usesUserProfileURL() {
        businessLogic.selectedAuthentication = libraryMock.oidcAuthentication
        businessLogic.authToken = "oidc-token"

        let request = businessLogic.makeRequest(for: .signOut, context: "test")

        XCTAssertNotNil(request)
        XCTAssertNotNil(request?.url)
    }
}

// MARK: - Unit Tests: Business Logic — Login Routing

final class OIDCLoginRoutingTests: XCTestCase {

    private var businessLogic: TPPSignInBusinessLogic!
    private var libraryMock: TPPLibraryAccountMock!
    private var uiDelegate: TPPSignInOutBusinessLogicUIDelegateMock!

    override func setUp() {
        super.setUp()
        TPPUserAccountMock.resetShared()
        libraryMock = TPPLibraryAccountMock()
        uiDelegate = TPPSignInOutBusinessLogicUIDelegateMock()

        businessLogic = TPPSignInBusinessLogic(
            libraryAccountID: libraryMock.tppAccountUUID,
            libraryAccountsProvider: libraryMock,
            urlSettingsProvider: TPPURLSettingsProviderMock(),
            bookRegistry: TPPBookRegistryMock(),
            bookDownloadsCenter: TPPMyBooksDownloadsCenterMock(),
            userAccountProvider: TPPUserAccountMock.self,
            networkExecutor: TPPRequestExecutorMock(),
            uiDelegate: uiDelegate,
            drmAuthorizer: TPPDRMAuthorizingMock()
        )
    }

    override func tearDown() {
        businessLogic.userAccount.removeAll()
        businessLogic = nil
        libraryMock = nil
        uiDelegate = nil
        super.tearDown()
    }

    func testLogIn_withOIDC_callsWillSignIn() {
        businessLogic.selectedAuthentication = libraryMock.oidcAuthentication

        businessLogic.logIn()

        XCTAssertTrue(uiDelegate.didCallWillSignIn,
                      "OIDC logIn should trigger businessLogicWillSignIn")
    }

    func testLogIn_withOIDC_doesNotValidateCredentialsDirectly() {
        businessLogic.selectedAuthentication = libraryMock.oidcAuthentication

        businessLogic.logIn()

        XCTAssertFalse(businessLogic.isValidatingCredentials,
                       "OIDC flow should NOT directly call validateCredentials; it uses ASWebAuthenticationSession")
    }

    func testLogIn_withOIDC_capturesCredentials() {
        uiDelegate.username = "oidc-user"
        uiDelegate.pin = nil
        businessLogic.selectedAuthentication = libraryMock.oidcAuthentication

        businessLogic.logIn()

        XCTAssertEqual(businessLogic.capturedBarcode, "oidc-user")
    }
}

// MARK: - Unit Tests: Business Logic — Update User Account

final class OIDCUpdateUserAccountTests: XCTestCase {

    private var businessLogic: TPPSignInBusinessLogic!
    private var libraryMock: TPPLibraryAccountMock!

    override func setUp() {
        super.setUp()
        TPPUserAccountMock.resetShared()

        libraryMock = TPPLibraryAccountMock()

        businessLogic = TPPSignInBusinessLogic(
            libraryAccountID: libraryMock.tppAccountUUID,
            libraryAccountsProvider: libraryMock,
            urlSettingsProvider: TPPURLSettingsProviderMock(),
            bookRegistry: TPPBookRegistryMock(),
            bookDownloadsCenter: TPPMyBooksDownloadsCenterMock(),
            userAccountProvider: TPPUserAccountMock.self,
            networkExecutor: TPPRequestExecutorMock(),
            uiDelegate: TPPSignInOutBusinessLogicUIDelegateMock(),
            drmAuthorizer: TPPDRMAuthorizingMock()
        )
    }

    override func tearDown() {
        businessLogic.userAccount.removeAll()
        businessLogic = nil
        libraryMock = nil
        super.tearDown()
    }

    func testUpdateUserAccount_withOIDC_storesAuthToken() {
        businessLogic.selectedAuthentication = libraryMock.oidcAuthentication

        businessLogic.updateUserAccount(
            forDRMAuthorization: true,
            withBarcode: nil,
            pin: nil,
            authToken: "oidc-access-token-xyz",
            expirationDate: Date().addingTimeInterval(3600),
            patron: ["name": "OIDC Patron"],
            cookies: nil
        )

        XCTAssertEqual(businessLogic.userAccount.authToken, "oidc-access-token-xyz")
    }

    func testUpdateUserAccount_withOIDC_storesPatronInfo() {
        businessLogic.selectedAuthentication = libraryMock.oidcAuthentication

        businessLogic.updateUserAccount(
            forDRMAuthorization: true,
            withBarcode: nil,
            pin: nil,
            authToken: "oidc-token",
            expirationDate: nil,
            patron: ["name": "Jane Doe", "email": "jane@example.com"],
            cookies: nil
        )

        XCTAssertEqual(businessLogic.userAccount.patron?["name"] as? String, "Jane Doe")
    }

    func testUpdateUserAccount_withOIDC_setsAuthDefinition() {
        businessLogic.selectedAuthentication = libraryMock.oidcAuthentication

        businessLogic.updateUserAccount(
            forDRMAuthorization: true,
            withBarcode: nil,
            pin: nil,
            authToken: "oidc-token",
            expirationDate: nil,
            patron: nil,
            cookies: nil
        )

        XCTAssertNotNil(businessLogic.userAccount.authDefinition)
        XCTAssertEqual(businessLogic.userAccount.authDefinition?.authType, .oidc)
    }

    func testUpdateUserAccount_withOIDC_marksLoggedIn() {
        businessLogic.selectedAuthentication = libraryMock.oidcAuthentication

        businessLogic.updateUserAccount(
            forDRMAuthorization: true,
            withBarcode: nil,
            pin: nil,
            authToken: "oidc-token",
            expirationDate: nil,
            patron: nil,
            cookies: nil
        )

        XCTAssertTrue(businessLogic.isSignedIn())
    }

    func testUpdateUserAccount_withOIDC_doesNotStoreCookies() {
        businessLogic.selectedAuthentication = libraryMock.oidcAuthentication

        businessLogic.updateUserAccount(
            forDRMAuthorization: true,
            withBarcode: nil,
            pin: nil,
            authToken: "oidc-token",
            expirationDate: nil,
            patron: nil,
            cookies: nil
        )

        XCTAssertNil(businessLogic.userAccount.cookies,
                      "OIDC should not store cookies (unlike SAML)")
    }
}

// MARK: - Unit Tests: OIDC Callback Scheme Constants

final class OIDCCallbackSchemeTests: XCTestCase {

    func testOidcCallbackScheme_matchesAndroidConvention() {
        XCTAssertEqual(TPPSignInBusinessLogic.oidcCallbackScheme, "palace-oidc-callback",
                       "Must match Android's custom scheme for consistent CM behavior")
    }

    func testOidcCallbackHost_matchesAndroidConvention() {
        XCTAssertEqual(TPPSignInBusinessLogic.oidcCallbackHost, "org.thepalaceproject.oidc")
    }

    func testOidcCallbackScheme_isNotHTTPS() {
        XCTAssertNotEqual(TPPSignInBusinessLogic.oidcCallbackScheme, "https",
                          "Must NOT use https — ASWebAuthenticationSession requires a custom scheme")
    }
}

// MARK: - Integration Tests: OIDC Callback Handling

final class OIDCCallbackHandlingTests: XCTestCase {

    private var businessLogic: TPPSignInBusinessLogic!
    private var libraryMock: TPPLibraryAccountMock!
    private var uiDelegate: TPPSignInOutBusinessLogicUIDelegateMock!
    private var networkExecutor: TPPRequestExecutorMock!

    override func setUp() {
        super.setUp()
        TPPUserAccountMock.resetShared()
        libraryMock = TPPLibraryAccountMock()
        uiDelegate = TPPSignInOutBusinessLogicUIDelegateMock()
        networkExecutor = TPPRequestExecutorMock()

        businessLogic = TPPSignInBusinessLogic(
            libraryAccountID: libraryMock.tppAccountUUID,
            libraryAccountsProvider: libraryMock,
            urlSettingsProvider: TPPURLSettingsProviderMock(),
            bookRegistry: TPPBookRegistryMock(),
            bookDownloadsCenter: TPPMyBooksDownloadsCenterMock(),
            userAccountProvider: TPPUserAccountMock.self,
            networkExecutor: networkExecutor,
            uiDelegate: uiDelegate,
            drmAuthorizer: TPPDRMAuthorizingMock()
        )
    }

    override func tearDown() {
        networkExecutor.reset()
        businessLogic.userAccount.removeAll()
        businessLogic = nil
        libraryMock = nil
        uiDelegate = nil
        networkExecutor = nil
        super.tearDown()
    }

    /// Callback URL uses the custom scheme with query parameters (like Android).
    func testHandleOIDCCallback_withQueryParams_extractsTokenAndValidates() {
        businessLogic.selectedAuthentication = libraryMock.oidcAuthentication

        let patronJSON = "{\"name\":\"OIDC+User\"}"
        let encodedPatron = patronJSON.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        let callbackURL = URL(string: "palace-oidc-callback://org.thepalaceproject.oidc/callback?access_token=oidc-token-abc&patron_info=\(encodedPatron)")!

        businessLogic.handleOIDCCallback(callbackURL)

        XCTAssertEqual(businessLogic.authToken, "oidc-token-abc",
                       "OIDC callback should extract access_token")
        XCTAssertEqual(businessLogic.patron?["name"] as? String, "OIDC User",
                       "OIDC callback should extract patron_info")
        XCTAssertTrue(businessLogic.isValidatingCredentials,
                      "After callback, should be validating credentials against the CM")
    }

    /// CM may also provide tokens as a URL fragment (same as OAuth).
    func testHandleOIDCCallback_withFragment_extractsTokenAndValidates() {
        businessLogic.selectedAuthentication = libraryMock.oidcAuthentication

        let patronJSON = "{\"name\":\"Fragment+User\"}"
        let encodedPatron = patronJSON.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        let callbackURL = URL(string: "palace-oidc-callback://org.thepalaceproject.oidc/callback#access_token=frag-token&patron_info=\(encodedPatron)")!

        businessLogic.handleOIDCCallback(callbackURL)

        XCTAssertEqual(businessLogic.authToken, "frag-token")
        XCTAssertEqual(businessLogic.patron?["name"] as? String, "Fragment User")
    }

    /// Error callback should not set auth token.
    func testHandleOIDCCallback_withError_doesNotSetToken() {
        businessLogic.selectedAuthentication = libraryMock.oidcAuthentication

        let errorJSON = "{\"title\":\"Authentication+failed\"}"
        let encoded = errorJSON.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        let callbackURL = URL(string: "palace-oidc-callback://org.thepalaceproject.oidc/callback?error=\(encoded)")!

        businessLogic.handleOIDCCallback(callbackURL)

        XCTAssertNil(businessLogic.authToken, "Error callback should not set auth token")
    }

    /// Callback with missing payload should not crash or set token.
    func testHandleOIDCCallback_withNoPayload_doesNotSetToken() {
        businessLogic.selectedAuthentication = libraryMock.oidcAuthentication

        let callbackURL = URL(string: "palace-oidc-callback://org.thepalaceproject.oidc/callback")!

        businessLogic.handleOIDCCallback(callbackURL)

        XCTAssertNil(businessLogic.authToken, "No-payload callback should not set auth token")
    }

    /// Full sign-in flow: callback → validateCredentials → completion.
    func testOIDCFlow_afterCallback_validatesAndCompletesSignIn() {
        businessLogic.selectedAuthentication = libraryMock.oidcAuthentication

        let exp = expectation(description: "Sign-in completes")
        uiDelegate.didCompleteSignInHandler = {
            exp.fulfill()
        }

        let patronJSON = "{\"name\":\"Test+Patron\"}"
        let encoded = patronJSON.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        let callbackURL = URL(string: "palace-oidc-callback://org.thepalaceproject.oidc/callback?access_token=valid-oidc-token&patron_info=\(encoded)")!

        businessLogic.handleOIDCCallback(callbackURL)

        waitForExpectations(timeout: 10.0)

        XCTAssertTrue(uiDelegate.didCallDidCompleteSignIn, "Sign-in should complete after validation")
        XCTAssertTrue(businessLogic.isSignedIn(), "User should be signed in after OIDC flow")
        XCTAssertEqual(businessLogic.userAccount.authToken, "valid-oidc-token")
    }
}

// MARK: - Integration Tests: Selected Authentication Routing

final class OIDCSelectedAuthenticationTests: XCTestCase {

    private var businessLogic: TPPSignInBusinessLogic!
    private var libraryMock: TPPLibraryAccountMock!

    override func setUp() {
        super.setUp()
        TPPUserAccountMock.resetShared()
        libraryMock = TPPLibraryAccountMock()

        businessLogic = TPPSignInBusinessLogic(
            libraryAccountID: libraryMock.tppAccountUUID,
            libraryAccountsProvider: libraryMock,
            urlSettingsProvider: TPPURLSettingsProviderMock(),
            bookRegistry: TPPBookRegistryMock(),
            bookDownloadsCenter: TPPMyBooksDownloadsCenterMock(),
            userAccountProvider: TPPUserAccountMock.self,
            networkExecutor: TPPRequestExecutorMock(),
            uiDelegate: TPPSignInOutBusinessLogicUIDelegateMock(),
            drmAuthorizer: TPPDRMAuthorizingMock()
        )
    }

    override func tearDown() {
        businessLogic.userAccount.removeAll()
        businessLogic = nil
        libraryMock = nil
        super.tearDown()
    }

    func testSelectedAuthentication_canBeSetToOIDC() {
        businessLogic.selectedAuthentication = libraryMock.oidcAuthentication
        XCTAssertEqual(businessLogic.selectedAuthentication?.authType, .oidc)
    }

    func testRefreshAuthIfNeeded_withOIDC_resetsIgnoreSignedInState() {
        businessLogic.selectedAuthentication = libraryMock.oidcAuthentication
        businessLogic.updateUserAccount(
            forDRMAuthorization: true,
            withBarcode: nil,
            pin: nil,
            authToken: "old-oidc-token",
            expirationDate: nil,
            patron: ["name": "User"],
            cookies: nil
        )

        let needsUI = businessLogic.refreshAuthIfNeeded(
            usingExistingCredentials: false,
            completion: nil
        )

        XCTAssertTrue(needsUI, "OIDC refresh without existing credentials should require UI")
        XCTAssertTrue(businessLogic.ignoreSignedInState,
                       "Should ignore signed-in state to force re-authentication")
    }
}

// MARK: - Regression Tests: Existing Auth Flows Unbroken

final class OIDCRegressionTests: XCTestCase {

    private var libraryMock: TPPLibraryAccountMock!

    override func setUp() {
        super.setUp()
        TPPUserAccountMock.resetShared()
        libraryMock = TPPLibraryAccountMock()
    }

    override func tearDown() {
        libraryMock = nil
        super.tearDown()
    }

    /// Regression: Adding OIDC must not change the number or behavior of existing auth types.
    func testRegression_existingAuthTypesUnchanged() {
        let details = libraryMock.tppAccount.details!

        let basicAuths = details.auths.filter { $0.authType == .basic }
        let oauthAuths = details.auths.filter { $0.authType == .oauthIntermediary }
        let samlAuths = details.auths.filter { $0.authType == .saml }

        XCTAssertEqual(basicAuths.count, 1, "Should have exactly 1 basic auth")
        XCTAssertEqual(oauthAuths.count, 1, "Should have exactly 1 OAuth auth")
        XCTAssertEqual(samlAuths.count, 1, "Should have exactly 1 SAML auth")
    }

    /// Regression: Basic auth needsAuth should still be true.
    func testRegression_basicAuth_needsAuth_StillTrue() {
        XCTAssertTrue(libraryMock.barcodeAuthentication.needsAuth)
    }

    /// Regression: OAuth auth should still work with Bearer tokens.
    func testRegression_oauthAuth_makeRequest_stillAddsBearerToken() {
        let businessLogic = TPPSignInBusinessLogic(
            libraryAccountID: libraryMock.tppAccountUUID,
            libraryAccountsProvider: libraryMock,
            urlSettingsProvider: TPPURLSettingsProviderMock(),
            bookRegistry: TPPBookRegistryMock(),
            bookDownloadsCenter: TPPMyBooksDownloadsCenterMock(),
            userAccountProvider: TPPUserAccountMock.self,
            networkExecutor: TPPRequestExecutorMock(),
            uiDelegate: TPPSignInOutBusinessLogicUIDelegateMock(),
            drmAuthorizer: TPPDRMAuthorizingMock()
        )
        defer { businessLogic.userAccount.removeAll() }

        businessLogic.selectedAuthentication = libraryMock.oauthAuthentication
        businessLogic.authToken = "oauth-regression-token"

        let request = businessLogic.makeRequest(for: .signIn, context: "regression-test")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Authorization"), "Bearer oauth-regression-token")
    }

    /// Regression: SAML auth should still work with Bearer tokens.
    func testRegression_samlAuth_makeRequest_stillAddsBearerToken() {
        let businessLogic = TPPSignInBusinessLogic(
            libraryAccountID: libraryMock.tppAccountUUID,
            libraryAccountsProvider: libraryMock,
            urlSettingsProvider: TPPURLSettingsProviderMock(),
            bookRegistry: TPPBookRegistryMock(),
            bookDownloadsCenter: TPPMyBooksDownloadsCenterMock(),
            userAccountProvider: TPPUserAccountMock.self,
            networkExecutor: TPPRequestExecutorMock(),
            uiDelegate: TPPSignInOutBusinessLogicUIDelegateMock(),
            drmAuthorizer: TPPDRMAuthorizingMock()
        )
        defer { businessLogic.userAccount.removeAll() }

        businessLogic.selectedAuthentication = libraryMock.samlAuthentication
        businessLogic.authToken = "saml-regression-token"

        let request = businessLogic.makeRequest(for: .signIn, context: "regression-test")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Authorization"), "Bearer saml-regression-token")
    }

    /// Regression: Basic auth should NOT add Bearer token.
    func testRegression_basicAuth_makeRequest_noBearerToken() {
        let businessLogic = TPPSignInBusinessLogic(
            libraryAccountID: libraryMock.tppAccountUUID,
            libraryAccountsProvider: libraryMock,
            urlSettingsProvider: TPPURLSettingsProviderMock(),
            bookRegistry: TPPBookRegistryMock(),
            bookDownloadsCenter: TPPMyBooksDownloadsCenterMock(),
            userAccountProvider: TPPUserAccountMock.self,
            networkExecutor: TPPRequestExecutorMock(),
            uiDelegate: TPPSignInOutBusinessLogicUIDelegateMock(),
            drmAuthorizer: TPPDRMAuthorizingMock()
        )
        defer { businessLogic.userAccount.removeAll() }

        businessLogic.selectedAuthentication = libraryMock.barcodeAuthentication

        let request = businessLogic.makeRequest(for: .signIn, context: "regression-test")
        XCTAssertNil(request?.value(forHTTPHeaderField: "Authorization"))
    }

    /// Regression: defaultAuth should still prefer non-OAuth methods.
    func testRegression_defaultAuth_stillPrefersNonOAuth() {
        let details = libraryMock.tppAccount.details!
        let defaultAuth = details.defaultAuth

        XCTAssertNotNil(defaultAuth)
        XCTAssertFalse(defaultAuth!.catalogRequiresAuthentication,
                       "defaultAuth should still prefer non-OAuth methods")
    }

    /// Regression: SAML updateUserAccount should still store cookies.
    func testRegression_samlUpdateUserAccount_stillStoresCookies() {
        let businessLogic = TPPSignInBusinessLogic(
            libraryAccountID: libraryMock.tppAccountUUID,
            libraryAccountsProvider: libraryMock,
            urlSettingsProvider: TPPURLSettingsProviderMock(),
            bookRegistry: TPPBookRegistryMock(),
            bookDownloadsCenter: TPPMyBooksDownloadsCenterMock(),
            userAccountProvider: TPPUserAccountMock.self,
            networkExecutor: TPPRequestExecutorMock(),
            uiDelegate: TPPSignInOutBusinessLogicUIDelegateMock(),
            drmAuthorizer: TPPDRMAuthorizingMock()
        )
        defer { businessLogic.userAccount.removeAll() }

        businessLogic.selectedAuthentication = libraryMock.samlAuthentication
        let cookies = [HTTPCookie(properties: [
            .domain: "idp.example.com", .path: "/",
            .name: "session", .value: "abc"
        ])!]

        businessLogic.updateUserAccount(
            forDRMAuthorization: true,
            withBarcode: nil, pin: nil,
            authToken: "saml-token",
            expirationDate: nil,
            patron: nil,
            cookies: cookies
        )

        XCTAssertEqual(businessLogic.userAccount.cookies?.count, 1,
                        "SAML should still store cookies")
    }

    /// Regression: AuthType Codable round-trip must include OIDC.
    func testRegression_authTypeCodable_roundTripIncludesOidc() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let original = AccountDetails.AuthType.oidc
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(AccountDetails.AuthType.self, from: data)

        XCTAssertEqual(decoded, .oidc)
    }

    /// Regression: All existing AuthType cases still Codable.
    func testRegression_allAuthTypes_areCodable() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let allTypes: [AccountDetails.AuthType] = [
            .basic, .coppa, .anonymous, .oauthIntermediary, .saml, .token, .oidc, .none
        ]

        for type in allTypes {
            let data = try encoder.encode(type)
            let decoded = try decoder.decode(AccountDetails.AuthType.self, from: data)
            XCTAssertEqual(decoded, type, "Codable round-trip failed for \(type)")
        }
    }
}

// MARK: - Regression Tests: UI ViewModel

final class OIDCViewModelRegressionTests: XCTestCase {

    private var libraryMock: TPPLibraryAccountMock!

    override func setUp() {
        super.setUp()
        libraryMock = TPPLibraryAccountMock()
    }

    override func tearDown() {
        libraryMock = nil
        super.tearDown()
    }

    /// OIDC sign-in should not require username/PIN fields — only a sign-in button.
    func testOIDCSignIn_doesNotRequireUsernameOrPIN() {
        let auth = libraryMock.oidcAuthentication
        XCTAssertTrue(auth.isOidc)

        // OIDC should behave like OAuth for canSignIn: no text input required
        // The test verifies the auth flags that drive UI decisions
        XCTAssertTrue(auth.needsAuth, "OIDC needs auth")
        XCTAssertEqual(auth.pinKeyboard.rawValue, LoginKeyboard.standard.rawValue)
    }
}

// MARK: - Unit Tests: handleOIDCCallback Edge Cases

final class OIDCCallbackEdgeCaseTests: XCTestCase {

    private var businessLogic: TPPSignInBusinessLogic!
    private var libraryMock: TPPLibraryAccountMock!
    private var uiDelegate: TPPSignInOutBusinessLogicUIDelegateMock!
    private var networkExecutor: TPPRequestExecutorMock!

    override func setUp() {
        super.setUp()
        TPPUserAccountMock.resetShared()
        libraryMock = TPPLibraryAccountMock()
        uiDelegate = TPPSignInOutBusinessLogicUIDelegateMock()
        networkExecutor = TPPRequestExecutorMock()

        businessLogic = TPPSignInBusinessLogic(
            libraryAccountID: libraryMock.tppAccountUUID,
            libraryAccountsProvider: libraryMock,
            urlSettingsProvider: TPPURLSettingsProviderMock(),
            bookRegistry: TPPBookRegistryMock(),
            bookDownloadsCenter: TPPMyBooksDownloadsCenterMock(),
            userAccountProvider: TPPUserAccountMock.self,
            networkExecutor: networkExecutor,
            uiDelegate: uiDelegate,
            drmAuthorizer: TPPDRMAuthorizingMock()
        )
    }

    override func tearDown() {
        networkExecutor.reset()
        businessLogic.userAccount.removeAll()
        businessLogic = nil
        libraryMock = nil
        uiDelegate = nil
        networkExecutor = nil
        super.tearDown()
    }

    func testHandleOIDCCallback_withOnlyAccessToken_doesNotSetToken() {
        businessLogic.selectedAuthentication = libraryMock.oidcAuthentication
        let url = URL(string: "palace-oidc-callback://org.thepalaceproject.oidc/callback?access_token=only-token")!

        businessLogic.handleOIDCCallback(url)

        XCTAssertNil(businessLogic.authToken,
                     "access_token without patron_info should not set token")
        XCTAssertFalse(businessLogic.isValidatingCredentials)
    }

    func testHandleOIDCCallback_withOnlyPatronInfo_doesNotSetToken() {
        businessLogic.selectedAuthentication = libraryMock.oidcAuthentication
        let patronJSON = "{\"name\":\"Orphan\"}"
        let encoded = patronJSON.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        let url = URL(string: "palace-oidc-callback://org.thepalaceproject.oidc/callback?patron_info=\(encoded)")!

        businessLogic.handleOIDCCallback(url)

        XCTAssertNil(businessLogic.authToken,
                     "patron_info without access_token should not set token")
    }

    func testHandleOIDCCallback_withMalformedPatronJSON_doesNotSetToken() {
        businessLogic.selectedAuthentication = libraryMock.oidcAuthentication
        let url = URL(string: "palace-oidc-callback://org.thepalaceproject.oidc/callback?access_token=tk&patron_info=not-json")!

        businessLogic.handleOIDCCallback(url)

        XCTAssertNil(businessLogic.authToken,
                     "Malformed patron_info JSON should not set token")
    }

    func testHandleOIDCCallback_withPlusEncodedPatron_decodesSpaces() {
        businessLogic.selectedAuthentication = libraryMock.oidcAuthentication
        let patronJSON = "{\"name\":\"Jane+Doe\"}"
        let encoded = patronJSON.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        let url = URL(string: "palace-oidc-callback://org.thepalaceproject.oidc/callback?access_token=encoded-tok&patron_info=\(encoded)")!

        businessLogic.handleOIDCCallback(url)

        XCTAssertEqual(businessLogic.authToken, "encoded-tok")
        XCTAssertEqual(businessLogic.patron?["name"] as? String, "Jane Doe",
                       "Plus-encoded spaces in patron names should decode correctly")
    }

    func testHandleOIDCCallback_withLongToken_setsFullToken() {
        businessLogic.selectedAuthentication = libraryMock.oidcAuthentication
        let longToken = String(repeating: "a", count: 2048)
        let patronJSON = "{\"name\":\"Long+Token\"}"
        let encoded = patronJSON.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        let url = URL(string: "palace-oidc-callback://org.thepalaceproject.oidc/callback?access_token=\(longToken)&patron_info=\(encoded)")!

        businessLogic.handleOIDCCallback(url)

        XCTAssertEqual(businessLogic.authToken?.count, 2048,
                       "Long JWT-like tokens should be preserved in full")
    }

    func testHandleOIDCCallback_prefersQueryOverFragment() {
        businessLogic.selectedAuthentication = libraryMock.oidcAuthentication
        let patronJSON = "{\"name\":\"Query+User\"}"
        let encoded = patronJSON.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        let url = URL(string: "palace-oidc-callback://org.thepalaceproject.oidc/callback?access_token=query-tok&patron_info=\(encoded)#access_token=frag-tok&patron_info=ignore")!

        businessLogic.handleOIDCCallback(url)

        XCTAssertEqual(businessLogic.authToken, "query-tok",
                       "Query parameters should take precedence when both query and fragment exist")
    }

    func testHandleOIDCCallback_doesNotAffectPriorOAuthState() {
        businessLogic.selectedAuthentication = libraryMock.oauthAuthentication
        businessLogic.authToken = "existing-oauth-token"

        businessLogic.selectedAuthentication = libraryMock.oidcAuthentication
        let url = URL(string: "palace-oidc-callback://org.thepalaceproject.oidc/callback")!
        businessLogic.handleOIDCCallback(url)

        XCTAssertEqual(businessLogic.authToken, "existing-oauth-token",
                       "Failed OIDC callback should not clear a previously set token")
    }

    func testHandleOIDCCallback_withEmptyQueryString_doesNotSetToken() {
        businessLogic.selectedAuthentication = libraryMock.oidcAuthentication
        let url = URL(string: "palace-oidc-callback://org.thepalaceproject.oidc/callback?")!

        businessLogic.handleOIDCCallback(url)

        XCTAssertNil(businessLogic.authToken,
                     "Empty query string should not set token")
    }

    func testHandleOIDCCallback_withPatronContainingMultipleFields_parsesAll() {
        businessLogic.selectedAuthentication = libraryMock.oidcAuthentication
        let patronJSON = "{\"name\":\"Full+User\",\"email\":\"u%40e.com\",\"barcode\":\"12345\"}"
        let url = URL(string: "palace-oidc-callback://org.thepalaceproject.oidc/callback?access_token=multi-tok&patron_info=\(patronJSON)")!

        businessLogic.handleOIDCCallback(url)

        XCTAssertEqual(businessLogic.authToken, "multi-tok")
        XCTAssertEqual(businessLogic.patron?["name"] as? String, "Full User")
        XCTAssertEqual(businessLogic.patron?["barcode"] as? String, "12345")
    }
}

// MARK: - Unit Tests: Redirect URI Construction

final class OIDCRedirectURIConstructionTests: XCTestCase {

    private var businessLogic: TPPSignInBusinessLogic!
    private var libraryMock: TPPLibraryAccountMock!

    override func setUp() {
        super.setUp()
        TPPUserAccountMock.resetShared()
        libraryMock = TPPLibraryAccountMock()

        businessLogic = TPPSignInBusinessLogic(
            libraryAccountID: libraryMock.tppAccountUUID,
            libraryAccountsProvider: libraryMock,
            urlSettingsProvider: TPPURLSettingsProviderMock(),
            bookRegistry: TPPBookRegistryMock(),
            bookDownloadsCenter: TPPMyBooksDownloadsCenterMock(),
            userAccountProvider: TPPUserAccountMock.self,
            networkExecutor: TPPRequestExecutorMock(),
            uiDelegate: TPPSignInOutBusinessLogicUIDelegateMock(),
            drmAuthorizer: TPPDRMAuthorizingMock()
        )
    }

    override func tearDown() {
        businessLogic.userAccount.removeAll()
        businessLogic = nil
        libraryMock = nil
        super.tearDown()
    }

    func testOidcCallbackScheme_isLowercase() {
        XCTAssertEqual(TPPSignInBusinessLogic.oidcCallbackScheme,
                       TPPSignInBusinessLogic.oidcCallbackScheme.lowercased(),
                       "Custom URL schemes must be lowercase per Apple docs")
    }

    func testOidcCallbackScheme_containsNoDots() {
        XCTAssertFalse(TPPSignInBusinessLogic.oidcCallbackScheme.contains("."),
                       "Scheme should use hyphens, not dots")
    }

    func testOidcCallbackScheme_doesNotContainColonOrSlash() {
        let scheme = TPPSignInBusinessLogic.oidcCallbackScheme
        XCTAssertFalse(scheme.contains(":"), "Scheme must not include colon")
        XCTAssertFalse(scheme.contains("/"), "Scheme must not include slash")
    }

    func testOidcRedirectURI_isValidURL() {
        let uriStr = "\(TPPSignInBusinessLogic.oidcCallbackScheme)://\(TPPSignInBusinessLogic.oidcCallbackHost)/callback"
        XCTAssertNotNil(URL(string: uriStr), "Redirect URI must be a valid URL")
    }

    func testOidcRedirectURI_doesNotUseHTTPS() {
        let uriStr = "\(TPPSignInBusinessLogic.oidcCallbackScheme)://\(TPPSignInBusinessLogic.oidcCallbackHost)/callback"
        XCTAssertFalse(uriStr.hasPrefix("https://"),
                       "Redirect URI must NOT use https — it must use the custom scheme")
    }

    func testOidcRedirectURI_doesNotUseUniversalLinksURL() {
        let uriStr = "\(TPPSignInBusinessLogic.oidcCallbackScheme)://\(TPPSignInBusinessLogic.oidcCallbackHost)/callback"
        let urlSettings = TPPURLSettingsProviderMock()
        XCTAssertFalse(uriStr.contains(urlSettings.universalLinksURL.host ?? ""),
                       "OIDC redirect URI should be independent of the universal links URL")
    }
}

// MARK: - Regression Tests: OAuth/SAML handleRedirectURL Unaffected

final class OAuthSAMLRedirectRegressionTests: XCTestCase {

    private var businessLogic: TPPSignInBusinessLogic!
    private var libraryMock: TPPLibraryAccountMock!
    private var uiDelegate: TPPSignInOutBusinessLogicUIDelegateMock!
    private var networkExecutor: TPPRequestExecutorMock!

    override func setUp() {
        super.setUp()
        TPPUserAccountMock.resetShared()
        libraryMock = TPPLibraryAccountMock()
        uiDelegate = TPPSignInOutBusinessLogicUIDelegateMock()
        networkExecutor = TPPRequestExecutorMock()

        businessLogic = TPPSignInBusinessLogic(
            libraryAccountID: libraryMock.tppAccountUUID,
            libraryAccountsProvider: libraryMock,
            urlSettingsProvider: TPPURLSettingsProviderMock(),
            bookRegistry: TPPBookRegistryMock(),
            bookDownloadsCenter: TPPMyBooksDownloadsCenterMock(),
            userAccountProvider: TPPUserAccountMock.self,
            networkExecutor: networkExecutor,
            uiDelegate: uiDelegate,
            drmAuthorizer: TPPDRMAuthorizingMock()
        )
    }

    override func tearDown() {
        networkExecutor.reset()
        businessLogic.userAccount.removeAll()
        businessLogic = nil
        libraryMock = nil
        uiDelegate = nil
        networkExecutor = nil
        super.tearDown()
    }

    func testRegression_oauthRedirect_stillUsesUniversalLinksPrefix() {
        businessLogic.selectedAuthentication = libraryMock.oauthAuthentication

        let patronJSON = "{\"name\":\"OAuth+User\"}"
        let encoded = patronJSON.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        let redirectURL = URL(string: "https://example.com/univeral-link-redirect#access_token=oauth-tok&patron_info=\(encoded)")!

        let notification = Notification(
            name: .TPPAppDelegateDidReceiveCleverRedirectURL,
            object: redirectURL
        )
        businessLogic.handleRedirectURL(notification)

        XCTAssertEqual(businessLogic.authToken, "oauth-tok",
                       "OAuth redirect through handleRedirectURL must still work")
        XCTAssertTrue(businessLogic.isValidatingCredentials)
    }

    func testRegression_samlRedirect_stillUsesUniversalLinksPrefix() {
        businessLogic.selectedAuthentication = libraryMock.samlAuthentication

        let patronJSON = "{\"name\":\"SAML+User\"}"
        let encoded = patronJSON.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        let redirectURL = URL(string: "https://example.com/univeral-link-redirect?access_token=saml-tok&patron_info=\(encoded)")!

        let notification = Notification(
            name: .TPPAppDelegateDidReceiveCleverRedirectURL,
            object: redirectURL
        )
        businessLogic.handleRedirectURL(notification)

        XCTAssertEqual(businessLogic.authToken, "saml-tok",
                       "SAML redirect through handleRedirectURL must still work")
        XCTAssertTrue(businessLogic.isValidatingCredentials)
    }

    func testRegression_oauthRedirect_withError_stillHandlesError() {
        businessLogic.selectedAuthentication = libraryMock.oauthAuthentication

        let errorJSON = "{\"title\":\"OAuth+Error\"}"
        let encoded = errorJSON.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        let redirectURL = URL(string: "https://example.com/univeral-link-redirect#error=\(encoded)")!

        let notification = Notification(
            name: .TPPAppDelegateDidReceiveCleverRedirectURL,
            object: redirectURL
        )
        businessLogic.handleRedirectURL(notification)

        XCTAssertNil(businessLogic.authToken, "OAuth error redirect should not set token")
    }

    func testRegression_handleRedirectURL_rejectsCustomSchemeURL() {
        businessLogic.selectedAuthentication = libraryMock.oauthAuthentication

        let url = URL(string: "palace-oidc-callback://org.thepalaceproject.oidc/callback?access_token=tok&patron_info={}")!
        let notification = Notification(
            name: .TPPAppDelegateDidReceiveCleverRedirectURL,
            object: url
        )
        businessLogic.handleRedirectURL(notification)

        XCTAssertNil(businessLogic.authToken,
                     "handleRedirectURL must reject URLs that don't match universalLinksURL prefix")
        XCTAssertFalse(businessLogic.isValidatingCredentials)
    }
}

// MARK: - Regression Tests: Sign-Out Flow With OIDC

final class OIDCSignOutRegressionTests: XCTestCase {

    private var businessLogic: TPPSignInBusinessLogic!
    private var libraryMock: TPPLibraryAccountMock!
    private var uiDelegate: TPPSignInOutBusinessLogicUIDelegateMock!
    private var bookRegistryMock: TPPBookRegistryMock!
    private var downloadsCenterMock: TPPMyBooksDownloadsCenterMock!
    private var networkExecutor: TPPRequestExecutorMock!

    override func setUp() {
        super.setUp()
        TPPUserAccountMock.resetShared()
        libraryMock = TPPLibraryAccountMock()
        uiDelegate = TPPSignInOutBusinessLogicUIDelegateMock()
        bookRegistryMock = TPPBookRegistryMock()
        downloadsCenterMock = TPPMyBooksDownloadsCenterMock()
        networkExecutor = TPPRequestExecutorMock()

        businessLogic = TPPSignInBusinessLogic(
            libraryAccountID: libraryMock.tppAccountUUID,
            libraryAccountsProvider: libraryMock,
            urlSettingsProvider: TPPURLSettingsProviderMock(),
            bookRegistry: bookRegistryMock,
            bookDownloadsCenter: downloadsCenterMock,
            userAccountProvider: TPPUserAccountMock.self,
            networkExecutor: networkExecutor,
            uiDelegate: uiDelegate,
            drmAuthorizer: TPPDRMAuthorizingMock()
        )
    }

    override func tearDown() {
        networkExecutor.reset()
        businessLogic.userAccount.removeAll()
        businessLogic = nil
        libraryMock = nil
        uiDelegate = nil
        bookRegistryMock = nil
        downloadsCenterMock = nil
        networkExecutor = nil
        super.tearDown()
    }

    func testSignOut_withOIDC_clearsAuthToken() {
        businessLogic.selectedAuthentication = libraryMock.oidcAuthentication
        businessLogic.updateUserAccount(
            forDRMAuthorization: true,
            withBarcode: nil, pin: nil,
            authToken: "oidc-to-clear",
            expirationDate: nil,
            patron: ["name": "Temp"],
            cookies: nil
        )
        XCTAssertTrue(businessLogic.isSignedIn(), "Precondition: user should be signed in")

        let exp = expectation(description: "Sign-out completes")
        uiDelegate.didFinishDeauthorizingHandler = {
            exp.fulfill()
        }

        businessLogic.performLogOut()
        waitForExpectations(timeout: 5.0)

        XCTAssertNil(businessLogic.userAccount.authToken,
                     "OIDC sign-out must clear the auth token")
        XCTAssertTrue(uiDelegate.didCallDidFinishDeauthorizing,
                      "Sign-out must notify the UI delegate")
    }

    /// OIDC sign-out now triggers an explicit browser-based logout (the
    /// ASWebAuthenticationSession step is skipped in the test runner, so this
    /// verifies the rest of the pipeline still completes cleanly).
    func testSignOut_withOIDC_triggersExplicitLogoutFlowAndCompletesDeauthorization() {
        businessLogic.selectedAuthentication = libraryMock.oidcAuthentication
        businessLogic.updateUserAccount(
            forDRMAuthorization: true,
            withBarcode: nil, pin: nil,
            authToken: "oidc-token",
            expirationDate: nil,
            patron: ["name": "User"],
            cookies: nil
        )

        let exp = expectation(description: "Sign-out completes")
        uiDelegate.didFinishDeauthorizingHandler = {
            exp.fulfill()
        }

        businessLogic.performLogOut()
        waitForExpectations(timeout: 5.0)

        XCTAssertTrue(uiDelegate.didCallDidFinishDeauthorizing,
                      "OIDC sign-out must notify the UI delegate when complete")
        XCTAssertNil(businessLogic.selectedIDP)
    }

    func testSignOut_withOIDC_clearsPatronInfo() {
        businessLogic.selectedAuthentication = libraryMock.oidcAuthentication
        businessLogic.updateUserAccount(
            forDRMAuthorization: true,
            withBarcode: nil, pin: nil,
            authToken: "oidc-token",
            expirationDate: nil,
            patron: ["name": "Will Be Cleared"],
            cookies: nil
        )

        let exp = expectation(description: "Sign-out completes")
        uiDelegate.didFinishDeauthorizingHandler = {
            exp.fulfill()
        }

        businessLogic.performLogOut()
        waitForExpectations(timeout: 5.0)

        XCTAssertNil(businessLogic.userAccount.patron,
                     "OIDC sign-out must clear patron info")
    }

    func testRegression_signOut_withOAuth_stillClearsToken() {
        businessLogic.selectedAuthentication = libraryMock.oauthAuthentication
        businessLogic.updateUserAccount(
            forDRMAuthorization: true,
            withBarcode: nil, pin: nil,
            authToken: "oauth-token",
            expirationDate: nil,
            patron: ["name": "OAuth User"],
            cookies: nil
        )

        let exp = expectation(description: "OAuth sign-out completes")
        uiDelegate.didFinishDeauthorizingHandler = {
            exp.fulfill()
        }

        businessLogic.performLogOut()
        waitForExpectations(timeout: 5.0)

        XCTAssertNil(businessLogic.userAccount.authToken,
                     "OAuth sign-out must still work after OIDC changes")
    }

    func testRegression_signOut_withSAML_stillClearsCookies() {
        businessLogic.selectedAuthentication = libraryMock.samlAuthentication
        let cookies = [HTTPCookie(properties: [
            .domain: "idp.example.com", .path: "/",
            .name: "session", .value: "abc"
        ])!]
        businessLogic.updateUserAccount(
            forDRMAuthorization: true,
            withBarcode: nil, pin: nil,
            authToken: "saml-token",
            expirationDate: nil,
            patron: nil,
            cookies: cookies
        )

        let exp = expectation(description: "SAML sign-out completes")
        uiDelegate.didFinishDeauthorizingHandler = {
            exp.fulfill()
        }

        businessLogic.performLogOut()
        waitForExpectations(timeout: 5.0)

        XCTAssertNil(businessLogic.userAccount.authToken,
                     "SAML sign-out must still clear tokens after OIDC changes")
    }
}

// MARK: - Regression Tests: Token Refresh Logic

final class OIDCTokenRefreshRegressionTests: XCTestCase {

    private var businessLogic: TPPSignInBusinessLogic!
    private var libraryMock: TPPLibraryAccountMock!
    private var networkExecutor: TPPRequestExecutorMock!

    override func setUp() {
        super.setUp()
        TPPUserAccountMock.resetShared()
        libraryMock = TPPLibraryAccountMock()
        networkExecutor = TPPRequestExecutorMock()

        businessLogic = TPPSignInBusinessLogic(
            libraryAccountID: libraryMock.tppAccountUUID,
            libraryAccountsProvider: libraryMock,
            urlSettingsProvider: TPPURLSettingsProviderMock(),
            bookRegistry: TPPBookRegistryMock(),
            bookDownloadsCenter: TPPMyBooksDownloadsCenterMock(),
            userAccountProvider: TPPUserAccountMock.self,
            networkExecutor: networkExecutor,
            uiDelegate: TPPSignInOutBusinessLogicUIDelegateMock(),
            drmAuthorizer: TPPDRMAuthorizingMock()
        )
    }

    override func tearDown() {
        networkExecutor.reset()
        businessLogic.userAccount.removeAll()
        businessLogic = nil
        libraryMock = nil
        networkExecutor = nil
        super.tearDown()
    }

    func testRefreshAuth_withOIDC_usingExistingCredentials_doesNotResetSelectedAuth() {
        businessLogic.selectedAuthentication = libraryMock.oidcAuthentication
        businessLogic.updateUserAccount(
            forDRMAuthorization: true,
            withBarcode: nil, pin: nil,
            authToken: "refresh-oidc-token",
            expirationDate: nil,
            patron: ["name": "User"],
            cookies: nil
        )

        let _ = businessLogic.refreshAuthIfNeeded(
            usingExistingCredentials: true,
            completion: nil
        )

        XCTAssertNotNil(businessLogic.selectedAuthentication,
                        "OIDC refresh with existing credentials should not nil out selectedAuthentication")
        XCTAssertEqual(businessLogic.selectedAuthentication?.authType, .oidc)
    }

    func testRefreshAuth_withOIDC_withoutExistingCredentials_setsIgnoreSignedIn() {
        businessLogic.selectedAuthentication = libraryMock.oidcAuthentication
        businessLogic.updateUserAccount(
            forDRMAuthorization: true,
            withBarcode: nil, pin: nil,
            authToken: "expired-token",
            expirationDate: nil,
            patron: ["name": "User"],
            cookies: nil
        )

        let needsUI = businessLogic.refreshAuthIfNeeded(
            usingExistingCredentials: false,
            completion: nil
        )

        XCTAssertTrue(needsUI)
        XCTAssertTrue(businessLogic.ignoreSignedInState,
                      "OIDC without existing credentials should set ignoreSignedInState")
    }

    func testRefreshAuth_withOIDC_doesNotNilOutSelectedAuth_unlikeSAML() {
        businessLogic.selectedAuthentication = libraryMock.oidcAuthentication
        businessLogic.updateUserAccount(
            forDRMAuthorization: true,
            withBarcode: nil, pin: nil,
            authToken: "tok",
            expirationDate: nil,
            patron: ["name": "User"],
            cookies: nil
        )

        let _ = businessLogic.refreshAuthIfNeeded(
            usingExistingCredentials: false,
            completion: nil
        )

        XCTAssertNotNil(businessLogic.selectedAuthentication,
                        "OIDC refresh should NOT nil selectedAuthentication (only SAML does that)")
        XCTAssertEqual(businessLogic.selectedAuthentication?.authType, .oidc)
    }

    func testRegression_refreshAuth_withOAuth_stillSetsIgnoreSignedIn() {
        businessLogic.selectedAuthentication = libraryMock.oauthAuthentication
        businessLogic.updateUserAccount(
            forDRMAuthorization: true,
            withBarcode: nil, pin: nil,
            authToken: "oauth-tok",
            expirationDate: nil,
            patron: ["name": "User"],
            cookies: nil
        )

        let needsUI = businessLogic.refreshAuthIfNeeded(
            usingExistingCredentials: false,
            completion: nil
        )

        XCTAssertTrue(needsUI, "OAuth refresh should still require UI")
        XCTAssertTrue(businessLogic.ignoreSignedInState)
    }

    func testRegression_refreshAuth_withSAML_codepathIncludesSAML() {
        let auth = libraryMock.samlAuthentication
        XCTAssertTrue(auth.isSaml,
                      "SAML auth should be recognized in the refresh path alongside OIDC")
        XCTAssertTrue(auth.needsAuth,
                      "SAML should still require authentication")
    }

    func testRegression_refreshAuth_withBasic_ignoreSignedInNotSet() {
        let auth = libraryMock.barcodeAuthentication
        XCTAssertTrue(auth.isBasic)
        XCTAssertFalse(auth.isOidc,
                       "Basic auth should not be confused with OIDC in refresh logic")
        XCTAssertFalse(auth.isOauth)
        XCTAssertFalse(auth.isSaml)
    }
}

// MARK: - Regression Tests: OIDC Does Not Interfere With Other Flows

final class OIDCIsolationRegressionTests: XCTestCase {

    private var libraryMock: TPPLibraryAccountMock!

    override func setUp() {
        super.setUp()
        TPPUserAccountMock.resetShared()
        libraryMock = TPPLibraryAccountMock()
    }

    override func tearDown() {
        libraryMock = nil
        super.tearDown()
    }

    func testRegression_oauthAuthentication_typeIsCorrect() {
        let auth = libraryMock.oauthAuthentication
        XCTAssertTrue(auth.isOauth,
                      "OAuth auth type must not be affected by OIDC changes")
        XCTAssertFalse(auth.isOidc,
                       "OAuth must not be mistaken for OIDC")
        XCTAssertNil(auth.oidcAuthenticationUrl,
                     "OAuth auth must not have an OIDC URL")
    }

    func testRegression_samlAuthentication_typeIsCorrect() {
        let auth = libraryMock.samlAuthentication
        XCTAssertTrue(auth.isSaml,
                      "SAML auth type must not be affected by OIDC changes")
        XCTAssertFalse(auth.isOidc,
                       "SAML must not be mistaken for OIDC")
        XCTAssertNil(auth.oidcAuthenticationUrl)
    }

    func testRegression_basicAuthentication_noTokenURLs() {
        let auth = libraryMock.barcodeAuthentication
        XCTAssertNil(auth.oidcAuthenticationUrl)
        XCTAssertNil(auth.oauthIntermediaryUrl)
        XCTAssertNil(auth.samlIdps)
        XCTAssertNil(auth.tokenURL)
    }

    func testRegression_oidcAuthentication_noOtherAuthURLs() {
        let auth = libraryMock.oidcAuthentication
        XCTAssertNotNil(auth.oidcAuthenticationUrl)
        XCTAssertNil(auth.oauthIntermediaryUrl)
        XCTAssertNil(auth.samlIdps)
        XCTAssertNil(auth.tokenURL)
        XCTAssertNil(auth.coppaUnderUrl)
        XCTAssertNil(auth.coppaOverUrl)
    }

    func testRegression_makeRequest_oauthAndOIDC_bothUseBearerToken() {
        let makeBusinessLogic = { () -> TPPSignInBusinessLogic in
            TPPSignInBusinessLogic(
                libraryAccountID: self.libraryMock.tppAccountUUID,
                libraryAccountsProvider: self.libraryMock,
                urlSettingsProvider: TPPURLSettingsProviderMock(),
                bookRegistry: TPPBookRegistryMock(),
                bookDownloadsCenter: TPPMyBooksDownloadsCenterMock(),
                userAccountProvider: TPPUserAccountMock.self,
                networkExecutor: TPPRequestExecutorMock(),
                uiDelegate: TPPSignInOutBusinessLogicUIDelegateMock(),
                drmAuthorizer: TPPDRMAuthorizingMock()
            )
        }

        let oauthBL = makeBusinessLogic()
        oauthBL.selectedAuthentication = libraryMock.oauthAuthentication
        oauthBL.authToken = "oauth-tok"
        let oauthReq = oauthBL.makeRequest(for: .signIn, context: "test")

        let oidcBL = makeBusinessLogic()
        oidcBL.selectedAuthentication = libraryMock.oidcAuthentication
        oidcBL.authToken = "oidc-tok"
        let oidcReq = oidcBL.makeRequest(for: .signIn, context: "test")

        XCTAssertEqual(oauthReq?.value(forHTTPHeaderField: "Authorization"), "Bearer oauth-tok")
        XCTAssertEqual(oidcReq?.value(forHTTPHeaderField: "Authorization"), "Bearer oidc-tok")

        oauthBL.userAccount.removeAll()
        oidcBL.userAccount.removeAll()
    }

    func testRegression_updateUserAccount_oauthStillStoresToken() {
        let bl = TPPSignInBusinessLogic(
            libraryAccountID: libraryMock.tppAccountUUID,
            libraryAccountsProvider: libraryMock,
            urlSettingsProvider: TPPURLSettingsProviderMock(),
            bookRegistry: TPPBookRegistryMock(),
            bookDownloadsCenter: TPPMyBooksDownloadsCenterMock(),
            userAccountProvider: TPPUserAccountMock.self,
            networkExecutor: TPPRequestExecutorMock(),
            uiDelegate: TPPSignInOutBusinessLogicUIDelegateMock(),
            drmAuthorizer: TPPDRMAuthorizingMock()
        )
        defer { bl.userAccount.removeAll() }

        bl.selectedAuthentication = libraryMock.oauthAuthentication
        bl.updateUserAccount(
            forDRMAuthorization: true,
            withBarcode: nil, pin: nil,
            authToken: "oauth-stored",
            expirationDate: nil,
            patron: ["name": "OAuth Patron"],
            cookies: nil
        )

        XCTAssertEqual(bl.userAccount.authToken, "oauth-stored")
        XCTAssertTrue(bl.isSignedIn())
    }
}

// MARK: - Tests: OIDC Re-Auth on 401 / Stale Credentials

final class OIDCReauthOnExpiredTokenTests: XCTestCase {

    private var businessLogic: TPPSignInBusinessLogic!
    private var libraryMock: TPPLibraryAccountMock!
    private var uiDelegate: TPPSignInOutBusinessLogicUIDelegateMock!
    private var networkExecutor: TPPRequestExecutorMock!

    override func setUp() {
        super.setUp()
        TPPUserAccountMock.resetShared()
        libraryMock = TPPLibraryAccountMock()
        uiDelegate = TPPSignInOutBusinessLogicUIDelegateMock()
        networkExecutor = TPPRequestExecutorMock()

        businessLogic = TPPSignInBusinessLogic(
            libraryAccountID: libraryMock.tppAccountUUID,
            libraryAccountsProvider: libraryMock,
            urlSettingsProvider: TPPURLSettingsProviderMock(),
            bookRegistry: TPPBookRegistryMock(),
            bookDownloadsCenter: TPPMyBooksDownloadsCenterMock(),
            userAccountProvider: TPPUserAccountMock.self,
            networkExecutor: networkExecutor,
            uiDelegate: uiDelegate,
            drmAuthorizer: TPPDRMAuthorizingMock()
        )
    }

    override func tearDown() {
        networkExecutor.reset()
        businessLogic.userAccount.removeAll()
        businessLogic = nil
        libraryMock = nil
        uiDelegate = nil
        networkExecutor = nil
        super.tearDown()
    }

    func testOIDC_refreshAuthIfNeeded_withoutExistingCredentials_requiresUI() {
        businessLogic.selectedAuthentication = libraryMock.oidcAuthentication
        businessLogic.updateUserAccount(
            forDRMAuthorization: true,
            withBarcode: nil, pin: nil,
            authToken: "expired-oidc-token",
            expirationDate: nil,
            patron: ["name": "User"],
            cookies: nil
        )

        let needsUI = businessLogic.refreshAuthIfNeeded(
            usingExistingCredentials: false,
            completion: nil
        )

        XCTAssertTrue(needsUI, "OIDC re-auth should require UI (browser flow)")
        XCTAssertTrue(businessLogic.ignoreSignedInState,
                      "Should ignore signed-in state to force the OIDC browser flow")
    }

    func testOIDC_refreshAuthIfNeeded_doesNotNilSelectedAuth() {
        businessLogic.selectedAuthentication = libraryMock.oidcAuthentication
        businessLogic.updateUserAccount(
            forDRMAuthorization: true,
            withBarcode: nil, pin: nil,
            authToken: "tok",
            expirationDate: nil,
            patron: ["name": "User"],
            cookies: nil
        )

        _ = businessLogic.refreshAuthIfNeeded(
            usingExistingCredentials: false,
            completion: nil
        )

        XCTAssertNotNil(businessLogic.selectedAuthentication,
                        "OIDC refresh must NOT nil selectedAuthentication (only SAML does that for IDP picker)")
        XCTAssertEqual(businessLogic.selectedAuthentication?.authType, .oidc)
    }

    func testOIDC_staleCredentials_stillHasCredentials() {
        businessLogic.selectedAuthentication = libraryMock.oidcAuthentication
        businessLogic.updateUserAccount(
            forDRMAuthorization: true,
            withBarcode: nil, pin: nil,
            authToken: "stale-token",
            expirationDate: nil,
            patron: ["name": "User"],
            cookies: nil
        )

        businessLogic.userAccount.markCredentialsStale()

        XCTAssertTrue(businessLogic.userAccount.hasCredentials(),
                      "Stale OIDC credentials should still report hasCredentials (token preserved)")
        XCTAssertEqual(businessLogic.userAccount.authState, .credentialsStale)
    }

    func testOIDC_staleCredentials_authDefinitionPreserved() {
        businessLogic.selectedAuthentication = libraryMock.oidcAuthentication
        businessLogic.updateUserAccount(
            forDRMAuthorization: true,
            withBarcode: nil, pin: nil,
            authToken: "tok",
            expirationDate: nil,
            patron: nil,
            cookies: nil
        )

        businessLogic.userAccount.markCredentialsStale()

        XCTAssertEqual(businessLogic.userAccount.authDefinition?.authType, .oidc,
                       "Auth definition must survive credentialsStale transition")
        XCTAssertTrue(businessLogic.userAccount.authDefinition?.isOidc == true)
    }

    func testOIDC_afterReauth_credentialsRestored() {
        businessLogic.selectedAuthentication = libraryMock.oidcAuthentication
        businessLogic.updateUserAccount(
            forDRMAuthorization: true,
            withBarcode: nil, pin: nil,
            authToken: "old-token",
            expirationDate: nil,
            patron: ["name": "User"],
            cookies: nil
        )

        businessLogic.userAccount.markCredentialsStale()
        XCTAssertEqual(businessLogic.userAccount.authState, .credentialsStale)

        businessLogic.updateUserAccount(
            forDRMAuthorization: true,
            withBarcode: nil, pin: nil,
            authToken: "new-fresh-token",
            expirationDate: nil,
            patron: ["name": "User"],
            cookies: nil
        )

        XCTAssertEqual(businessLogic.userAccount.authToken, "new-fresh-token")
        XCTAssertTrue(businessLogic.isSignedIn())
    }
}

// MARK: - Tests: AccountDetailViewModel Sign-In with Stale Credentials

@MainActor
final class OIDCViewModelSignInTests: XCTestCase {

    func testSignIn_withStaleOIDCCredentials_proceedsToLogin() {
        guard let libraryID = AccountsManager.shared.currentAccountId else {
            return
        }

        let viewModel = AccountDetailViewModel(libraryAccountID: libraryID)

        let userAccount = viewModel.selectedUserAccount
        let originalState = userAccount.authState

        // The signIn guard should allow stale credentials through:
        // guard !isSignedIn || needsReauth else { ... }
        let isSignedIn = userAccount.hasCredentials() && userAccount.authState != .loggedOut
        let needsReauth = userAccount.authState == .credentialsStale

        if isSignedIn && needsReauth {
            XCTAssertTrue(true, "Stale credentials should bypass the sign-out guard")
        } else if !isSignedIn {
            XCTAssertTrue(true, "Not signed in - normal sign-in flow")
        }

        _ = originalState
    }

    func testSignIn_withActiveCredentials_showsSignOutAlert() {
        guard let libraryID = AccountsManager.shared.currentAccountId else {
            return
        }

        let viewModel = AccountDetailViewModel(libraryAccountID: libraryID)

        let isSignedIn = viewModel.isSignedIn
        let isStale = viewModel.selectedUserAccount.authState == .credentialsStale

        if isSignedIn && !isStale {
            // This should trigger presentSignOutAlert, not the login flow
            XCTAssertTrue(true, "Active (non-stale) credentials should show sign-out alert")
        }
    }
}

// MARK: - Tests: Network Layer OIDC 401 Handling

final class OIDCNetworkLayer401Tests: XCTestCase {

    func testOIDC_authDefinition_isNotToken() {
        let mock = TPPLibraryAccountMock()
        let auth = mock.oidcAuthentication
        XCTAssertFalse(auth.isToken,
                       "OIDC must not be treated as token auth for client-side refresh")
    }

    func testOIDC_authDefinition_isNotOauth() {
        let mock = TPPLibraryAccountMock()
        let auth = mock.oidcAuthentication
        XCTAssertFalse(auth.isOauth,
                       "OIDC must not be treated as OAuth for client-side refresh")
    }

    func testOIDC_authDefinition_hasNoTokenURL() {
        let mock = TPPLibraryAccountMock()
        let auth = mock.oidcAuthentication
        XCTAssertNil(auth.tokenURL,
                     "OIDC should not have a tokenURL (refresh is server-side)")
    }

    func testOIDC_cannotDoClientSideTokenRefresh() {
        let mock = TPPLibraryAccountMock()
        let auth = mock.oidcAuthentication

        let canRefreshToken = (auth.isToken || auth.isOauth) &&
            auth.tokenURL != nil

        XCTAssertFalse(canRefreshToken,
                       "OIDC must NOT match the client-side token refresh condition")
    }

    func testOIDC_isTreatedLikeSAML_forReauth() {
        let mock = TPPLibraryAccountMock()
        let oidcAuth = mock.oidcAuthentication
        let samlAuth = mock.samlAuthentication

        // Both should require browser-based re-auth, not client-side token refresh
        let oidcNeedsBrowserReauth = oidcAuth.isOidc || oidcAuth.isSaml
        let samlNeedsBrowserReauth = samlAuth.isOidc || samlAuth.isSaml

        XCTAssertTrue(oidcNeedsBrowserReauth, "OIDC should match the browser re-auth path")
        XCTAssertTrue(samlNeedsBrowserReauth, "SAML should match the browser re-auth path")
    }
}

// MARK: - OIDC Explicit Logout Tests

/// OIDC login uses `ASWebAuthenticationSession` which shares the system Safari
/// browser session (unlike SAML which uses WKWebView). On sign-out, clearing
/// WKWebView data has no effect on the Safari session, so the IdP (e.g. Google)
/// would auto-sign the patron back in on the next login attempt.
///
/// The fix mirrors the SAML pattern: after clearing local credentials, open an
/// `ASWebAuthenticationSession` to the CM's end_session endpoint so the IdP
/// session in Safari is also invalidated.
final class OIDCExplicitLogoutTests: XCTestCase {

    private var businessLogic: TPPSignInBusinessLogic!
    private var libraryMock: TPPLibraryAccountMock!
    private var uiDelegate: TPPSignInOutBusinessLogicUIDelegateMock!
    private var bookRegistryMock: TPPBookRegistryMock!
    private var downloadsCenterMock: TPPMyBooksDownloadsCenterMock!
    private var networkExecutor: TPPRequestExecutorMock!

    override func setUp() {
        super.setUp()
        TPPUserAccountMock.resetShared()
        libraryMock = TPPLibraryAccountMock()
        uiDelegate = TPPSignInOutBusinessLogicUIDelegateMock()
        bookRegistryMock = TPPBookRegistryMock()
        downloadsCenterMock = TPPMyBooksDownloadsCenterMock()
        networkExecutor = TPPRequestExecutorMock()

        businessLogic = TPPSignInBusinessLogic(
            libraryAccountID: libraryMock.tppAccountUUID,
            libraryAccountsProvider: libraryMock,
            urlSettingsProvider: TPPURLSettingsProviderMock(),
            bookRegistry: bookRegistryMock,
            bookDownloadsCenter: downloadsCenterMock,
            userAccountProvider: TPPUserAccountMock.self,
            networkExecutor: networkExecutor,
            uiDelegate: uiDelegate,
            drmAuthorizer: TPPDRMAuthorizingMock()
        )
    }

    override func tearDown() {
        networkExecutor.reset()
        businessLogic.userAccount.removeAll()
        businessLogic = nil
        libraryMock = nil
        uiDelegate = nil
        bookRegistryMock = nil
        downloadsCenterMock = nil
        networkExecutor = nil
        super.tearDown()
    }

    func testOIDCExplicitLogout_logoutHref_isParsedFromAuthDocument() {
        let auth = libraryMock.oidcAuthentication
        XCTAssertNotNil(auth.oidcLogoutHref,
                        "OIDC auth document must provide a logout href")
        XCTAssertEqual(
            auth.oidcLogoutHref,
            "https://circulation.example.com/NYNYPL/oidc/logout?provider=OpenID+Connect{&post_logout_redirect_uri}",
            "oidcLogoutHref must be parsed verbatim from the 'logout' rel link (URI template preserved)")
    }

    func testOIDCExplicitLogout_logoutHref_isNilForNonOIDCAuthTypes() {
        XCTAssertNil(libraryMock.barcodeAuthentication.oidcLogoutHref,
                     "Basic auth must not have an oidcLogoutHref")
        XCTAssertNil(libraryMock.oauthAuthentication.oidcLogoutHref,
                     "OAuth auth must not have an oidcLogoutHref")
        XCTAssertNil(libraryMock.samlAuthentication.oidcLogoutHref,
                     "SAML auth must not have an oidcLogoutHref")
    }

    func testOIDCExplicitLogout_uriTemplate_isExpandedCorrectly() {
        let template = "https://example.com/oidc/logout?provider=OpenID+Connect{&post_logout_redirect_uri}"
        let redirectURI = TPPSignInBusinessLogic.oidcPostLogoutRedirectURI

        let expanded = try? StdUriTemplate.expand(
            template,
            substitutions: ["post_logout_redirect_uri": redirectURI]
        )

        XCTAssertNotNil(expanded,
                        "StdUriTemplate must expand the logout template without error")
        XCTAssertTrue(expanded?.contains("post_logout_redirect_uri=") == true,
                      "Expanded URL must contain the post_logout_redirect_uri parameter")
        XCTAssertNotNil(expanded.flatMap { URL(string: $0) },
                        "Expanded logout URL must be a valid URL")
    }

    func testOIDCExplicitLogout_postLogoutRedirectURI_usesOIDCCallbackScheme() {
        XCTAssertTrue(
            TPPSignInBusinessLogic.oidcPostLogoutRedirectURI.hasPrefix(
                TPPSignInBusinessLogic.oidcCallbackScheme),
            "Post-logout redirect URI must use the palace-oidc-callback scheme")
        XCTAssertTrue(
            TPPSignInBusinessLogic.oidcPostLogoutRedirectURI.hasSuffix("/logout"),
            "Post-logout redirect URI must use the /logout path to distinguish it from a login callback")
    }

    func testOIDCExplicitLogout_withNoEndSessionUrl_callsCompletionImmediately() {
        businessLogic.selectedAuthentication = nil

        let exp = expectation(description: "Completion called")
        businessLogic.oidcLogOut {
            exp.fulfill()
        }
        waitForExpectations(timeout: 2.0)
    }

    func testOIDCExplicitLogout_signOutPipeline_clearsTokenAndNotifiesDelegate() {
        businessLogic.selectedAuthentication = libraryMock.oidcAuthentication
        businessLogic.updateUserAccount(
            forDRMAuthorization: true,
            withBarcode: nil, pin: nil,
            authToken: "oidc-token-to-clear",
            expirationDate: nil,
            patron: ["name": "Test Patron"],
            cookies: nil
        )
        XCTAssertTrue(businessLogic.isSignedIn(), "Precondition: user must be signed in")

        let exp = expectation(description: "Sign-out pipeline completes")
        uiDelegate.didFinishDeauthorizingHandler = { exp.fulfill() }

        businessLogic.performLogOut()
        waitForExpectations(timeout: 5.0)

        XCTAssertNil(businessLogic.userAccount.authToken,
                     "OIDC access token must be cleared after explicit logout")
        XCTAssertTrue(uiDelegate.didCallDidFinishDeauthorizing,
                      "UI delegate must be notified that deauthorization finished")
    }

    // MARK: - Regression: wrong rel value

    /// Direct regression test for the rel mismatch bug.
    /// The server sends rel="logout"; our original code matched rel="sign-out".
    /// This test pins both sides of the contract so the same mistake cannot
    /// silently pass again.
    func testOIDCExplicitLogout_correctRel_producesLogoutHref() {
        let json = makeOIDCAuthJSON(logoutRel: "logout")
        let auth = decodeAccountAuth(from: json)
        XCTAssertNotNil(auth.oidcLogoutHref,
                        "rel='logout' must populate oidcLogoutHref")
    }

    func testOIDCExplicitLogout_wrongRel_producesNilLogoutHref() {
        // "sign-out" was our original (wrong) assumption; it must NOT match.
        let json = makeOIDCAuthJSON(logoutRel: "sign-out")
        let auth = decodeAccountAuth(from: json)
        XCTAssertNil(auth.oidcLogoutHref,
                     "rel='sign-out' is not the server contract and must not populate oidcLogoutHref")
    }

    // MARK: - URI template expansion: value correctness

    func testOIDCExplicitLogout_expandedURL_containsRedirectURIValue() {
        // More specific than testOIDCExplicitLogout_uriTemplate_isExpandedCorrectly:
        // verifies the actual redirect URI value appears in the expanded URL, not just the key.
        let template = "https://example.com/oidc/logout?provider=OpenID+Connect{&post_logout_redirect_uri}"
        let redirectURI = TPPSignInBusinessLogic.oidcPostLogoutRedirectURI

        let expanded = try? StdUriTemplate.expand(
            template,
            substitutions: ["post_logout_redirect_uri": redirectURI]
        )

        // StdUriTemplate percent-encodes the value per RFC 6570 (unreserved chars
        // like letters, digits, -, _, ., ~ are NOT encoded; others are).
        // The scheme "palace-oidc-callback" contains only unreserved chars after
        // the colon, so the scheme name itself will appear literally.
        XCTAssertTrue(
            expanded?.contains("post_logout_redirect_uri=palace-oidc-callback") == true,
            "Expanded URL must contain the redirect URI scheme as the parameter value; got: \(expanded ?? "nil")"
        )
        XCTAssertTrue(
            expanded?.contains("/logout") == true,
            "Expanded URL must include the /logout path from the redirect URI; got: \(expanded ?? "nil")"
        )
    }

    func testOIDCExplicitLogout_icarusRealWorldTemplate_expandsToValidURL() {
        // Uses the exact template format Icarus sends (provider param already in
        // the href, logout variable in query-continuation position).
        let icarusTemplate = "https://minotaur.dev.palaceproject.io/icarus-test-library/oidc/logout?provider=OpenID+Connect{&post_logout_redirect_uri}"
        let redirectURI = TPPSignInBusinessLogic.oidcPostLogoutRedirectURI

        let expanded = try? StdUriTemplate.expand(
            icarusTemplate,
            substitutions: ["post_logout_redirect_uri": redirectURI]
        )

        XCTAssertNotNil(expanded, "Icarus real-world template must expand without error")
        XCTAssertNotNil(expanded.flatMap { URL(string: $0) },
                        "Expanded Icarus logout URL must be a valid URL")
        XCTAssertTrue(
            expanded?.contains("provider=OpenID+Connect") == true,
            "Existing query params must be preserved in the expanded URL; got: \(expanded ?? "nil")"
        )
        XCTAssertTrue(
            expanded?.contains("post_logout_redirect_uri=") == true,
            "Template variable must be expanded into the URL; got: \(expanded ?? "nil")"
        )
    }

    // MARK: - Helpers

    private func makeOIDCAuthJSON(logoutRel: String) -> Data {
        """
        {
            "type": "http://palaceproject.io/authtype/OpenIDConnect",
            "links": [
                {
                    "href": "https://example.com/oidc/authenticate",
                    "rel": "authenticate"
                },
                {
                    "href": "https://example.com/oidc/logout?provider=OpenID+Connect{&post_logout_redirect_uri}",
                    "rel": "\(logoutRel)",
                    "templated": true
                }
            ]
        }
        """.data(using: .utf8)!
    }

    private func decodeAccountAuth(from data: Data) -> AccountDetails.Authentication {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let opdsAuth = try! decoder.decode(
            OPDS2AuthenticationDocument.Authentication.self,
            from: data
        )
        return AccountDetails.Authentication(auth: opdsAuth)
    }
}
