//
//  TPPSignInBusinessLogicCharacterizationTests.swift
//  PalaceTests
//
//  CHARACTERIZATION PACK — blocking prerequisite for the god-class
//  decomposition of `TPPSignInBusinessLogic` (see
//  docs/architecture/god-class-decomposition-plan.md §5, row
//  "TPPSignInBusinessLogic").
//
//  This file pins the behavior of the two clusters the plan extracts into
//  PalaceAuth / PalaceAccounts:
//    - SignInRequestService  (makeRequest + validateCredentials wiring +
//      error surfacing) → PalaceAuth
//    - CredentialStore       (updateUserAccount persistence contract per auth
//      method) → PalaceAccounts (+ PalaceKeychain)
//
//  A second file, TPPSignInCapabilitiesCharacterizationTests.swift, covers the
//  AuthCapabilities-derivation and Adobe-DRM-activation-skip clusters.
//
//  Every test drives a real Arrange→Act→Assert against TODAY's code with a
//  mutation-killing assertion (flip a conditional / drop an assignment in the
//  covered code and the test fails). Hermetic: TPPRequestExecutorMock for the
//  /patrons/me request, TPPUserAccountMock for the keychain seam,
//  TPPDRMAuthorizingMock for device auth. No live network / keychain.
//
//  NOTE (integration): this class already carries broad scattered coverage
//  (TPPSignInBusinessLogicTests, ...OAuthTests, ...SignOutTests, ...OIDCTests,
//  ...ExtendedTests, ...StateMachineTests, TPPSAMLSignInTests, TPPSignInAdobe
//  SkipTests). The "0 dedicated tests" premise in the plan is STALE. This pack
//  is the *consolidated per-extraction-boundary contract* plus the genuinely
//  uncovered branches (no-URL validation error, oauth-family barcode fallback,
//  non-SAML cookie gate). Overlaps are called out in the mission report.
//

import XCTest
import PalaceCatalog
@testable import Palace

// MARK: - Recording delegate (captures validation-error + didReceiveCredentials)

/// The shared `TPPSignInOutBusinessLogicUIDelegateMock` treats
/// `didEncounterValidationError` as a no-op, so it cannot prove that an error
/// was surfaced to the UI. This standalone delegate records the validation-error
/// callback (title/message) AND the didReceiveCredentials call so tests can pin
/// the success-vs-failure fork of `validateCredentials`.
private final class RecordingSignInUIDelegate: NSObject, TPPSignInOutBusinessLogicUIDelegate {
    var context = "RecordingDelegate"
    var username: String? = "recorded-user"
    var pin: String? = "recorded-pin"
    var usernameTextField: UITextField?
    var PINTextField: UITextField?
    var forceEditability: Bool = false

    private(set) var validationErrorCount = 0
    private(set) var lastValidationTitle: String?
    private(set) var lastValidationMessage: String?
    private(set) var didReceiveCredentialsCount = 0

    func businessLogicWillSignIn(_ businessLogic: TPPSignInBusinessLogic) {}
    func businessLogicDidCancelSignIn(_ businessLogic: TPPSignInBusinessLogic) {}
    func businessLogicDidCompleteSignIn(_ businessLogic: TPPSignInBusinessLogic) {}
    func businessLogic(_ logic: TPPSignInBusinessLogic,
                       didEncounterValidationError error: Error?,
                       userFriendlyErrorTitle title: String?,
                       andMessage message: String?) {
        validationErrorCount += 1
        lastValidationTitle = title
        lastValidationMessage = message
    }
    func businessLogicDidReceiveCredentials(_ businessLogic: TPPSignInBusinessLogic) {
        didReceiveCredentialsCount += 1
    }
    func dismiss(animated flag: Bool, completion: (() -> Void)?) { completion?() }
    func present(_ viewControllerToPresent: UIViewController,
                 animated flag: Bool,
                 completion: (() -> Void)?) { completion?() }
    func businessLogicWillSignOut(_ businessLogic: TPPSignInBusinessLogic) {}
    func businessLogic(_ logic: TPPSignInBusinessLogic,
                       didEncounterSignOutError error: Error?,
                       withHTTPStatusCode httpStatusCode: Int) {}
    func businessLogicDidFinishDeauthorizing(_ logic: TPPSignInBusinessLogic) {}
}

