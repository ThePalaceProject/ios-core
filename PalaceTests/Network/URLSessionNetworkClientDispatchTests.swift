//
//  URLSessionNetworkClientDispatchTests.swift
//  PalaceTests
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import PalaceNetwork
@testable import Palace

/// What `URLSessionNetworkClient.send` puts on the wire per HTTP method, and
/// how the response comes back: the wire method, the cache policy, whether a
/// near-expiry token is refreshed first, which bearer is sent, and the
/// success / error contract `NetworkClient` callers rely on.
@MainActor
final class URLSessionNetworkClientDispatchTests: XCTestCase {

    /// Per-test path segment: `ScriptedURLProtocol` is process-wide, so a request
    /// left over from another test class must not reach or be counted by this one.
    private let runID = UUID().uuidString
    private lazy var apiURL = URL(string: "https://api.example.com/\(runID)/resource")!
    private lazy var tokenURL = URL(string: "https://token.example.com/\(runID)/oauth/token")!
    private let allMethods: [HTTPMethod] = [.GET, .HEAD, .POST, .PUT, .PATCH, .DELETE]

    override func setUp() async throws {
        try await super.setUp()
        ScriptedURLProtocol.reset()
    }

    override func tearDown() async throws {
        ScriptedURLProtocol.reset()
        try await super.tearDown()
    }

    // MARK: - Wire shape

    /// GET and HEAD go out as GET with `.useProtocolCachePolicy`; the other
    /// verbs keep their method and the session's default cache policy.
    func testSend_eachMethod_reachesTheServerWithItsWireMethodAndCachePolicy() async throws {
        let expected: [HTTPMethod: (String, URLRequest.CachePolicy)] = [
            .GET: ("GET", .useProtocolCachePolicy),
            .HEAD: ("GET", .useProtocolCachePolicy),
            .POST: ("POST", .reloadIgnoringLocalCacheData),
            .PUT: ("PUT", .reloadIgnoringLocalCacheData),
            .PATCH: ("PATCH", .reloadIgnoringLocalCacheData),
            .DELETE: ("DELETE", .reloadIgnoringLocalCacheData),
        ]
        for method in allMethods {
            ScriptedURLProtocol.reset()
            let fixture = URLSessionNetworkClientFixture(tokenURL: tokenURL, tokenExpiresIn: 3600,
                                                         requestCachePolicy: .reloadIgnoringLocalCacheData)
            ScriptedURLProtocol.route(apiURL, .respond(status: 200, headers: nil, body: Data()))

            _ = try await send(fixture.client, method)

            let seen = try XCTUnwrap(ScriptedURLProtocol.started.first, "\(method) sent nothing")
            XCTAssertEqual(seen.method, expected[method]?.0, "\(method): wire method")
            XCTAssertEqual(seen.cachePolicy, expected[method]?.1, "\(method): cache policy")
        }
    }

    /// With a near-expiry token, GET, HEAD, POST and PUT refresh before they
    /// dispatch; PATCH and DELETE dispatch without refreshing.
    func testSend_nearExpiryToken_refreshesFirstOnlyForRefreshEnabledMethods() async throws {
        let refreshes: Set<HTTPMethod> = [.GET, .HEAD, .POST, .PUT]
        for method in allMethods {
            ScriptedURLProtocol.reset()
            let fixture = URLSessionNetworkClientFixture(tokenURL: tokenURL, tokenExpiresIn: 60)
            ScriptedURLProtocol.route(tokenURL, .respond(status: 200, headers: nil,
                                                         body: URLSessionNetworkClientFixture.tokenJSON("refreshed")))
            ScriptedURLProtocol.route(apiURL, .respond(status: 200, headers: nil, body: Data()))

            _ = try await send(fixture.client, method)

            let order = ScriptedURLProtocol.started.map(\.url)
            if refreshes.contains(method) {
                XCTAssertEqual(order, [tokenURL, apiURL], "\(method) must refresh, then dispatch once")
            } else {
                XCTAssertEqual(order, [apiURL], "\(method) must dispatch without refreshing")
            }
        }
    }

    /// Every method but PATCH sends the current account's bearer from
    /// `request(for:)`, and caller headers are applied on top of it.
    func testSend_nonPatchMethods_sendTheCurrentAccountBearerAndCallerHeaders() async throws {
        for method in allMethods where method != .PATCH {
            ScriptedURLProtocol.reset()
            let fixture = URLSessionNetworkClientFixture(tokenURL: tokenURL, tokenExpiresIn: 3600, token: "token-A")
            ScriptedURLProtocol.route(apiURL, .respond(status: 200, headers: nil, body: Data()))

            _ = try await send(fixture.client, method, headers: ["X-Caller": "yes"])

            let seen = try XCTUnwrap(ScriptedURLProtocol.started.first)
            XCTAssertEqual(seen.authorization, "Bearer token-A", "\(method): bearer")
            XCTAssertEqual(seen.headers["X-Caller"], "yes", "\(method): caller header")
        }
    }

    /// PATCH replaces any caller Authorization with the legacy class-level
    /// bearer, as `addBearerAndExecute` did.
    func testSend_patch_replacesTheCallerAuthorizationWithTheLegacyBearer() async throws {
        let fixture = URLSessionNetworkClientFixture(tokenURL: tokenURL, tokenExpiresIn: 3600, token: "token-A")
        ScriptedURLProtocol.route(apiURL, .respond(status: 200, headers: nil, body: Data()))
        let legacy = TPPNetworkExecutor.bearerAuthorized(request: URLRequest(url: apiURL))
            .value(forHTTPHeaderField: "Authorization") ?? ""

        _ = try await send(fixture.client, .PATCH, headers: ["Authorization": "Bearer caller-supplied"])

        let seen = try XCTUnwrap(ScriptedURLProtocol.started.first)
        XCTAssertNotEqual(seen.authorization, "Bearer caller-supplied")
        XCTAssertEqual(seen.authorization ?? "", legacy)
    }

