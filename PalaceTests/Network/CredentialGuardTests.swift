//
//  CredentialGuardTests.swift
//  PalaceTests
//
//  Regression tests for the Pattern 1 Crashlytics issue: the CM's
//  server_side_validation rejected token requests because the app
//  intermittently sent empty or malformed Basic Auth credentials.
//
//  These tests verify the three-layered defense added in PR #791:
//    1. TokenRequest.execute() guards against empty username/password
//    2. TPPNetworkExecutor.refreshTokenAndResume() guards against empty credentials
//    3. URLSessionConfiguration.urlCredentialStorage is nil (no stale cred replay)
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import XCTest
import PalaceAuth
import PalaceNetwork
@testable import Palace

// MARK: - TokenRequest Empty Credential Guards

@MainActor
final class TokenRequestCredentialGuardTests: XCTestCase {

    private let tokenURL = URL(string: "https://example.com/patrons/me/token/")!

    override func setUp() {
        super.setUp()
        HTTPStubURLProtocol.reset()
    }

    override func tearDown() {
        HTTPStubURLProtocol.reset()
        super.tearDown()
    }

    // MARK: Empty Credential Rejection

    func testExecute_EmptyUsername_ReturnsFailureWithoutNetworkCall() async {
        let request = TokenRequest(url: tokenURL, username: "", password: "validpin")

        HTTPStubURLProtocol.register { _ in
            XCTFail("Network request should not be made with empty username")
            return nil
        }

        let session = URLSession.stubbedSession()
        let result = await request.execute(session: session)

        switch result {
        case .success:
            XCTFail("Expected failure for empty username")
        case .failure(let error):
            XCTAssertTrue(error.localizedDescription.contains("empty username"),
                          "Error should mention empty username, got: \(error.localizedDescription)")
        }
    }

    /// Empty password is valid for pinless libraries (PP-4045).
    /// Libraries like Wolcott Public Library and Bentley Memorial Library
    /// do not require a PIN. Basic Auth sends "barcode:" with empty password.
    func testExecute_EmptyPassword_PinlessLogin_MakesNetworkCall() async {
        let request = TokenRequest(url: tokenURL, username: "23160026460829", password: "")

        var networkCallMade = false
        HTTPStubURLProtocol.register { req in
            networkCallMade = true
            // Verify Basic Auth header is present with barcode and empty password
            let authHeader = req.value(forHTTPHeaderField: "Authorization") ?? ""
            XCTAssertTrue(authHeader.hasPrefix("Basic "), "Should have Basic auth header")
            // Decode and verify format is "barcode:"
            if let base64Data = Data(base64Encoded: authHeader.replacingOccurrences(of: "Basic ", with: "")),
               let credential = String(data: base64Data, encoding: .utf8) {
                XCTAssertEqual(credential, "23160026460829:", "Should be barcode with empty password")
            }
            // Return a valid token response
            let tokenJSON = """
            {"access_token": "test_token", "token_type": "Bearer", "expires_in": 3600}
            """.data(using: .utf8)
            return HTTPStubURLProtocol.StubbedResponse(statusCode: 200, headers: nil, body: tokenJSON)
        }

        let session = URLSession.stubbedSession()
        let result = await request.execute(session: session)

        XCTAssertTrue(networkCallMade, "Network call should be made for pinless login")

        switch result {
        case .success(let tokenResponse):
            XCTAssertEqual(tokenResponse.accessToken, "test_token")
        case .failure(let error):
            XCTFail("Pinless login should succeed, got error: \(error.localizedDescription)")
        }
    }

