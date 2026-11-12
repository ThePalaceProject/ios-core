//
//  TPPSignInAppNetworkInjectionTests.swift
//  PalaceTests
//
//  Token sign-in and token refresh reach the network and the current account
//  only through what the business logic was built with (PP-5544).
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import PalaceCatalog
@testable import Palace

@MainActor
final class TPPSignInAppNetworkInjectionTests: XCTestCase {

    nonisolated private static let tokenURL = URL(string: "https://cm.example.test/lib/token")!
    private var tokenURL: URL { Self.tokenURL }
    private var libraryMock: TPPLibraryAccountMock!
    private var userAccount: TPPUserAccountMock!
    private var appNetwork: SignInAppNetworkSpy!
    private var uiDelegate: TPPSignInOutBusinessLogicUIDelegateMock!
    private var businessLogic: TPPSignInBusinessLogic!

    override func setUpWithError() throws {
        try super.setUpWithError()
        libraryMock = TPPLibraryAccountMock()
        userAccount = TPPUserAccountMock()
        userAccount._authDefinition = try Self.makeTokenAuthentication()
        libraryMock.userAccountResolver = { [userAccount = userAccount!] _ in userAccount }
        appNetwork = SignInAppNetworkSpy()
        uiDelegate = TPPSignInOutBusinessLogicUIDelegateMock()
        businessLogic = TPPSignInBusinessLogic(
            libraryAccountID: libraryMock.tppAccountUUID,
            libraryAccountsProvider: libraryMock,
            urlSettingsProvider: TPPURLSettingsProviderMock(),
            bookRegistry: TPPBookRegistryMock(),
            bookDownloadsCenter: TPPMyBooksDownloadsCenterMock(),
            userAccountProvider: TPPUserAccountMock.self,
            networkExecutor: TPPRequestExecutorMock(),
            uiDelegate: uiDelegate,
            drmAuthorizer: TPPDRMAuthorizingMock(),
            appNetwork: appNetwork
        )
    }

    override func tearDown() {
        businessLogic = nil
        uiDelegate = nil
        appNetwork = nil
        userAccount = nil
        libraryMock = nil
        super.tearDown()
    }

    nonisolated private static func makeTokenAuthentication() throws -> AccountDetails.Authentication {
        let json = """
        {"type": "\(AccountDetails.AuthType.token.rawValue)",
         "links": [{"rel": "authenticate", "href": "\(Self.tokenURL.absoluteString)"}]}
        """
        let auth = try JSONDecoder().decode(OPDS2AuthenticationDocument.Authentication.self,
                                            from: Data(json.utf8))
        return AccountDetails.Authentication(auth: auth)
    }

    /// An expired token on the provider's current account is refreshed through
    /// the injected app network with the stored barcode and PIN.
    func testRefreshAuthIfNeeded_expiredToken_refreshesThroughInjectedAppNetwork() async {
        XCTAssertEqual(userAccount.authDefinition?.tokenURL, tokenURL, "precondition: token auth fixture")
        userAccount.setAuthToken("expired", barcode: "23333000", pin: "4321",
                                 expirationDate: Date().addingTimeInterval(-3600))

        let completed = expectation(description: "refresh completion")
        _ = businessLogic.refreshAuthIfNeeded(usingExistingCredentials: true) { completed.fulfill() }
        await fulfillment(of: [completed], timeout: 5)  // STARVE-001-OK: the spy completes inline; the completion hops once to the main actor

        XCTAssertEqual(appNetwork.tokenRequests, [
            .init(username: "23333000", password: "4321", tokenURL: tokenURL,
                  accountId: libraryMock.tppAccountUUID)
        ])
    }

    /// A token that has not expired needs no refresh, so nothing reaches the network.
    func testRefreshAuthIfNeeded_unexpiredToken_returnsFalseWithoutTokenRequest() {
        userAccount.setAuthToken("fresh", barcode: "23333000", pin: "4321",
                                 expirationDate: Date().addingTimeInterval(3600))
        var completed = false

        let needsUI = businessLogic.refreshAuthIfNeeded(usingExistingCredentials: true) { completed = true }

        XCTAssertFalse(needsUI)
        XCTAssertTrue(completed, "the no-refresh branch completes synchronously")
        XCTAssertTrue(appNetwork.tokenRequests.isEmpty)
    }

    /// Token sign-in exchanges the typed credentials through the injected app network.
    func testLogIn_tokenAuth_exchangesTypedCredentialsThroughInjectedAppNetwork() async throws {
        businessLogic.selectedAuthentication = try Self.makeTokenAuthentication()
        uiDelegate.username = "patron-77"
        uiDelegate.pin = "9090"

        await businessLogic.logIn(with: tokenURL)
        await businessLogic._awaitSignInWorkForTesting()

        XCTAssertEqual(appNetwork.tokenRequests, [
            .init(username: "patron-77", password: "9090", tokenURL: tokenURL,
                  accountId: libraryMock.tppAccountUUID)
        ])
    }

    /// Barcode/PIN auth with nothing stored asks for the sign-in form.
    func testRefreshAuthIfNeeded_basicAuthWithoutStoredCredentials_needsSignInUI() {
        userAccount._authDefinition = libraryMock.basicAuthentication
        var completed = false

        let needsUI = businessLogic.refreshAuthIfNeeded(usingExistingCredentials: true) { completed = true }

        XCTAssertTrue(needsUI)
        XCTAssertFalse(completed, "the completion waits for the patron to sign in")
        XCTAssertTrue(appNetwork.tokenRequests.isEmpty)
    }

    /// OAuth always goes back through the browser sign-in.
    func testRefreshAuthIfNeeded_oauth_needsSignInUI() {
        userAccount._authDefinition = libraryMock.oauthAuthentication
        var completed = false

        let needsUI = businessLogic.refreshAuthIfNeeded(usingExistingCredentials: false) { completed = true }

        XCTAssertTrue(needsUI)
        XCTAssertFalse(completed)
    }

    /// SAML and OIDC go back through the browser sign-in.
    func testRefreshAuthIfNeeded_samlAndOIDC_needSignInUI() {
        for auth in [libraryMock.samlAuthentication, libraryMock.oidcAuthentication] {
            userAccount._authDefinition = auth
            var completed = false

            let needsUI = businessLogic.refreshAuthIfNeeded(usingExistingCredentials: false) { completed = true }

            XCTAssertTrue(needsUI, "\(auth.authType)")
            XCTAssertFalse(completed, "\(auth.authType)")
        }
    }
}
