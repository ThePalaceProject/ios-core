import XCTest
import PalaceAuth
import PalaceCatalog
@testable import Palace

/// Behavior tests for `AuthReducer` — the pure-function core of the
/// sign-in / refresh / sign-out state machine that backs
/// `TPPSignInBusinessLogic`. These tests exercise the reducer directly,
/// without a network executor, keychain, DRM authorizer, or UI delegate.
/// The 413 dedicated SignInLogic tests still cover the businessLogic
/// façade end-to-end; this file pins the transition rules in isolation
/// so a regression in any one rule fails its own focused test.
final class AuthReducerTests: XCTestCase {

    // MARK: - Authentication-document loading

    func testAuthDocumentLoadStarted_setsLoadingFlag() {
        var state = AuthState()
        _ = AuthReducer.reduce(&state, .authDocumentLoadStarted)
        XCTAssertTrue(state.isAuthenticationDocumentLoading)
    }

    func testAuthDocumentLoadCompleted_clearsLoadingFlag() {
        var state = AuthState(isAuthenticationDocumentLoading: true)
        _ = AuthReducer.reduce(&state, .authDocumentLoadCompleted)
        XCTAssertFalse(state.isAuthenticationDocumentLoading)
    }

    // MARK: - Credential capture

    func testCredentialCaptureStarted_storesBarcodeAndPinAndClearsStaleError() {
        var state = AuthState(
            lastErrorTitle: "Wrong password",
            lastErrorMessage: "Try again"
        )
        _ = AuthReducer.reduce(&state, .credentialCaptureStarted(barcode: "12345", pin: "9999"))

        XCTAssertEqual(state.capturedBarcode, "12345")
        XCTAssertEqual(state.capturedPin, "9999")
        XCTAssertNil(state.lastErrorTitle,
                     "Starting a new sign-in must clear the previous error so the UI doesn't render both")
        XCTAssertNil(state.lastErrorMessage)
    }

    func testCredentialCaptureStarted_acceptsNilCredentials() {
        var state = AuthState()
        _ = AuthReducer.reduce(&state, .credentialCaptureStarted(barcode: nil, pin: nil))
        XCTAssertNil(state.capturedBarcode)
        XCTAssertNil(state.capturedPin)
    }

    // MARK: - Validation lifecycle

    func testCredentialsValidationStarted_setsFlagAndClearsAnyPriorError() {
        var state = AuthState(
            lastErrorTitle: "Network blip",
            lastErrorMessage: "Try again"
        )
        _ = AuthReducer.reduce(&state, .credentialsValidationStarted)

        XCTAssertTrue(state.isValidatingCredentials)
        XCTAssertNil(state.lastErrorTitle,
                     "A retry is in flight — the previous error banner is stale")
        XCTAssertNil(state.lastErrorMessage)
    }

    func testCredentialsValidationSucceeded_clearsFlagWithoutTouchingCapturedCreds() {
        var state = AuthState(
            isValidatingCredentials: true,
            capturedBarcode: "12345",
            capturedPin: "9999"
        )
        _ = AuthReducer.reduce(&state, .credentialsValidationSucceeded)

        XCTAssertFalse(state.isValidatingCredentials)
        XCTAssertEqual(state.capturedBarcode, "12345",
                       "Captured creds must survive validation success — finalizeSignIn still needs them")
        XCTAssertEqual(state.capturedPin, "9999")
    }

    func testCredentialsValidationFailed_clearsFlagAndSurfacesError() {
        var state = AuthState(isValidatingCredentials: true)
        _ = AuthReducer.reduce(&state, .credentialsValidationFailed(
            title: "Sign-in failed",
            message: "Your library card has expired."
        ))

        XCTAssertFalse(state.isValidatingCredentials)
        XCTAssertEqual(state.lastErrorTitle, "Sign-in failed")
        XCTAssertEqual(state.lastErrorMessage, "Your library card has expired.")
    }

