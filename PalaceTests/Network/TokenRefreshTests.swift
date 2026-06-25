//
//  TokenRefreshTests.swift
//  PalaceTests
//
//  Unit tests for token refresh and 401 retry logic.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import XCTest
import PalaceAuth
@testable import Palace

final class TokenRefreshTests: XCTestCase {

    // MARK: - TokenResponse Tests

    func testTokenResponse_ExpirationDateCalculation() {
        let response = TokenResponse(
            accessToken: "test-token",
            tokenType: "Bearer",
            expiresIn: 3600
        )

        let expectedExpiration = Date().addingTimeInterval(3600)

        // Allow 1 second tolerance
        XCTAssertEqual(
            response.expirationDate.timeIntervalSince1970,
            expectedExpiration.timeIntervalSince1970,
            accuracy: 1.0
        )
    }

    func testTokenResponse_ZeroExpiresIn() {
        let response = TokenResponse(
            accessToken: "test-token",
            tokenType: "Bearer",
            expiresIn: 0
        )

        // Expiration should be approximately now
        let now = Date()
        XCTAssertEqual(
            response.expirationDate.timeIntervalSince1970,
            now.timeIntervalSince1970,
            accuracy: 1.0
        )
    }

    func testTokenResponse_NegativeExpiresIn() {
        let response = TokenResponse(
            accessToken: "test-token",
            tokenType: "Bearer",
            expiresIn: -3600
        )

        // Expiration should be in the past
        let now = Date()
        XCTAssertLessThan(response.expirationDate, now)
    }

    // MARK: - TokenRequest Tests

    func testTokenRequest_InitializesCorrectly() {
        let url = URL(string: "https://example.com/token")!
        let request = TokenRequest(url: url, username: "user", password: "pass")

        XCTAssertEqual(request.url, url)
        XCTAssertEqual(request.username, "user")
        XCTAssertEqual(request.password, "pass")
    }

    func testTokenRequest_EmptyUsername() {
        let url = URL(string: "https://example.com/token")!
        let request = TokenRequest(url: url, username: "", password: "pass")

        XCTAssertEqual(request.username, "")
        XCTAssertTrue(request.username.isEmpty, "Empty username must be stored as an empty string")
        // Password should be unaffected by an empty username
        XCTAssertEqual(request.password, "pass", "Password must be stored independently from username")
    }

    func testTokenRequest_EmptyPassword() {
        let url = URL(string: "https://example.com/token")!
        let request = TokenRequest(url: url, username: "user", password: "")

        XCTAssertEqual(request.password, "")
        XCTAssertTrue(request.password.isEmpty, "Empty password must be stored as an empty string")
        // Username should be unaffected by an empty password
        XCTAssertEqual(request.username, "user", "Username must be stored independently from password")
    }

    func testTokenRequest_SpecialCharactersInCredentials() {
        let url = URL(string: "https://example.com/token")!
        let request = TokenRequest(
            url: url,
            username: "user@domain.com",
            password: "p@ss!word#123"
        )

        XCTAssertEqual(request.username, "user@domain.com")
        XCTAssertEqual(request.password, "p@ss!word#123")
    }

    // MARK: - Mock Executor Tests

    func testMockExecutor_ReturnsConfiguredResponse() {
        let mock = TPPRequestExecutorMock()
        let testURL = URL(string: "https://test.com/api")!
        let responseBody = "{\"test\": \"data\"}"
        mock.responseBodies[testURL] = responseBody

        let expectation = XCTestExpectation(description: "Response received")

        let request = URLRequest(url: testURL)
        _ = mock.executeRequest(request, enableTokenRefresh: false) { result in
            switch result {
            case .success(let data, let response):
                XCTAssertNotNil(data)
                XCTAssertNotNil(response)
                if let responseString = String(data: data, encoding: .utf8) {
                    XCTAssertEqual(responseString, responseBody)
                }
            case .failure:
                XCTFail("Expected success")
            }
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 2.0)
    }

    func testMockExecutor_Returns404ForUnknownURL() {
        let mock = TPPRequestExecutorMock()
        let unknownURL = URL(string: "https://unknown.com/api")!

        let expectation = XCTestExpectation(description: "Error received")

        let request = URLRequest(url: unknownURL)
        _ = mock.executeRequest(request, enableTokenRefresh: false) { result in
            switch result {
            case .success:
                XCTFail("Expected failure for unknown URL")
            case .failure(_, let response):
                if let httpResponse = response as? HTTPURLResponse {
                    XCTAssertEqual(httpResponse.statusCode, 404)
                }
            }
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 2.0)
    }

