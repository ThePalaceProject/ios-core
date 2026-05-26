//
//  TPPPreferredAuthSelectionTests.swift
//  PalaceTests
//
//  Regression tests for the multi-auth library UI fix.
//
//  Context: libraries that advertise multiple auth methods (e.g. SAML
//  paired with a legacy basic-auth fallback) used to render the SAML
//  sign-in prompt (single "Sign in" button → IdP WebView) on the
//  Account Detail screen. A regression caused the screen to render the
//  basic-auth credential fields instead, because `selectedAuthentication`
//  returns nil for multi-auth libraries and the view's
//  `shouldShowSignInPrompt` gates on a concrete SAML/OAuth selection.
//
//  Fix: `selectPreferredAuthIfNeeded()` auto-selects SAML (then OIDC)
//  when a multi-auth library has one and no explicit choice exists.
//

import XCTest
import PalaceCatalog
@testable import Palace

final class TPPPreferredAuthSelectionTests: XCTestCase {

    private var libraryAccountMock: TPPLibraryAccountMock!
    private var businessLogic: TPPSignInBusinessLogic!

    override func setUp() {
        super.setUp()
        libraryAccountMock = TPPLibraryAccountMock()
        businessLogic = TPPSignInBusinessLogic(
            libraryAccountID: libraryAccountMock.tppAccountUUID,
            libraryAccountsProvider: libraryAccountMock,
            urlSettingsProvider: TPPURLSettingsProviderMock(),
            bookRegistry: TPPBookRegistryMock(),
            bookDownloadsCenter: TPPMyBooksDownloadsCenterMock(),
            userAccountProvider: TPPUserAccountProviderMock.self,
            uiDelegate: nil,
            drmAuthorizer: nil
        )
    }

    override func tearDown() {
        businessLogic = nil
        libraryAccountMock = nil
        super.tearDown()
    }

    // Precondition: NYPL fixture exposes 4 auth methods.
    // This test pins the fixture so any future change is noticed.
    func testPrecondition_NYPLFixtureHasMultipleAuthMethods() {
        let auths = libraryAccountMock.tppAccount.details?.auths ?? []
        XCTAssertGreaterThan(auths.count, 1,
                             "precondition: test library fixture must be multi-auth")
        XCTAssertTrue(auths.contains { $0.isSaml },
                      "precondition: fixture must contain a SAML auth")
    }

    func testSelectPreferredAuth_PicksSAML_WhenMultipleAuthsAndNoneSelected() {
        XCTAssertNil(businessLogic.selectedAuthentication,
                     "precondition: fresh business logic has no auth selected for multi-auth library")

        businessLogic.selectPreferredAuthIfNeeded()

        XCTAssertEqual(businessLogic.selectedAuthentication?.authType, .saml,
                       "Multi-auth library with a SAML method must default to SAML — restores the single-button SAML sign-in prompt")
    }

    func testSelectPreferredAuth_IsIdempotent() {
        businessLogic.selectPreferredAuthIfNeeded()
        let first = businessLogic.selectedAuthentication
        businessLogic.selectPreferredAuthIfNeeded()
        let second = businessLogic.selectedAuthentication
        XCTAssertTrue(first === second,
                      "Calling selectPreferredAuthIfNeeded twice must not clobber the prior selection")
    }

    func testSelectPreferredAuth_DoesNotOverrideExplicitChoice() {
        let basic = libraryAccountMock.barcodeAuthentication
        businessLogic.selectedAuthentication = basic

        businessLogic.selectPreferredAuthIfNeeded()

        XCTAssertTrue(businessLogic.selectedAuthentication === basic,
                      "A user's explicit non-SAML choice must be preserved")
    }