    // MARK: - Bearer token capture

    func testBearerTokenReceived_storesTokenAndExpiration() {
        var state = AuthState()
        let exp = Date().addingTimeInterval(3600)
        _ = AuthReducer.reduce(&state, .bearerTokenReceived(token: "abc.def.ghi", expiration: exp))

        XCTAssertEqual(state.authToken, "abc.def.ghi")
        guard let storedExpiration = state.authTokenExpiration else {
            return XCTFail("Expiration must be stored alongside the token")
        }
        XCTAssertEqual(storedExpiration.timeIntervalSince1970, exp.timeIntervalSince1970, accuracy: 0.001)
    }

    // MARK: - Refresh-auth bypass rules
    //
    // These pin the legacy `refreshAuthIfNeeded` behavior:
    //   - SAML / OAuth / OIDC + non-cached refresh → arm ignoreSignedInState
    //   - Basic / token → never arm (they refresh inline)
    //   - Using existing credentials → never arm regardless of method
    // Without the bypass, a stale browser-session token returned true from
    // isSignedIn() and the user got stuck in a "logged in but every request
    // 401s" state.

    func testRefreshAuthStarted_samlNonExisting_armsIgnoreSignedInState() {
        var state = AuthState()
        _ = AuthReducer.reduce(&state, .refreshAuthStarted(
            authType: .saml,
            usingExistingCredentials: false
        ))
        XCTAssertTrue(state.ignoreSignedInState)
    }

    func testRefreshAuthStarted_oauthNonExisting_armsIgnoreSignedInState() {
        var state = AuthState()
        _ = AuthReducer.reduce(&state, .refreshAuthStarted(
            authType: .oauthIntermediary,
            usingExistingCredentials: false
        ))
        XCTAssertTrue(state.ignoreSignedInState)
    }

    func testRefreshAuthStarted_oidcNonExisting_armsIgnoreSignedInState() {
        var state = AuthState()
        _ = AuthReducer.reduce(&state, .refreshAuthStarted(
            authType: .oidc,
            usingExistingCredentials: false
        ))
        XCTAssertTrue(state.ignoreSignedInState)
    }

    func testRefreshAuthStarted_basicAuth_neverArmsBypass() {
        var state = AuthState()
        _ = AuthReducer.reduce(&state, .refreshAuthStarted(
            authType: .basic,
            usingExistingCredentials: false
        ))
        XCTAssertFalse(state.ignoreSignedInState,
                       "Basic auth refreshes inline — the bypass would render an unnecessary re-auth UI")
    }

    func testRefreshAuthStarted_tokenAuth_neverArmsBypass() {
        var state = AuthState()
        _ = AuthReducer.reduce(&state, .refreshAuthStarted(
            authType: .token,
            usingExistingCredentials: false
        ))
        XCTAssertFalse(state.ignoreSignedInState)
    }

    func testRefreshAuthStarted_samlWithExistingCredentials_doesNotArmBypass() {
        var state = AuthState()
        _ = AuthReducer.reduce(&state, .refreshAuthStarted(
            authType: .saml,
            usingExistingCredentials: true
        ))
        XCTAssertFalse(state.ignoreSignedInState,
                       "Reusing cached SAML creds (e.g. silent refresh) must not flag the session as expired")
    }

    // MARK: - Final commit / sign-out

    func testUserAccountUpdated_clearsAllInFlightAuthState() {
        var state = AuthState(
            isValidatingCredentials: true,
            ignoreSignedInState: true,
            capturedBarcode: "12345",
            capturedPin: "9999",
            authToken: "stale-token",
            authTokenExpiration: Date(),
            lastErrorTitle: "x",
            lastErrorMessage: "y"
        )
        _ = AuthReducer.reduce(&state, .userAccountUpdated)

        XCTAssertFalse(state.isValidatingCredentials)
        XCTAssertFalse(state.ignoreSignedInState)
        XCTAssertNil(state.capturedBarcode,
                     "After commit the canonical store is TPPUserAccount; in-flight mirrors must be dropped")
        XCTAssertNil(state.capturedPin)
        XCTAssertNil(state.authToken,
                     "Keeping a stale token in the reducer would override TPPUserAccount on the next read")
        XCTAssertNil(state.authTokenExpiration)
        XCTAssertNil(state.lastErrorTitle)
        XCTAssertNil(state.lastErrorMessage)
    }