    func testMockExecutor_HandlesEmptyURL() {
        let mock = TPPRequestExecutorMock()

        let expectation = XCTestExpectation(description: "Error received")

        var request = URLRequest(url: URL(string: "https://example.com")!)
        request.url = nil // Set URL to nil

        _ = mock.executeRequest(request, enableTokenRefresh: false) { result in
            switch result {
            case .success:
                XCTFail("Expected failure for nil URL")
            case .failure:
                break
            }
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 2.0)
    }

    // MARK: - Request Timeout Tests

    func testRequestTimeout_DefaultValue() {
        let mock = TPPRequestExecutorMock()
        XCTAssertEqual(mock.requestTimeout, 60)
        XCTAssertGreaterThan(mock.requestTimeout, 0, "Request timeout must be positive")
        // Note: The mock hardcodes 60s for broader test coverage; the global constant is 30s
        XCTAssertEqual(TPPDefaultRequestTimeout, 30.0,
                       "Global TPPDefaultRequestTimeout must be 30 seconds")
    }

    func testRequestTimeout_StaticDefault() {
        XCTAssertEqual(TPPRequestExecutorMock.defaultRequestTimeout, TPPDefaultRequestTimeout)
        XCTAssertGreaterThan(TPPRequestExecutorMock.defaultRequestTimeout, 0,
                             "Default request timeout constant must be positive")
        // The mock instance overrides requestTimeout to 60; static default follows the protocol (30)
        let mock = TPPRequestExecutorMock()
        XCTAssertEqual(mock.requestTimeout, 60,
                       "Mock instance requestTimeout is hardcoded to 60")
        XCTAssertEqual(TPPRequestExecutorMock.defaultRequestTimeout, 30,
                       "Static defaultRequestTimeout must equal TPPDefaultRequestTimeout (30)")
    }

    // MARK: - NYPLResult Tests

    func testNYPLResult_SuccessCase() {
        let data = Data("test".utf8)
        let response = HTTPURLResponse(url: URL(string: "https://test.com")!,
                                       statusCode: 200,
                                       httpVersion: nil,
                                       headerFields: nil)

        let result: NYPLResult<Data> = .success(data, response)

        switch result {
        case .success(let resultData, let resultResponse):
            XCTAssertEqual(resultData, data)
            XCTAssertNotNil(resultResponse)
        case .failure:
            XCTFail("Expected success")
        }
    }

    func testNYPLResult_FailureCase() {
        let error = NSError(domain: "Test", code: -1, userInfo: nil)
        let response = HTTPURLResponse(url: URL(string: "https://test.com")!,
                                       statusCode: 401,
                                       httpVersion: nil,
                                       headerFields: nil)

        let result: NYPLResult<Data> = .failure(error, response)

        switch result {
        case .success:
            XCTFail("Expected failure")
        case .failure(let resultError, let resultResponse):
            XCTAssertEqual((resultError as NSError).code, -1)
            XCTAssertNotNil(resultResponse)
        }
    }

    func testNYPLResult_SuccessWithNilResponse() {
        let data = Data("test".utf8)
        let result: NYPLResult<Data> = .success(data, nil)

        switch result {
        case .success(let resultData, let resultResponse):
            XCTAssertEqual(resultData, data)
            XCTAssertNil(resultResponse)
        case .failure:
            XCTFail("Expected success")
        }
    }

    func testNYPLResult_FailureWithNilResponse() {
        let error = NSError(domain: "Test", code: -1, userInfo: nil)
        let result: NYPLResult<Data> = .failure(error, nil)

        switch result {
        case .success:
            XCTFail("Expected failure")
        case .failure(let resultError, let resultResponse):
            XCTAssertNotNil(resultError)
            XCTAssertNil(resultResponse)
        }
    }

    // MARK: - Token Expiry Edge Cases

    func testTokenResponse_LargeExpiresIn() {
        let oneYearInSeconds = 31536000
        let response = TokenResponse(
            accessToken: "long-lived-token",
            tokenType: "Bearer",
            expiresIn: oneYearInSeconds
        )

        let expectedExpiration = Date().addingTimeInterval(Double(oneYearInSeconds))

        XCTAssertEqual(
            response.expirationDate.timeIntervalSince1970,
            expectedExpiration.timeIntervalSince1970,
            accuracy: 1.0
        )
    }