    func testExecute_BothEmpty_ReturnsFailureWithoutNetworkCall() async {
        let request = TokenRequest(url: tokenURL, username: "", password: "")

        HTTPStubURLProtocol.register { _ in
            XCTFail("Network request should not be made with both credentials empty")
            return nil
        }

        let session = URLSession.stubbedSession()
        let result = await request.execute(session: session)

        switch result {
        case .success:
            XCTFail("Expected failure for empty credentials")
        case .failure(let error):
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, "TokenRequest")
            XCTAssertEqual(nsError.code, -1)
        }
    }

    func testExecute_EmptyCredentials_ErrorDomain() async {
        let request = TokenRequest(url: tokenURL, username: "", password: "")

        let session = URLSession.stubbedSession()
        let result = await request.execute(session: session)

        switch result {
        case .success:
            XCTFail("Expected failure")
        case .failure(let error):
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, "TokenRequest",
                           "Error domain should be TokenRequest for credential validation failures")
        }
    }

    // MARK: Valid Credential Acceptance

    func testExecute_ValidCredentials_MakesNetworkCall() async {
        let request = TokenRequest(url: tokenURL, username: "12345", password: "1234")
        var requestMade = false

        HTTPStubURLProtocol.register { _ in
            requestMade = true
            let json = """
            {"access_token":"test","token_type":"Bearer","expires_in":3600}
            """.data(using: .utf8)!
            return HTTPStubURLProtocol.StubbedResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: json
            )
        }

        let session = URLSession.stubbedSession()
        let result = await request.execute(session: session)

        XCTAssertTrue(requestMade, "Network request should be made with valid credentials")

        switch result {
        case .success(let response):
            XCTAssertEqual(response.accessToken, "test")
            XCTAssertEqual(response.tokenType, "Bearer")
            XCTAssertEqual(response.expiresIn, 3600)
        case .failure(let error):
            XCTFail("Expected success but got: \(error)")
        }
    }

    // MARK: Basic Auth Header Encoding

    func testExecute_ValidCredentials_SendsCorrectBasicAuthHeader() async {
        let request = TokenRequest(url: tokenURL, username: "mybarcode", password: "mypin")
        var capturedAuthHeader: String?

        HTTPStubURLProtocol.register { urlRequest in
            capturedAuthHeader = urlRequest.value(forHTTPHeaderField: "Authorization")
            let json = """
            {"access_token":"t","token_type":"Bearer","expires_in":3600}
            """.data(using: .utf8)!
            return HTTPStubURLProtocol.StubbedResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: json
            )
        }

        let session = URLSession.stubbedSession()
        _ = await request.execute(session: session)

        let expectedBase64 = Data("mybarcode:mypin".utf8).base64EncodedString()
        XCTAssertEqual(capturedAuthHeader, "Basic \(expectedBase64)")
    }

    func testExecute_SpecialCharactersInCredentials_EncodesCorrectly() async {
        let request = TokenRequest(url: tokenURL, username: "user@lib.org", password: "p@ss:word!")
        var capturedAuthHeader: String?

        HTTPStubURLProtocol.register { urlRequest in
            capturedAuthHeader = urlRequest.value(forHTTPHeaderField: "Authorization")
            let json = """
            {"access_token":"t","token_type":"Bearer","expires_in":3600}
            """.data(using: .utf8)!
            return HTTPStubURLProtocol.StubbedResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: json
            )
        }

        let session = URLSession.stubbedSession()
        _ = await request.execute(session: session)

        let expectedBase64 = Data("user@lib.org:p@ss:word!".utf8).base64EncodedString()
        XCTAssertEqual(capturedAuthHeader, "Basic \(expectedBase64)",
                       "Special characters in credentials must be properly base64-encoded")
    }

    func testExecute_ColonInPassword_EncodesCorrectly() async {
        let request = TokenRequest(url: tokenURL, username: "user", password: "pass:with:colons")
        var capturedAuthHeader: String?

        HTTPStubURLProtocol.register { urlRequest in
            capturedAuthHeader = urlRequest.value(forHTTPHeaderField: "Authorization")
            let json = """
            {"access_token":"t","token_type":"Bearer","expires_in":3600}
            """.data(using: .utf8)!
            return HTTPStubURLProtocol.StubbedResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: json
            )
        }

        let session = URLSession.stubbedSession()
        _ = await request.execute(session: session)

        let expectedBase64 = Data("user:pass:with:colons".utf8).base64EncodedString()
        XCTAssertEqual(capturedAuthHeader, "Basic \(expectedBase64)",
                       "Colons in password must be preserved (only first colon separates user:pass)")
    }

    func testExecute_SendsPOSTMethod() async {
        let request = TokenRequest(url: tokenURL, username: "user", password: "pass")
        var capturedMethod: String?

        HTTPStubURLProtocol.register { urlRequest in
            capturedMethod = urlRequest.httpMethod
            let json = """
            {"access_token":"t","token_type":"Bearer","expires_in":3600}
            """.data(using: .utf8)!
            return HTTPStubURLProtocol.StubbedResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: json
            )
        }

        let session = URLSession.stubbedSession()
        _ = await request.execute(session: session)

        XCTAssertEqual(capturedMethod, "POST", "Token requests must use POST")
    }

    // MARK: Server Error Handling

    func testExecute_ServerReturns401_ReturnsFailureWithStatusCode() async {
        let request = TokenRequest(url: tokenURL, username: "user", password: "pass")

        HTTPStubURLProtocol.register { _ in
            let body = """
            {"type":"http://palaceproject.io/terms/problem/auth/unrecoverable/credentials/invalid","title":"Invalid credentials","status":401}
            """.data(using: .utf8)!
            return HTTPStubURLProtocol.StubbedResponse(statusCode: 401, headers: nil, body: body)
        }

        let session = URLSession.stubbedSession()
        let result = await request.execute(session: session)

        switch result {
        case .success:
            XCTFail("Expected failure for 401 response")
        case .failure(let error):
            let nsError = error as NSError
            XCTAssertEqual(nsError.code, 401)
        }
    }

    func testExecute_ServerReturns400_ReturnsFailureWithStatusCode() async {
        let request = TokenRequest(url: tokenURL, username: "user", password: "pass")

        HTTPStubURLProtocol.register { _ in
            let body = "Bad Request".data(using: .utf8)!
            return HTTPStubURLProtocol.StubbedResponse(statusCode: 400, headers: nil, body: body)
        }

        let session = URLSession.stubbedSession()
        let result = await request.execute(session: session)

        switch result {
        case .success:
            XCTFail("Expected failure for 400 response")
        case .failure(let error):
            let nsError = error as NSError
            XCTAssertEqual(nsError.code, 400)
        }
    }

    func testExecute_ServerReturnsNonJSON_ReturnsDecodingError() async {
        let request = TokenRequest(url: tokenURL, username: "user", password: "pass")

        HTTPStubURLProtocol.register { _ in
            let body = "<html>Not JSON</html>".data(using: .utf8)!
            return HTTPStubURLProtocol.StubbedResponse(
                statusCode: 200,
                headers: ["Content-Type": "text/html"],
                body: body
            )
        }

        let session = URLSession.stubbedSession()
        let result = await request.execute(session: session)

        switch result {
        case .success:
            XCTFail("Expected failure for non-JSON response body")
        case .failure(let error):
            XCTAssertTrue(error is DecodingError,
                          "Non-JSON response should produce DecodingError, got: \(type(of: error))")
        }
    }

    func testExecute_ServerReturnsIncompleteJSON_ReturnsDecodingError() async {
        let request = TokenRequest(url: tokenURL, username: "user", password: "pass")

        HTTPStubURLProtocol.register { _ in
            let body = """
            {"access_token":"test"}
            """.data(using: .utf8)!
            return HTTPStubURLProtocol.StubbedResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: body
            )
        }

        let session = URLSession.stubbedSession()
        let result = await request.execute(session: session)

        switch result {
        case .success:
            XCTFail("Expected failure for incomplete JSON (missing token_type, expires_in)")
        case .failure:
            break
        }
    }
}

