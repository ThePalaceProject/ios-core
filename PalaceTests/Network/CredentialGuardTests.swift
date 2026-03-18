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
@testable import Palace

// MARK: - TokenRequest Empty Credential Guards

final class TokenRequestCredentialGuardTests: XCTestCase {

    private let tokenURL = URL(string: "https://example.com/patrons/me/token/")!

    override func tearDown() {
        super.tearDown()
        HTTPStubURLProtocol.reset()
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
            XCTAssertTrue(error.localizedDescription.contains("empty credentials"),
                          "Error should mention empty credentials, got: \(error.localizedDescription)")
        }
    }

    func testExecute_EmptyPassword_ReturnsFailureWithoutNetworkCall() async {
        let request = TokenRequest(url: tokenURL, username: "12345", password: "")

        HTTPStubURLProtocol.register { _ in
            XCTFail("Network request should not be made with empty password")
            return nil
        }

        let session = URLSession.stubbedSession()
        let result = await request.execute(session: session)

        switch result {
        case .success:
            XCTFail("Expected failure for empty password")
        case .failure(let error):
            XCTAssertTrue(error.localizedDescription.contains("empty credentials"),
                          "Error should mention empty credentials, got: \(error.localizedDescription)")
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

    override func tearDown() {
        super.tearDown()
        HTTPStubURLProtocol.reset()
    }

    // MARK: refreshTokenAndResume Guards

    func testRefreshTokenAndResume_NoCredentials_FailsGracefully() {
        let executor = makeExecutor()
        let expectation = XCTestExpectation(description: "Refresh completes with failure")

        executor.refreshTokenAndResume(task: nil, accountId: "nonexistent-account-xyz") { result in
            switch result {
            case .failure:
                break
            case .success:
                XCTFail("Expected failure when no credentials are available")
            }
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5.0)
    }

    func testRefreshTokenAndResume_NilTask_NilAccountId_DoesNotCrash() {
        let executor = makeExecutor()
        let expectation = XCTestExpectation(description: "Refresh completes")

        executor.refreshTokenAndResume(task: nil, accountId: nil) { result in
            switch result {
            case .failure, .success:
                break
            }
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5.0)
    }

    func testRefreshTokenAndResume_DefaultAccountId_BackwardCompatible() {
        let executor = makeExecutor()
        let expectation = XCTestExpectation(description: "Refresh completes")

        executor.refreshTokenAndResume(task: nil) { _ in
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5.0)
    }

    // MARK: executeTokenRefresh Guards

    func testExecuteTokenRefresh_EmptyUsername_FailsViaTokenRequestGuard() {
        let executor = makeExecutor()
        let expectation = XCTestExpectation(description: "Refresh completes")

        HTTPStubURLProtocol.register { _ in
            XCTFail("Should not reach the network with empty username")
            return nil
        }

        let tokenURL = URL(string: "https://example.com/token")!
        executor.executeTokenRefresh(
            username: "",
            password: "validpin",
            tokenURL: tokenURL
        ) { result in
            switch result {
            case .failure(let error):
                XCTAssertTrue(error.localizedDescription.contains("empty credentials"),
                              "Should fail with empty credentials error, got: \(error.localizedDescription)")
            case .success:
                XCTFail("Expected failure for empty username")
            }
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 15.0)
    }

    func testExecuteTokenRefresh_EmptyPassword_FailsViaTokenRequestGuard() {
        let executor = makeExecutor()
        let expectation = XCTestExpectation(description: "Refresh completes")

        HTTPStubURLProtocol.register { _ in
            XCTFail("Should not reach the network with empty password")
            return nil
        }

        let tokenURL = URL(string: "https://example.com/token")!
        executor.executeTokenRefresh(
            username: "12345",
            password: "",
            tokenURL: tokenURL
        ) { result in
            switch result {
            case .failure(let error):
                XCTAssertTrue(error.localizedDescription.contains("empty credentials"),
                              "Should fail with empty credentials error, got: \(error.localizedDescription)")
            case .success:
                XCTFail("Expected failure for empty password")
            }
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 15.0)
    }

    func testExecuteTokenRefresh_BothEmpty_FailsViaTokenRequestGuard() {
        let executor = makeExecutor()
        let expectation = XCTestExpectation(description: "Refresh completes")

        let tokenURL = URL(string: "https://example.com/token")!
        executor.executeTokenRefresh(
            username: "",
            password: "",
            tokenURL: tokenURL
        ) { result in
            switch result {
            case .failure:
                break
            case .success:
                XCTFail("Expected failure for both credentials empty")
            }
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 15.0)
    }

    // MARK: executeTokenRefresh Success Path

    func testExecuteTokenRefresh_ValidCredentials_ReturnsTokenResponse() {
        let executor = makeExecutor()
        let expectation = XCTestExpectation(description: "Refresh completes")

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

        let tokenURL = URL(string: "https://example.com/patrons/me/token/")!
        executor.executeTokenRefresh(
            username: "12345",
            password: "1234",
            tokenURL: tokenURL
        ) { result in
            switch result {
            case .success(let response):
                XCTAssertEqual(response.accessToken, "fresh-token-abc")
                XCTAssertEqual(response.tokenType, "Bearer")
                XCTAssertEqual(response.expiresIn, 7200)
            case .failure(let error):
                XCTFail("Expected success but got: \(error)")
            }
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 15.0)
    }

    func testExecuteTokenRefresh_ServerReturns401_ReturnsFailure() {
        let executor = makeExecutor()
        let expectation = XCTestExpectation(description: "Refresh completes")

        HTTPStubURLProtocol.register { request in
            guard request.url?.absoluteString.contains("token") == true else { return nil }
            let body = "Invalid credentials".data(using: .utf8)!
            return HTTPStubURLProtocol.StubbedResponse(statusCode: 401, headers: nil, body: body)
        }

        let tokenURL = URL(string: "https://example.com/patrons/me/token/")!
        executor.executeTokenRefresh(
            username: "12345",
            password: "wrongpin",
            tokenURL: tokenURL
        ) { result in
            switch result {
            case .failure:
                break
            case .success:
                XCTFail("Expected failure for 401 from token endpoint")
            }
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 15.0)
    }

    func testExecuteTokenRefresh_WithAccountId_Succeeds() {
        let executor = makeExecutor()
        let expectation = XCTestExpectation(description: "Refresh completes")

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

        let tokenURL = URL(string: "https://example.com/patrons/me/token/")!
        executor.executeTokenRefresh(
            username: "user",
            password: "pass",
            tokenURL: tokenURL,
            accountId: "urn:uuid:test-library-123"
        ) { result in
            switch result {
            case .success(let response):
                XCTAssertEqual(response.accessToken, "account-specific-token")
            case .failure(let error):
                XCTFail("Expected success but got: \(error)")
            }
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 15.0)
    }
}

// MARK: - Concurrent Token Refresh Coordination

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

    override func tearDown() {
        super.tearDown()
        HTTPStubURLProtocol.reset()
    }

    func testMultipleExecuteTokenRefresh_AllComplete() {
        let executor = makeExecutor()
        let tokenRequestCount = AtomicCounter()

        HTTPStubURLProtocol.register { request in
            guard request.url?.absoluteString.contains("token") == true else { return nil }
            tokenRequestCount.increment()
            Thread.sleep(forTimeInterval: 0.2)
            let json = """
            {"access_token":"shared-token","token_type":"Bearer","expires_in":3600}
            """.data(using: .utf8)!
            return HTTPStubURLProtocol.StubbedResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: json
            )
        }

        let tokenURL = URL(string: "https://example.com/token")!
        let expectation1 = XCTestExpectation(description: "First refresh")
        let expectation2 = XCTestExpectation(description: "Second refresh")
        let expectation3 = XCTestExpectation(description: "Third refresh")

        executor.executeTokenRefresh(
            username: "user", password: "pass", tokenURL: tokenURL
        ) { _ in expectation1.fulfill() }

        executor.executeTokenRefresh(
            username: "user", password: "pass", tokenURL: tokenURL
        ) { _ in expectation2.fulfill() }

        executor.executeTokenRefresh(
            username: "user", password: "pass", tokenURL: tokenURL
        ) { _ in expectation3.fulfill() }

        wait(for: [expectation1, expectation2, expectation3], timeout: 15.0)
    }

    func testRefreshTokenAndResume_PendingCompletionsAllFired() {
        let executor = makeExecutor()
        let completionCount = AtomicCounter()

        HTTPStubURLProtocol.register { request in
            guard request.url?.absoluteString.contains("token") == true else { return nil }
            Thread.sleep(forTimeInterval: 0.3)
            let json = """
            {"access_token":"test","token_type":"Bearer","expires_in":3600}
            """.data(using: .utf8)!
            return HTTPStubURLProtocol.StubbedResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: json
            )
        }

        let count = 5
        let expectations = (0..<count).map { i in
            XCTestExpectation(description: "Refresh \(i)")
        }

        for i in 0..<count {
            DispatchQueue.global().asyncAfter(deadline: .now() + Double(i) * 0.05) {
                executor.refreshTokenAndResume(task: nil) { _ in
                    completionCount.increment()
                    expectations[i].fulfill()
                }
            }
        }

        wait(for: expectations, timeout: 15.0)

        XCTAssertEqual(completionCount.value, count,
                       "All \(count) pending completions must fire")
    }

    func testRefreshTokenAndResume_FailurePropagatedToPendingCompletions() {
        let executor = makeExecutor()
        let failureCount = AtomicCounter()

        // All refreshes will fail since there are no credentials in the test account
        let count = 3
        let expectations = (0..<count).map { i in
            XCTestExpectation(description: "Refresh \(i)")
        }

        for i in 0..<count {
            DispatchQueue.global().asyncAfter(deadline: .now() + Double(i) * 0.02) {
                executor.refreshTokenAndResume(task: nil) { result in
                    if case .failure = result {
                        failureCount.increment()
                    }
                    expectations[i].fulfill()
                }
            }
        }

        wait(for: expectations, timeout: 10.0)

        XCTAssertEqual(failureCount.value, count,
                       "All pending completions should receive the failure")
    }
}

