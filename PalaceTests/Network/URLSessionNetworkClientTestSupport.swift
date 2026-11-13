//
//  URLSessionNetworkClientTestSupport.swift
//  PalaceTests
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import PalaceAuth
import PalaceCatalog
@testable import Palace

/// A URLProtocol whose answer per URL is chosen by the test: respond at once,
/// or hold the request until `release` is called. Records every request that
/// starts and every one URLSession stops, and fulfils per-URL expectations at
/// those points so tests wait on the event rather than on a sleep.
final class ScriptedURLProtocol: URLProtocol {
    enum Route {
        case respond(status: Int, headers: [String: String]?, body: Data?)
        case hold
    }

    struct Seen {
        let url: URL
        let method: String?
        let authorization: String?
        let cachePolicy: URLRequest.CachePolicy
        let headers: [String: String]
    }

    private struct State {
        var routes: [URL: Route] = [:]
        var started: [Seen] = []
        var stopped: [URL] = []
        var held: [ScriptedURLProtocol] = []
        var onStart: [URL: XCTestExpectation] = [:]
        var onStop: [URL: XCTestExpectation] = [:]
    }

    private static let state = LockIsolated(State())
    private let finished = LockIsolated(false)
    /// The loading thread's run loop. A held request is answered there,
    /// because URLSession expects client callbacks on the thread that called
    /// `startLoading`.
    private let loadingRunLoop = LockIsolated<CFRunLoop?>(nil)

    static func reset() {
        state.value = State()
    }

    static func route(_ url: URL, _ route: Route) {
        state.withValue { $0.routes[url] = route }
    }

    static func expectStart(of url: URL, _ expectation: XCTestExpectation) {
        state.withValue { $0.onStart[url] = expectation }
    }

    static func expectStop(of url: URL, _ expectation: XCTestExpectation) {
        state.withValue { $0.onStop[url] = expectation }
    }

    static var started: [Seen] { state.value.started }

    /// The started requests whose path carries `runID`, the per-test path
    /// segment. A request a previous test left in flight can start after
    /// `reset()`; filtering on the run keeps it out of this test's assertions.
    static func started(inRun runID: String) -> [Seen] {
        state.value.started.filter { $0.url.path.contains("/\(runID)/") }
    }

    static func startCount(of url: URL) -> Int {
        state.value.started.filter { $0.url == url }.count
    }

    /// Answers every held request for `url` that URLSession has not stopped.
    static func release(_ url: URL, status: Int, body: Data?) {
        let toAnswer = state.withValue { state -> [ScriptedURLProtocol] in
            let matching = state.held.filter { $0.request.url == url }
            state.held.removeAll { $0.request.url == url }
            return matching
        }
        for request in toAnswer {
            guard let runLoop = request.loadingRunLoop.value else { continue }
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) {
                request.answer(status: status, headers: nil, body: body)
            }
            CFRunLoopWakeUp(runLoop)
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        loadingRunLoop.value = CFRunLoopGetCurrent()
        let seen = Seen(url: url,
                        method: request.httpMethod,
                        authorization: request.value(forHTTPHeaderField: "Authorization"),
                        cachePolicy: request.cachePolicy,
                        headers: request.allHTTPHeaderFields ?? [:])
        let (route, onStart) = Self.state.withValue { state -> (Route?, XCTestExpectation?) in
            state.started.append(seen)
            let route = state.routes[url]
            if case .hold = route { state.held.append(self) }
            return (route, state.onStart.removeValue(forKey: url))
        }
        switch route {
        case .respond(let status, let headers, let body):
            answer(status: status, headers: headers, body: body)
        case .hold:
            break
        case nil:
            answer(status: 501, headers: nil, body: nil)
        }
        onStart?.fulfill()
    }

    override func stopLoading() {
        guard let url = request.url else { return }
        finished.value = true
        let onStop = Self.state.withValue { state -> XCTestExpectation? in
            state.stopped.append(url)
            state.held.removeAll { $0 === self }
            return state.onStop.removeValue(forKey: url)
        }
        onStop?.fulfill()
    }

    private func answer(status: Int, headers: [String: String]?, body: Data?) {
        guard let url = request.url, !finished.value else { return }
        let response = HTTPURLResponse(url: url, statusCode: status,
                                       httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let body { client?.urlProtocol(self, didLoad: body) }
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// Builds a `URLSessionNetworkClient` over an executor whose accounts and
/// transport are both injected, so the token-refresh precondition is set by the
/// test rather than read from whatever account an earlier test left behind.
@MainActor
struct URLSessionNetworkClientFixture {
    let executor: TPPNetworkExecutor
    let client: URLSessionNetworkClient
    let accounts: TPPLibraryAccountMock
    let currentUser: TPPUserAccountMock

    /// - Parameter tokenExpiresIn: seconds until the current account's token
    ///   expires. Under the near-expiry threshold the executor refreshes
    ///   before dispatching a refresh-enabled request.
    /// - Parameter requestCachePolicy: the session default, which
    ///   `executor.request(for:)` copies onto every request it builds.
    /// - Parameter tokenURL: the current account's token endpoint. Callers pass
    ///   a per-test URL: `ScriptedURLProtocol` is process-wide, so a shared one
    ///   lets a request left by another test class be counted here.
    init(tokenURL: URL,
         tokenExpiresIn: TimeInterval,
         token: String = "current-token",
         requestCachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy) {
        let user = Self.tokenUser(token: token, expiresIn: tokenExpiresIn, tokenURL: tokenURL)
        let accounts = TPPLibraryAccountMock()
        let resolved: TPPUserAccountMock = user
        accounts.userAccountResolver = { _ in resolved }

        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = requestCachePolicy
        config.protocolClasses = [ScriptedURLProtocol.self]
        let executor = TPPNetworkExecutor(credentialsProvider: nil,
                                          cachingStrategy: .ephemeral,
                                          sessionConfiguration: config,
                                          accountsManager: accounts,
                                          delegateQueue: nil)
        executor.presentSignInAfterRefusedRefresh = {}

        self.executor = executor
        self.client = URLSessionNetworkClient(executor: executor)
        self.accounts = accounts
        self.currentUser = user
    }

    static func tokenUser(token: String, expiresIn: TimeInterval,
                          tokenURL: URL) -> TPPUserAccountMock {
        let user = TPPUserAccountMock()
        user._authDefinition = tokenAuth(tokenURL: tokenURL)
        user._credentials = .token(authToken: token, barcode: "user-001", pin: "1234",
                                   expirationDate: Date().addingTimeInterval(expiresIn))
        user.markLoggedIn()
        return user
    }

    nonisolated static func tokenAuth(tokenURL: URL) -> AccountDetails.Authentication {
        let json = """
        {
          "type": "http://thepalaceproject.org/authtype/basic-token",
          "links": [
            {"rel": "authenticate", "href": "\(tokenURL.absoluteString)"}
          ]
        }
        """
        let docAuth = try! JSONDecoder().decode(
            OPDS2AuthenticationDocument.Authentication.self, from: Data(json.utf8))
        return AccountDetails.Authentication(auth: docAuth)
    }

    nonisolated static func tokenJSON(_ accessToken: String) -> Data {
        Data("""
        {"access_token":"\(accessToken)","token_type":"Bearer","expires_in":3600}
        """.utf8)
    }
}
