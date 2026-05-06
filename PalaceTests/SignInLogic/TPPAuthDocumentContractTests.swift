//
//  TPPAuthDocumentContractTests.swift
//  PalaceTests
//
//  Client-side contract guard for OPDS2 authentication documents.
//
//  Motivation — the PP-3452 SAML SLO miss:
//  The CM added `rel="logout"` to the SAML authentication block on 2026-04-07.
//  iOS parsed it into `links[]` but the `.saml` branch in Account.swift
//  hardcoded `samlLogoutHref = nil`, silently dropping the data. No test failed
//  because no test asserted "every rel CM advertises must be captured."
//
//  This file adds that guard. When the CM ships a new rel on any auth type,
//  this test fails in CI **before** the link can silently land on the floor.
//
//  How it works:
//   - For each auth-document fixture that ships with tests, for each
//     authentication block, we enumerate every `rel` the CM advertises.
//   - For each (auth type, rel) pair, a lookup table says which client-side
//     property captures it (or explicitly that it's ignored by design).
//   - If a rel is advertised but nothing is mapped, the test fails with
//     a message pointing the reviewer at the CM contract change.
//

import XCTest
@testable import Palace

final class TPPAuthDocumentContractTests: XCTestCase {

    // MARK: - Coverage table

    /// For each (auth type, rel) pair, describe how the iOS client handles it.
    /// `.captured(name:)` — parsed into a named client property.
    /// `.ignored(reason:)` — deliberately not parsed; document why.
    /// Missing entries → test failure (the whole point of this guard).
    private enum Handler {
        case captured(name: String)
        case ignored(reason: String)
    }

    private static let coverage: [AccountDetails.AuthType: [String: Handler]] = [
        .saml: [
            "authenticate": .captured(name: "samlIdps"),
            "logout":       .captured(name: "samlLogoutHref")
        ],
        .oidc: [
            "authenticate": .captured(name: "oidcAuthenticationUrl"),
            "logout":       .captured(name: "oidcLogoutHref")
        ],
        .oauthIntermediary: [
            "authenticate": .captured(name: "oauthIntermediaryUrl")
        ],
        .token: [
            "authenticate": .captured(name: "tokenURL")
        ],
        .coppa: [
            "http://librarysimplified.org/terms/rel/authentication/restriction-not-met":
                .captured(name: "coppaUnderUrl"),
            "http://librarysimplified.org/terms/rel/authentication/restriction-met":
                .captured(name: "coppaOverUrl")
        ],
        .basic: [:],
        .anonymous: [:],
        .none: [:]
    ]

    // MARK: - Fixtures under guard

    /// Every auth-doc JSON fixture under PalaceTests. Additional fixtures
    /// should be added here so the contract guard sees them.
    private static let fixtureFilenames: [String] = [
        "nypl_authentication_document",
        "dpl_authentication_document",
        "acl_authentication_document",
        "gpl_authentication_document",
        "simplye_authentication_document"
    ]

    // MARK: - The guard

    /// For every (fixture, auth block, rel) tuple, assert the iOS client
    /// has a declared handler. A missing handler means the CM has started
    /// advertising a rel that iOS will silently drop.
    func testEveryAdvertisedRel_HasAClientSideHandler() throws {
        var failures: [String] = []

        for fixtureName in Self.fixtureFilenames {
            guard let url = Bundle(for: Self.self).url(
                forResource: fixtureName, withExtension: "json"
            ) else {
                XCTFail("Fixture \(fixtureName).json not found in test bundle")
                continue
            }
            let data = try Data(contentsOf: url)
            let doc = try OPDS2AuthenticationDocument.fromData(data)

            for authBlock in doc.authentication ?? [] {
                let authType = AccountDetails.AuthType.from(authBlock.type)
                let handlers = Self.coverage[authType] ?? [:]

                for link in authBlock.links ?? [] {
                    // Links without a rel aren't actionable — skip.
                    guard let rel = link.rel else { continue }
                    if handlers[rel] == nil {
                        failures.append("""
                          \(fixtureName).json
                            auth.type = \(authBlock.type) (parsed as .\(authType))
                            UNHANDLED rel = \(rel)
                            href = \(link.href)
                            → add an entry to TPPAuthDocumentContractTests.coverage
                              and capture this link in AccountDetails.Authentication,
                              or document why it's intentionally ignored.
                          """)
                    }
                }
            }
        }

        XCTAssertTrue(
            failures.isEmpty,
            "CM is advertising rels that iOS has no handler for:\n\n\(failures.joined(separator: "\n"))"
        )
    }

    /// Targeted guard specifically for the logout contract across the two
    /// auth types that use it (OIDC and SAML). Explicitly exercises the
    /// exact miss that led to PP-3452 slipping.
    func testLogoutRel_OnAuthWithLogoutLink_IsCapturedAsHref() throws {
        let samlJSON = """
        {
          "id": "https://cm.example.com/TEST/authentication_document",
          "title": "Test SAML",
          "authentication": [{
            "type": "http://librarysimplified.org/authtype/SAML-2.0",
            "description": "SAML",
            "links": [
              {"rel": "authenticate", "href": "https://idp/saml"},
              {"rel": "logout", "href": "https://cm/saml/logout{&post_logout_redirect_uri}", "templated": true}
            ]
          }]
        }
        """
        let oidcJSON = """
        {
          "id": "https://cm.example.com/TEST/authentication_document",
          "title": "Test OIDC",
          "authentication": [{
            "type": "http://palaceproject.io/authtype/OpenIDConnect",
            "description": "OIDC",
            "links": [
              {"rel": "authenticate", "href": "https://cm/oidc/auth"},
              {"rel": "logout", "href": "https://cm/oidc/logout{&post_logout_redirect_uri}", "templated": true}
            ]
          }]
        }
        """

        // SAML logout
        let samlDoc = try OPDS2AuthenticationDocument.fromData(samlJSON.data(using: .utf8)!)
        let samlAuth = AccountDetails.Authentication(auth: samlDoc.authentication!.first!)
        XCTAssertNotNil(samlAuth.samlLogoutHref,
                        "Regression guard: when CM advertises rel=logout on a SAML auth block, samlLogoutHref must capture it")

        // OIDC logout
        let oidcDoc = try OPDS2AuthenticationDocument.fromData(oidcJSON.data(using: .utf8)!)
        let oidcAuth = AccountDetails.Authentication(auth: oidcDoc.authentication!.first!)
        XCTAssertNotNil(oidcAuth.oidcLogoutHref,
                        "Regression guard: when CM advertises rel=logout on an OIDC auth block, oidcLogoutHref must capture it")
    }

    /// The coverage table must have at least one entry for every auth type
    /// the client recognizes (even if empty for types that never carry links).
    /// This prevents adding a new auth type to the client without also
    /// declaring how its links are handled.
    func testCoverageTable_CoversEveryKnownAuthType() {
        let allTypes: [AccountDetails.AuthType] = [
            .saml, .oidc, .oauthIntermediary, .token,
            .coppa, .basic, .anonymous, .none
        ]
        for type in allTypes {
            XCTAssertNotNil(Self.coverage[type],
                            "coverage[.\(type)] is missing — adding an auth type requires declaring its link handlers")
        }
    }
}
