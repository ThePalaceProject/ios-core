//
//  TokenRequestRetryTests.swift
//  PalaceAuthTests
//
//  Pins the bounded-retry resilience added to TokenRequest.execute for
//  HelpSpot 18046: a transient server hiccup (5xx/429/408) or retriable
//  network error must be retried and recover, while a genuine 401/403 must
//  fail immediately (never retried, never masked).
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import PalaceAuth

private enum StubResponse {
    case http(Int, Data)
    case failure(URLError)
}

/// URLProtocol that replays a programmed sequence of responses, one per
/// request, so a test can model "transient-then-success" across retries.
private final class SequencedStubURLProtocol: URLProtocol {
    static let lock = NSLock()
    static var responses: [StubResponse] = []
    static var requestCount = 0

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        responses = []
        requestCount = 0
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.requestCount += 1
        let next: StubResponse = Self.responses.isEmpty ? .http(200, Data()) : Self.responses.removeFirst()
        Self.lock.unlock()

        switch next {
        case let .http(status, body):
            let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                           httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case let .failure(urlError):
            client?.urlProtocol(self, didFailWithError: urlError)
        }
    }

    override func stopLoading() {}
}

final class TokenRequestRetryTests: XCTestCase {

    private var session: URLSession!
    private let noBackoff: @Sendable (Int) async -> Void = { _ in }

    private let tokenJSON = Data(#"{"access_token":"tok-123","token_type":"Bearer","expires_in":3600}"#.utf8)
    private let errBody = Data("server error".utf8)

    override func setUp() {
        super.setUp()
        SequencedStubURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SequencedStubURLProtocol.self]
        session = URLSession(configuration: config)
    }

    override func tearDown() {
        SequencedStubURLProtocol.reset()
        session = nil
        super.tearDown()
    }

    private func makeRequest() -> TokenRequest {
        TokenRequest(url: URL(string: "https://library.example.org/token")!,
                     username: "12345678", password: "1234")
    }

    // MARK: - Retry recovery

    /// A transient 503 on the first attempt followed by a 200 must recover —
    /// the patron never sees an error. This is the core 18046 scenario.
    func testExecute_transient5xxThenSuccess_retriesAndSucceeds() async {
        SequencedStubURLProtocol.responses = [.http(503, errBody), .http(200, tokenJSON)]

        let result = await makeRequest().execute(session: session, maxAttempts: 3, backoff: noBackoff)

        switch result {
        case .success(let token):
            XCTAssertEqual(token.accessToken, "tok-123")
        case .failure(let error):
            XCTFail("Expected success after retrying a transient 503, got \(error)")
        }
        XCTAssertEqual(SequencedStubURLProtocol.requestCount, 2,
                       "Must have made exactly 2 attempts (503 then 200)")
    }

    /// A retriable transport error (timeout) then a 200 must recover.
    func testExecute_retriableURLErrorThenSuccess_retries() async {
        SequencedStubURLProtocol.responses = [.failure(URLError(.timedOut)), .http(200, tokenJSON)]

        let result = await makeRequest().execute(session: session, maxAttempts: 3, backoff: noBackoff)

        if case .failure(let error) = result {
            XCTFail("Expected success after retrying a timeout, got \(error)")
        }
        XCTAssertEqual(SequencedStubURLProtocol.requestCount, 2)
    }

    // MARK: - Genuine auth failures are NOT retried

    /// A 401 is a real credential rejection — it must fail immediately on the
    /// first attempt, NOT be retried (we must never hammer /token with bad
    /// creds, and the user must get the auth error without delay).
    func testExecute_genuine401_doesNotRetry_failsImmediately() async {
        SequencedStubURLProtocol.responses = [.http(401, errBody), .http(200, tokenJSON)]

        let result = await makeRequest().execute(session: session, maxAttempts: 3, backoff: noBackoff)

        switch result {
        case .success:
            XCTFail("A 401 must not be retried into a success")
        case .failure(let error):
            XCTAssertEqual((error as NSError).code, 401, "Failure must carry the 401 status")
        }
        XCTAssertEqual(SequencedStubURLProtocol.requestCount, 1,
                       "A 401 must NOT be retried — exactly one attempt")
    }

    /// A persistent transient failure must stop after maxAttempts and fail
    /// (no infinite retry), surfacing the last transient status.
    func testExecute_persistent5xx_exhaustsAttemptsThenFails() async {
        SequencedStubURLProtocol.responses = [.http(500, errBody), .http(500, errBody), .http(500, errBody)]

        let result = await makeRequest().execute(session: session, maxAttempts: 3, backoff: noBackoff)

        switch result {
        case .success:
            XCTFail("Persistent 500 must fail after exhausting attempts")
        case .failure(let error):
            XCTAssertEqual((error as NSError).code, 500)
        }
        XCTAssertEqual(SequencedStubURLProtocol.requestCount, 3,
                       "Must stop after exactly maxAttempts (3) — no unbounded retry")
    }

    // MARK: - Pure classification helpers

    func testIsTransientStatus_retriableCodes() {
        for code in [408, 429, 500, 502, 503, 504] {
            XCTAssertTrue(TokenRequest.isTransientStatus(code), "\(code) should be transient")
        }
        for code in [200, 400, 401, 403, 404, 422] {
            XCTAssertFalse(TokenRequest.isTransientStatus(code), "\(code) should NOT be transient")
        }
    }

    func testIsRetriableURLError_networkErrorsOnly() {
        XCTAssertTrue(TokenRequest.isRetriableURLError(URLError(.timedOut)))
        XCTAssertTrue(TokenRequest.isRetriableURLError(URLError(.networkConnectionLost)))
        XCTAssertTrue(TokenRequest.isRetriableURLError(URLError(.cannotConnectToHost)))
        // Hard offline is NOT retried — fast-fail to the network-unavailable path.
        XCTAssertFalse(TokenRequest.isRetriableURLError(URLError(.notConnectedToInternet)))
        // A non-URLError (e.g. decoding) is never retriable.
        XCTAssertFalse(TokenRequest.isRetriableURLError(
            NSError(domain: "x", code: 1)))
    }
}
