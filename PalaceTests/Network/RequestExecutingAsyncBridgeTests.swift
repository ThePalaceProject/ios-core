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

    private let tokenURL = URL(string: "https://token.example.com/oauth/token")!
    private let apiURL = URL(string: "https://api.example.com/protected")!

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
        case let .failure(_, response):
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 401,
                           "the response must survive the await — sign-in reads "
                           + "the problem document off it")
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
}
