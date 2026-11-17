//
//  RequestExecutingAsyncBridgeTests.swift
//  The Palace Project
//

import XCTest
import PalaceAuth
import PalaceCatalog
@testable import Palace

/// Drives the real `TPPNetworkExecutor.execute` over a stubbed URLSession, so
/// the async entry point, its single continuation and the preflight it shares
/// with the callback form all actually run.
///
/// The property under test is the one that makes `execute` a fix rather than a
/// style preference: a caller gets its result back on its own actor, whatever
/// thread URLSession completed on. The callback requirements this replaced
/// could not offer that — a completion typed `(NYPLResult<Data>) -> Void`
/// carries no isolation, and the sessions use `delegateQueue: nil` (PP-5299).
@MainActor
final class RequestExecutingAsyncBridgeTests: XCTestCase {

    private var executor: TPPNetworkExecutor!
    private var libraryAccount: TPPLibraryAccountMock!
    private var userAccount: TPPUserAccountMock!

    /// Per-test path segment: the stub handlers are process-wide, so a retry
    /// left over from another test class must not reach or be counted by this one.
    private let runID = UUID().uuidString
    private lazy var tokenURL = URL(string: "https://token.example.com/\(runID)/oauth/token")!
    private lazy var apiURL = URL(string: "https://api.example.com/\(runID)/protected")!