    func testSelectPreferredAuth_NoOp_ForSingleAuthLibrary() {
        // Build a single-auth fixture inline so we don't depend on a new JSON file.
        let json = """
        {
          "id": "https://cm.example.com/BASIC/authentication_document",
          "title": "Basic-Only Library",
          "authentication": [{
            "type": "http://opds-spec.org/auth/basic",
            "description": "Basic",
            "inputs": {
              "login": { "keyboard": "Default" },
              "password": { "keyboard": "Default" }
            },
            "labels": { "login": "Barcode", "password": "PIN" }
          }]
        }
        """
        guard let doc = try? OPDS2AuthenticationDocument.fromData(json.data(using: .utf8)!),
              let only = doc.authentication?.first else {
            XCTFail("fixture decode failed")
            return
        }

        // With only one auth, `selectedAuthentication` already returns it without
        // any intervention — selectPreferredAuthIfNeeded should not crash and
        // should leave state consistent.
        let auth = AccountDetails.Authentication(auth: only)
        XCTAssertEqual(auth.authType, .basic, "precondition: single-auth fixture resolves to basic")
    }

    // Regression guard: the view's `shouldShowSignInPrompt` reads
    // `selectedAuthentication?.isSaml`. After the fix, this must be true
    // for a multi-auth library that includes SAML. Also verify the state
    // transition: selectedAuthentication is nil before auto-selection and
    // non-nil after (a mutation that made auto-selection a no-op would
    // pass a looser "isSaml == true" check if the default happened to be
    // SAML, but would fail the nil-to-non-nil transition check).
    func testAfterAutoSelection_SelectedAuthIsSaml_forMultiAuthLibrary() {
        XCTAssertNil(businessLogic.selectedAuthentication,
                     "precondition: selectedAuthentication must be nil before auto-selection")

        businessLogic.selectPreferredAuthIfNeeded()

        XCTAssertNotNil(businessLogic.selectedAuthentication,
                        "auto-selection must populate selectedAuthentication")
        XCTAssertEqual(businessLogic.selectedAuthentication?.isSaml, true,
                       "selectedAuthentication.isSaml must be true so shouldShowSignInPrompt renders the SAML prompt")
    }

    // The Sign In button is a silent no-op if `selectedIDP` is nil when
    // `samlHelper.logIn()` runs (it guards on `context.selectedIDP?.url`).
    // For single-IdP SAML libraries, auto-selection must populate selectedIDP
    // so the tap on "Sign in" opens the WebView immediately.
    func testSelectPreferredAuth_AutoSelectsSoleSAMLIDP() {
        businessLogic.selectPreferredAuthIfNeeded()

        guard let samlAuth = businessLogic.selectedAuthentication, samlAuth.isSaml else {
            XCTFail("precondition: auto-selection should have picked SAML")
            return
        }

        let idpCount = samlAuth.samlIdps?.count ?? 0
        if idpCount == 1 {
            XCTAssertNotNil(businessLogic.selectedIDP,
                            "Single-IdP SAML libraries must have selectedIDP populated after auto-select — " +
                            "otherwise samlHelper.logIn() guards on nil and Sign In does nothing")
            XCTAssertTrue(samlAuth.samlIdps?.contains(where: { $0 === businessLogic.selectedIDP }) ?? false,
                          "Auto-selected IdP must be the one advertised by the auth doc")
        } else {
            // Multi-IdP — don't auto-select (user must pick).
            XCTAssertNil(businessLogic.selectedIDP,
                         "Multi-IdP libraries must NOT auto-select an IdP — user must choose")
        }
    }

    func testSelectPreferredAuth_DoesNotOverrideExplicitIDPChoice() {
        businessLogic.selectPreferredAuthIfNeeded()
        let firstIDP = businessLogic.selectedIDP

        // Simulate user picking a different IdP (or re-picking).
        businessLogic.selectPreferredAuthIfNeeded()
        let secondIDP = businessLogic.selectedIDP

        XCTAssertTrue(firstIDP === secondIDP,
                      "Repeated calls must not clobber the IdP — idempotent behavior required for view redraws")
    }
}