// MARK: - SignInRequestService cluster

@MainActor
final class SignInRequestServiceCharacterizationTests: XCTestCase {

    private var businessLogic: TPPSignInBusinessLogic!
    private var libraryMock: TPPLibraryAccountMock!
    private var uiDelegate: TPPSignInOutBusinessLogicUIDelegateMock!
    private var networkExecutor: TPPRequestExecutorMock!

    /// The /patrons/me URL the fixture's userProfileUrl resolves to and that
    /// TPPRequestExecutorMock is pre-wired to answer 200.
    private let profilePath = "patrons/me"

    override func setUpWithError() throws {
        try super.setUpWithError()
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
            drmAuthorizer: TPPDRMAuthorizingMock())
    }

    override func tearDownWithError() throws {
        networkExecutor.reset()
        businessLogic.userAccount.removeAll()
        businessLogic = nil
        libraryMock = nil
        uiDelegate = nil
        networkExecutor = nil
        try super.tearDownWithError()
    }

    // A1 — sign-OUT request for basic auth: URL present, NO bearer header.
    // Kills a mutant that adds a bearer header for non-token auth on sign-out,
    // or that drops the userProfileUrl → returns nil.
    func test_makeRequest_signOut_basicAuth_hasProfileURL_andNoBearerHeader() {
        businessLogic.selectedAuthentication = libraryMock.barcodeAuthentication

        let req = businessLogic.makeRequest(for: .signOut, context: "signout-basic")

        XCTAssertNotNil(req, "sign-out request must be built from the loaded userProfileUrl")
        XCTAssertTrue(req?.url?.absoluteString.contains(profilePath) ?? false,
                      "sign-out request must target the /patrons/me user-profile URL")
        XCTAssertNil(req?.value(forHTTPHeaderField: "Authorization"),
                     "basic-auth sign-out must NOT attach a Bearer header")
    }

    // A2 — GAP: validateCredentials when the request cannot be built.
    // Building against a library whose details never loaded makes makeRequest
    // return nil; validateCredentials must surface a validation error to the UI
    // and fire NO network call. Kills the `guard let req = makeRequest` mutant
    // (removing/negating it would proceed to executeRequest).
    func test_validateCredentials_whenRequestUnbuildable_surfacesError_andFiresNoNetworkCall() {
        let recording = RecordingSignInUIDelegate()
        let blogic = TPPSignInBusinessLogic(
            libraryAccountID: "totally-unknown-library",   // resolves to detail-less Account
            libraryAccountsProvider: libraryMock,
            urlSettingsProvider: TPPURLSettingsProviderMock(),
            bookRegistry: TPPBookRegistryMock(),
            bookDownloadsCenter: TPPMyBooksDownloadsCenterMock(),
            userAccountProvider: TPPUserAccountMock.self,
            networkExecutor: networkExecutor,
            uiDelegate: recording,
            drmAuthorizer: TPPDRMAuthorizingMock())

        XCTAssertNil(blogic.makeRequest(for: .signIn, context: "precondition"),
                     "precondition: makeRequest must be nil for a detail-less library")

        blogic.validateCredentials()
        drainMainQueue()   // the delegate error hop runs via asyncIfNeeded

        XCTAssertTrue(networkExecutor.executedRequestURLs.isEmpty,
                      "an unbuildable request must short-circuit BEFORE any network call")
        XCTAssertEqual(recording.validationErrorCount, 1,
                       "validateCredentials must surface exactly one validation error when the request can't be built")
        XCTAssertNotNil(recording.lastValidationTitle,
                        "the surfaced validation error must carry a user-facing title")
        XCTAssertFalse(blogic.isValidatingCredentials,
                       "validating flag must be cleared once the failure is surfaced")
    }

    // A3 — validateCredentials success path routes makeRequest's URL through the
    // executor. Pins the makeRequest→executeRequest wiring at the /patrons/me
    // URL. Kills a mutant that fires the wrong URL or skips the request.
    func test_validateCredentials_basicAuth_firesUserProfileRequest() {
        businessLogic.selectedAuthentication = libraryMock.barcodeAuthentication

        businessLogic.validateCredentials()   // executeRequest records URL synchronously

        XCTAssertEqual(networkExecutor.executedRequestURLs.count, 1,
                       "validateCredentials must fire exactly one credential-validation request")
        XCTAssertTrue(networkExecutor.executedRequestURLs.first?.absoluteString.contains(profilePath) ?? false,
                      "the validation request must target the fixture's userProfileUrl (/patrons/me)")
        XCTAssertTrue(businessLogic.isValidatingCredentials,
                      "validateCredentials must enter the validating state")
    }

    // A4 — validateCredentials failure (401) surfaces a validation error and does
    // NOT report didReceiveCredentials. Distinct from the callback-order test:
    // here we prove the error CONTENT is surfaced (recording delegate). Kills a
    // mutant that swaps the success/failure arms of the executor result switch.
    func test_validateCredentials_httpFailure_surfacesValidationError_andNoCredentialsReceived() {
        let recording = RecordingSignInUIDelegate()
        businessLogic.uiDelegate = recording
        businessLogic.selectedAuthentication = libraryMock.barcodeAuthentication
        networkExecutor.forceFailureStatusCode = 401

        businessLogic.validateCredentials()
        drainMainQueue()

        XCTAssertEqual(recording.validationErrorCount, 1,
                       "a 401 must surface exactly one validation error to the UI")
        XCTAssertEqual(recording.didReceiveCredentialsCount, 0,
                       "the failure arm must NOT signal didReceiveCredentials (no DRM spinner)")
        XCTAssertFalse(businessLogic.isValidatingCredentials,
                       "validating flag must be cleared after a failed validation")
    }

    // A5 — makeRequest header contract: basic auth carries NO Authorization.
    func test_makeRequest_signIn_basicAuth_omitsBearerHeader() {
        businessLogic.selectedAuthentication = libraryMock.barcodeAuthentication
        let req = businessLogic.makeRequest(for: .signIn, context: "basic")
        XCTAssertNotNil(req)
        XCTAssertNil(req?.value(forHTTPHeaderField: "Authorization"),
                     "basic auth must never attach a Bearer token")
    }

    // A6 — makeRequest header contract: OAuth attaches "Bearer <in-flight token>".
    func test_makeRequest_signIn_oauth_attachesInFlightBearer() {
        businessLogic.selectedAuthentication = libraryMock.oauthAuthentication
        businessLogic.dispatch(.bearerTokenReceived(token: "oauth-flight", expiration: nil))
        let req = businessLogic.makeRequest(for: .signIn, context: "oauth")
        XCTAssertEqual(req?.value(forHTTPHeaderField: "Authorization"), "Bearer oauth-flight")
    }

    // A7 — makeRequest header contract: SAML attaches a Bearer token.
    func test_makeRequest_signIn_saml_attachesInFlightBearer() {
        businessLogic.selectedAuthentication = libraryMock.samlAuthentication
        businessLogic.dispatch(.bearerTokenReceived(token: "saml-flight", expiration: nil))
        let req = businessLogic.makeRequest(for: .signIn, context: "saml")
        XCTAssertEqual(req?.value(forHTTPHeaderField: "Authorization"), "Bearer saml-flight")
    }

    // A8 — makeRequest header contract: OIDC attaches a Bearer token.
    func test_makeRequest_signIn_oidc_attachesInFlightBearer() {
        businessLogic.selectedAuthentication = libraryMock.oidcAuthentication
        businessLogic.dispatch(.bearerTokenReceived(token: "oidc-flight", expiration: nil))
        let req = businessLogic.makeRequest(for: .signIn, context: "oidc")
        XCTAssertEqual(req?.value(forHTTPHeaderField: "Authorization"), "Bearer oidc-flight")
    }

    // A9 — makeRequest falls back to the persisted userAccount token when there
    // is no in-flight token (the `authToken ?? userAccount.authToken` chain).
    func test_makeRequest_signIn_oauth_fallsBackToPersistedToken() {
        businessLogic.selectedAuthentication = libraryMock.oauthAuthentication
        businessLogic.userAccount.setAuthToken("persisted-only", barcode: nil, pin: nil, expirationDate: nil)
        // Clear any in-flight reducer token so only the persisted one remains.
        businessLogic.dispatch(.userAccountUpdated)
        XCTAssertNil(businessLogic.authToken, "precondition: no in-flight token")

        let req = businessLogic.makeRequest(for: .signIn, context: "oauth-fallback")

        XCTAssertEqual(req?.value(forHTTPHeaderField: "Authorization"), "Bearer persisted-only",
                       "with no in-flight token, makeRequest must fall back to userAccount.authToken")
    }

    // A17 — validateCredentials SUCCESS arm reports didReceiveCredentials (so the
    // UI can show its DRM spinner). Positive complement of A4; kills a mutant
    // that drops the businessLogicDidReceiveCredentials call on success.
    func test_validateCredentials_basicAuthSuccess_reportsDidReceiveCredentials() {
        let recording = RecordingSignInUIDelegate()
        businessLogic.uiDelegate = recording
        businessLogic.selectedAuthentication = libraryMock.barcodeAuthentication

        businessLogic.validateCredentials()
        drainMainQueue()

        XCTAssertEqual(recording.didReceiveCredentialsCount, 1,
                       "a successful validation must signal didReceiveCredentials exactly once")
        XCTAssertEqual(recording.validationErrorCount, 0,
                       "a successful validation must NOT surface a validation error")
    }

    // A18 — makeRequest header contract also applies on SIGN-OUT: an OAuth
    // sign-out carries the Bearer token. Kills a mutant that only attaches the
    // header on sign-in.
    func test_makeRequest_signOut_oauth_attachesBearer() {
        businessLogic.selectedAuthentication = libraryMock.oauthAuthentication
        businessLogic.dispatch(.bearerTokenReceived(token: "signout-tok", expiration: nil))

        let req = businessLogic.makeRequest(for: .signOut, context: "oauth-signout")

        XCTAssertEqual(req?.value(forHTTPHeaderField: "Authorization"), "Bearer signout-tok",
                       "OAuth sign-out must attach the Bearer token, same as sign-in")
    }
}

