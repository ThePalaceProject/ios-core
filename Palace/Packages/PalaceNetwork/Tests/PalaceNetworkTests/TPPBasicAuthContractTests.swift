//
//  TPPBasicAuthContractTests.swift
//  PalaceNetworkTests
//
//  Contract tests for TPPBasicAuth — the HTTP-Basic challenge handler used
//  by the network executor. The contract is: with valid credentials and
//  zero previousFailureCount, return .useCredential with the provider's
//  username/password; with previousFailureCount > 0, return
//  .cancelAuthenticationChallenge to avoid retry-storms against bad creds.
//

import XCTest
@testable import PalaceNetwork

final class TPPBasicAuthContractTests: XCTestCase {

    // MARK: - Test stubs

    private final class StubCredentialsProvider: NSObject, NYPLBasicAuthCredentialsProvider {
        let username: String?
        let pin: String?
        init(username: String?, pin: String?) {
            self.username = username
            self.pin = pin
        }
    }

    /// Minimal URLAuthenticationChallenge subclass — the system class can be
    /// constructed with a sender; we stub the sender so calls are inert.
    private final class StubChallengeSender: NSObject, URLAuthenticationChallengeSender {
        func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
        func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
        func cancel(_ challenge: URLAuthenticationChallenge) {}
        func performDefaultHandling(for challenge: URLAuthenticationChallenge) {}
        func rejectProtectionSpace(_ challenge: URLAuthenticationChallenge) {}
    }

    private func makeChallenge(method: String,
                               previousFailureCount: Int) -> URLAuthenticationChallenge {
        let space = URLProtectionSpace(host: "example.com",
                                       port: 443,
                                       protocol: "https",
                                       realm: nil,
                                       authenticationMethod: method)
        return URLAuthenticationChallenge(protectionSpace: space,
                                          proposedCredential: nil,
                                          previousFailureCount: previousFailureCount,
                                          failureResponse: nil,
                                          error: nil,
                                          sender: StubChallengeSender())
    }

    // MARK: - Basic auth, valid creds, no prior failures → useCredential

    func testHandleChallenge_BasicAuth_WithValidCreds_ZeroFailures_UsesCredentialFromProvider() {
        let provider = StubCredentialsProvider(username: "alice", pin: "s3cret")
        let auth = TPPBasicAuth(credentialsProvider: provider)
        let challenge = makeChallenge(method: NSURLAuthenticationMethodHTTPBasic,
                                      previousFailureCount: 0)

        var receivedDisposition: URLSession.AuthChallengeDisposition?
        var receivedCredential: URLCredential?
        auth.handleChallenge(challenge) { disposition, credential in
            receivedDisposition = disposition
            receivedCredential = credential
        }

        XCTAssertEqual(receivedDisposition, .useCredential)
        XCTAssertEqual(receivedCredential?.user, "alice",
                       "Username on the URLCredential must come from the provider, not from elsewhere")
        XCTAssertEqual(receivedCredential?.password, "s3cret",
                       "Password on the URLCredential must come from the provider's pin field")
        XCTAssertEqual(receivedCredential?.persistence, URLCredential.Persistence.none,
                       "Persistence must be .none — credentials are session-scoped, never persisted to keychain by the URL loading system")
    }

    // MARK: - Basic auth, prior failure → cancel (no retry-storm)

    func testHandleChallenge_BasicAuth_WithPriorFailure_CancelsChallenge() {
        let provider = StubCredentialsProvider(username: "alice", pin: "s3cret")
        let auth = TPPBasicAuth(credentialsProvider: provider)
        let challenge = makeChallenge(method: NSURLAuthenticationMethodHTTPBasic,
                                      previousFailureCount: 1)

        var receivedDisposition: URLSession.AuthChallengeDisposition?
        var receivedCredential: URLCredential?
        auth.handleChallenge(challenge) { disposition, credential in
            receivedDisposition = disposition
            receivedCredential = credential
        }

        XCTAssertEqual(receivedDisposition, .cancelAuthenticationChallenge,
                       "Prior failure must short-circuit to .cancel — otherwise a bad-creds response triggers an infinite retry loop")
        XCTAssertNil(receivedCredential,
                     "On cancel, no credential should be passed to the URL loading system")
    }

    // MARK: - Basic auth, missing username → cancel

    func testHandleChallenge_BasicAuth_NilUsername_CancelsChallenge() {
        let provider = StubCredentialsProvider(username: nil, pin: "s3cret")
        let auth = TPPBasicAuth(credentialsProvider: provider)
        let challenge = makeChallenge(method: NSURLAuthenticationMethodHTTPBasic,
                                      previousFailureCount: 0)

        var receivedDisposition: URLSession.AuthChallengeDisposition?
        auth.handleChallenge(challenge) { disposition, _ in
            receivedDisposition = disposition
        }
        XCTAssertEqual(receivedDisposition, .cancelAuthenticationChallenge,
                       "Missing username must cancel — would otherwise crash on force-unwrap or send empty creds")
    }

    func testHandleChallenge_BasicAuth_NilPin_CancelsChallenge() {
        let provider = StubCredentialsProvider(username: "alice", pin: nil)
        let auth = TPPBasicAuth(credentialsProvider: provider)
        let challenge = makeChallenge(method: NSURLAuthenticationMethodHTTPBasic,
                                      previousFailureCount: 0)

        var receivedDisposition: URLSession.AuthChallengeDisposition?
        auth.handleChallenge(challenge) { disposition, _ in
            receivedDisposition = disposition
        }
        XCTAssertEqual(receivedDisposition, .cancelAuthenticationChallenge)
    }

    // MARK: - Server trust → performDefaultHandling

    func testHandleChallenge_ServerTrust_PerformsDefaultHandling() {
        let provider = StubCredentialsProvider(username: "alice", pin: "s3cret")
        let auth = TPPBasicAuth(credentialsProvider: provider)
        let challenge = makeChallenge(method: NSURLAuthenticationMethodServerTrust,
                                      previousFailureCount: 0)

        var receivedDisposition: URLSession.AuthChallengeDisposition?
        auth.handleChallenge(challenge) { disposition, _ in
            receivedDisposition = disposition
        }
        XCTAssertEqual(receivedDisposition, .performDefaultHandling,
                       "Server-trust challenges must defer to system default handling, not be treated as basic-auth")
    }

    // MARK: - Unknown method → rejectProtectionSpace

    func testHandleChallenge_UnknownMethod_RejectsProtectionSpace() {
        let provider = StubCredentialsProvider(username: "alice", pin: "s3cret")
        let auth = TPPBasicAuth(credentialsProvider: provider)
        let challenge = makeChallenge(method: NSURLAuthenticationMethodNTLM,
                                      previousFailureCount: 0)

        var receivedDisposition: URLSession.AuthChallengeDisposition?
        auth.handleChallenge(challenge) { disposition, _ in
            receivedDisposition = disposition
        }
        XCTAssertEqual(receivedDisposition, .rejectProtectionSpace,
                       "Unknown auth methods must reject the protection space, letting the system try other methods")
    }
}
