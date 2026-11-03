//
//  BookDetailAuthGateTests.swift
//  PalaceTests
//
//  Gated actions ask for sign-in up front when there are no credentials, or
//  when credentials are stale (HelpSpot 17716). A barcode/PIN borrow is the
//  exception: it goes to the server first, and a refusal there opens the
//  sign-in sheet (PP-5449).
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import PalaceCatalog
import PalaceBookModel
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
                         needsAuth: Bool = true,
                         request: BookDetailViewModel.GatedRequest = .borrow) throws -> Bool {
        BookDetailViewModel.promptsSignInBeforeAction(
            needsAuth: needsAuth,
            hasCredentials: hasCredentials,
            authState: authState,
            authDefinition: try type.map { try authentication(type: $0) },
            request: request)
    }

    private func staleBasicAccount() throws -> TPPUserAccountMock {
        let account = TPPUserAccountMock()
        account.authDefinition = try authentication(type: .basic)
        account.credentials = .barcodeAndPin(barcode: "23333000000001", pin: "1234")
        account.setAuthState(.credentialsStale)
        return account
    }

    // MARK: - Barcode/PIN

    /// The reported defect: every Get or Place Hold reopened the sheet before
    /// any request, though the server might still accept the credentials.
    func testGate_WhenBasicCredentialsAreStale_RunsTheBorrow() throws {
        XCTAssertFalse(try prompts(.basic, hasCredentials: true, authState: .credentialsStale))
    }

    /// A refused fulfilment or open shows only an error, so stale barcode/PIN
    /// must still offer sign-in before Download, Read or licence-first Listen.
    func testGate_WhenBasicCredentialsAreStale_PromptsBeforeANonBorrow() throws {
        XCTAssertTrue(try prompts(.basic, hasCredentials: true, authState: .credentialsStale, request: .other))
    }

    func testGate_WhenBasicCredentialsAreFresh_RunsANonBorrow() throws {
        XCTAssertFalse(try prompts(.basic, hasCredentials: true, authState: .loggedIn, request: .other))
    }

    func testGate_WhenNoCredentials_PromptsBeforeANonBorrow() throws {
        XCTAssertTrue(try prompts(.basic, hasCredentials: false, authState: .loggedOut, request: .other))
    }

    // MARK: - Account reading

    /// The production call site reads these four fields from the account; a
    /// dropped auth definition would bring back the up-front prompt on Get.
    func testGateForAccount_WhenStaleBarcodePinBorrows_RunsTheBorrow() throws {
        let account = try staleBasicAccount()
        XCTAssertFalse(BookDetailViewModel.promptsSignInBeforeAction(for: account, request: .borrow))
    }

    func testGateForAccount_WhenStaleBarcodePinDownloadsALoan_Prompts() throws {
        let account = try staleBasicAccount()
        XCTAssertTrue(BookDetailViewModel.promptsSignInBeforeAction(for: account, request: .other))
    }

    func testGateForAccount_WhenSignedOut_PromptsBeforeABorrow() throws {
        let account = TPPUserAccountMock()
        account.authDefinition = try authentication(type: .basic)
        XCTAssertTrue(BookDetailViewModel.promptsSignInBeforeAction(for: account, request: .borrow))
    }

    // MARK: - Download request kind

    /// Get on a book not on loan borrows; every other Download state is a
    /// fulfilment of a loan or a ready hold, which has no refusal sheet.
    func testDownloadRequest_ForEachState_OnlyUnregisteredBorrows() {
        for state in TPPBookState.allCases {
            let expected: BookDetailViewModel.GatedRequest = state == .unregistered ? .borrow : .other
            XCTAssertEqual(BookDetailViewModel.gatedRequest(forDownloadFrom: state), expected, "\(state)")
        }
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
        XCTAssertTrue(try prompts(.saml, hasCredentials: true, authState: .credentialsStale, request: .other))
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
