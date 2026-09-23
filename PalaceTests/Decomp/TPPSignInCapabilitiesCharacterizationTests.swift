//
//  TPPSignInCapabilitiesCharacterizationTests.swift
//  PalaceTests
//
//  CHARACTERIZATION PACK (part 2 of 2) — blocking prerequisite for the
//  decomposition of `TPPSignInBusinessLogic` (see
//  docs/architecture/god-class-decomposition-plan.md §5).
//
//  Clusters pinned here:
//    - AuthCapabilities derivation  (barcode-display gating, registration
//      gating, SAML/OIDC preferred-auth + sole-IdP selection, password-reset
//      availability) → pure derivation extracted to PalaceAuth
//    - Adobe-DRM-activation SKIP decision (stays app-target) — the POSITIVE
//      decision + the device-not-authorized branch that the existing suite
//      never exercised (it only covers the false early-returns)
//    - refreshAuthIfNeeded basic auto-reauth path
//    - logIn() routing per auth method (safe branches only)
//
//  Companion file: TPPSignInBusinessLogicCharacterizationTests.swift
//  (SignInRequestService + CredentialStore clusters).
//

import XCTest
import PalaceCatalog
@testable import Palace

@MainActor
final class TPPSignInCapabilitiesCharacterizationTests: XCTestCase {

    private var businessLogic: TPPSignInBusinessLogic!
    private var libraryMock: TPPLibraryAccountMock!
    private var uiDelegate: TPPSignInOutBusinessLogicUIDelegateMock!
    private var networkExecutor: TPPRequestExecutorMock!
    private var drmAuthorizer: TPPDRMAuthorizingMock!

    override func setUpWithError() throws {
        try super.setUpWithError()
        TPPUserAccountMock.resetShared()
        libraryMock = TPPLibraryAccountMock()
        uiDelegate = TPPSignInOutBusinessLogicUIDelegateMock()
        networkExecutor = TPPRequestExecutorMock()
        drmAuthorizer = TPPDRMAuthorizingMock()
        businessLogic = TPPSignInBusinessLogic(
            libraryAccountID: libraryMock.tppAccountUUID,
            libraryAccountsProvider: libraryMock,
            urlSettingsProvider: TPPURLSettingsProviderMock(),
            bookRegistry: TPPBookRegistryMock(),
            bookDownloadsCenter: TPPMyBooksDownloadsCenterMock(),
            userAccountProvider: TPPUserAccountMock.self,
            networkExecutor: networkExecutor,
            uiDelegate: uiDelegate,
            drmAuthorizer: drmAuthorizer)
        businessLogic.userAccount.removeAll()   // F-008 defense: guaranteed-clean creds
    }

    override func tearDownWithError() throws {
        networkExecutor.reset()
        drmAuthorizer.reset()
        businessLogic.userAccount.removeAll()
        businessLogic = nil
        libraryMock = nil
        uiDelegate = nil
        networkExecutor = nil
        drmAuthorizer = nil
        try super.tearDownWithError()
    }

    private func signInBasic(barcode: String = "bc", pin: String = "pin") {
        businessLogic.selectedAuthentication = libraryMock.barcodeAuthentication
        businessLogic.updateUserAccount(forDRMAuthorization: true,
                                        withBarcode: barcode, pin: pin,
                                        authToken: nil, expirationDate: nil,
                                        patron: nil, cookies: nil)
    }

    // MARK: - AuthCapabilities: barcode display gating (3-way AND)

    // B1 — GAP (positive path): librarySupportsBarcodeDisplay is TRUE only when
    // ALL three hold — hasBarcodeAndPIN, authorizationIdentifier != nil, and the
    // selected auth supportsBarcodeDisplay (fixture basic = Codabar → true).
    // The existing suite only covers the FALSE early-outs; this pins the AND.
    func test_librarySupportsBarcodeDisplay_true_whenAllThreeConditionsMet() {
        signInBasic()
        (businessLogic.userAccount as! TPPUserAccountMock).setAuthorizationIdentifier("auth-id-1")

        XCTAssertTrue(businessLogic.librarySupportsBarcodeDisplay(),
                      "barcode display must be enabled when signed-in + authorizationIdentifier + auth supportsBarcodeDisplay")
    }

