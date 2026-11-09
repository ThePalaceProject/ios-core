//
//  SignInRedirectRoutingTests.swift
//  PalaceTests
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import Combine
import PalaceCatalog
@testable import Palace

/// PP-5473 — a browser sign-in (Clever and other OAuth intermediaries) ends
/// when the app receives a universal link on the redirect host. The app
/// delegate hands it to the relay, and the sign-in that opened the browser
/// takes the next one.
@MainActor
final class SignInRedirectRoutingTests: XCTestCase {

    private var businessLogic: TPPSignInBusinessLogic!
    private var relay: SignInRedirectRelay!
    private var browser: BrowserRecorder!
    private var openedPages: [URL] { browser.pages }
    private var cancellables = Set<AnyCancellable>()
    private let universalLinksURL = TPPURLSettingsProviderMock().universalLinksURL

    override func setUpWithError() throws {
        try super.setUpWithError()
        TPPUserAccountMock.resetShared()
        let libraryAccountMock = TPPLibraryAccountMock()
        businessLogic = TPPSignInBusinessLogic(
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
        businessLogic.selectedAuthentication = try Self.oauthMethod()
        relay = SignInRedirectRelay()
        businessLogic.signInRedirects = { [relay] in relay!.redirects }
        browser = BrowserRecorder()
        businessLogic.openInBrowser = { [browser] url in browser?.pages.append(url) }
    }

    override func tearDownWithError() throws {
        cancellables.removeAll()
        businessLogic.userAccount.removeAll()
        businessLogic = nil
        relay = nil
        try super.tearDownWithError()
    }

    /// An OAuth intermediary method as the circulation manager describes it.
    nonisolated static func oauthMethod() throws -> AccountDetails.Authentication {
        let json = """
        {"type": "http://librarysimplified.org/authtype/OAuth-with-intermediary",
         "description": "Clever",
         "links": [{"rel": "authenticate", "href": "https://cm.example.org/oauth_authenticate?provider=Clever"}]}
        """
        let auth = try JSONDecoder().decode(OPDS2AuthenticationDocument.Authentication.self,
                                            from: Data(json.utf8))
        return AccountDetails.Authentication(auth: auth)
    }

    private func redirect(token: String) -> URL {
        let patron = "%7B%22name%22%3A%22Carol%22%7D"
        return URL(string: "\(universalLinksURL.absoluteString)#access_token=\(token)&patron_info=\(patron)")!
    }

    private func browserActivity(_ url: URL) -> NSUserActivity {
        let activity = NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
        activity.webpageURL = url
        return activity
    }

    // MARK: - Sign-in

    func testOAuthSignIn_OpensTheIntermediaryWithTheRedirectAddress() throws {
        businessLogic.oauthLogIn()

        let page = try XCTUnwrap(openedPages.first)
        let redirectParam = URLComponents(url: page, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "redirect_uri" }?.value
        XCTAssertEqual(redirectParam, universalLinksURL.absoluteString)
        XCTAssertEqual(openedPages.count, 1)
    }

    func testOAuthSignIn_AppliesTheRedirectThatFollows() {
        businessLogic.oauthLogIn()

        relay.deliver(redirect(token: "clever-token"))

        XCTAssertEqual(businessLogic.authToken, "clever-token")
    }

    /// A redirect that arrived before the sign-in started is not replayed to
    /// it; the sign-in takes the next one.
    func testRedirectBeforeSignInStarts_IsNotReplayed() {
        relay.deliver(redirect(token: "stray-token"))

        businessLogic.oauthLogIn()
        XCTAssertNil(businessLogic.authToken)
        relay.deliver(redirect(token: "real-token"))

        XCTAssertEqual(businessLogic.authToken, "real-token")
    }

    /// The sign-in takes one redirect; a second link must not sign in again.
    func testSecondRedirect_IsIgnored() {
        businessLogic.oauthLogIn()
        relay.deliver(redirect(token: "first-token"))
        businessLogic.dispatch(.userAccountUpdated)

        relay.deliver(redirect(token: "second-token"))

        XCTAssertNil(businessLogic.authToken)
    }

    // MARK: - App delegate

    func testUniversalLinkOnTheRedirectHost_IsDeliveredToTheRelay() {
        var delivered: [URL] = []
        relay.redirects.sink { delivered.append($0) }.store(in: &cancellables)
        let url = redirect(token: "tok")

        let handled = TPPAppDelegate.routeSignInRedirect(browserActivity(url),
                                                         universalLinksURL: universalLinksURL,
                                                         to: relay)

        XCTAssertTrue(handled)
        XCTAssertEqual(delivered, [url])
    }

    func testUniversalLinkOnAnotherHost_IsNotDelivered() {
        var delivered: [URL] = []
        relay.redirects.sink { delivered.append($0) }.store(in: &cancellables)

        let handled = TPPAppDelegate.routeSignInRedirect(
            browserActivity(URL(string: "https://elsewhere.example.org/books#access_token=tok")!),
            universalLinksURL: universalLinksURL,
            to: relay)

        XCTAssertFalse(handled)
        XCTAssertEqual(delivered, [])
    }
}

@MainActor
private final class BrowserRecorder {
    var pages: [URL] = []
}