// MARK: - Network Executor Token Refresh Guards

@MainActor
final class NetworkExecutorCredentialGuardTests: XCTestCase {

    private func makeExecutor() -> TPPNetworkExecutor {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HTTPStubURLProtocol.self]
        return TPPNetworkExecutor(
            credentialsProvider: nil,
            cachingStrategy: .ephemeral,
            sessionConfiguration: config,
            delegateQueue: nil
        )
    }

    override func setUp() {
        super.setUp()
        HTTPStubURLProtocol.reset()
    }

    override func tearDown() {
        HTTPStubURLProtocol.reset()
        super.tearDown()
    }

    // MARK: refreshTokenAndResume Guards

    func testRefreshTokenAndResume_NoCredentials_FailsGracefully() async {
        let executor = makeExecutor()

        // Deterministic join: await the ACTUAL refresh completion instead of a
        // wall-clock deadline. refreshTokenAndResume's completion fires as the
        // last step of the refresh, so bridging it through a continuation
        // resumes exactly when the refresh settles — it can't starve under
        // parallel-CI contention the way the fixed 10s timeout did.
        // Resume with a Sendable projection — only the case matters here, and
        // NYPLResult is not Sendable, so sending the whole value out of the
        // off-isolation completion trips Swift 6's `sending 'result'`.
        let succeeded = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            executor.refreshTokenAndResume(task: nil, accountId: "nonexistent-account-xyz") { result in
                if case .success = result { cont.resume(returning: true) }
                else { cont.resume(returning: false) }
            }
        }

        XCTAssertFalse(succeeded, "Expected failure when no credentials are available")
    }

    func testRefreshTokenAndResume_NilTask_NilAccountId_DoesNotCrash() async {
        let executor = makeExecutor()
        var gotResult = false

        // Deterministic join: awaiting the completion IS the assertion that it
        // fired — the continuation only resumes when refreshTokenAndResume
        // invokes its completion. No wall-clock timeout to starve under CI load.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            executor.refreshTokenAndResume(task: nil, accountId: nil) { _ in
                gotResult = true
                cont.resume()
            }
        }

        XCTAssertTrue(gotResult,
                      "Completion must be invoked (success or failure) even with nil task and nil accountId")
    }

    func testRefreshTokenAndResume_DefaultAccountId_BackwardCompatible() async {
        let executor = makeExecutor()
        var gotResult = false

        // Deterministic join: the continuation resumes exactly when the
        // backward-compat overload delivers its completion — no fixed deadline.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            executor.refreshTokenAndResume(task: nil) { _ in
                gotResult = true
                cont.resume()
            }
        }

        XCTAssertTrue(gotResult,
                      "Backward-compat overload (no accountId) must still deliver a completion")
    }

    // MARK: executeTokenRefresh Guards

    func testExecuteTokenRefresh_EmptyUsername_FailsViaTokenRequestGuard() async {
        let executor = makeExecutor()

        HTTPStubURLProtocol.register { _ in
            XCTFail("Should not reach the network with empty username")
            return nil
        }

        // Deterministic join: await executeTokenRefresh's actual completion.
        // The empty-credential guard fires the completion directly, so the
        // continuation resumes the instant the guard rejects — no clock.
        let tokenURL = URL(string: "https://example.com/token")!
        let result = await withCheckedContinuation { (cont: CheckedContinuation<Result<TokenResponse, Error>, Never>) in
            executor.executeTokenRefresh(
                username: "",
                password: "validpin",
                tokenURL: tokenURL
            ) { result in
                cont.resume(returning: result)
            }
        }

        switch result {
        case .failure(let error):
            XCTAssertTrue(error.localizedDescription.contains("empty") || error.localizedDescription.contains("username"),
                          "Should fail with empty credentials error, got: \(error.localizedDescription)")
        case .success:
            XCTFail("Expected failure for empty username")
        }
    }

    func testExecuteTokenRefresh_BothEmpty_FailsViaTokenRequestGuard() async {
        let executor = makeExecutor()

        let tokenURL = URL(string: "https://example.com/token")!
        let result = await withCheckedContinuation { (cont: CheckedContinuation<Result<TokenResponse, Error>, Never>) in
            executor.executeTokenRefresh(
                username: "",
                password: "",
                tokenURL: tokenURL
            ) { result in
                cont.resume(returning: result)
            }
        }

        switch result {
        case .failure:
            break
        case .success:
            XCTFail("Expected failure for both credentials empty")
        }
    }

    // MARK: executeTokenRefresh Success Path

    func testExecuteTokenRefresh_ValidCredentials_ReturnsTokenResponse() async {
        let executor = makeExecutor()

        HTTPStubURLProtocol.register { request in
            guard request.url?.absoluteString.contains("token") == true else { return nil }
            let json = """
            {"access_token":"fresh-token-abc","token_type":"Bearer","expires_in":7200}
            """.data(using: .utf8)!
            return HTTPStubURLProtocol.StubbedResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: json
            )
        }

        // Deterministic join: the continuation resumes when the refresh's HTTP
        // round-trip settles and the completion fires — not after a fixed 5s.
        let tokenURL = URL(string: "https://example.com/patrons/me/token/")!
        let result = await withCheckedContinuation { (cont: CheckedContinuation<Result<TokenResponse, Error>, Never>) in
            executor.executeTokenRefresh(
                username: "12345",
                password: "1234",
                tokenURL: tokenURL
            ) { result in
                cont.resume(returning: result)
            }
        }

        switch result {
        case .success(let response):
            XCTAssertEqual(response.accessToken, "fresh-token-abc")
            XCTAssertEqual(response.tokenType, "Bearer")
            XCTAssertEqual(response.expiresIn, 7200)
        case .failure(let error):
            XCTFail("Expected success but got: \(error)")
        }
    }

    func testExecuteTokenRefresh_ServerReturns401_ReturnsFailure() async {
        let executor = makeExecutor()

        HTTPStubURLProtocol.register { request in
            guard request.url?.absoluteString.contains("token") == true else { return nil }
            let body = "Invalid credentials".data(using: .utf8)!
            return HTTPStubURLProtocol.StubbedResponse(statusCode: 401, headers: nil, body: body)
        }

        let tokenURL = URL(string: "https://example.com/patrons/me/token/")!
        let result = await withCheckedContinuation { (cont: CheckedContinuation<Result<TokenResponse, Error>, Never>) in
            executor.executeTokenRefresh(
                username: "12345",
                password: "wrongpin",
                tokenURL: tokenURL
            ) { result in
                cont.resume(returning: result)
            }
        }

        switch result {
        case .failure:
            break
        case .success:
            XCTFail("Expected failure for 401 from token endpoint")
        }
    }

    func testExecuteTokenRefresh_WithAccountId_Succeeds() async {
        let executor = makeExecutor()

        HTTPStubURLProtocol.register { request in
            guard request.url?.absoluteString.contains("token") == true else { return nil }
            let json = """
            {"access_token":"account-specific-token","token_type":"Bearer","expires_in":3600}
            """.data(using: .utf8)!
            return HTTPStubURLProtocol.StubbedResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: json
            )
        }

        // Deterministic join to the actual refresh completion — the exact fix
        // for this test's parallel-CI-clone flake (fixed 5s deadline starved
        // under 2 concurrent sim clones and failed all 3 retries).
        let tokenURL = URL(string: "https://example.com/patrons/me/token/")!
        let result = await withCheckedContinuation { (cont: CheckedContinuation<Result<TokenResponse, Error>, Never>) in
            executor.executeTokenRefresh(
                username: "user",
                password: "pass",
                tokenURL: tokenURL,
                accountId: "urn:uuid:test-library-123"
            ) { result in
                cont.resume(returning: result)
            }
        }

        switch result {
        case .success(let response):
            XCTAssertEqual(response.accessToken, "account-specific-token")
        case .failure(let error):
            XCTFail("Expected success but got: \(error)")
        }
    }
}