    // B2 — GAP: FALSE when the selected auth does NOT support barcode display,
    // even with credentials + authorizationIdentifier present. OAuth in the
    // fixture has no Codabar input → supportsBarcodeDisplay == false. Kills the
    // `supportsBarcodeDisplay` conjunct mutant.
    func test_librarySupportsBarcodeDisplay_false_whenSelectedAuthLacksDisplaySupport() {
        // Persist barcode/pin via the OAuth-family no-token fallback so
        // hasBarcodeAndPIN is satisfied while OAuth is the selected auth.
        businessLogic.selectedAuthentication = libraryMock.oauthAuthentication
        businessLogic.updateUserAccount(forDRMAuthorization: true,
                                        withBarcode: "bc", pin: "pin",
                                        authToken: nil, expirationDate: nil,
                                        patron: nil, cookies: nil)
        (businessLogic.userAccount as! TPPUserAccountMock).setAuthorizationIdentifier("auth-id-2")
        XCTAssertTrue(businessLogic.userAccount.hasBarcodeAndPIN(), "precondition")
        XCTAssertNotNil(businessLogic.userAccount.authorizationIdentifier, "precondition")

        XCTAssertFalse(businessLogic.librarySupportsBarcodeDisplay(),
                       "an auth without barcode-display support must gate the feature off despite creds + auth id")
    }

    // MARK: - AuthCapabilities: registration gating

    // B3 — registrationIsPossible flips with sign-in state: true when signed-out
    // (fixture has a card-creator register link → signUpUrl != nil), false once
    // signed in. Pins both operands of `!isSignedIn() && signUpUrl != nil`.
    func test_registrationIsPossible_flipsWithSignInState() {
        XCTAssertFalse(businessLogic.isSignedIn(), "precondition: signed out")
        XCTAssertTrue(businessLogic.registrationIsPossible(),
                      "signed-out patron on a library with a sign-up URL can register")

        signInBasic()

        XCTAssertTrue(businessLogic.isSignedIn(), "precondition: signed in")
        XCTAssertFalse(businessLogic.registrationIsPossible(),
                       "a signed-in patron must NOT be offered registration")
    }

    // MARK: - AuthCapabilities: password reset availability

    // B4 — canResetPassword is FALSE when the auth document exposes no
    // password-reset link. Replaces the existing tautology-ish
    // "returns a valid Bool" assertion with a real characterization.
    // VERIFY: the NYPL fixture auth doc carries no `password reset` rel link.
    func test_canResetPassword_false_whenAuthDocHasNoResetLink() {
        XCTAssertFalse(businessLogic.canResetPassword,
                       "with no password-reset link in the auth document, canResetPassword must be false")
    }

    // MARK: - AuthCapabilities: preferred-auth + sole-IdP selection

    // B5 — GAP: selectPreferredAuthIfNeeded auto-selects the SOLE SAML IdP once a
    // SAML auth is chosen. Kills the `idps.count == 1` guard.
    // VERIFY: the fixture SAML auth advertises exactly one `authenticate` link.
    func test_selectPreferredAuthIfNeeded_autoSelectsSoleSamlIDP() {
        businessLogic.selectedAuthentication = libraryMock.samlAuthentication
        XCTAssertNil(businessLogic.selectedIDP, "precondition: no IdP chosen yet")

        businessLogic.selectPreferredAuthIfNeeded()

        XCTAssertNotNil(businessLogic.selectedIDP,
                        "a single-IdP SAML auth must auto-select its sole IdP so Sign In opens the WebView")
        XCTAssertTrue(businessLogic.selectedIDP?.url.absoluteString.contains("saml_authenticate") ?? false,
                      "the auto-selected IdP must be the fixture's SAML authenticate endpoint")
    }

    // B6 — selectPreferredAuthIfNeeded must NOT set an IdP for a non-SAML auth.
    // Kills the `samlAuth.isSaml` guard on the IdP-selection branch.
    func test_selectPreferredAuthIfNeeded_doesNotSelectIDP_forNonSamlAuth() {
        businessLogic.selectedAuthentication = libraryMock.oauthAuthentication

        businessLogic.selectPreferredAuthIfNeeded()

        XCTAssertNil(businessLogic.selectedIDP,
                     "a non-SAML selected auth must never auto-select a SAML IdP")
    }

