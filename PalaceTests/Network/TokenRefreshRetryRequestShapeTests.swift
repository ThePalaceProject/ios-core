//  TokenRefreshRetryRequestShapeTests.swift
//
//  The request resent after a 401 and a successful token refresh must be the
//  request the caller sent, with only the bearer replaced: annotation, playtime
//  and renewal POSTs and the device-token PUT go through this path.

import XCTest
import PalaceAuth
import PalaceCatalog
@testable import Palace

@MainActor
final class TokenRefreshRetryRequestShapeTests: XCTestCase {

    private var executor: TPPNetworkExecutor!
    private var userAccount: TPPUserAccountMock!

    private let tokenURL = URL(string: "https://token.example.com/oauth/token")!
    private let apiURL = URL(string: "https://api.example.com/annotations/42")!
    private let body = Data(#"{"motivation":"bookmarking","id":"k-42"}"#.utf8)

    override func setUp() async throws {
        try await super.setUp()
        HTTPStubURLProtocol.reset()
        TPPUserAccountMock.resetShared()

        userAccount = TPPUserAccountMock()
        userAccount._authDefinition = try Self.makeTokenAuth(tokenURL: tokenURL)
        userAccount._credentials = .token(authToken: "stale-token",
                                          barcode: "user-12345",
                                          pin: "1234",
                                          expirationDate: Date().addingTimeInterval(3600))
        userAccount.markLoggedIn()

        let libraryAccount = TPPLibraryAccountMock()
        let resolved: TPPUserAccountMock = userAccount
        libraryAccount.userAccountResolver = { _ in resolved }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HTTPStubURLProtocol.self]
        executor = TPPNetworkExecutor(credentialsProvider: nil,
                                      cachingStrategy: .ephemeral,
                                      sessionConfiguration: config,
                                      accountsManager: libraryAccount,
                                      delegateQueue: nil)
        await executor.resetRefreshAttemptCount()
    }