    // MARK: - Response contract

    /// A 2xx returns the body, status and headers for every method.
    func testSend_success_returnsBodyStatusAndHeadersForEveryMethod() async throws {
        for method in allMethods {
            ScriptedURLProtocol.reset()
            let fixture = URLSessionNetworkClientFixture(tokenURL: tokenURL, tokenExpiresIn: 3600)
            ScriptedURLProtocol.route(apiURL, .respond(status: 201,
                                                       headers: ["Content-Type": "application/opds+json"],
                                                       body: Data("payload".utf8)))

            let response = try await send(fixture.client, method)

            XCTAssertEqual(response.data, Data("payload".utf8), "\(method): body")
            XCTAssertEqual(response.statusCode, 201, "\(method): status")
            XCTAssertEqual(response.contentType, "application/opds+json", "\(method): headers")
        }
    }

    /// A non-2xx with a problem document throws the responder's error, with the
    /// problem document attached, for every method.
    func testSend_errorWithProblemDocument_throwsTheParsedProblemForEveryMethod() async {
        let problem = Data("""
        {"type":"http://librarysimplified.org/terms/problem/loan-limit-reached","title":"Loan limit reached"}
        """.utf8)
        for method in allMethods {
            ScriptedURLProtocol.reset()
            let fixture = URLSessionNetworkClientFixture(tokenURL: tokenURL, tokenExpiresIn: 3600)
            ScriptedURLProtocol.route(apiURL, .respond(status: 403, headers: nil, body: problem))

            do {
                _ = try await send(fixture.client, method)
                XCTFail("\(method): a 403 must throw")
            } catch {
                XCTAssertEqual((error as NSError).problemDocument?.title, "Loan limit reached",
                               "\(method): the problem document must reach the caller")
            }
        }
    }

    /// A non-2xx with no body throws the responder's generic failure error.
    func testSend_errorWithEmptyBody_throwsTheResponseFailError() async {
        for method in allMethods {
            ScriptedURLProtocol.reset()
            let fixture = URLSessionNetworkClientFixture(tokenURL: tokenURL, tokenExpiresIn: 3600)
            ScriptedURLProtocol.route(apiURL, .respond(status: 500, headers: nil, body: nil))

            do {
                _ = try await send(fixture.client, method)
                XCTFail("\(method): a 500 must throw")
            } catch {
                XCTAssertEqual((error as NSError).code, TPPErrorCode.responseFail.rawValue,
                               "\(method): error code")
            }
        }
    }

    // MARK: - Account selection

    /// `send` names no account, so the current account's credentials and token
    /// state apply, not another library's.
    func testSend_usesTheCurrentAccountForBearerAndRefresh() async throws {
        let fixture = URLSessionNetworkClientFixture(tokenURL: tokenURL, tokenExpiresIn: 3600)
        let otherTokenURL = URL(string: "https://other.example.com/\(runID)/token")!
        let current = URLSessionNetworkClientFixture.tokenUser(token: "token-current", expiresIn: 60,
                                                               tokenURL: tokenURL)
        let other = URLSessionNetworkClientFixture.tokenUser(token: "token-other", expiresIn: 60,
                                                             tokenURL: otherTokenURL)
        let currentId = fixture.accounts.currentAccountId
        fixture.accounts.userAccountResolver = { id in id == currentId ? current : other }
        ScriptedURLProtocol.route(tokenURL, .respond(status: 200, headers: nil,
                                                     body: URLSessionNetworkClientFixture.tokenJSON("refreshed")))
        ScriptedURLProtocol.route(apiURL, .respond(status: 200, headers: nil, body: Data()))

        _ = try await send(fixture.client, .GET)

        XCTAssertEqual(ScriptedURLProtocol.started.map(\.url), [tokenURL, apiURL],
                       "the current account's token endpoint must be the one refreshed")
        XCTAssertEqual(ScriptedURLProtocol.started.last?.authorization, "Bearer refreshed",
                       "the request is sent with the current account's refreshed token")
        XCTAssertEqual(current.authToken, "refreshed")
        XCTAssertNotEqual(other.authToken, "refreshed")
    }

    // MARK: - Helpers

    private func send(_ client: URLSessionNetworkClient,
                      _ method: HTTPMethod,
                      headers: [String: String] = [:]) async throws -> Reply {
        try await Self.send(client, method: method.rawValue, url: apiURL, headers: headers)
    }

    /// `NetworkRequest`, `NetworkResponse` and `HTTPMethod` are not Sendable,
    /// so they are built and read off the main actor and only Sendable values
    /// cross.
    private nonisolated static func send(_ client: URLSessionNetworkClient,
                                         method rawMethod: String,
                                         url: URL,
                                         headers: [String: String]) async throws -> Reply {
        guard let method = HTTPMethod(rawValue: rawMethod) else { throw URLError(.unsupportedURL) }
        let body = method == .GET || method == .HEAD ? nil : Data("{}".utf8)
        let response = try await client.send(NetworkRequest(method: method, url: url,
                                                            headers: headers, body: body))
        return Reply(data: response.data,
                     statusCode: response.response.statusCode,
                     contentType: response.response.value(forHTTPHeaderField: "Content-Type"))
    }

    private struct Reply: Sendable {
        let data: Data
        let statusCode: Int
        let contentType: String?
    }
}
