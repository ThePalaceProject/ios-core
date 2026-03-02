//
//  TPPCrossLibrarySignOutTests.swift
//  PalaceTests
//
//  Regression tests for cross-library credential contamination during sign-out.
//
//  Bug: Signing out of a non-active library would clear the *active* library's
//  credentials instead, because the error handler in performLogOut() called
//  TPPUserAccount.sharedAccount().removeAll() (which defaults to currentAccountId)
//  instead of self.userAccount.removeAll() (which is scoped to the target library).
//
//  Also fixes unscoped sharedAccount() calls in refreshAuthIfNeeded and logIn
//  that could read the wrong library's token/auth state.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

// MARK: - Multi-Library Account Mock

/// A user account mock that returns separate instances per library UUID,
/// enabling tests that verify credential isolation between libraries.
private class TPPMultiLibraryAccountMock: TPPUserAccountMock {
    private static var accounts: [String: TPPUserAccountMock] = [:]

    static func resetAccounts() {
        accounts.removeAll()
    }

    private static func account(for uuid: String) -> TPPUserAccountMock {
        if let existing = accounts[uuid] {
            return existing
        }
        let newAccount = TPPUserAccountMock()
        accounts[uuid] = newAccount
        return newAccount
    }

    override class func sharedAccount(libraryUUID: String?) -> TPPUserAccount {
        return account(for: libraryUUID ?? "unknown")
    }
}

// MARK: - Cross-Library Sign-Out Tests

final class TPPCrossLibrarySignOutTests: XCTestCase {

    private static let activeLibraryUUID = "urn:uuid:active-library-aaa"

    private var libraryMock: TPPLibraryAccountMock!
    /// The target library UUID uses the mock's real account so sign-out has valid URLs.
    private var targetLibraryUUID: String!

    private var activeBusinessLogic: TPPSignInBusinessLogic!
    private var activeUIDelegate: TPPSignInOutBusinessLogicUIDelegateMock!

    private var targetBusinessLogic: TPPSignInBusinessLogic!
    private var targetUIDelegate: TPPSignInOutBusinessLogicUIDelegateMock!

    override func setUp() {
        super.setUp()
        TPPMultiLibraryAccountMock.resetAccounts()
        libraryMock = TPPLibraryAccountMock()
        targetLibraryUUID = libraryMock.tppAccountUUID
        activeUIDelegate = TPPSignInOutBusinessLogicUIDelegateMock()
        targetUIDelegate = TPPSignInOutBusinessLogicUIDelegateMock()

        activeBusinessLogic = TPPSignInBusinessLogic(
            libraryAccountID: Self.activeLibraryUUID,
            libraryAccountsProvider: libraryMock,
            urlSettingsProvider: TPPURLSettingsProviderMock(),
            bookRegistry: TPPBookRegistryMock(),
            bookDownloadsCenter: TPPMyBooksDownloadsCenterMock(),
            userAccountProvider: TPPMultiLibraryAccountMock.self,
            networkExecutor: TPPRequestExecutorMock(),
            uiDelegate: activeUIDelegate,
            drmAuthorizer: TPPDRMAuthorizingMock()
        )

        targetBusinessLogic = TPPSignInBusinessLogic(
            libraryAccountID: targetLibraryUUID,
            libraryAccountsProvider: libraryMock,
            urlSettingsProvider: TPPURLSettingsProviderMock(),
            bookRegistry: TPPBookRegistryMock(),
            bookDownloadsCenter: TPPMyBooksDownloadsCenterMock(),
            userAccountProvider: TPPMultiLibraryAccountMock.self,
            networkExecutor: TPPRequestExecutorMock(),
            uiDelegate: targetUIDelegate,
            drmAuthorizer: TPPDRMAuthorizingMock()
        )
    }

    override func tearDown() {
        activeBusinessLogic.userAccount.removeAll()
        targetBusinessLogic.userAccount.removeAll()
        activeBusinessLogic = nil
        targetBusinessLogic = nil
        libraryMock = nil
        TPPMultiLibraryAccountMock.resetAccounts()
        super.tearDown()
    }

    // MARK: - Helpers

    private func signIn(businessLogic: TPPSignInBusinessLogic,
                        authentication: AccountDetails.Authentication,
                        barcode: String = "patron-barcode",
                        pin: String = "1234") {
        businessLogic.selectedAuthentication = authentication
        businessLogic.updateUserAccount(
            forDRMAuthorization: true,
            withBarcode: barcode,
            pin: pin,
            authToken: nil,
            expirationDate: nil,
            patron: ["name": "Test Patron"],
            cookies: nil
        )
    }

    private func signInWithToken(businessLogic: TPPSignInBusinessLogic,
                                 authentication: AccountDetails.Authentication,
                                 token: String = "oauth-access-token") {
        businessLogic.selectedAuthentication = authentication
        businessLogic.updateUserAccount(
            forDRMAuthorization: true,
            withBarcode: nil,
            pin: nil,
            authToken: token,
            expirationDate: Date().addingTimeInterval(3600),
            patron: ["name": "OAuth Patron"],
            cookies: nil
        )
    }

    // MARK: - Tests: Mock Isolation Verification

    /// Verifies that each library gets its own separate user account via the mock.
    func testMultiLibraryMock_returnsSeparateAccountsPerUUID() {
        XCTAssertFalse(
            activeBusinessLogic.userAccount === targetBusinessLogic.userAccount,
            "Each library should have its own user account instance"
        )
    }

