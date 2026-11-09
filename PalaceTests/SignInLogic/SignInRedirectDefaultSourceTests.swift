//
//  SignInRedirectDefaultSourceTests.swift
//  PalaceTests
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

/// PP-5473 — pins the production wiring of the browser sign-in redirect.
/// Reads `AppContainer.production()` on purpose: the app delegate delivers to
/// that container's relay.
@MainActor
final class SignInRedirectDefaultSourceTests: XCTestCase {

    private var businessLogic: TPPSignInBusinessLogic?

    /// The production relay lives for the whole test process, so cancel the
    /// sign-in's subscription to it here.
    override func tearDownWithError() throws {
        businessLogic?.redirectSubscription = nil
        businessLogic?.userAccount.removeAll()
        businessLogic = nil
        try super.tearDownWithError()
    }

    /// The app delegate delivers to the production container's relay, so a
    /// sign-in built without a test source must listen there.
    func testDefaultRedirectSource_IsTheAppContainersRelay() throws {
        let libraryAccountMock = TPPLibraryAccountMock()
        let production = TPPSignInBusinessLogic(
            libraryAccountID: libraryAccountMock.tppAccountUUID,
            libraryAccountsProvider: libraryAccountMock,
            urlSettingsProvider: TPPURLSettingsProviderMock(),
            bookRegistry: TPPBookRegistryMock(),
            bookDownloadsCenter: TPPMyBooksDownloadsCenterMock(),
            userAccountProvider: TPPUserAccountMock.self,
            networkExecutor: TPPRequestExecutorMock(),
            uiDelegate: TPPSignInOutBusinessLogicUIDelegateMock(),
            drmAuthorizer: TPPDRMAuthorizingMock()
        )
        businessLogic = production
        production.selectedAuthentication = try SignInRedirectRoutingTests.oauthMethod()
        production.openInBrowser = { _ in }
        production.oauthLogIn()

        let base = TPPURLSettingsProviderMock().universalLinksURL.absoluteString
        let redirect = try XCTUnwrap(URL(string: "\(base)#access_token=app-token&patron_info=%7B%22name%22%3A%22Carol%22%7D"))
        AppContainer.production().signInRedirects.deliver(redirect)

        XCTAssertEqual(production.authToken, "app-token")
    }
}