// MARK: - URLSession Configuration Tests

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
                     "Fallback config must set urlCredentialStorage=nil -- this is the config used by TPPNetworkExecutor.shared")
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

    func testNetworkExecutor_CustomConfig_AcceptsNilCredentialStorage() {
        let config = URLSessionConfiguration.ephemeral
        config.urlCredentialStorage = nil
        config.protocolClasses = [HTTPStubURLProtocol.self]

        let executor = TPPNetworkExecutor(
            credentialsProvider: nil,
            cachingStrategy: .ephemeral,
            sessionConfiguration: config,
            delegateQueue: nil
        )

        XCTAssertNotNil(executor, "Executor must work with nil credential storage config")
    }
}

// MARK: - Basic Auth Challenge Empty Credential Behavior

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
        XCTAssertEqual(receivedCredential?.persistence, .none,
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

    func testBarcodeAndPin_ValidCredentials_ProducesNonTrivialBasicAuthHeader() {
        let loginString = "12345:1234"
        let base64 = Data(loginString.utf8).base64EncodedString()
        XCTAssertTrue(base64.count > 10,
                      "Valid credentials produce a reasonably long base64 string")
    }

    func testBarcodeAndPin_SingleCharEach_StillValidButShort() {
        let loginString = "a:b"
        let base64 = Data(loginString.utf8).base64EncodedString()
        XCTAssertEqual(base64, "YTpi", "Single-char credentials still produce valid base64")
    }
}

