import XCTest
@testable import PalaceAuth

/// Smoke coverage for the moved-into-package `AuthReducer`. The bulk of
/// AuthReducer tests live in `PalaceTests/SignInLogic/AuthReducerTests.swift`
/// (impl 4 will retarget them at PalaceAuth); this file pins the most
/// critical state transition — `signOutCompleted` MUST blow away every
/// in-flight credential mirror — so a regression in the package is caught
/// even before the main-target test bundle runs.
final class PalaceAuthSmokeTests: XCTestCase {

    func test_signOutCompleted_clearsCapturedCredentials() {
        var state = AuthState(
            capturedBarcode: "12345",
            capturedPin: "9999",
            authToken: "stale-bearer",
            authTokenExpiration: Date(),
            lastErrorTitle: "Was Bad",
            lastErrorMessage: "Try again"
        )

        _ = AuthReducer.reduce(&state, .signOutCompleted)

        XCTAssertNil(state.capturedBarcode)
        XCTAssertNil(state.capturedPin)
        XCTAssertNil(state.authToken)
        XCTAssertNil(state.authTokenExpiration)
        XCTAssertNil(state.lastErrorTitle)
        XCTAssertNil(state.lastErrorMessage)
        XCTAssertFalse(state.isValidatingCredentials)
        XCTAssertFalse(state.ignoreSignedInState)
    }

    func test_refreshAuthStarted_armsBypass_onlyForBrowserFlows_withoutCachedCreds() {
        // SAML, no cached creds → bypass armed (need to re-auth via browser)
        var samlState = AuthState()
        _ = AuthReducer.reduce(
            &samlState,
            .refreshAuthStarted(authType: .saml, usingExistingCredentials: false)
        )
        XCTAssertTrue(samlState.ignoreSignedInState)

        // SAML, cached creds → bypass NOT armed (silent refresh OK)
        var samlCachedState = AuthState()
        _ = AuthReducer.reduce(
            &samlCachedState,
            .refreshAuthStarted(authType: .saml, usingExistingCredentials: true)
        )
        XCTAssertFalse(samlCachedState.ignoreSignedInState)

        // Basic, no cached creds → bypass NOT armed (no browser, refresh inline)
        var basicState = AuthState()
        _ = AuthReducer.reduce(
            &basicState,
            .refreshAuthStarted(authType: .basic, usingExistingCredentials: false)
        )
        XCTAssertFalse(basicState.ignoreSignedInState)
    }
}
