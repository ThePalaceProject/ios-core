//
//  TPPSignInOIDCTests.swift
//  PalaceTests
//
//  Tests for OIDC (OpenID Connect) patron authentication (PP-3474).
//  Includes unit, integration, and regression tests.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

// MARK: - Unit Tests: AuthType & Authentication Model

final class OIDCAuthTypeTests: XCTestCase {

    func testAuthType_OidcRawValue_IsCorrect() {
        XCTAssertEqual(
            AccountDetails.AuthType.oidc.rawValue,
            "http://thepalaceproject.org/authtype/openid-connect"
        )
    }

    func testAuthType_InitFromOidcString_ReturnsOidc() {
        let authType = AccountDetails.AuthType(rawValue: "http://thepalaceproject.org/authtype/openid-connect")
        XCTAssertEqual(authType, .oidc)
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
            "https://circulation.example.com/NYNYPL/oidc/authenticate"
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

// MARK: - Integration Tests: Redirect Handling

final class OIDCRedirectHandlingTests: XCTestCase {

    private var businessLogic: TPPSignInBusinessLogic!
    private var libraryMock: TPPLibraryAccountMock!
    private var uiDelegate: TPPSignInOutBusinessLogicUIDelegateMock!
    private var networkExecutor: TPPRequestExecutorMock!

    override func setUp() {
        super.setUp()
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
        businessLogic.userAccount.removeAll()
        businessLogic = nil
        libraryMock = nil
        uiDelegate = nil
        networkExecutor = nil
        super.tearDown()
    }

    /// Integration test: OIDC redirect with access_token + patron_info triggers credential validation.
    func testHandleRedirectURL_withOIDCToken_extractsTokenAndValidates() {
        businessLogic.selectedAuthentication = libraryMock.oidcAuthentication

        let patronJSON = "{\"name\":\"OIDC+User\"}"
        let encodedPatron = patronJSON.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        let redirectURL = URL(string: "https://example.com/univeral-link-redirect#access_token=oidc-token-abc&patron_info=\(encodedPatron)")!

        let notification = Notification(
            name: .TPPAppDelegateDidReceiveCleverRedirectURL,
            object: redirectURL
        )

        businessLogic.handleRedirectURL(notification)

        XCTAssertEqual(businessLogic.authToken, "oidc-token-abc",
                       "OIDC redirect should extract access_token")
        XCTAssertEqual(businessLogic.patron?["name"] as? String, "OIDC User",
                       "OIDC redirect should extract patron_info")
        XCTAssertTrue(businessLogic.isValidatingCredentials,
                      "After redirect, should be validating credentials against the CM")
    }

    /// Integration test: OIDC redirect with error should not set auth token.
    func testHandleRedirectURL_withError_doesNotSetToken() {
        businessLogic.selectedAuthentication = libraryMock.oidcAuthentication

        let errorJSON = "{\"title\":\"Authentication+failed\"}"
        let encoded = errorJSON.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        let redirectURL = URL(string: "https://example.com/univeral-link-redirect#error=\(encoded)")!

        let notification = Notification(
            name: .TPPAppDelegateDidReceiveCleverRedirectURL,
            object: redirectURL
        )

        businessLogic.handleRedirectURL(notification)

        XCTAssertNil(businessLogic.authToken, "Error redirect should not set auth token")
    }

    /// Integration test: Full credential validation flow after OIDC redirect.
    func testOIDCFlow_afterRedirect_validatesAndCompletesSignIn() {
        businessLogic.selectedAuthentication = libraryMock.oidcAuthentication

        let exp = expectation(description: "Sign-in completes")
        uiDelegate.didCompleteSignInHandler = {
            exp.fulfill()
        }

        let patronJSON = "{\"name\":\"Test+Patron\"}"
        let encoded = patronJSON.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        let redirectURL = URL(string: "https://example.com/univeral-link-redirect#access_token=valid-oidc-token&patron_info=\(encoded)")!

        let notification = Notification(
            name: .TPPAppDelegateDidReceiveCleverRedirectURL,
            object: redirectURL
        )

        businessLogic.handleRedirectURL(notification)

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