// MARK: - Token Request + Network Executor Integration

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

    override func tearDown() {
        super.tearDown()
        HTTPStubURLProtocol.reset()
    }

    func testExecuteTokenRefresh_ValidatesBasicAuthHeaderOnWire() {
        let executor = makeExecutor()
        let expectation = XCTestExpectation(description: "Token refresh completes")
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
        executor.executeTokenRefresh(
            username: "testbarcode",
            password: "testpin",
            tokenURL: tokenURL
        ) { _ in
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 15.0)

        let expectedBase64 = Data("testbarcode:testpin".utf8).base64EncodedString()
        XCTAssertEqual(capturedAuthHeader, "Basic \(expectedBase64)",
                       "executeTokenRefresh should delegate to TokenRequest which sets the correct Basic Auth header")
    }

    func testExecuteTokenRefresh_EmptyUsername_NeverHitsNetwork() {
        let executor = makeExecutor()
        let expectation = XCTestExpectation(description: "Token refresh completes")
        var networkCallMade = false

        HTTPStubURLProtocol.register { _ in
            networkCallMade = true
            return HTTPStubURLProtocol.StubbedResponse(statusCode: 200, headers: nil, body: Data())
        }

        let tokenURL = URL(string: "https://example.com/token")!
        executor.executeTokenRefresh(
            username: "",
            password: "pin",
            tokenURL: tokenURL
        ) { _ in
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 15.0)

        XCTAssertFalse(networkCallMade,
                       "Empty username must be caught before any network I/O")
    }

    func testExecuteTokenRefresh_EmptyPassword_NeverHitsNetwork() {
        let executor = makeExecutor()
        let expectation = XCTestExpectation(description: "Token refresh completes")
        var networkCallMade = false

        HTTPStubURLProtocol.register { _ in
            networkCallMade = true
            return HTTPStubURLProtocol.StubbedResponse(statusCode: 200, headers: nil, body: Data())
        }

        let tokenURL = URL(string: "https://example.com/token")!
        executor.executeTokenRefresh(
            username: "barcode",
            password: "",
            tokenURL: tokenURL
        ) { _ in
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 15.0)

        XCTAssertFalse(networkCallMade,
                       "Empty password must be caught before any network I/O")
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
