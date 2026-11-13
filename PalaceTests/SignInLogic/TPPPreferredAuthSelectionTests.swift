//  TPPPreferredAuthSelectionTests.swift
//
//  Libraries advertising several auth methods (e.g. SAML plus a basic-auth
//  fallback) should show the SAML "Sign in" prompt on Account Detail. With no
//  explicit choice, `selectedAuthentication` is nil and the view fell back to
//  basic-auth fields. `selectPreferredAuthIfNeeded()` now auto-selects SAML,
//  then OIDC.

import XCTest
import PalaceCatalog
@testable import Palace

@MainActor
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
        // The single-auth test writes a DIFFERENTLY SHAPED auth document for the
        // NYPL uuid into `AccountStateStore.shared`, which outlives the mock.
        // Each `setUp` rebuilds the mock so the class self-heals, but leaving a
        // 1-auth `.detailsLoaded` under a uuid every other suite reads as
        // multi-auth is the shared-state bleed this repo's teardown rule exists
        // for. Reset it explicitly rather than relying on who runs next.
        //
        // The NARROW reset is deliberate and sufficient ONLY because no test in
        // this class parks an awaiter. `reset(for:)` sends `.notLoaded`, which
        // is non-terminal: `awaitReady()` treats it as `continue`, so a parked
        // Task would survive the boundary and feed the cooperative-pool
        // starvation that hangs mock-based suites. The suites that park
        // awaiters use `_resetAllForTesting()`, which drains terminally
        // (`.detailsEvicted` then `.notLoaded`) at the cost of clobbering every
        // uuid. If an async test is ever added here, switch to that helper.
        if let uuid = libraryAccountMock?.tppAccountUUID {
            AccountStateStore.shared.reset(for: uuid)
        }
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

    /// A library advertising exactly ONE auth method must resolve to that
    /// method, not to nil.
    ///
    /// `selectedAuthentication`'s fallback is
    /// `TPPSignInBusinessLogic.swift:443`:
    ///
    ///     guard auths.count > 1 else { return auths.first }
    ///
    /// Mutating `>` to `>=` makes a one-auth library fall through to
    /// `return nil` — no authentication selected, on the commonest library
    /// shape there is. That mutant SURVIVED the 2026-09-29 run, and this test
    /// exists to kill it.
    ///
    /// An earlier version of this test carried this name, decoded the same
    /// single-auth document, and then asserted `auth.authType == .basic` on
    /// the fixture it had just built — a property of the fixture, never of
    /// the business logic, which it did not reference at all. The name
    /// promised coverage the body did not provide, so a reader grepping for
    /// single-auth coverage found it and stopped looking. That is worse than
    /// the gap it concealed.
    func testSelectedAuthentication_ForSingleAuthLibrary_IsThatAuth() {
        // A single-auth authentication document, assigned to the SAME seam the
        // mock's init uses, so the state machine reaches `.detailsLoaded` the
        // same way it does for the stock multi-auth fixture.
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
        guard let doc = try? OPDS2AuthenticationDocument.fromData(json.data(using: .utf8)!) else {
            return XCTFail("fixture decode failed")
        }
        libraryAccountMock.tppAccount.authenticationDocument = doc
        guard let details = libraryAccountMock.tppAccount.details else {
            return XCTFail("assigning the auth document must populate details")
        }
        libraryAccountMock.tppAccount._setState(.detailsLoaded(details))

        XCTAssertEqual(details.auths.count, 1,
                       "precondition: this fixture must be single-auth, or the test proves nothing")

        XCTAssertEqual(businessLogic.selectedAuthentication?.authType, .basic,
                       "A library with one auth method must resolve to it. Under "
                       + "`auths.count >= 1` this is nil and sign-in offers no method.")
    }

    /// Kept to hold the NAME, not to add coverage.
    ///
    /// This does NOT discriminate the `:443` mutant: under `auths.count >= 1` a
    /// multi-auth fixture still resolves to nil, so this stays green either way.
    /// Both its assertions already exist elsewhere on this branch: the count
    /// precondition in `testPrecondition_NYPLFixtureHasMultipleAuthMethods`,
    /// the nil expectation in
    /// `testSelectPreferredAuth_PicksSAML_WhenMultipleAuthsAndNoneSelected`
    /// and `testAfterAutoSelection_SelectedAuthIsSaml_forMultiAuthLibrary`,
    /// and `test_selectedAuthentication_nilOnMultiAuthLibraryWithNothingChosen`
    /// in `TPPSignInFlowCharacterizationTests`.
    ///
    /// Named, not numbered, deliberately: an earlier version of this comment
    /// cited line numbers and they went stale TWICE inside two amends of the
    /// same commit — one of them ended up pointing into this comment. A
    /// pointer in a durable note has to survive edits above it.
    ///
    /// It earns its place by stopping this file from once again carrying a
    /// single-auth-sounding name over a body that never drives the SUT, which
    /// is how the gap it replaced stayed hidden. Do not count it as coverage,
    /// and do not let a future edit describe it as pinning a boundary.
    func testSelectedAuthentication_ForMultiAuthLibrary_IsNilPendingChoice() {
        XCTAssertGreaterThan(libraryAccountMock.tppAccount.details?.auths.count ?? 0, 1,
                             "precondition: stock fixture is multi-auth")
        XCTAssertNil(businessLogic.selectedAuthentication,
                     "A multi-auth library must not silently pick one")
    }

    // Regression guard: the view's `shouldShowSignInPrompt` reads
    // `selectedAuthentication?.isSaml`. After the fix, this must be true
    // for a multi-auth library that includes SAML. Also verify the state
    // transition: selectedAuthentication is nil before auto-selection and
    // non-nil after (a regression that made auto-selection a no-op would
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