    func testTokenResponse_SmallExpiresIn() {
        let response = TokenResponse(
            accessToken: "short-lived-token",
            tokenType: "Bearer",
            expiresIn: 1
        )

        let expectedExpiration = Date().addingTimeInterval(1)

        XCTAssertEqual(
            response.expirationDate.timeIntervalSince1970,
            expectedExpiration.timeIntervalSince1970,
            accuracy: 1.0
        )
    }

    // MARK: - JSON Decoding Integration Tests

    func testTokenResponse_DecodesFromJSON() throws {
        let json = Data("""
    {
      "access_token": "decoded-token",
      "token_type": "Bearer",
      "expires_in": 7200
    }
    """.utf8)

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let response = try decoder.decode(TokenResponse.self, from: json)

        XCTAssertEqual(response.accessToken, "decoded-token")
        XCTAssertEqual(response.tokenType, "Bearer")
        XCTAssertEqual(response.expiresIn, 7200)
    }

    func testTokenResponse_EncodesToJSON() throws {
        let response = TokenResponse(
            accessToken: "encoded-token",
            tokenType: "Bearer",
            expiresIn: 3600
        )

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase

        let data = try encoder.encode(response)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertEqual(json?["access_token"] as? String, "encoded-token")
        XCTAssertEqual(json?["token_type"] as? String, "Bearer")
        XCTAssertEqual(json?["expires_in"] as? Int, 3600)
    }

    func testTokenResponse_RoundTrip() throws {
        let original = TokenResponse(
            accessToken: "roundtrip-token",
            tokenType: "Bearer",
            expiresIn: 1800
        )

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let decoded = try decoder.decode(TokenResponse.self, from: data)

        XCTAssertEqual(decoded.accessToken, original.accessToken)
        XCTAssertEqual(decoded.tokenType, original.tokenType)
        XCTAssertEqual(decoded.expiresIn, original.expiresIn)
    }

    // MARK: - Bearer Token Authorization Tests

    func testBearerAuthorized_AddsAuthorizationHeader() {
        // This test would require access to TPPUserAccount mock
        // For now, test the structure of the request
        let url = URL(string: "https://example.com/api")!
        var request = URLRequest(url: url)
        request.setValue("Bearer test-token", forHTTPHeaderField: "Authorization")

        let authHeader = request.value(forHTTPHeaderField: "Authorization")
        XCTAssertEqual(authHeader, "Bearer test-token")
        XCTAssertTrue(authHeader?.starts(with: "Bearer ") == true,
                      "Authorization header must start with 'Bearer ' prefix")
        // URL must be unaffected by header mutation
        XCTAssertEqual(request.url, url, "URL must not change when adding Authorization header")
    }

    func testBearerAuthorized_EmptyTokenSetsEmptyHeader() {
        let url = URL(string: "https://example.com/api")!
        var request = URLRequest(url: url)
        request.setValue("", forHTTPHeaderField: "Authorization")

        let authHeader = request.value(forHTTPHeaderField: "Authorization")
        XCTAssertEqual(authHeader, "")
        XCTAssertTrue(authHeader?.isEmpty == true,
                      "Empty token should produce an empty Authorization header value")
        XCTAssertEqual(request.url, url, "URL must not change when adding empty Authorization header")
    }
}

// MARK: - Token Type Tests

extension TokenRefreshTests {

    func testTokenResponse_DifferentTokenTypes() throws {
        let bearerJSON = Data("""
    {"access_token": "token", "token_type": "Bearer", "expires_in": 3600}
    """.utf8)

        let macJSON = Data("""
    {"access_token": "token", "token_type": "MAC", "expires_in": 3600}
    """.utf8)

        let customJSON = Data("""
    {"access_token": "token", "token_type": "CustomType", "expires_in": 3600}
    """.utf8)

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let bearerResponse = try decoder.decode(TokenResponse.self, from: bearerJSON)
        let macResponse = try decoder.decode(TokenResponse.self, from: macJSON)
        let customResponse = try decoder.decode(TokenResponse.self, from: customJSON)

        XCTAssertEqual(bearerResponse.tokenType, "Bearer")
        XCTAssertEqual(macResponse.tokenType, "MAC")
        XCTAssertEqual(customResponse.tokenType, "CustomType")
    }
}

// MARK: - Error Code Tests

extension TokenRefreshTests {

    func testTPPErrorCode_InvalidCredentialsValue() {
        // Verify the error code constant exists and has expected behavior
        let error = NSError(
            domain: TPPErrorLogger.clientDomain,
            code: TPPErrorCode.invalidCredentials.rawValue,
            userInfo: nil
        )

        XCTAssertEqual(error.domain, TPPErrorLogger.clientDomain)
        XCTAssertEqual(error.code, TPPErrorCode.invalidCredentials.rawValue,
                       "NSError code must match the TPPErrorCode raw value")
        XCTAssertGreaterThan(TPPErrorCode.invalidCredentials.rawValue, 0,
                             "Error codes should be positive integers")
    }
}