// MARK: - Concurrent Token Refresh Coordination

@MainActor
final class ConcurrentTokenRefreshTests: XCTestCase {

    private func makeExecutor() -> TPPNetworkExecutor {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HTTPStubURLProtocol.self]
        return TPPNetworkExecutor(
            credentialsProvider: nil,
            cachingStrategy: .ephemeral,
            sessionConfiguration: config,
            delegateQueue: nil
        )
    }

    override func setUp() {
        super.setUp()
        HTTPStubURLProtocol.reset()
    }

    override func tearDown() {
        HTTPStubURLProtocol.reset()
        super.tearDown()
    }

    func testTokenRequest_canExecuteViaStub() async {
        HTTPStubURLProtocol.register { request in
            guard request.url?.absoluteString.contains("token") == true else { return nil }
            let json = """
            {"access_token":"shared-token","token_type":"Bearer","expires_in":3600}
            """.data(using: .utf8)!
            return HTTPStubURLProtocol.StubbedResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: json
            )
        }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HTTPStubURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        let tokenURL = URL(string: "https://example.com/token")!
        let request = TokenRequest(url: tokenURL, username: "user", password: "pass")
        let result = await request.execute(session: session)

        switch result {
        case .success(let response):
            XCTAssertEqual(response.accessToken, "shared-token")
        case .failure(let error):
            XCTFail("Token request should succeed: \(error)")
        }
    }

    func testRefreshTokenAndResume_noCredentials_failsImmediately() async {
        let executor = makeExecutor()

        // Deterministic join: await the refresh's actual completion rather than
        // a fixed 10s deadline. The continuation resumes exactly when
        // refreshTokenAndResume settles, so it cannot starve under parallel-CI
        // scheduling contention.
        let succeeded = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            executor.refreshTokenAndResume(task: nil) { result in
                if case .success = result { cont.resume(returning: true) }
                else { cont.resume(returning: false) }
            }
        }

        XCTAssertFalse(succeeded, "refreshTokenAndResume without credentials must fail immediately, not succeed")
    }
}

