//
//  AccountDetailsAuthenticationIsBrowserBasedTests.swift
//  PalaceTests
//
//  Module B of swarm_66819d80 — truth-table coverage for the new
//  `AccountDetails.Authentication.isBrowserBased` predicate that
//  retires six scattered `(isOauth || isSaml || isOidc)` duplications
//  identified in `docs/3.2.0-auth-recon.md` § Section 4.
//
//  The truth table is the mutation-killing surface for the property:
//  the implementation is a single ORed expression, so flipping any
//  operand or returning a constant must fail at least one row.
//
//  Copyright 2026 The Palace Project. All rights reserved.
//

import XCTest
import PalaceCatalog
@testable import Palace

final class AccountDetailsAuthenticationIsBrowserBasedTests: XCTestCase {

    // MARK: - Truth table — one row per auth type

    func testIsBrowserBased_basic_returnsFalse() throws {
        let auth = try makeAuthentication(type: .basic)
        XCTAssertFalse(auth.isBrowserBased,
                       "Basic auth uses an in-app credential prompt, not a browser flow")
    }

    func testIsBrowserBased_oauthIntermediary_returnsTrue() throws {
        let auth = try makeAuthentication(type: .oauthIntermediary)
        XCTAssertTrue(auth.isBrowserBased,
                      "OAuth-intermediary (Clever) routes through the OAuth web sheet — must be browser-based")
    }

    func testIsBrowserBased_saml_returnsTrue() throws {
        let auth = try makeAuthentication(type: .saml)
        XCTAssertTrue(auth.isBrowserBased,
                      "SAML routes through the IdP web sheet — must be browser-based")
    }

    func testIsBrowserBased_oidc_returnsTrue() throws {
        let auth = try makeAuthentication(type: .oidc)
        XCTAssertTrue(auth.isBrowserBased,
                      "OIDC routes through ASWebAuthenticationSession — must be browser-based")
    }

    func testIsBrowserBased_token_returnsFalse() throws {
        let auth = try makeAuthentication(type: .token)
        XCTAssertFalse(auth.isBrowserBased,
                       "Basic-token auth refreshes programmatically against tokenURL — no browser involved")
    }

    func testIsBrowserBased_anonymous_returnsFalse() throws {
        let auth = try makeAuthentication(type: .anonymous)
        XCTAssertFalse(auth.isBrowserBased,
                       "Anonymous libraries (Palace Bookshelf) have no auth flow at all")
    }

    func testIsBrowserBased_coppa_returnsFalse() throws {
        let auth = try makeAuthentication(type: .coppa)
        XCTAssertFalse(auth.isBrowserBased,
                       "COPPA is an age gate, not a credentialed sign-in — no browser involved")
    }

    func testIsBrowserBased_none_returnsFalse() throws {
        let auth = try makeAuthenticationWithUnknownType()
        XCTAssertEqual(auth.authType, .none,
                       "Precondition: unknown OPDS2 auth-type strings must decode to .none")
        XCTAssertFalse(auth.isBrowserBased,
                       "Unknown auth type must default to non-browser to avoid spurious browser-reauth attempts")
    }

    // MARK: - Disambiguation tests
    //
    // `isBrowserBased` is a NEW predicate, not a rename of `needsAuth` or
    // `(isOauth || isOidc)`. These tests pin the distinctions so a future
    // collapse refactor breaks loudly instead of silently.

    /// `needsAuth` is broader than `isBrowserBased` — it includes Basic
    /// + Token (which require credentials but no browser). The four sites
    /// the recon flagged as off-limits (TPPSignInBusinessLogic L376/L652/
    /// L748, AccountDetailViewModel L367) gate on `needsAuth`-style
    /// supersets, not `isBrowserBased`. Pinning the difference here
    /// prevents a "simplify" refactor from substituting one for the other.
    func testIsBrowserBased_vs_needsAuth_areDistinctPredicates() throws {
        let basic = try makeAuthentication(type: .basic)
        XCTAssertTrue(basic.needsAuth, "Basic credentials still require sign-in")
        XCTAssertFalse(basic.isBrowserBased,
                       "...but the sign-in is in-app, not browser-based")

        let token = try makeAuthentication(type: .token)
        XCTAssertTrue(token.needsAuth, "Basic-token requires sign-in")
        XCTAssertFalse(token.isBrowserBased,
                       "...but the token refresh is programmatic, not browser-based")

        let saml = try makeAuthentication(type: .saml)
        XCTAssertTrue(saml.needsAuth, "SAML requires sign-in")
        XCTAssertTrue(saml.isBrowserBased,
                      "...AND the SAML sign-in is browser-based — both predicates fire")

        let anonymous = try makeAuthentication(type: .anonymous)
        XCTAssertFalse(anonymous.needsAuth, "Anonymous needs no sign-in")
        XCTAssertFalse(anonymous.isBrowserBased,
                       "...and obviously no browser either — both predicates agree")
    }

    /// AccountDetailViewModel.swift:367 uses `(isOauth || isOidc)` to
    /// gate a profile-fetch decision; it must NOT collapse to
    /// `isBrowserBased` because SAML doesn't carry a profile endpoint
    /// the same way. This test pins the asymmetry: SAML is browser-based
    /// but is NOT in the `(isOauth || isOidc)` subset.
    func testIsBrowserBased_isStrictSupersetOf_isOauthOrIsOidc_forSaml() throws {
        let saml = try makeAuthentication(type: .saml)
        XCTAssertTrue(saml.isBrowserBased,
                      "SAML belongs to the browser-based family")
        XCTAssertFalse(saml.isOauth || saml.isOidc,
                       "SAML is NOT in the (isOauth || isOidc) subset — profile-fetch site (off-limits 4.7) must remain narrow")
    }

    // MARK: - Helpers

    /// Constructs an `AccountDetails.Authentication` of the requested
    /// auth type via the OPDS2 authentication-document JSON path — the
    /// supported construction route since the memberwise init on the
    /// PalaceCatalog OPDS2 type is module-internal.
    private func makeAuthentication(type: AccountDetails.AuthType) throws -> AccountDetails.Authentication {
        let json = """
        {
          "type": "\(type.rawValue)",
          "description": "isBrowserBased fixture",
          "labels": {"login": "x", "password": "y"}
        }
        """
        let docAuth = try JSONDecoder().decode(
            OPDS2AuthenticationDocument.Authentication.self,
            from: Data(json.utf8)
        )
        return AccountDetails.Authentication(auth: docAuth)
    }

    /// Construction path for the `.none` case — an unknown OPDS2
    /// authentication type string decodes through `AuthType.from(_:)` to
    /// `.none`. We exercise the real decode path rather than synthesising
    /// `.none` directly so the test pins the production fallback.
    private func makeAuthenticationWithUnknownType() throws -> AccountDetails.Authentication {
        let json = """
        {
          "type": "urn:isBrowserBased:test:unknown-auth-type",
          "description": "unknown-type fixture"
        }
        """
        let docAuth = try JSONDecoder().decode(
            OPDS2AuthenticationDocument.Authentication.self,
            from: Data(json.utf8)
        )
        return AccountDetails.Authentication(auth: docAuth)
    }
}