    override func tearDown() {
        HTTPStubURLProtocol.reset()
        executor = nil
        userAccount = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private static func makeTokenAuth(tokenURL: URL) throws -> AccountDetails.Authentication {
        let json = """
        {"type":"http://thepalaceproject.org/authtype/basic-token",
         "links":[{"rel":"authenticate","href":"\(tokenURL.absoluteString)"}]}
        """
        let docAuth = try JSONDecoder().decode(OPDS2AuthenticationDocument.Authentication.self,
                                                from: Data(json.utf8))
        return AccountDetails.Authentication(auth: docAuth)
    }

    private nonisolated static func tokenJSON(_ token: String) -> Data {
        Data(#"{"access_token":"\#(token)","token_type":"Bearer","expires_in":3600}"#.utf8)
    }

    /// URLProtocol usually sees the body as a stream, whatever the caller set.
    private nonisolated static func bodyBytes(of request: URLRequest) -> Data? {
        if let direct = request.httpBody { return direct }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var collected = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            collected.append(buffer, count: count)
        }
        return collected
    }

    private struct SeenRequest: Sendable {
        let method: String?
        let body: Data?
        let headers: [String: String]
    }

    /// A request as a caller builds it: the executor's request with the stale
    /// bearer, then method, body and caller headers on top.
    private func callerRequest(method: String, body: Data?) -> URLRequest {
        var request = executor.request(for: apiURL)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/ld+json", forHTTPHeaderField: "Content-Type")
        request.setValue("k-42", forHTTPHeaderField: "X-Idempotency-Key")
        return request
    }

    /// Sends `request` once, then queues that sent task as a 401 retry and
    /// refreshes the token to "fresh-token". Returns every request the server
    /// saw after the first send, and the result the caller finally received.
    private func sendThenRetryAfterRefresh(_ request: URLRequest)
        async throws -> (retries: [SeenRequest], result: NYPLResult<Data>?) {
        let seen = LockIsolated<[SeenRequest]>([])
        HTTPStubURLProtocol.register { @Sendable [tokenURL, apiURL] request in
            if request.url == tokenURL {
                return .init(statusCode: 200, headers: nil, body: Self.tokenJSON("fresh-token"))
            }
            guard request.url == apiURL else { return nil }
            seen.withValue {
                $0.append(SeenRequest(method: request.httpMethod,
                                      body: Self.bodyBytes(of: request),
                                      headers: request.allHTTPHeaderFields ?? [:]))
            }
            return .init(statusCode: 200, headers: nil, body: Data("ok".utf8))
        }

        // The first send goes over the wire like production, so the retry is
        // rebuilt from a task that has already been sent.
        let sent = expectation(description: "first send completes")
        let task = try XCTUnwrap(executor.executeRequest(request, enableTokenRefresh: false) { @Sendable _ in
            sent.fulfill()
        })
        await fulfillment(of: [sent], timeout: 5.0)   // STARVE-001-OK: the stub answers at once

        let outcome = LockIsolated<NYPLResult<Data>?>(nil)
        let finished = expectation(description: "caller completion fires after the refresh")
        executor.refreshTokenAndResume(task: task, accountId: nil) { @Sendable result in
            outcome.withValue { $0 = result }
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 5.0)   // STARVE-001-OK: the stub answers at once

        XCTAssertGreaterThanOrEqual(seen.value.count, 1, "the first send must reach the server")
        return (Array(seen.value.dropFirst()), outcome.value)
    }

    private func retryAfterRefresh(of request: URLRequest) async throws -> SeenRequest {
        let (retries, result) = try await sendThenRetryAfterRefresh(request)
        XCTAssertEqual(retries.count, 1, "exactly one retry must reach the server")
        guard case .success? = result else {
            XCTFail("the retry must succeed, got \(String(describing: result))")
            return try XCTUnwrap(retries.first)
        }
        return try XCTUnwrap(retries.first)
    }

    private func assertSameRequestWithFreshBearer(_ retry: SeenRequest,
                                                  method: String,
                                                  body expectedBody: Data?,
                                                  file: StaticString = #filePath,
                                                  line: UInt = #line) {
        XCTAssertEqual(retry.method, method, "the retry must keep the HTTP method", file: file, line: line)
        XCTAssertEqual(retry.body, expectedBody, "the retry must resend the same body bytes", file: file, line: line)
        XCTAssertEqual(retry.headers["Content-Type"], "application/ld+json", file: file, line: line)
        XCTAssertEqual(retry.headers["X-Idempotency-Key"], "k-42", file: file, line: line)
        XCTAssertEqual(retry.headers["Authorization"], "Bearer fresh-token",
                       "only the bearer changes, to the refreshed token", file: file, line: line)
    }

    // MARK: - Tests

    func testRetryAfterRefresh_POST_KeepsMethodBodyAndHeadersWithFreshBearer() async throws {
        let retry = try await retryAfterRefresh(of: callerRequest(method: "POST", body: body))
        assertSameRequestWithFreshBearer(retry, method: "POST", body: body)
    }

    func testRetryAfterRefresh_PUT_KeepsMethodBodyAndHeadersWithFreshBearer() async throws {
        let retry = try await retryAfterRefresh(of: callerRequest(method: "PUT", body: body))
        assertSameRequestWithFreshBearer(retry, method: "PUT", body: body)
    }

    func testRetryAfterRefresh_DELETE_KeepsMethodAndHeadersWithFreshBearer() async throws {
        let retry = try await retryAfterRefresh(of: callerRequest(method: "DELETE", body: nil))
        assertSameRequestWithFreshBearer(retry, method: "DELETE", body: nil)
    }

    func testRetryAfterRefresh_GET_StaysAGetWithFreshBearer() async throws {
        let retry = try await retryAfterRefresh(of: callerRequest(method: "GET", body: nil))
        assertSameRequestWithFreshBearer(retry, method: "GET", body: nil)
    }

    /// A stream body is consumed by the first send, so the retry cannot resend
    /// it; the caller gets an error instead of a request with an empty body.
    func testRetryAfterRefresh_StreamBody_FailsTheCallerAndSendsNothing() async throws {
        var request = callerRequest(method: "POST", body: nil)
        request.httpBodyStream = InputStream(data: body)

        let (retries, result) = try await sendThenRetryAfterRefresh(request)

        guard case .failure(let error, _)? = result else {
            return XCTFail("a stream-bodied retry must fail, got \(String(describing: result))")
        }
        XCTAssertEqual((error as NSError).code, TPPErrorCode.responseFail.rawValue)
        XCTAssertEqual(retries.count, 0, "no retry may be sent without its body")
        XCTAssertEqual(userAccount.authToken, "fresh-token", "the refresh itself still succeeded")
    }
}