// MARK: - URLSession Configuration Tests

@MainActor
final class URLSessionCredentialStorageTests: XCTestCase {

    func testMakeURLSessionConfiguration_Default_DisablesCredentialStorage() {
        let config = TPPCaching.makeURLSessionConfiguration(
            caching: .default,
            requestTimeout: 30
        )

        XCTAssertNil(config.urlCredentialStorage,
                     "Default config must set urlCredentialStorage=nil to prevent iOS from caching and replaying stale Basic Auth credentials")
    }

    func testMakeURLSessionConfiguration_Fallback_DisablesCredentialStorage() {
        let config = TPPCaching.makeURLSessionConfiguration(
            caching: .fallback,
            requestTimeout: 30
        )

        XCTAssertNil(config.urlCredentialStorage,
                     "Fallback config must set urlCredentialStorage=nil -- this is the config used by the production networkExecutor")
    }

    func testMakeURLSessionConfiguration_Ephemeral_ReturnsEphemeralConfig() {
        let config = TPPCaching.makeURLSessionConfiguration(
            caching: .ephemeral,
            requestTimeout: 30
        )

        // .ephemeral returns URLSessionConfiguration.ephemeral which uses in-memory
        // storage only -- acceptable for short-lived sessions, and credentials are
        // discarded when the session is deallocated.
        XCTAssertNotNil(config)
    }

}