// MARK: - Token Refresh Watchdog Tests

/// Regression guard for the persistent "main catalog hangs across library
/// switches until restart" symptom. If a token refresh ever wedges with
/// `isRefreshing == true`, every later token-authed request coalesces behind
/// it and hangs forever. The watchdog must force-release a stuck slot while
/// never disturbing a refresh that completed normally or a newer one in
/// flight. These lock that contract deterministically (no real timing).
final class TokenRefreshWatchdogTests: XCTestCase {

    private func makeExecutor() -> TPPNetworkExecutor {
        TPPNetworkExecutor(credentialsProvider: nil, cachingStrategy: .ephemeral, delegateQueue: nil)
    }

    private func dummyTask() -> URLSessionTask {
        URLSession.shared.dataTask(with: URL(string: "https://example.com/loans")!)
    }

    func testWatchdog_forceReleasesStuckRefresh_andHandsBackStrandedQueue() async {
        let ex = makeExecutor()
        let claimed = await ex.claimTokenRefreshSlotForTesting()
        XCTAssertTrue(claimed, "First caller must claim the single-flight slot")
        let gen = await ex.currentTokenRefreshGenerationForTesting()
        await ex.appendTokenRetryForTesting(dummyTask())

        let refreshingBefore = await ex.isTokenRefreshingForTesting
        XCTAssertTrue(refreshingBefore)

        let stranded = await ex.forceReleaseStuckTokenRefreshForTesting(generation: gen)
        XCTAssertEqual(stranded?.count, 1, "A wedged refresh must return its stranded retry queue")

        let refreshingAfter = await ex.isTokenRefreshingForTesting
        XCTAssertFalse(refreshingAfter, "Watchdog must clear isRefreshing so future refreshes can proceed")
    }

    func testWatchdog_doesNotDisturb_aRefreshThatCompletedNormally() async {
        let ex = makeExecutor()
        let claimed = await ex.claimTokenRefreshSlotForTesting()
        XCTAssertTrue(claimed)
        let gen = await ex.currentTokenRefreshGenerationForTesting()
        // Normal completion path:
        await ex.setTokenRefreshingForTesting(false)
        let stranded = await ex.forceReleaseStuckTokenRefreshForTesting(generation: gen)
        XCTAssertNil(stranded, "A completed refresh must not be treated as stuck")
    }

    func testWatchdog_staleGeneration_doesNotReleaseNewerRefresh() async {
        let ex = makeExecutor()
        let claimedOld = await ex.claimTokenRefreshSlotForTesting()
        XCTAssertTrue(claimedOld)
        let oldGen = await ex.currentTokenRefreshGenerationForTesting()
        await ex.setTokenRefreshingForTesting(false)             // old refresh completes

        let claimedNew = await ex.claimTokenRefreshSlotForTesting() // a NEW refresh claims
        XCTAssertTrue(claimedNew)
        let newGen = await ex.currentTokenRefreshGenerationForTesting()
        XCTAssertNotEqual(oldGen, newGen, "Each claim must advance the generation")

        let stranded = await ex.forceReleaseStuckTokenRefreshForTesting(generation: oldGen)
        XCTAssertNil(stranded, "A stale watchdog must not release a newer refresh's slot")
        let stillRefreshing = await ex.isTokenRefreshingForTesting
        XCTAssertTrue(stillRefreshing, "Newer refresh must remain in flight after a stale watchdog fires")
    }

    func testWatchdog_isIdempotent() async {
        let ex = makeExecutor()
        let claimed = await ex.claimTokenRefreshSlotForTesting()
        XCTAssertTrue(claimed)
        let gen = await ex.currentTokenRefreshGenerationForTesting()
        _ = await ex.forceReleaseStuckTokenRefreshForTesting(generation: gen)
        let second = await ex.forceReleaseStuckTokenRefreshForTesting(generation: gen)
        XCTAssertNil(second, "Releasing an already-released slot must be a no-op")
    }

    func testClaim_isSingleFlight() async {
        let ex = makeExecutor()
        let first = await ex.claimTokenRefreshSlotForTesting()
        let second = await ex.claimTokenRefreshSlotForTesting()
        XCTAssertTrue(first)
        XCTAssertFalse(second, "Only one refresh may hold the slot at a time")
    }
}
