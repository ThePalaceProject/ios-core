//
//  AccountDetailBasicChallengeTests.swift
//  PalaceTests
//
//  PP-5465. The Account screen is the credentials provider for its sign-in
//  requests, and URLSession asks for those credentials off the main thread.
//  These drive the network layer's challenge callback from a detached task
//  with a real AccountDetailViewModel as the provider.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import PalaceNetwork
@testable import Palace

@MainActor
final class AccountDetailBasicChallengeTests: PalaceTestCase {

    private var viewModel: AccountDetailViewModel!
    private var responder: TPPNetworkResponder!

    override func setUp() {
        super.setUp()
        let appContainer = makeTestAppContainer()
        let signedOut = TPPUserAccount.CredentialSnapshot(
            hasCredentials: false,
            hasAuthToken: false,
            authState: .loggedOut,
            barcode: nil,
            pin: nil,
            authToken: nil,
            authDefinition: nil,
            cookies: nil
        )
        viewModel = AccountDetailViewModel(
            libraryAccountID: "pp5465-basic-challenge",
            accountsManager: appContainer.accountsManager,
            bookRegistry: appContainer.bookRegistry,
            downloadCenter: appContainer.downloadCenter,
            settings: appContainer.settings,
            userAccountPublisher: appContainer.userAccountPublisher,
            drmAuthorizerProvider: { nil },
            credentialSnapshotProvider: { _ in signedOut }
        )
        // The responder holds its provider weakly; the test owns the view model.
        responder = TPPNetworkResponder(credentialsProvider: viewModel,
                                        useFallbackCaching: false,
                                        fallbackCredentialsProvider: { MockCredentialsProvider() })
    }

    override func tearDown() {
        responder = nil
        viewModel = nil
        super.tearDown()
    }

    /// The sign-in request's 401 + `WWW-Authenticate: Basic` is answered with the
    /// barcode and PIN the patron typed, from off the main thread.
    func testBasicChallenge_offMainThread_answersWithTypedCredentials() async {
        viewModel.usernameText = "23456789012345"
        viewModel.pinText = "1234"

        let (disposition, credential) = await respondOffMain(to: basicAuthChallenge())

        XCTAssertEqual(disposition, .useCredential)
        XCTAssertEqual(credential?.user, "23456789012345")
        XCTAssertEqual(credential?.password, "1234")
    }

    /// An edit after the first value must reach the next challenge, so the
    /// off-main copy cannot go stale behind the text field.
    func testBasicChallenge_afterEditingCredentials_answersWithTheLatestValues() async {
        viewModel.usernameText = "11111111111111"
        viewModel.pinText = "0000"
        _ = await respondOffMain(to: basicAuthChallenge())

        viewModel.usernameText = "22222222222222"
        viewModel.pinText = "9999"
        let (disposition, credential) = await respondOffMain(to: basicAuthChallenge())

        XCTAssertEqual(disposition, .useCredential)
        XCTAssertEqual(credential?.user, "22222222222222")
        XCTAssertEqual(credential?.password, "9999")
    }

    /// An empty barcode field means no username, so the challenge is declined
    /// rather than answered with an empty user.
    func testBasicChallenge_withEmptyBarcode_cancels() async {
        viewModel.usernameText = ""
        viewModel.pinText = "1234"

        let (disposition, credential) = await respondOffMain(to: basicAuthChallenge())

        XCTAssertEqual(disposition, .cancelAuthenticationChallenge)
        XCTAssertNil(credential)
    }

    /// PIN-less libraries leave the PIN field empty; the barcode alone still
    /// answers, with an empty password.
    func testBasicChallenge_withEmptyPIN_answersWithEmptyPassword() async {
        viewModel.usernameText = "23456789012345"
        viewModel.pinText = ""

        let (disposition, credential) = await respondOffMain(to: basicAuthChallenge())

        XCTAssertEqual(disposition, .useCredential)
        XCTAssertEqual(credential?.user, "23456789012345")
        XCTAssertEqual(credential?.password, "")
    }

    // MARK: - Helpers

    /// Runs the challenge callback on a detached task, so it never inherits the
    /// main actor from this test — the thread URLSession uses in production.
    private func respondOffMain(
        to challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let responder = self.responder!
        let task = URLSession(configuration: .ephemeral)
            .dataTask(with: URL(string: "https://circulation.palace-test.invalid/loans")!)
        let box = UncheckedBox((challenge, task))
        return await Task.detached {
            XCTAssertFalse(Thread.isMainThread)
            let (challenge, task) = box.value
            let answer = await responder.urlSession(
                URLSession(configuration: .ephemeral),
                task: task,
                didReceive: challenge)
            return UncheckedBox(answer)
        }.value.value
    }

    private func basicAuthChallenge() -> URLAuthenticationChallenge {
        let protectionSpace = URLProtectionSpace(
            host: "circulation.palace-test.invalid",
            port: 443,
            protocol: "https",
            realm: "Palace",
            authenticationMethod: NSURLAuthenticationMethodHTTPBasic)
        return URLAuthenticationChallenge(
            protectionSpace: protectionSpace,
            proposedCredential: nil,
            previousFailureCount: 0,
            failureResponse: nil,
            error: nil,
            sender: MockChallengeSender())
    }
}

/// Carries non-Sendable Foundation values into and out of the detached task.
private struct UncheckedBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