    // MARK: - Adobe DRM activation SKIP decision

    // B7 — GAP (positive decision): skip Adobe activation when credentials are
    // stale, Adobe userID+deviceID exist, and the device is still authorized.
    // The existing suite only covers the FALSE early-returns.
    func test_shouldSkipAdobeActivation_true_whenStaleWithAdobeCredsAndAuthorizedDevice() {
        let acct = businessLogic.userAccount as! TPPUserAccountMock
        acct.setUserID("adobe-user")
        acct.setDeviceID("adobe-device")
        acct.setAuthState(.credentialsStale)
        drmAuthorizer.isUserAuthorizedReturnValue = true   // default, made explicit

        XCTAssertTrue(businessLogic.shouldSkipAdobeActivation(),
                      "stale creds + Adobe id/device + authorized device must skip activation (preserve the slot)")
    }

    // B8 — GAP: even when stale WITH Adobe creds, do NOT skip if the device is no
    // longer authorized with Adobe. This branch only exists under the DRM
    // connector; the guard is compiled out in the open-source build.
    #if FEATURE_DRM_CONNECTOR
    func test_shouldSkipAdobeActivation_false_whenDeviceNoLongerAuthorized() {
        let acct = businessLogic.userAccount as! TPPUserAccountMock
        acct.setUserID("adobe-user")
        acct.setDeviceID("adobe-device")
        acct.setAuthState(.credentialsStale)
        drmAuthorizer.isUserAuthorizedReturnValue = false

        XCTAssertFalse(businessLogic.shouldSkipAdobeActivation(),
                       "a device Adobe no longer recognizes must re-activate, not skip")
    }
    #endif

    // B9 — do NOT skip when stale but Adobe deviceID is missing (isolates the
    // second `guard let deviceID` clause; userID present, deviceID absent).
    func test_shouldSkipAdobeActivation_false_whenStaleButMissingDeviceID() {
        let acct = businessLogic.userAccount as! TPPUserAccountMock
        acct.setUserID("adobe-user")   // deviceID intentionally left nil
        acct.setAuthState(.credentialsStale)

        XCTAssertFalse(businessLogic.shouldSkipAdobeActivation(),
                       "missing Adobe deviceID must block the skip even with a userID and stale state")
    }

    // B10 — do NOT skip when Adobe creds exist and device is authorized but the
    // account is NOT stale (isolates the leading `authState == .credentialsStale`
    // guard). A fresh sign-in must re-activate.
    func test_shouldSkipAdobeActivation_false_whenAuthorizedButNotStale() {
        let acct = businessLogic.userAccount as! TPPUserAccountMock
        acct.setUserID("adobe-user")
        acct.setDeviceID("adobe-device")
        acct.setAuthState(.loggedIn)
        drmAuthorizer.isUserAuthorizedReturnValue = true

        XCTAssertFalse(businessLogic.shouldSkipAdobeActivation(),
                       "a non-stale (fresh) sign-in must never skip Adobe activation")
    }

    // MARK: - refreshAuthIfNeeded: basic auto-reauth

    // SEAM: the TOKEN-auth branch of refreshAuthIfNeeded is NOT exercised here
    // because its expiry guard reads `AppContainer.production().accountsManager
    // .currentUserAccount.authTokenHasExpired` and the refresh calls
    // `getBearerToken(username:password:tokenURL:completion:)` whose default
    // `networkExecutor` argument is `AppContainer.production().networkExecutor` —
    // both reach the process-wide container. The SignInRequestService extraction
    // must inject a `TokenRefreshing` collaborator (the §10.2 seam the OAuth
    // token-flow tests already use) AND an auth-token-expiry checker so the token
    // refresh path is deterministically testable without the container.
    // (The fixture also has no `.token` auth method, so the logIn() `.token`
    // routing branch is unreachable from this library mock regardless.)

