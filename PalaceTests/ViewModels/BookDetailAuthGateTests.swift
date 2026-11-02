//
//  BookDetailAuthGateTests.swift
//  PalaceTests
//
//  Read, Get and Place Hold ask for sign-in up front only when there are no
//  credentials, or when browser sign-in credentials are stale (HelpSpot
//  17716). Stale barcode/PIN credentials go to the server first; a refusal
//  there opens the sign-in sheet (PP-5449).
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import PalaceCatalog
@testable import Palace

@MainActor
final class BookDetailAuthGateTests: XCTestCase {

    private func authentication(type: AccountDetails.AuthType) throws -> AccountDetails.Authentication {
        let json = """
        {
          "id": "https://cm.example.com/GATE/authentication_document",
          "title": "Gate Library",
          "authentication": [
            {"type": "\(type.rawValue)", "description": "Gate",
             "links": [{"rel": "authenticate", "href": "https://cm.example.com/GATE/authenticate"}],
             "inputs": {"login": {"keyboard": "Default"}, "password": {"keyboard": "Default"}},
             "labels": {"login": "Barcode", "password": "PIN"}}
          ]
        }
        """
        let doc = try OPDS2AuthenticationDocument.fromData(try XCTUnwrap(json.data(using: .utf8)))
        let raw = try XCTUnwrap(doc.authentication?.first)
        return AccountDetails.Authentication(auth: raw)
    }

    private func prompts(_ type: AccountDetails.AuthType?,
                         hasCredentials: Bool,
                         authState: TPPAccountAuthState,
                         needsAuth: Bool = true) throws -> Bool {
        BookDetailViewModel.promptsSignInBeforeAction(
            needsAuth: needsAuth,
            hasCredentials: hasCredentials,
            authState: authState,
            authDefinition: try type.map { try authentication(type: $0) })
    }

    // MARK: - Barcode/PIN

    /// The reported defect: every Read or Place Hold reopened the sheet before
    /// any request, though the server might still accept the credentials.
    func testGate_WhenBasicCredentialsAreStale_RunsTheAction() throws {
        XCTAssertFalse(try prompts(.basic, hasCredentials: true, authState: .credentialsStale))
    }

    func testGate_WhenBasicCredentialsAreFresh_RunsTheAction() throws {
        XCTAssertFalse(try prompts(.basic, hasCredentials: true, authState: .loggedIn))
    }

    func testGate_WhenNoCredentials_PromptsUpFront() throws {
        XCTAssertTrue(try prompts(.basic, hasCredentials: false, authState: .loggedOut))
    }

    func testGate_WhenLibraryNeedsNoAuth_RunsTheAction() throws {
        XCTAssertFalse(try prompts(nil, hasCredentials: false, authState: .loggedOut, needsAuth: false))
    }

    // MARK: - Browser sign-in (HelpSpot 17716)

    func testGate_WhenSAMLCredentialsAreStale_PromptsUpFront() throws {
        XCTAssertTrue(try prompts(.saml, hasCredentials: true, authState: .credentialsStale))
    }

    func testGate_WhenOIDCCredentialsAreStale_PromptsUpFront() throws {
        XCTAssertTrue(try prompts(.oidc, hasCredentials: true, authState: .credentialsStale))
    }

    func testGate_WhenOAuthCredentialsAreStale_PromptsUpFront() throws {
        XCTAssertTrue(try prompts(.oauthIntermediary, hasCredentials: true, authState: .credentialsStale))
    }

    func testGate_WhenSAMLCredentialsAreFresh_RunsTheAction() throws {
        XCTAssertFalse(try prompts(.saml, hasCredentials: true, authState: .loggedIn))
    }

    /// With no stored auth definition the method is unknown, so stale keeps the
    /// up-front prompt it always had.
    func testGate_WhenStaleAndAuthMethodUnknown_PromptsUpFront() throws {
        XCTAssertTrue(try prompts(nil, hasCredentials: true, authState: .credentialsStale))
    }
}