    override func setUp() async throws {
        try await super.setUp()
        HTTPStubURLProtocol.reset()
        TPPUserAccountMock.resetShared()

        userAccount = TPPUserAccountMock()
        userAccount._authDefinition = Self.makeTokenAuth(tokenURL: tokenURL)
        userAccount._credentials = .token(authToken: "fresh",
                                          barcode: "user-001",
                                          pin: "1234",
                                          expirationDate: Date().addingTimeInterval(3600))
        userAccount.markLoggedIn()

        libraryAccount = TPPLibraryAccountMock()
        let resolved: TPPUserAccountMock = userAccount
        libraryAccount.userAccountResolver = { _ in resolved }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HTTPStubURLProtocol.self]
        executor = TPPNetworkExecutor(credentialsProvider: nil,
                                      cachingStrategy: .ephemeral,
                                      sessionConfiguration: config,
                                      accountsManager: libraryAccount,
                                      delegateQueue: nil)
    }

    override func tearDown() async throws {
        HTTPStubURLProtocol.reset()
        executor = nil
        libraryAccount = nil
        userAccount = nil
        try await super.tearDown()
    }

    // MARK: - The two awaited entry points added for PP-5301
    //
    // Both are production wiring: `fetchResult(from:)` is what
    // `Sample.fetchSample` calls and `refreshToken(accountId:)` is
    // `AudiobookLoader`'s default refresh — the PP-5299 path. Each wraps a
    // completion-handler form in a continuation, so a double resume would be a
    // hard trap rather than a failure, and neither had a test calling it.

    /// `fetchResult` reports the failure response rather than discarding it,
    /// which is the whole reason it exists beside the `async throws` `GET`
    /// overloads: callers read problem documents off error responses and
    /// `throws` loses them.
    func testFetchResult_on401_reportsFailureCarryingTheResponse() async {
        signOutInjectedAccount()
        HTTPStubURLProtocol.register { @Sendable [apiURL] request in
            guard request.url == apiURL else { return nil }
            return .init(statusCode: 401, headers: nil, body: Data("{}".utf8))
        }

        let result = await executor.fetchResult(from: apiURL, useTokenIfAvailable: false)

        guard case .failure(_, let response) = result else {
            return XCTFail("a 401 must surface as .failure, got \(result)")
        }
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 401,
                       "the response must be carried on the failure — discarding it is what the "
                       + "throwing overload does and why this entry point exists")
    }

    /// The success path: the body reaches the caller intact.
    ///
    /// Resuming on the caller's actor is not asserted here — this case is
    /// `@MainActor`, so the compiler already guarantees it and an assertion
    /// would restate the language rather than test the code. The sibling that
    /// can fail on that property is
    /// `testExecute_whenURLSessionCompletesOffMain…`, which records where the
    /// stub answered as a premise control.
    func testFetchResult_onSuccess_returnsTheBody() async {
        HTTPStubURLProtocol.register { @Sendable [apiURL] request in
            guard request.url == apiURL else { return nil }
            return .init(statusCode: 200, headers: nil, body: Data("payload".utf8))
        }

        let result = await executor.fetchResult(from: apiURL, useTokenIfAvailable: false)

        guard case .success(let data, _) = result else {
            return XCTFail("expected success, got \(result)")
        }
        XCTAssertEqual(String(data: data, encoding: .utf8), "payload")
    }

    /// `refreshToken` bridges `refreshTokenAndResume`, whose completion fires
    /// from inside its own `Task`. The awaited form must answer exactly once:
    /// the continuation box is the only thing standing between a second
    /// completion and a crash.
    func testRefreshToken_whenTheTokenEndpointAnswers_resumesExactlyOnce() async {
        let hits = CallCounter()
        HTTPStubURLProtocol.register { @Sendable [tokenURL] request in
            guard request.url == tokenURL else { return nil }
            hits.increment()
            return .init(statusCode: 200,
                         headers: nil,
                         body: Self.tokenJSON("refreshed-by-await"))
        }

        let result = await executor.refreshToken(accountId: nil)

        guard case .success = result else {
            return XCTFail("a 200 from the token endpoint must surface as .success, got \(result)")
        }
        XCTAssertEqual(hits.value, 1, "exactly one token request per awaited refresh")
        XCTAssertEqual(userAccount.authToken, "refreshed-by-await",
                       "the refreshed token must reach the account, not just the caller")
    }

    /// The failure arm. A rejected refresh must come back as `.failure` rather
    /// than hanging — an unresumed continuation here would wedge every awaiting
    /// caller, which on the audiobook path is the open itself.
    func testRefreshToken_whenTheTokenEndpointRejects_reportsFailureRatherThanHanging() async {
        HTTPStubURLProtocol.register { @Sendable [tokenURL] request in
            guard request.url == tokenURL else { return nil }
            return .init(statusCode: 401, headers: nil, body: Data("{}".utf8))
        }

        let result = await executor.refreshToken(accountId: nil)

        guard case .failure = result else {
            return XCTFail("a refused refresh must surface as .failure, got \(result)")
        }
    }

    // MARK: - The production conformers must send an authenticated request
    //
    // These drive `ProductionAudiobookManifestFetcher` and the executor's
    // `fetchLicense` rather than the protocols they satisfy. The adapter suites
    // mock those protocols, so nothing there can see how the real conformer
    // builds its request — which is how converting these two call sites to a
    // bare `URLRequest(url:)` passed a 9,755-test suite while dropping the
    // bearer token from every audiobook manifest fetch and LCP license
    // re-download. The repair path would have rescued most of those — the
    // retry is rebuilt through `request(for:)` — at the cost of a wasted trip,
    // a spurious token exchange and `markCredentialsStale()`, and it is
    // terminal for several auth shapes — enumerated once at
    // `ProductionAudiobookManifestFetcher.fetchData` rather than repeated here,
    // so the list cannot drift between the two. The header is the thing to
    // assert either way.

    func testProductionManifestFetcher_sendsTheBearerToken() async throws {
        let seen = HeaderRecorder()
        HTTPStubURLProtocol.register { @Sendable [apiURL] request in
            guard request.url == apiURL else { return nil }
            seen.record(request.value(forHTTPHeaderField: "Authorization"))
            return .init(statusCode: 200, headers: nil, body: Data("{}".utf8))
        }

        let fetcher = ProductionAudiobookManifestFetcher(executor: executor)
        _ = try await fetcher.fetchData(from: apiURL)

        XCTAssertEqual(seen.value, "Bearer fresh",
                       "the manifest fetch must carry the account's bearer token — a bare "
                       + "URLRequest(url:) reaches the CM unauthenticated, costing a 401 round trip "
                       + "and a spurious refresh at best")
    }

    func testExecutorFetchLicense_sendsTheBearerToken() async throws {
        let seen = HeaderRecorder()
        HTTPStubURLProtocol.register { @Sendable [apiURL] request in
            guard request.url == apiURL else { return nil }
            seen.record(request.value(forHTTPHeaderField: "Authorization"))
            return .init(statusCode: 200, headers: nil, body: Data("{}".utf8))
        }

        _ = try await executor.fetchLicense(from: apiURL)

        XCTAssertEqual(seen.value, "Bearer fresh",
                       "the LCP license re-download must carry the account's bearer token")
    }

    /// Carries a header value off URLSession's queue.
    private final class HeaderRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: String?
        func record(_ value: String?) { lock.lock(); storage = value; lock.unlock() }
        var value: String? { lock.lock(); defer { lock.unlock() }; return storage }
    }

    /// Thread-safe counter: the stub runs on URLSession's queue, so a plain
    /// captured `var` would be a data race rather than a convenience.
    private final class CallCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() { lock.lock(); count += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    private nonisolated static func makeTokenAuth(tokenURL: URL) -> AccountDetails.Authentication {
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

    private nonisolated static func tokenJSON(_ accessToken: String) -> Data {
        Data("""
        {"access_token":"\(accessToken)","token_type":"Bearer","expires_in":3600}
        """.utf8)
    }

    /// Leaves the injected account with nothing to refresh, so a 401 reaches
    /// the caller as is instead of starting a token refresh.
    private func signOutInjectedAccount() {
        userAccount._credentials = nil
    }

    private func setTokenExpiringIn(_ seconds: TimeInterval) {
        userAccount._credentials = .token(authToken: "near-expiry",
                                          barcode: "user-001",
                                          pin: "1234",
                                          expirationDate: Date().addingTimeInterval(seconds))
    }

    // MARK: - The guarantee

    /// URLSession completes on its own queue; the caller must continue on the
    /// main actor regardless. `completedOnMain` is the premise control — without
    /// it this would pass just as happily against a session that happened to
    /// call back on main.
    func testExecute_whenURLSessionCompletesOffMain_returnsToTheMainActorCaller() async {
        let completedOnMain = LockIsolated<Bool?>(nil)
        HTTPStubURLProtocol.register { @Sendable [apiURL] request in
            guard request.url == apiURL else { return nil }
            completedOnMain.value = Thread.isMainThread
            return .init(statusCode: 200, headers: nil, body: Data("body".utf8))
        }

        let result = await executor.execute(URLRequest(url: apiURL),
                                            enableTokenRefresh: false,
                                            accountId: nil)

        XCTAssertTrue(
            Thread.isMainThread,
            "await returned the caller off the main actor. Every main-actor "
            + "caller migrated to execute() would need its own hop again."
        )
        XCTAssertEqual(completedOnMain.value, false,
                       "the stub ran on main, so this test proves nothing")
        switch result {
        case let .success(data, _): XCTAssertEqual(data, Data("body".utf8))
        case let .failure(error, _): XCTFail("expected success, got \(error)")
        }
    }

    /// Sign-in reads problem documents off error responses, which is why
    /// `execute` returns `NYPLResult` instead of throwing: a thrown error would
    /// drop the response and the body with it.
    func testExecute_httpFailure_carriesTheResponseAndTheProblemDocument() async {
        signOutInjectedAccount()
        let problem = Data("""
        {"type":"http://librarysimplified.org/terms/problem/credentials-invalid","title":"Invalid credentials"}
        """.utf8)
        HTTPStubURLProtocol.register { @Sendable [apiURL] request in
            guard request.url == apiURL else { return nil }
            return .init(statusCode: 401, headers: nil, body: problem)
        }

        let result = await executor.execute(URLRequest(url: apiURL),
                                            enableTokenRefresh: false,
                                            accountId: nil)

        switch result {
        case .success:
            XCTFail("a 401 must not arrive as success")
        case let .failure(error, response):
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 401,
                           "the response must survive the await")
            XCTAssertEqual((error as NSError).problemDocument?.title,
                           "Invalid credentials",
                           "the problem document must survive too — sign-in "
                           + "shows its title rather than a generic failure")
        }
    }

    // MARK: - The preflight both entry points share

    /// The async path must take the same near-expiry branch the callback path
    /// takes: refresh first, then dispatch exactly once. Kills a deletion of
    /// the refresh arm and a follow-up that fires twice.
    func testExecute_nearExpiryToken_refreshesFirstThenDispatchesOnce() async {
        setTokenExpiringIn(60)
        let hits = LockIsolated<[String]>([])
        HTTPStubURLProtocol.register { @Sendable [tokenURL, apiURL] request in
            if request.url == tokenURL {
                hits.withValue { $0.append("token") }
                return .init(statusCode: 200, headers: nil, body: Self.tokenJSON("refreshed"))
            }
            if request.url == apiURL {
                hits.withValue { $0.append("api") }
                return .init(statusCode: 200, headers: nil, body: Data("ok".utf8))
            }
            return nil
        }

        _ = await executor.execute(URLRequest(url: apiURL),
                                   enableTokenRefresh: true,
                                   accountId: nil)

        let snapshot = hits.value
        XCTAssertEqual(snapshot.first, "token",
                       "the refresh must reach the network before the request it guards")
        XCTAssertEqual(snapshot.filter { $0 == "api" }.count, 1,
                       "the guarded request must be dispatched exactly once after the refresh")
    }

    /// `enableTokenRefresh: false` must skip the refresh even when the token is
    /// near expiry — the flag is the whole point of the first clause.
    func testExecute_nearExpiryToken_whenRefreshDisabled_doesNotRefresh() async {
        setTokenExpiringIn(60)
        let hits = LockIsolated<[String]>([])
        HTTPStubURLProtocol.register { @Sendable [tokenURL, apiURL] request in
            if request.url == tokenURL {
                hits.withValue { $0.append("token") }
                return .init(statusCode: 200, headers: nil, body: Self.tokenJSON("refreshed"))
            }
            if request.url == apiURL {
                hits.withValue { $0.append("api") }
                return .init(statusCode: 200, headers: nil, body: Data("ok".utf8))
            }
            return nil
        }

        _ = await executor.execute(URLRequest(url: apiURL),
                                   enableTokenRefresh: false,
                                   accountId: nil)

        XCTAssertEqual(hits.value, ["api"],
                       "a caller that opted out of refresh must reach the network directly")
    }

    /// Both entry points resolve the same decision from the same account state.
    /// This is the drift guard: a change to one path that skipped the refresh
    /// would show here as the two disagreeing.
    func testExecute_andExecuteRequest_agreeOnTheNearExpiryBranch() async {
        setTokenExpiringIn(60)
        let hits = LockIsolated<[String]>([])
        HTTPStubURLProtocol.register { @Sendable [tokenURL, apiURL] request in
            if request.url == tokenURL {
                hits.withValue { $0.append("token") }
                return .init(statusCode: 200, headers: nil, body: Self.tokenJSON("refreshed"))
            }
            if request.url == apiURL { return .init(statusCode: 200, headers: nil, body: Data()) }
            return nil
        }

        _ = await executor.execute(URLRequest(url: apiURL),
                                   enableTokenRefresh: true, accountId: nil)
        let afterAsync = hits.value.filter { $0 == "token" }.count

        setTokenExpiringIn(60)
        let viaCallback = expectation(description: "callback form completes")
        _ = executor.executeRequest(URLRequest(url: apiURL),
                                    enableTokenRefresh: true,
                                    accountId: nil) { _ in viaCallback.fulfill() }
        await fulfillment(of: [viaCallback], timeout: 5.0)   // STARVE-001-OK: HTTPStubURLProtocol answers from a registered stub with no network and no fire-and-forget task
        let afterCallback = hits.value.filter { $0 == "token" }.count - afterAsync

        XCTAssertEqual(afterAsync, 1, "the async form must refresh a near-expiry token")
        XCTAssertEqual(afterCallback, 1, "the callback form must refresh it too")
    }

    // MARK: - The request sent after a proactive refresh

    private struct SentRequest: Sendable {
        let method: String?
        let body: Data?
        let headers: [String: String]
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

    /// Answers the token endpoint with `token` and records every request that
    /// reaches the API URL.
    private func stubRefreshReturning(_ token: String) -> LockIsolated<[SentRequest]> {
        let sent = LockIsolated<[SentRequest]>([])
        HTTPStubURLProtocol.register { @Sendable [tokenURL, apiURL] request in
            if request.url == tokenURL {
                return .init(statusCode: 200, headers: nil, body: Self.tokenJSON(token))
            }
            guard request.url == apiURL else { return nil }
            sent.withValue {
                $0.append(SentRequest(method: request.httpMethod,
                                      body: Self.bodyBytes(of: request),
                                      headers: request.allHTTPHeaderFields ?? [:]))
            }
            return .init(statusCode: 200, headers: nil, body: Data("ok".utf8))
        }
        return sent
    }

    /// A POST as a caller builds it: the executor's request, carrying the
    /// bearer the refresh is about to replace, with a body and a caller header.
    private func callerPOST(accountId: String? = nil) -> URLRequest {
        var request = executor.request(for: apiURL, accountId: accountId)
        request.httpMethod = "POST"
        request.httpBody = Data("position".utf8)
        request.setValue("k-7", forHTTPHeaderField: "X-Idempotency-Key")
        return request
    }

    private func assertSentOnceWithBearer(_ sent: [SentRequest], _ bearer: String,
                                          file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(sent.count, 1, "the guarded request must be sent exactly once", file: file, line: line)
        guard let request = sent.first else { return }
        XCTAssertEqual(request.headers["Authorization"], bearer,
                       "the request must carry the token the refresh obtained, not the one it replaced",
                       file: file, line: line)
        XCTAssertEqual(request.method, "POST", file: file, line: line)
        XCTAssertEqual(request.body, Data("position".utf8), file: file, line: line)
        XCTAssertEqual(request.headers["X-Idempotency-Key"], "k-7", file: file, line: line)
    }

    /// The async form refreshes first; the request it then sends must carry
    /// the new token. Sending the old one costs a 401 and a second refresh.
    func testExecute_nearExpiryToken_sendsTheRefreshedBearer() async {
        setTokenExpiringIn(60)
        let sent = stubRefreshReturning("refreshed")

        _ = await executor.execute(callerPOST(), enableTokenRefresh: true, accountId: nil)

        assertSentOnceWithBearer(sent.value, "Bearer refreshed")
    }

    /// Same property on the callback form, which `GET`/`PUT`/`POST` use.
    func testExecuteRequest_nearExpiryToken_sendsTheRefreshedBearer() async {
        setTokenExpiringIn(60)
        let sent = stubRefreshReturning("refreshed")

        let done = expectation(description: "callback form completes")
        _ = executor.executeRequest(callerPOST(), enableTokenRefresh: true,
                                    accountId: nil) { @Sendable _ in done.fulfill() }
        await fulfillment(of: [done], timeout: 5.0)   // STARVE-001-OK: HTTPStubURLProtocol answers from a registered stub with no network and no fire-and-forget task

        assertSentOnceWithBearer(sent.value, "Bearer refreshed")
    }

    /// A request for a library other than the selected one is refreshed and
    /// re-authorized for that library; the selected library's token must not
    /// reach the request (PP-4986).
    func testExecute_nearExpiryTokenOnANamedLibrary_sendsThatLibrarysRefreshedBearer() async {
        let otherLibraryId = "urn:uuid:other-library"
        let otherLibrary = TPPUserAccountMock()
        otherLibrary._authDefinition = Self.makeTokenAuth(tokenURL: tokenURL)
        otherLibrary._credentials = .token(authToken: "other-near-expiry",
                                           barcode: "user-002",
                                           pin: "5678",
                                           expirationDate: Date().addingTimeInterval(60))
        otherLibrary.markLoggedIn()
        let selected: TPPUserAccountMock = userAccount
        libraryAccount.userAccountResolver = { @Sendable id in id == otherLibraryId ? otherLibrary : selected }
        let sent = stubRefreshReturning("other-refreshed")

        _ = await executor.execute(callerPOST(accountId: otherLibraryId),
                                   enableTokenRefresh: true, accountId: otherLibraryId)

        assertSentOnceWithBearer(sent.value, "Bearer other-refreshed")
        XCTAssertEqual(otherLibrary.authToken, "other-refreshed", "the refresh writes the named library")
        XCTAssertNil(userAccount.authToken, "the refresh must not write the selected library")
    }

    /// A request the caller sent without a bearer is not given one by the
    /// refresh: only a bearer the caller chose to send is replaced.
    func testExecute_nearExpiryToken_requestWithoutABearer_isSentWithoutOne() async {
        setTokenExpiringIn(60)
        let sent = stubRefreshReturning("refreshed")

        _ = await executor.execute(URLRequest(url: apiURL), enableTokenRefresh: true, accountId: nil)

        XCTAssertEqual(sent.value.count, 1)
        XCTAssertNil(sent.value.first?.headers["Authorization"],
                     "an unauthenticated request must stay unauthenticated after the refresh")
    }
}