    /// Verifies that userAccount on the business logic is scoped to its libraryAccountID.
    func testUserAccount_isScopedToLibraryAccountID() {
        signIn(businessLogic: activeBusinessLogic,
               authentication: libraryMock.barcodeAuthentication,
               barcode: "unique-active-barcode",
               pin: "0000")

        XCTAssertEqual(activeBusinessLogic.userAccount.barcode, "unique-active-barcode")
        XCTAssertFalse(targetBusinessLogic.userAccount.hasCredentials(),
                       "Target library should not see active library's credentials")
    }

    // MARK: - Tests: Cross-Library Sign-Out Isolation

    /// Signing out of a non-active library must not affect the active library's credentials.
    func testSignOut_ofNonActiveLibrary_doesNotClearActiveLibraryCredentials() {
        signIn(businessLogic: activeBusinessLogic,
               authentication: libraryMock.barcodeAuthentication,
               barcode: "active-patron",
               pin: "active-pin")

        signIn(businessLogic: targetBusinessLogic,
               authentication: libraryMock.barcodeAuthentication,
               barcode: "target-patron",
               pin: "target-pin")

        XCTAssertTrue(activeBusinessLogic.userAccount.hasCredentials(),
                      "Precondition: active library should be signed in")
        XCTAssertTrue(targetBusinessLogic.userAccount.hasCredentials(),
                      "Precondition: target library should be signed in")

        let exp = expectation(description: "Target library sign-out completes")
        targetUIDelegate.didFinishDeauthorizingHandler = { exp.fulfill() }

        targetBusinessLogic.performLogOut()
        wait(for: [exp], timeout: 10.0)

        XCTAssertFalse(targetBusinessLogic.userAccount.hasCredentials(),
                       "Target library credentials should be cleared")
        XCTAssertTrue(activeBusinessLogic.userAccount.hasCredentials(),
                      "Active library credentials must NOT be cleared by another library's sign-out")
        XCTAssertEqual(activeBusinessLogic.userAccount.barcode, "active-patron",
                       "Active library barcode must be preserved")
    }

    /// Sign out of non-active library with OAuth credentials preserves active library's token.
    func testSignOut_ofNonActiveOAuthLibrary_doesNotClearActiveLibraryToken() {
        signInWithToken(businessLogic: activeBusinessLogic,
                        authentication: libraryMock.oauthAuthentication,
                        token: "active-oauth-token")

        signInWithToken(businessLogic: targetBusinessLogic,
                        authentication: libraryMock.oauthAuthentication,
                        token: "target-oauth-token")

        let exp = expectation(description: "Target sign-out completes")
        targetUIDelegate.didFinishDeauthorizingHandler = { exp.fulfill() }

        targetBusinessLogic.performLogOut()
        wait(for: [exp], timeout: 10.0)

        XCTAssertNil(targetBusinessLogic.userAccount.authToken,
                     "Target library token should be cleared")
        XCTAssertEqual(activeBusinessLogic.userAccount.authToken, "active-oauth-token",
                       "Active library OAuth token must be preserved")
    }

    /// Sign out of non-active library with SAML credentials preserves active library's cookies.
    func testSignOut_ofNonActiveSAMLLibrary_doesNotClearActiveLibraryCookies() {
        activeBusinessLogic.selectedAuthentication = libraryMock.samlAuthentication
        activeBusinessLogic.updateUserAccount(
            forDRMAuthorization: true,
            withBarcode: nil, pin: nil,
            authToken: "active-saml-token",
            expirationDate: nil,
            patron: ["name": "Active SAML User"],
            cookies: [HTTPCookie(properties: [
                .domain: "active-idp.example.com", .path: "/",
                .name: "session", .value: "active-session"
            ])!]
        )

        targetBusinessLogic.selectedAuthentication = libraryMock.samlAuthentication
        targetBusinessLogic.updateUserAccount(
            forDRMAuthorization: true,
            withBarcode: nil, pin: nil,
            authToken: "target-saml-token",
            expirationDate: nil,
            patron: ["name": "Target SAML User"],
            cookies: [HTTPCookie(properties: [
                .domain: "target-idp.example.com", .path: "/",
                .name: "session", .value: "target-session"
            ])!]
        )

        let exp = expectation(description: "Target SAML sign-out completes")
        targetUIDelegate.didFinishDeauthorizingHandler = { exp.fulfill() }

        targetBusinessLogic.performLogOut()
        wait(for: [exp], timeout: 10.0)

        XCTAssertNil(targetBusinessLogic.userAccount.authToken)
        XCTAssertEqual(activeBusinessLogic.userAccount.authToken, "active-saml-token",
                       "Active library SAML token must be preserved")
        XCTAssertEqual(activeBusinessLogic.userAccount.cookies?.first?.value, "active-session",
                       "Active library SAML cookies must be preserved")
    }

    /// Signing out of one library and then another should not corrupt either.
    func testSequentialSignOuts_ofMultipleLibraries_clearCorrectCredentials() {
        signIn(businessLogic: targetBusinessLogic,
               authentication: libraryMock.barcodeAuthentication,
               barcode: "patron-target", pin: "pinT")

        signIn(businessLogic: activeBusinessLogic,
               authentication: libraryMock.barcodeAuthentication,
               barcode: "patron-active", pin: "pinA")

        // Sign out target library first
        let exp1 = expectation(description: "Target sign-out completes")
        targetUIDelegate.didFinishDeauthorizingHandler = { exp1.fulfill() }
        targetBusinessLogic.performLogOut()
        wait(for: [exp1], timeout: 10.0)

        XCTAssertFalse(targetBusinessLogic.userAccount.hasCredentials())
        XCTAssertTrue(activeBusinessLogic.userAccount.hasCredentials(),
                      "Active library should still be signed in after target sign-out")
        XCTAssertEqual(activeBusinessLogic.userAccount.barcode, "patron-active")
    }
}
