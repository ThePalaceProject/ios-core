//
//  SignInRedirectDefaultSourceTests.swift
//  PalaceTests
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

/// PP-5473 — the account page's sign-in is the one that opens the browser, so
/// the page built from an app container must listen on that container's
/// redirect relay, where the app delegate delivers.
@MainActor
final class SignInRedirectDefaultSourceTests: XCTestCase {

    func testAccountPageSignIn_ListensOnTheContainersRelay() throws {
        let container = makeTestAppContainer()
        let viewModel = AccountDetailViewModel(
            libraryAccountID: "urn:uuid:pp5473-redirect-wiring-\(UUID().uuidString)",
            appContainer: container
        )
        let signIn = viewModel.businessLogic
        defer { signIn.userAccount.removeAll() }
        signIn.selectedAuthentication = try SignInRedirectRoutingTests.oauthMethod()
        signIn.openInBrowser = { _ in }
        signIn.oauthLogIn()

        let base = container.settings.universalLinksURL.absoluteString
        let redirect = try XCTUnwrap(URL(string: "\(base)#access_token=app-token&patron_info=%7B%22name%22%3A%22Carol%22%7D"))
        container.signInRedirects.deliver(redirect)

        XCTAssertEqual(signIn.authToken, "app-token")
    }
}
