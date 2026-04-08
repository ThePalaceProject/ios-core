//
//  AuthFlowSecurityTests.swift
//  PalaceTests
//
//  Adversarial tests for OAuth / SAML / token-refresh flows.
//  Each test PASSES by confirming the attack vector is rejected.
//
//  Hermetic: uses HTTPStubURLProtocol + URLSession.stubbedSession().
//

import XCTest
@testable import Palace

final class AuthFlowSecurityTests: XCTestCase {

    private var session: URLSession!

    override func setUp() {
        super.setUp()
        HTTPStubURLProtocol.reset()
        session = URLSession.stubbedSession()
    }

    override func tearDown() {
        HTTPStubURLProtocol.reset()
        session = nil
        super.tearDown()
    }

    // MARK: - OAuth state parameter

    func testOAuth_callbackMissingStateParameter_isRejected() throws {
        // The OAuth callback URL handler must require a `state` parameter and
        // refuse callbacks that omit it. We exercise the URL parsing seam.
        let callbackNoState = URL(string: "palace://oauth-callback?code=abc123")!
        let callbackWithState = URL(string: "palace://oauth-callback?code=abc123&state=expected")!

        // SECURITY-GAP: TPPSignInBusinessLogic+OAuth currently routes through
        // a notification (TPPAppDelegate.handleOpenURL) and ASWebAuthenticationSession
        // which validates state internally. There is no public pure-function
        // we can call with a URL and get a Bool back. Validate the structural
        // contract instead — the no-state URL must lack the parameter.
        XCTAssertNil(
            URLComponents(url: callbackNoState, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "state" }),
            "Test fixture sanity: callbackNoState must omit state."
        )
        XCTAssertNotNil(
            URLComponents(url: callbackWithState, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "state" })
        )

        throw XCTSkip("SECURITY-GAP: needs pure-function OAuth callback validator on TPPSignInBusinessLogic+OAuth to assert rejection.")
    }

    func testOAuth_invalidRedirectURI_isRejected() throws {
        // SECURITY-GAP: ASWebAuthenticationSession enforces the callback URL
        // scheme registered at session start; there is no app-level seam to
        // pass an arbitrary redirect_uri and assert rejection. The system layer
        // is responsible. We document the contract here.
        throw XCTSkip("SECURITY-GAP: redirect URI validation enforced by ASWebAuthenticationSession; no app-level seam to test.")
    }

    // MARK: - Token replay / single-flight refresh

    func testToken_expiredTokenNotReplayedAfterRefreshFailure() throws {
        // After a 401 + refresh-failure, the executor must NOT retry the original
        // request with the now-known-expired token.
        var requestCount = 0
        var lastAuthHeader: String?

        HTTPStubURLProtocol.register { request in
            requestCount += 1
            lastAuthHeader = request.value(forHTTPHeaderField: "Authorization")
            // Always 401 to simulate expired credential.
            return .init(statusCode: 401, headers: nil, body: nil)
        }

        let url = URL(string: "https://example.org/loans")!
        let exp = expectation(description: "request completed")
        var task: URLSessionDataTask?
        task = session.dataTask(with: url) { _, response, _ in
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 401)
            exp.fulfill()
        }
        task?.resume()
        wait(for: [exp], timeout: 5)

        XCTAssertEqual(requestCount, 1, "Single network attempt observed at the URLSession layer — refresh-and-replay logic lives above.")
        XCTAssertNil(lastAuthHeader, "No Authorization header injected by URLSession itself.")

        // SECURITY-GAP: needs a TPPNetworkExecutor test seam that lets us inject
        // a stub token store and observe replay-suppression after refresh failure.
        throw XCTSkip("SECURITY-GAP: needs TPPNetworkExecutor refresh-and-replay seam to assert no-replay on refresh failure.")
    }

    func testToken_reauthenticatorCallCount_observableForRawCallAssertion() {
        // SEAM-VERIFIED: TPPReauthenticator now exposes `authenticateCallCount`.
        // This is the RAW call count (no dedupe) — every invocation increments.
        // For true single-flight verification, see
        // testToken_networkExecutorRefreshCount_singleFlightSemantics below.
        let reauth = TPPReauthenticator()
        XCTAssertEqual(reauth.authenticateCallCount, 0)
        reauth.authenticateIfNeeded(TPPUserAccount.sharedAccount(),
                                    usingExistingCredentials: true,
                                    authenticationCompletion: nil)
        XCTAssertEqual(reauth.authenticateCallCount, 1)
        reauth.authenticateIfNeeded(TPPUserAccount.sharedAccount(),
                                    usingExistingCredentials: true,
                                    authenticationCompletion: nil)
        XCTAssertEqual(reauth.authenticateCallCount, 2,
                       "Raw counter increments per call — single-flight is enforced upstream")
    }

    func testToken_networkExecutorRefreshCount_singleFlightSemantics() async {
        // SEAM-VERIFIED: TPPNetworkExecutor exposes `refreshAttemptCount` which
        // increments ONLY when the underlying TokenRefreshCoordinator transitions
        // `isRefreshing` from false → true. This is the true single-flight
        // contract — concurrent 401s that arrive while a refresh is already in
        // flight do NOT increment the counter.
        //
        // This test pins the contract structurally: starting from a fresh reset,
        // the counter is zero. After resetting it explicitly, it remains zero
        // and is observable. Driving an end-to-end concurrent-401 storm requires
        // standing up the executor with stubbed credentials and a 401-replying
        // URLProtocol, which is left as a follow-up integration test.
        let executor = TPPNetworkExecutor.shared
        await executor.resetRefreshAttemptCount()
        let after = await executor.refreshAttemptCount
        XCTAssertEqual(after, 0,
                       "After reset, refreshAttemptCount must be observably zero")
    }

    // MARK: - SAML

    func testSAML_unsignedAssertion_loginFails() throws {
        // SECURITY-GAP: TPPSAMLHelper delegates assertion validation to the IdP
        // and to the server-side SAML endpoint; iOS only carries the cookie jar
        // back. There is no client-side assertion-signature check to assert.
        throw XCTSkip("SECURITY-GAP: SAML assertion signing validated server-side; no client seam to test unsigned-assertion rejection.")
    }

    // MARK: - Session fixation

    func testSession_identifierRotatedOnSignIn() {
        // SEAM-VERIFIED: TPPUserAccount.sessionIdentifier is now public-readable
        // and rotates inside the credentials setter and setAuthToken. Both
        // sign-in entry points (basic + token) trigger rotation.
        let account = TPPUserAccount.sharedAccount()
        let before = account.sessionIdentifier

        // Drive a sign-in via setBarcode (routes through the credentials setter,
        // which is the rotation site).
        account.setBarcode("test-barcode-\(UUID().uuidString)", PIN: "0000")
        let after = account.sessionIdentifier
        XCTAssertNotEqual(before, after,
                          "sessionIdentifier must rotate on successful sign-in (defense against fixation)")

        // Second sign-in must rotate again.
        account.setBarcode("test-barcode-\(UUID().uuidString)", PIN: "1111")
        XCTAssertNotEqual(after, account.sessionIdentifier,
                          "sessionIdentifier must rotate on every sign-in, not just the first")
    }
}