// MARK: - Basic Auth Challenge Empty Credential Behavior

@MainActor
final class BasicAuthEmptyCredentialTests: XCTestCase {

    func testHandleChallenge_EmptyUsername_StillUsesCredential() {
        // Documents current behavior: TPPBasicAuth only checks for nil, not empty.
        // The TokenRequest empty guard is the primary defense layer.
        let provider = MockCredentialsProvider()
        provider.username = ""
        provider.pin = "validpin"

        let auth = TPPBasicAuth(credentialsProvider: provider)
        let challenge = createBasicAuthChallenge()

        var receivedDisposition: URLSession.AuthChallengeDisposition?

        auth.handleChallenge(challenge) { disposition, _ in
            receivedDisposition = disposition
        }

        XCTAssertEqual(receivedDisposition, .useCredential,
                       "Empty strings pass the nil guard -- empty credential defense is in TokenRequest and TPPNetworkExecutor")
    }

    func testHandleChallenge_NilUsername_CancelsChallenge() {
        let provider = MockCredentialsProvider()
        provider.username = nil
        provider.pin = "validpin"

        let auth = TPPBasicAuth(credentialsProvider: provider)
        let challenge = createBasicAuthChallenge()

        var receivedDisposition: URLSession.AuthChallengeDisposition?

        auth.handleChallenge(challenge) { disposition, _ in
            receivedDisposition = disposition
        }

        XCTAssertEqual(receivedDisposition, .cancelAuthenticationChallenge)
    }

    func testHandleChallenge_NilPassword_CancelsChallenge() {
        let provider = MockCredentialsProvider()
        provider.username = "validuser"
        provider.pin = nil

        let auth = TPPBasicAuth(credentialsProvider: provider)
        let challenge = createBasicAuthChallenge()

        var receivedDisposition: URLSession.AuthChallengeDisposition?

        auth.handleChallenge(challenge) { disposition, _ in
            receivedDisposition = disposition
        }

        XCTAssertEqual(receivedDisposition, .cancelAuthenticationChallenge)
    }