    func testSignOutCompleted_resetsToInitialState() {
        var state = AuthState(
            isValidatingCredentials: true,
            ignoreSignedInState: true,
            isLoggingInAfterSignUp: true,
            capturedBarcode: "x",
            authToken: "t"
        )
        _ = AuthReducer.reduce(&state, .signOutCompleted)

        XCTAssertFalse(state.isValidatingCredentials)
        XCTAssertFalse(state.ignoreSignedInState)
        XCTAssertFalse(state.isLoggingInAfterSignUp,
                       "signOut must clear the after-signup flag — a future sign-up flow starts fresh")
        XCTAssertNil(state.capturedBarcode)
        XCTAssertNil(state.authToken)
    }

    // MARK: - Error / flag toggles

    func testErrorCleared_dropsPriorErrorWithoutTouchingOtherFields() {
        var state = AuthState(
            isValidatingCredentials: true,
            capturedBarcode: "12345",
            lastErrorTitle: "x",
            lastErrorMessage: "y"
        )
        _ = AuthReducer.reduce(&state, .errorCleared)

        XCTAssertNil(state.lastErrorTitle)
        XCTAssertNil(state.lastErrorMessage)
        XCTAssertTrue(state.isValidatingCredentials,
                      "Dismissing the error banner must not interrupt an in-flight validation")
        XCTAssertEqual(state.capturedBarcode, "12345")
    }

    func testLoggingInAfterSignUpFlagSet_storesValue() {
        var state = AuthState()
        _ = AuthReducer.reduce(&state, .loggingInAfterSignUpFlagSet(true))
        XCTAssertTrue(state.isLoggingInAfterSignUp)
        _ = AuthReducer.reduce(&state, .loggingInAfterSignUpFlagSet(false))
        XCTAssertFalse(state.isLoggingInAfterSignUp)
    }

    // MARK: - Static error classifier

    func testClassifyValidationError_problemDocument_takesPrecedenceOverEverything() throws {
        let json = """
        {"title": "Card expired", "detail": "Renew at your library."}
        """.data(using: .utf8)!
        let pd = try TPPProblemDocument.fromData(json)
        let networkErr = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorNotConnectedToInternet,
            userInfo: nil
        )
        let result = AuthReducer.classifyValidationError(networkErr, problemDocument: pd)
        XCTAssertEqual(result.title, "Card expired",
                       "Server-supplied problem document must beat the connectivity-error fallback")
        XCTAssertEqual(result.message, "Renew at your library.")
    }

    func testClassifyValidationError_networkConnectivityError_returnsConnectivityCopy() {
        let err = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorTimedOut,
            userInfo: nil
        )
        let result = AuthReducer.classifyValidationError(err, problemDocument: nil)
        XCTAssertEqual(result.title, Strings.Error.networkUnavailableErrorTitle,
                       "Without a problem doc, a connectivity error must surface the network-unavailable copy, not 'invalid credentials'")
        XCTAssertEqual(result.message, Strings.Error.networkUnavailableErrorMessage)
    }

    func testClassifyValidationError_genericError_fallsBackToInvalidCredentials() {
        let err = NSError(domain: "com.example.unknown", code: 42, userInfo: nil)
        let result = AuthReducer.classifyValidationError(err, problemDocument: nil)
        XCTAssertEqual(result.title, Strings.Error.invalidCredentialsErrorTitle)
        XCTAssertEqual(result.message, Strings.Error.invalidCredentialsErrorMessage)
    }
}
