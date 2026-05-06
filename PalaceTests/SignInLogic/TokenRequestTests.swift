//
//  TokenRequestTests.swift
//  PalaceTests
//
//  Tests for TokenRequest and TokenResponse authentication flow.
//

import XCTest
@testable import Palace

/// SRS: REL-003 — Token refresh retry limit prevents loops
class TokenRequestTests: XCTestCase {

    override func setUp() {
        super.setUp()
        HTTPStubURLProtocol.reset()
    }

    override func tearDown() {
        HTTPStubURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - TokenResponse

    func testTokenResponseInitProperties() {
        let response = TokenResponse(accessToken: "abc123", tokenType: "Bearer", expiresIn: 3600)
        XCTAssertEqual(response.accessToken, "abc123")
        XCTAssertEqual(response.tokenType, "Bearer")
        XCTAssertEqual(response.expiresIn, 3600)
    }

    func testTokenResponseExpirationDate() {
        let response = TokenResponse(accessToken: "abc", tokenType: "Bearer", expiresIn: 3600)
        let before = Date(timeIntervalSinceNow: 3599)
        let expDate = response.expirationDate
        let after = Date(timeIntervalSinceNow: 3601)
        XCTAssertTrue(expDate >= before && expDate <= after, "Expiration date should be approximately expiresIn seconds from now")
    }

    func testTokenResponseDecodableFromJSON() throws {
        let json = """
        {"access_token": "tok_123", "token_type": "Bearer", "expires_in": 7200}
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(TokenResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.accessToken, "tok_123")
        XCTAssertEqual(response.tokenType, "Bearer")
        XCTAssertEqual(response.expiresIn, 7200)
    }

    // MARK: - TokenRequest Init

    func testTokenRequestInitProperties() {
        let url = URL(string: "https://auth.example.com/token")!
        let request = TokenRequest(url: url, username: "user", password: "pass")
        XCTAssertEqual(request.url, url)
        XCTAssertEqual(request.username, "user")
        XCTAssertEqual(request.password, "pass")
    }

    // MARK: - TokenRequest Execute (with stubbed session)

    func testExecuteSuccessReturnsToken() async {
        let tokenURL = URL(string: "https://auth.example.com/token")!
        let responseJSON = """
        {"access_token": "fresh_token", "token_type": "Bearer", "expires_in": 3600}
        """

        HTTPStubURLProtocol.register { request in
            guard request.url == tokenURL else { return nil }
            return .init(statusCode: 200,
                         headers: ["Content-Type": "application/json"],
                         body: Data(responseJSON.utf8))
        }

        let session = URLSession.stubbedSession()
        let tokenRequest = TokenRequest(url: tokenURL, username: "user", password: "pass")
        let result = await tokenRequest.execute(session: session)

        switch result {
        case .success(let tokenResponse):
            XCTAssertEqual(tokenResponse.accessToken, "fresh_token")
            XCTAssertEqual(tokenResponse.tokenType, "Bearer")
            XCTAssertEqual(tokenResponse.expiresIn, 3600)
        case .failure(let error):
            XCTFail("Expected success but got error: \(error)")
        }
    }

    func testExecuteSendsBasicAuthHeader() async {
        let tokenURL = URL(string: "https://auth.example.com/token")!
        var capturedAuth: String?

        HTTPStubURLProtocol.register { request in
            guard request.url == tokenURL else { return nil }
            capturedAuth = request.value(forHTTPHeaderField: "Authorization")
            let body = Data("{\"access_token\":\"t\",\"token_type\":\"B\",\"expires_in\":60}".utf8)
            return .init(statusCode: 200, headers: ["Content-Type": "application/json"], body: body)
        }

        let session = URLSession.stubbedSession()
        let tokenRequest = TokenRequest(url: tokenURL, username: "testuser", password: "testpass")
        _ = await tokenRequest.execute(session: session)

        let expectedCredentials = Data("testuser:testpass".utf8).base64EncodedString()
        XCTAssertEqual(capturedAuth, "Basic \(expectedCredentials)")
    }

    func testExecuteUsesPOSTMethod() async {
        let tokenURL = URL(string: "https://auth.example.com/token")!
        var capturedMethod: String?

        HTTPStubURLProtocol.register { request in
            guard request.url == tokenURL else { return nil }
            capturedMethod = request.httpMethod
            let body = Data("{\"access_token\":\"t\",\"token_type\":\"B\",\"expires_in\":60}".utf8)
            return .init(statusCode: 200, headers: ["Content-Type": "application/json"], body: body)
        }

        let session = URLSession.stubbedSession()
        let tokenRequest = TokenRequest(url: tokenURL, username: "u", password: "p")
        _ = await tokenRequest.execute(session: session)

        XCTAssertEqual(capturedMethod, "POST")
    }

    func testExecuteNon200StatusReturnsFailure() async {
        let tokenURL = URL(string: "https://auth.example.com/token")!

        HTTPStubURLProtocol.register { request in
            guard request.url == tokenURL else { return nil }
            return .init(statusCode: 401, headers: nil, body: Data("Unauthorized".utf8))
        }

        let session = URLSession.stubbedSession()
        let tokenRequest = TokenRequest(url: tokenURL, username: "user", password: "wrongpass")
        let result = await tokenRequest.execute(session: session)

        switch result {
        case .success:
            XCTFail("Expected failure for 401 response")
        case .failure(let error):
            let nsError = error as NSError
            XCTAssertEqual(nsError.code, 401)
        }
    }

    func testExecuteInvalidJSONReturnsDecodingError() async {
        let tokenURL = URL(string: "https://auth.example.com/token")!

        HTTPStubURLProtocol.register { request in
            guard request.url == tokenURL else { return nil }
            return .init(statusCode: 200,
                         headers: ["Content-Type": "application/json"],
                         body: Data("not json".utf8))
        }

        let session = URLSession.stubbedSession()
        let tokenRequest = TokenRequest(url: tokenURL, username: "user", password: "pass")
        let result = await tokenRequest.execute(session: session)

        switch result {
        case .success:
            XCTFail("Expected failure for invalid JSON")
        case .failure(let error):
            XCTAssertTrue(error is DecodingError, "Expected DecodingError but got \(type(of: error))")
        }
    }
}