// MARK: - CredentialStore cluster (updateUserAccount persistence contract)

@MainActor
final class CredentialStoreCharacterizationTests: XCTestCase {

    private var businessLogic: TPPSignInBusinessLogic!
    private var libraryMock: TPPLibraryAccountMock!

    override func setUpWithError() throws {
        try super.setUpWithError()
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
            drmAuthorizer: TPPDRMAuthorizingMock())
    }

    override func tearDownWithError() throws {
        businessLogic.userAccount.removeAll()
        businessLogic = nil
        libraryMock = nil
        try super.tearDownWithError()
    }

    private func update(auth: AccountDetails.Authentication,
                        barcode: String? = nil, pin: String? = nil,
                        token: String? = nil, patron: [String: Any]? = nil,
                        cookies: [HTTPCookie]? = nil) {
        businessLogic.selectedAuthentication = auth
        businessLogic.updateUserAccount(forDRMAuthorization: true,
                                        withBarcode: barcode, pin: pin,
                                        authToken: token, expirationDate: nil,
                                        patron: patron, cookies: cookies)
    }

    // A10 — basic-auth persistence contract: barcode+pin stored, logged in,
    // NO token, NO cookies.
    func test_updateUserAccount_basicAuth_persistsBarcodePin_marksLoggedIn() {
        update(auth: libraryMock.barcodeAuthentication, barcode: "bc-1", pin: "pin-1")

        let acct = businessLogic.userAccount
        XCTAssertEqual(acct.barcode, "bc-1")
        XCTAssertEqual(acct.PIN, "pin-1")
        XCTAssertNil(acct.authToken, "basic auth must not persist a bearer token")
        XCTAssertNil(acct.cookies, "basic auth must not persist cookies")
        XCTAssertTrue(businessLogic.isSignedIn(), "credentials must mark the account signed in")
    }

    // A11 — OAuth/Clever persistence contract: token+patron stored, logged in.
    func test_updateUserAccount_oauthClever_persistsTokenAndPatron() {
        update(auth: libraryMock.cleverAuthentication,
               token: "clever-tok", patron: ["name": "Ada"])

        let acct = businessLogic.userAccount
        XCTAssertEqual(acct.authToken, "clever-tok")
        XCTAssertEqual(acct.patron?["name"] as? String, "Ada")
        XCTAssertTrue(businessLogic.isSignedIn())
    }

    // A12 — SAML persistence contract: token+patron+COOKIES stored (the isSaml
    // cookie gate). Kills the `if selectedAuth.isSaml, let cookies` mutant.
    func test_updateUserAccount_saml_persistsTokenPatronAndCookies() {
        let cookie = HTTPCookie(properties: [
            .domain: "idp.example.com", .path: "/", .name: "s", .value: "v"])!
        update(auth: libraryMock.samlAuthentication,
               token: "saml-tok", patron: ["name": "Grace"], cookies: [cookie])

        let acct = businessLogic.userAccount
        XCTAssertEqual(acct.authToken, "saml-tok")
        XCTAssertEqual(acct.patron?["name"] as? String, "Grace")
        XCTAssertEqual(acct.cookies?.count, 1, "SAML must persist the IdP session cookies")
    }

    // A13 — OIDC persistence contract: token+patron stored, authDefinition is
    // .oidc, and NO cookies (unlike SAML).
    func test_updateUserAccount_oidc_persistsToken_setsOidcAuthDefinition_noCookies() {
        update(auth: libraryMock.oidcAuthentication,
               token: "oidc-tok", patron: ["name": "Alan"])

        let acct = businessLogic.userAccount
        XCTAssertEqual(acct.authToken, "oidc-tok")
        XCTAssertEqual(acct.authDefinition?.authType, .oidc,
                       "updateUserAccount must stamp the selected OIDC auth definition")
        XCTAssertNil(acct.cookies, "OIDC must NOT persist cookies")
    }

    // A14 — GAP: OAuth-family with BOTH token AND barcode/pin persists all three
    // (the setAuthToken(token, barcode:, pin:) arm). Kills a mutant that drops
    // the barcode/pin arguments when a token is present.
    func test_updateUserAccount_oauthFamily_withTokenAndBarcodePin_persistsAll() {
        update(auth: libraryMock.oauthAuthentication,
               barcode: "bc-x", pin: "pin-x", token: "tok-x")

        let acct = businessLogic.userAccount
        XCTAssertEqual(acct.authToken, "tok-x")
        XCTAssertEqual(acct.barcode, "bc-x",
                       "a token+barcode OAuth update must persist the barcode too")
        XCTAssertEqual(acct.PIN, "pin-x")
    }

    // A15 — GAP: OAuth-family WITHOUT a token falls back to barcode/pin
    // (the inner `else if let barcode, let pin` arm). Kills a mutant that drops
    // the no-token fallback.
    func test_updateUserAccount_oauthFamily_withoutToken_fallsBackToBarcodePin() {
        update(auth: libraryMock.oauthAuthentication, barcode: "bc-y", pin: "pin-y")

        let acct = businessLogic.userAccount
        XCTAssertNil(acct.authToken, "no token was supplied — none must be persisted")
        XCTAssertEqual(acct.barcode, "bc-y",
                       "OAuth-family update with no token must fall back to persisting barcode/pin")
        XCTAssertEqual(acct.PIN, "pin-y")
    }

    // A16 — GAP: a non-SAML auth must NOT persist cookies even when they are
    // passed. Kills a mutant that widens the cookie gate beyond SAML.
    func test_updateUserAccount_basicAuth_ignoresCookies() {
        let cookie = HTTPCookie(properties: [
            .domain: "x.example.com", .path: "/", .name: "leak", .value: "no"])!
        update(auth: libraryMock.barcodeAuthentication,
               barcode: "bc-z", pin: "pin-z", cookies: [cookie])

        XCTAssertNil(businessLogic.userAccount.cookies,
                     "cookies must only be persisted for SAML — basic auth must ignore them")
    }
}