    func testHandleChallenge_ValidCredentials_UsesCredentialWithNoPersistence() {
        let provider = MockCredentialsProvider()
        provider.username = "12345"
        provider.pin = "1234"

        let auth = TPPBasicAuth(credentialsProvider: provider)
        let challenge = createBasicAuthChallenge()

        var receivedDisposition: URLSession.AuthChallengeDisposition?
        var receivedCredential: URLCredential?

        auth.handleChallenge(challenge) { disposition, credential in
            receivedDisposition = disposition
            receivedCredential = credential
        }

        XCTAssertEqual(receivedDisposition, .useCredential)
        XCTAssertEqual(receivedCredential?.user, "12345")
        XCTAssertEqual(receivedCredential?.password, "1234")
        XCTAssertEqual(receivedCredential?.persistence, URLCredential.Persistence.none,
                       "Credentials must use .none persistence to prevent URLSession from caching them")
    }

    // MARK: - Helpers

    private func createBasicAuthChallenge(previousFailureCount: Int = 0) -> URLAuthenticationChallenge {
        let protectionSpace = URLProtectionSpace(
            host: "example.com",
            port: 443,
            protocol: NSURLProtectionSpaceHTTPS,
            realm: nil,
            authenticationMethod: NSURLAuthenticationMethodHTTPBasic
        )
        return URLAuthenticationChallenge(
            protectionSpace: protectionSpace,
            proposedCredential: nil,
            previousFailureCount: previousFailureCount,
            failureResponse: nil,
            error: nil,
            sender: MockChallengeSender()
        )
    }
}

// MARK: - Credential Edge Cases

@MainActor
final class CredentialEdgeCaseTests: XCTestCase {

    func testTokenCredential_NilBarcode_ReturnsNilUsername() {
        let credentials = TPPCredentials.token(authToken: "token123", barcode: nil, pin: nil)

        if case let .token(_, barcode, pin, _) = credentials {
            XCTAssertNil(barcode)
            XCTAssertNil(pin)
        } else {
            XCTFail("Expected token credentials")
        }
    }

    func testTokenCredential_EmptyBarcode_IsDistinctFromNil() {
        let credentials = TPPCredentials.token(authToken: "token123", barcode: "", pin: "1234")

        if case let .token(_, barcode, _, _) = credentials {
            XCTAssertNotNil(barcode, "Empty string barcode should not be nil")
            XCTAssertEqual(barcode, "")
            XCTAssertTrue(barcode!.isEmpty,
                          "Empty barcode passes guard-let-nil but fails guard-!isEmpty -- this is the distinction the empty-string guards address")
        } else {
            XCTFail("Expected token credentials")
        }
    }

    func testTokenCredential_EmptyPin_IsDistinctFromNil() {
        let credentials = TPPCredentials.token(authToken: "token123", barcode: "12345", pin: "")

        if case let .token(_, _, pin, _) = credentials {
            XCTAssertNotNil(pin)
            XCTAssertEqual(pin, "")
            XCTAssertTrue(pin!.isEmpty)
        } else {
            XCTFail("Expected token credentials")
        }
    }

    func testBarcodeAndPin_EmptyStrings_ProduceMalformedBasicAuthHeader() {
        // This test demonstrates WHY the empty-string guards are critical:
        // base64(":") produces "Og==" which the CM's server_side_validation rejects
        let loginString = ":"
        let base64 = Data(loginString.utf8).base64EncodedString()
        XCTAssertEqual(base64, "Og==",
                       "Empty username:password encodes to 'Og==' which CM rejects in server_side_validation")
        XCTAssertFalse(base64.isEmpty,
                       "The base64 is non-empty, so it looks like a valid header but contains no actual credentials")
    }

    func testCredentials_BarcodeAndPin_RoundTripsThroughCodable() throws {
        let original = TPPCredentials.barcodeAndPin(barcode: "23160026460829", pin: "1234")

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TPPCredentials.self, from: encoded)