    // B11 — GAP: basic auth WITH saved credentials + usingExistingCredentials
    // returns false (no sign-in UI needed) and drives logIn() directly. The
    // existing suite covers the WITHOUT-creds → true complement.
    func test_refreshAuthIfNeeded_basicWithSavedCredentials_returnsFalse_andLogsIn() {
        signInBasic(barcode: "saved-bc", pin: "saved-pin")

        let result = businessLogic.refreshAuthIfNeeded(usingExistingCredentials: true, completion: nil)

        XCTAssertFalse(result,
                       "basic auth with saved credentials must NOT require a sign-in UI (returns false)")
        XCTAssertTrue(businessLogic.isValidatingCredentials,
                      "refreshAuthIfNeeded must drive logIn() → validateCredentials for the saved-creds path")
    }

    // MARK: - logIn() routing per auth method (safe branches)

    // B12 — logIn(basic) captures creds, enters validating, and fires the
    // credential-validation request.
    func test_logIn_basicAuth_capturesCredentials_entersValidating_andFiresRequest() {
        uiDelegate.username = "login-bc"
        uiDelegate.pin = "login-pin"
        businessLogic.selectedAuthentication = libraryMock.barcodeAuthentication

        businessLogic.logIn()

        XCTAssertEqual(businessLogic.capturedBarcode, "login-bc")
        XCTAssertEqual(businessLogic.capturedPin, "login-pin")
        XCTAssertTrue(businessLogic.isValidatingCredentials,
                      "basic logIn routes straight to validateCredentials")
        XCTAssertEqual(networkExecutor.executedRequestURLs.count, 1,
                       "basic logIn must fire exactly one validation request")
    }

    // SEAM: logIn()'s OAuth (`oauthLogIn`) and SAML (`samlHelper.logIn`) arms
    // launch an external browser via `UIApplication.shared.open` / a web-sheet
    // presenter reached inside the SUT — not deterministically drivable in a unit
    // test (the existing OAuth suite avoids logIn() entirely, driving
    // handleRedirectURL directly instead). The flow-engine extraction must inject
    // a URL-opener / web-auth-session presenter protocol so these two routing
    // arms become observable. OIDC (`oidcLogIn`) is safe to invoke here because
    // ASWebAuthenticationSession no-ops without a presentation anchor in tests.

    // B13 — logIn(OIDC) captures the barcode and notifies willSignIn but does
    // NOT validate directly (it hands off to the external web-auth session).
    func test_logIn_oidc_capturesBarcode_notifiesWillSignIn_doesNotValidateDirectly() {
        uiDelegate.username = "oidc-u"
        uiDelegate.pin = nil
        businessLogic.selectedAuthentication = libraryMock.oidcAuthentication

        businessLogic.logIn()
        drainMainQueue()   // willSignIn is dispatched async

        XCTAssertEqual(businessLogic.capturedBarcode, "oidc-u")
        XCTAssertFalse(businessLogic.isValidatingCredentials,
                       "OIDC must NOT call validateCredentials directly — it uses ASWebAuthenticationSession")
        XCTAssertTrue(uiDelegate.didCallWillSignIn,
                      "logIn must notify the UI it is about to sign in")
    }

    // B14 — DRM-failure guard: a failed DRM authorization must PRESERVE existing
    // credentials (no new barcode written). This guard only exists under the DRM
    // connector build. Money-path invariant: never corrupt creds on DRM failure.
    #if FEATURE_DRM_CONNECTOR
    func test_updateUserAccount_drmAuthorizationFailed_preservesExistingCredentials() {
        signInBasic(barcode: "keep-bc", pin: "keep-pin")
        XCTAssertEqual(businessLogic.userAccount.barcode, "keep-bc", "precondition")

        businessLogic.updateUserAccount(forDRMAuthorization: false,
                                        withBarcode: "SHOULD-NOT-PERSIST", pin: "nope",
                                        authToken: nil, expirationDate: nil,
                                        patron: nil, cookies: nil)

        XCTAssertEqual(businessLogic.userAccount.barcode, "keep-bc",
                       "a failed DRM authorization must not overwrite existing credentials")
    }
    #endif
}