        guard case let .barcodeAndPin(barcode, pin) = decoded else {
            XCTFail("Expected .barcodeAndPin after Codable round-trip, got \(decoded)")
            return
        }
        XCTAssertEqual(barcode, "23160026460829")
        XCTAssertEqual(pin, "1234")
    }

    // Covers decodeIfPresent on lines 68-69 of TPPCredentials.swift: legacy
    // keychain entries may have been written with nil barcode/pin and must
    // still decode cleanly after Codable was hardened.
    func testCredentials_TokenWithNilBarcodeAndPin_SurvivesCodableRoundTrip() throws {
        let original = TPPCredentials.token(authToken: "oauth-abc-123",
                                            barcode: nil,
                                            pin: nil,
                                            expirationDate: nil)

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TPPCredentials.self, from: encoded)

        guard case let .token(token, barcode, pin, expiration) = decoded else {
            XCTFail("Expected .token after Codable round-trip, got \(decoded)")
            return
        }
        XCTAssertEqual(token, "oauth-abc-123")
        XCTAssertNil(barcode)
        XCTAssertNil(pin)
        XCTAssertNil(expiration)
    }
}

// MARK: - Token Request + Network Executor Integration

@MainActor
final class TokenRefreshIntegrationTests: XCTestCase {

    private func makeExecutor() -> TPPNetworkExecutor {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HTTPStubURLProtocol.self]
        return TPPNetworkExecutor(
            credentialsProvider: nil,
            cachingStrategy: .ephemeral,
            sessionConfiguration: config,
            delegateQueue: nil
        )
    }

    override func setUp() {
        super.setUp()
        HTTPStubURLProtocol.reset()
    }

    override func tearDown() {
        HTTPStubURLProtocol.reset()
        super.tearDown()
    }

    func testExecuteTokenRefresh_ValidatesBasicAuthHeaderOnWire() async {
        // Use async test to avoid blocking the main thread with wait(for:).
        // The sync + XCTestExpectation pattern blocks the main thread, which
        // can deadlock when the success path calls notifyAccountDidChange()
        // and any NotificationCenter observer tries to dispatch back to main.
        let executor = makeExecutor()
        var capturedAuthHeader: String?

        HTTPStubURLProtocol.register { request in
            capturedAuthHeader = request.value(forHTTPHeaderField: "Authorization")
            let json = """
            {"access_token":"t","token_type":"Bearer","expires_in":3600}
            """.data(using: .utf8)!
            return HTTPStubURLProtocol.StubbedResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: json
            )
        }

        let tokenURL = URL(string: "https://example.com/token")!
        await withCheckedContinuation { continuation in
            executor.executeTokenRefresh(
                username: "testbarcode",
                password: "testpin",
                tokenURL: tokenURL
            ) { _ in
                continuation.resume()
            }
        }

        let expectedBase64 = Data("testbarcode:testpin".utf8).base64EncodedString()
        XCTAssertEqual(capturedAuthHeader, "Basic \(expectedBase64)",
                       "executeTokenRefresh should delegate to TokenRequest which sets the correct Basic Auth header")
    }

    func testExecuteTokenRefresh_EmptyUsername_NeverHitsNetwork() async {
        let executor = makeExecutor()
        var networkCallMade = false

        HTTPStubURLProtocol.register { _ in
            networkCallMade = true
            return HTTPStubURLProtocol.StubbedResponse(statusCode: 200, headers: nil, body: Data())
        }

        // Deterministic join: the empty-username guard fires the completion
        // without any network I/O, so awaiting the completion resumes the
        // instant the guard rejects — no wall-clock deadline to starve. By the
        // time the continuation returns, the guard has run, so networkCallMade
        // reflects the final decision.
        let tokenURL = URL(string: "https://example.com/token")!
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            executor.executeTokenRefresh(
                username: "",
                password: "pin",
                tokenURL: tokenURL
            ) { _ in
                cont.resume()
            }
        }

        XCTAssertFalse(networkCallMade,
                       "Empty username must be caught before any network I/O")
    }

}

// MARK: - Thread-safe Counter Helper

private class AtomicCounter {
    private var _value = 0
    private let lock = NSLock()

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }

    func increment() {
        lock.lock()
        _value += 1
        lock.unlock()
    }
}
