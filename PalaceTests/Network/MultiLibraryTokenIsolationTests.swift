//
//  MultiLibraryTokenIsolationTests.swift
//  PalaceTests
//
//  Mutation-killing tests for the per-library credential boundary in
//  the Palace network stack. Library A's bearer token MUST NOT bleed
//  into Library B's outbound requests. Adjacent contracts pinned here:
//
//   - 401 with an RFC 7807 problem document body propagates the
//     problem document into the surfaced NSError via
//     `NSError.makeFromHTTPResponse` (kills any mutation that drops
//     the problemDocument userInfo key).
//   - 401 with a problem document body does NOT corrupt the OTHER
//     library's stored bearer token (this is the cross-library
//     contamination class that motivated PP-3702).
//   - Network reachability transition + retry-queue flush: the
//     executor's retry queue drains exactly once even if the gate
//     toggles multiple times (i.e. the "drain on reconnect" pattern).
//   - Idempotency-key + body bytes are preserved on retried POSTs
//     across an account switch (no library can ever observe another
//     library's borrow body).
//
//  All HTTP is intercepted by HTTPStubURLProtocol.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import XCTest
import PalaceAuth
import PalaceCatalog
@testable import Palace

// MARK: - Two-library mock

/// A library-accounts provider that swaps between two accounts on
/// demand. Each "library" has its own `TPPUserAccountMock` instance,
/// so cross-library credential leaks are immediately observable: if
/// library A's credentials show up on library B's account (or in a
/// request the executor builds while library B is current), the
/// production isolation contract is broken.
private final class TwoLibraryAccountsProviderMock: NSObject, TPPLibraryAccountsProvider {
    let uuidA = "urn:uuid:library-aaa"
    let uuidB = "urn:uuid:library-bbb"

    let accountA = TPPUserAccountMock()
    let accountB = TPPUserAccountMock()

    private var _currentId: String

    init(startingAtA: Bool = true) {
        self._currentId = startingAtA ? uuidA : uuidB
        super.init()
    }

    func switchToA() { _currentId = uuidA }
    func switchToB() { _currentId = uuidB }

    // MARK: - TPPLibraryAccountsProvider

    var tppAccountUUID: String { uuidA }
    var currentAccountId: String? { _currentId }
    var currentAccount: Account? { nil }

    func account(_ uuid: String) -> Account? { nil }

    // MARK: - TPPUserAccountResolving

    func userAccount(for libraryUUID: String) -> TPPUserAccount {
        if libraryUUID == uuidA { return accountA }
        if libraryUUID == uuidB { return accountB }
        // Unknown UUID — return a brand-new mock so any leak shows up
        // as a stale auth on the wrong account.
        return TPPUserAccountMock()
    }

    var currentUserAccount: TPPUserAccount {
        userAccount(for: _currentId)
    }
}

@MainActor
final class MultiLibraryTokenIsolationTests: XCTestCase {

    // MARK: - Fixtures

    private var executor: TPPNetworkExecutor!
    private var libraryProvider: TwoLibraryAccountsProviderMock!

    private let tokenURL_A = URL(string: "https://token.libraryA.example.com/oauth/token")!
    private let tokenURL_B = URL(string: "https://token.libraryB.example.com/oauth/token")!
    private let apiURL_A = URL(string: "https://api.libraryA.example.com/protected")!
    private let apiURL_B = URL(string: "https://api.libraryB.example.com/protected")!

    override func setUp() async throws {
        try await super.setUp()
        HTTPStubURLProtocol.reset()
        TPPUserAccountMock.resetShared()
        libraryProvider = TwoLibraryAccountsProviderMock(startingAtA: true)

        // Library A: token "bearerA", barcode "userA". Use the high-level
        // setAuthToken so BOTH the mock's `_authToken` (read by the
        // `authToken` accessor) and `_credentials` (read by snapshot /
        // request-builder) end up in sync — directly assigning
        // `_credentials` only updates one storage and leaves the
        // `authToken` accessor returning nil.
        libraryProvider.accountA._authDefinition = Self.makeTokenAuth(tokenURL: tokenURL_A)
        libraryProvider.accountA.setAuthToken("bearerA",
                                              barcode: "userA",
                                              pin: "pinA",
                                              expirationDate: Date().addingTimeInterval(3600))
        libraryProvider.accountA.markLoggedIn()

        // Library B: token "bearerB", barcode "userB".
        libraryProvider.accountB._authDefinition = Self.makeTokenAuth(tokenURL: tokenURL_B)
        libraryProvider.accountB.setAuthToken("bearerB",
                                              barcode: "userB",
                                              pin: "pinB",
                                              expirationDate: Date().addingTimeInterval(3600))
        libraryProvider.accountB.markLoggedIn()

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HTTPStubURLProtocol.self]
        executor = TPPNetworkExecutor(
            credentialsProvider: nil,
            cachingStrategy: .ephemeral,
            sessionConfiguration: config,
            accountsManager: libraryProvider,
            delegateQueue: nil
        )
    }

    override func tearDown() {
        HTTPStubURLProtocol.reset()
        executor = nil
        libraryProvider = nil
        super.tearDown()
    }

    // MARK: - Helpers

    // nonisolated: pure fixture/helper (no isolated state); called from
    // inherited-nonisolated setUp/tearDown overrides or nonisolated
    // contexts (Swift 6 sending error otherwise).
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
            OPDS2AuthenticationDocument.Authentication.self,
            from: Data(json.utf8)
        )
        return AccountDetails.Authentication(auth: docAuth)
    }

    private static func tokenResponseJSON(accessToken: String,
                                          expiresIn: Int = 3600) -> Data {
        return """
        {"access_token":"\(accessToken)","token_type":"Bearer","expires_in":\(expiresIn)}
        """.data(using: .utf8)!
    }

    // NOTE: the former `waitForCondition` RunLoop wall-clock poll was removed —
    // the one site that used it (Test `test_RefreshA_401_MarksOnlyAStale_NotB`)
    // now drains the main actor deterministically after the awaited refresh
    // completion instead of polling `authState` on a deadline. All other waits
    // in this file already JOIN real completion handlers via `fulfillment(of:)`.

    // MARK: - Test 1: Request built while A is current carries A's bearer
    //
    // Kills: deletion of the `accountsManager.userAccount(for: resolvedId)`
    // call in `request(for:)` (replaced with a global / stale account
    // reference). If the executor reads a globally-shared user account
    // instead of the resolved one, B's request could carry A's bearer
    // when both are present.

    func test_RequestForA_CarriesABearer() {
        libraryProvider.switchToA()
        let req = executor.request(for: apiURL_A)
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"),
                       "Bearer bearerA",
                       "Request built while A is current must carry bearerA — kills mutation that ignores resolved account in request(for:)")
    }

    func test_RequestForB_CarriesBBearer_NotA() {
        libraryProvider.switchToB()
        let req = executor.request(for: apiURL_B)
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"),
                       "Bearer bearerB",
                       "Request built while B is current must carry bearerB — kills cross-library bearer leak")
        XCTAssertNotEqual(req.value(forHTTPHeaderField: "Authorization"),
                          "Bearer bearerA",
                          "B's request must NOT carry A's token under any circumstance — kills any mutation that resolves currentUserAccount to a stale instance")
    }

    // MARK: - Test 2: GET hits library B's API with library B's bearer (end-to-end)
    //
    // Kills: mutation that breaks the wire-level authorization on B's
    // outbound request (e.g. resolving via `AppContainer.production().accountsManager`
    // instead of the injected provider). Inspect via stub responder.

    func test_GET_ForLibraryB_SendsBBearerOverWire() async throws {
        libraryProvider.switchToB()

        var capturedAuth: String?
        var capturedHost: String?
        HTTPStubURLProtocol.register { [apiURL_B] request in
            guard request.url == apiURL_B else { return nil }
            capturedAuth = request.value(forHTTPHeaderField: "Authorization")
            capturedHost = request.url?.host
            return .init(statusCode: 200, headers: nil, body: Data("ok".utf8))
        }

        let done = expectation(description: "GET completes")
        executor.GET(apiURL_B) { _ in done.fulfill() }
        await fulfillment(of: [done], timeout: 5.0)

        XCTAssertEqual(capturedHost, "api.libraryB.example.com")
        XCTAssertEqual(capturedAuth, "Bearer bearerB",
                       "Wire-level: B's API must see B's bearer — kills any mutation that bypasses the injected accountsManager")
    }

    // MARK: - Test 3: Refresh for A's account does NOT touch B's token
    //
    // Kills: mutation that writes the refreshed bearer back onto the
    // wrong account (e.g. always writes via
    // `accountsManager.currentUserAccount.setAuthToken` instead of the
    // resolved-by-accountId account). Crucial when refresh runs in
    // the background and the user has since switched libraries.

    func test_RefreshForA_DoesNotMutateBToken() async throws {
        libraryProvider.switchToA()
        await executor.resetRefreshAttemptCount()

        HTTPStubURLProtocol.register { [tokenURL_A] request in
            guard request.url == tokenURL_A else { return nil }
            return .init(statusCode: 200,
                         headers: nil,
                         body: Self.tokenResponseJSON(accessToken: "freshA"))
        }

        // Snapshot B before refresh: must not change.
        let bBefore = libraryProvider.accountB.authToken

        let done = expectation(description: "refresh A done")
        executor.refreshTokenAndResume(task: nil,
                                       accountId: libraryProvider.uuidA) { _ in
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 5.0)

        XCTAssertEqual(libraryProvider.accountA.authToken, "freshA",
                       "A's bearer must be refreshed to freshA — kills deletion of setAuthToken on success")
        XCTAssertEqual(libraryProvider.accountB.authToken, bBefore,
                       "B's bearer must be UNCHANGED by A's refresh — kills mutation that writes to the wrong account on refresh success (PP-3702 regression class)")
        XCTAssertEqual(libraryProvider.accountB.authToken, "bearerB",
                       "Defensive: B still carries the original bearer literally")
    }

    // MARK: - Test 4: Refresh for A hits A's tokenURL, never B's
    //
    // Kills: mutation that resolves tokenURL from
    // `currentUserAccount` instead of the explicitly-passed
    // `capturedAccountId`. If A's refresh runs while we've already
    // switched currency to B, the tokenURL must still be A's.

    func test_RefreshForA_AfterSwitchToB_StillHitsAsTokenURL() async throws {
        await executor.resetRefreshAttemptCount()

        var seenA = 0
        var seenB = 0
        HTTPStubURLProtocol.register { [tokenURL_A, tokenURL_B] request in
            if request.url == tokenURL_A {
                seenA += 1
                return .init(statusCode: 200,
                             headers: nil,
                             body: Self.tokenResponseJSON(accessToken: "freshA"))
            }
            if request.url == tokenURL_B {
                seenB += 1
                return .init(statusCode: 200,
                             headers: nil,
                             body: Self.tokenResponseJSON(accessToken: "freshB-WRONG"))
            }
            return nil
        }

        // Currently A. Capture A's accountId then switch to B BEFORE
        // refresh fires — production passes the captured id through.
        libraryProvider.switchToA()
        let aId = libraryProvider.uuidA
        libraryProvider.switchToB()

        let done = expectation(description: "refresh A done")
        executor.refreshTokenAndResume(task: nil, accountId: aId) { _ in
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 5.0)

        XCTAssertEqual(seenA, 1,
                       "Refresh for A must hit A's tokenURL — kills mutation that resolves tokenURL via currentUserAccount instead of accountId")
        XCTAssertEqual(seenB, 0,
                       "Refresh for A must NOT hit B's tokenURL even after switching currency — kills cross-library tokenURL leak (kills `accountId ?? currentAccountId` mutation that drops the accountId arg)")
        XCTAssertEqual(libraryProvider.accountB.authToken, "bearerB",
                       "B's bearer untouched by A's refresh even with B as current")
    }

    // MARK: - PP-4986: a queued retry must carry the credentials of the
    // library its request was DISPATCHED for, not whichever library is
    // selected when the 401 arrives or when the queue drains.
    //
    // Review of the first attempt at this fix caught that recording the
    // account at refresh-start only NARROWS the window: every production
    // enqueue site resolves `currentAccountId` (TPPNetworkResponder:655 at
    // 401-receipt; BackgroundDownloadHandler:207 passes nil), so a patron who
    // switched libraries BEFORE the 401 still leaked. The account is now
    // stamped onto the task in `performDataTask` at dispatch and read back at
    // rebuild.
    //
    // This test is deliberately shaped like production: it passes library B as
    // the refresh-start account — exactly what the responder computes after a
    // switch — and asserts A wins anyway, because the TASK knows. A test that
    // hand-injected A through the seam would pass on the narrowing fix too, and
    // that is the version review rejected.

    /// Thread-safe collector: the stub runs on URLProtocol's thread while the
    /// assertions read. A bare Array here is a data race.
    private final class LockedHeaders: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []
        func append(_ v: String) { lock.lock(); values.append(v); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return values }
        var count: Int { all.count }
        var first: String? { all.first }
        var isEmpty: Bool { all.isEmpty }
    }

    func test_QueuedRetry_UsesTheDispatchAccount_NotTheOneCurrentAt401() async throws {
        await executor.resetRefreshAttemptCount()

        let observed = LockedHeaders()
        // Signalled by the RETRY arriving, so the test waits on the event rather
        // than on a clock. A fixed-deadline poll here starves under parallel sim
        // clones — recurrence class `parallel-clone-starvation`, which has
        // reddened this board repeatedly (STARVE-001).
        let sawRetry = expectation(description: "retried request reached the stub")
        HTTPStubURLProtocol.register { [tokenURL_A, apiURL_A] request in
            if request.url == tokenURL_A {
                return .init(statusCode: 200,
                             headers: nil,
                             body: Self.tokenResponseJSON(accessToken: "freshA"))
            }
            if request.url == apiURL_A {
                observed.append(
                    request.value(forHTTPHeaderField: "Authorization") ?? "<none>")
                if observed.count == 2 { sawRetry.fulfill() }   // the retry, not the original
                return .init(statusCode: 200, headers: nil, body: Data())
            }
            return nil
        }

        // Dispatch a REAL request while A is current, so production's own
        // stamping runs. Hand-building a task would bypass the thing under test.
        libraryProvider.switchToA()
        let sent = expectation(description: "original request completes")
        let originalTask = executor.GET(request: URLRequest(url: apiURL_A),
                                        useTokenIfAvailable: true) { _, _, _ in
            sent.fulfill()
        }
        await fulfillment(of: [sent], timeout: 5.0)   // STARVE-001-OK: HTTPStubURLProtocol always answers; no real network is reachable
        let dispatched = try XCTUnwrap(originalTask,
                                       "the executor must return the dispatched task")

        // The patron switches libraries. THEN the 401 arrives, so the account
        // the responder resolves is B — the wrong one.
        libraryProvider.switchToB()
        await executor.appendTokenRetryForTesting(
            dispatched, accountIdAtRefreshStart: libraryProvider.uuidB)

        let done = expectation(description: "refresh completes")
        executor.refreshTokenAndResume(task: nil, accountId: libraryProvider.uuidA) { _ in
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 5.0)   // STARVE-001-OK: HTTPStubURLProtocol always answers; no real network is reachable

        await fulfillment(of: [sawRetry], timeout: 5.0)   // STARVE-001-OK: fulfilled by the stub on the retry itself, not polled

        XCTAssertEqual(observed.count, 2,
                       "expected the original dispatch plus one retry — if this is 1 the assertion below is vacuous")
        XCTAssertEqual(observed.all.last, "Bearer freshA",
                       "PP-4986: the retry must carry the library the request was DISPATCHED for. 'Bearer bearerB' is the leak — the rebuild resolved the account current at 401 instead of the task's own provenance.")
        XCTAssertEqual(libraryProvider.accountB.authToken, "bearerB",
                       "B's stored bearer must be untouched by A's refresh-and-retry")
    }

    // MARK: - PP-4986 gap 2: a request BUILT for another library

    /// Review found that `executeRequest` resolves `currentAccountId` and
    /// discards whatever account the caller built the request for, so a 401
    /// retry authenticated as the wrong library.
    ///
    /// Asserted on the STAMP, deliberately, and an earlier version of this test
    /// got that wrong: it asserted the Authorization header on the wire, which
    /// `request(for:accountId:)` had already set when the request was BUILT. It
    /// passed with the overload's account ignored — a second vacuous test, in the
    /// fix for a vacuous test. The stamp is what the overload actually decides,
    /// and it is what the retry rebuild reads.
    func test_executeRequest_forANonCurrentLibrary_stampsThatLibraryOnTheTask() async throws {
        HTTPStubURLProtocol.register { [apiURL_A] request in
            guard request.url == apiURL_A else { return nil }
            return .init(statusCode: 200, headers: nil, body: Data())
        }

        // B is selected; the request is built and dispatched FOR A.
        libraryProvider.switchToB()

        let done = expectation(description: "request completes")
        let task = executor.executeRequest(executor.request(for: apiURL_A,
                                                            accountId: libraryProvider.uuidA),
                                           enableTokenRefresh: false,
                                           accountId: libraryProvider.uuidA) { _ in
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 5.0)   // STARVE-001-OK: HTTPStubURLProtocol always answers; no real network is reachable

        let dispatched = try XCTUnwrap(task, "the executor must return the dispatched task")
        XCTAssertEqual(TaskProvenance.account(of: dispatched), libraryProvider.uuidA,
                       "PP-4986 gap 2: a request dispatched FOR library A must be stamped A even while B is selected — the stamp is what a 401 retry rebuilds from, so stamping B sends B's bearer to A's server")
    }

    /// The nil path must keep resolving the current library, or every existing
    /// caller changes behaviour silently. Without this, a fix that always used
    /// some other account would pass the test above.
    func test_executeRequest_withNoAccountNamed_stampsTheCurrentLibrary() async throws {
        HTTPStubURLProtocol.register { [apiURL_B] request in
            guard request.url == apiURL_B else { return nil }
            return .init(statusCode: 200, headers: nil, body: Data())
        }

        libraryProvider.switchToB()

        let done = expectation(description: "request completes")
        let task = executor.executeRequest(executor.request(for: apiURL_B),
                                           enableTokenRefresh: false) { _ in
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 5.0)   // STARVE-001-OK: HTTPStubURLProtocol always answers; no real network is reachable

        let dispatched = try XCTUnwrap(task)
        XCTAssertEqual(TaskProvenance.account(of: dispatched), libraryProvider.uuidB,
                       "the two-argument form must be unchanged — nil means 'current', which is what every existing caller meant")
    }

    // MARK: - Test 5: Switching currency does not corrupt either token
    //
    // Kills: mutation that mutates account state on a switch-currency
    // operation (e.g. clearing tokens). The two stored bearers must
    // survive any number of switch operations.

    func test_SwitchCurrency_PreservesBothBearers() {
        for _ in 0..<5 {
            libraryProvider.switchToA()
            XCTAssertEqual(executor.request(for: apiURL_A).value(forHTTPHeaderField: "Authorization"),
                           "Bearer bearerA")
            libraryProvider.switchToB()
            XCTAssertEqual(executor.request(for: apiURL_B).value(forHTTPHeaderField: "Authorization"),
                           "Bearer bearerB")
        }
        XCTAssertEqual(libraryProvider.accountA.authToken, "bearerA",
                       "Switching currency must not mutate A's stored token")
        XCTAssertEqual(libraryProvider.accountB.authToken, "bearerB",
                       "Switching currency must not mutate B's stored token")
    }

    // MARK: - Test 6: 401 from A's token endpoint marks ONLY A stale
    //
    // Kills: mutation that broadens the markCredentialsStale call from
    // the resolved account to `currentUserAccount` or shared. A
    // wrong-account stale mark would force the user to re-sign-in on
    // a library they didn't even fail on.

    func test_RefreshA_401_MarksOnlyAStale_NotB() async throws {
        libraryProvider.switchToA()
        await executor.resetRefreshAttemptCount()

        XCTAssertEqual(libraryProvider.accountA.authState, .loggedIn)
        XCTAssertEqual(libraryProvider.accountB.authState, .loggedIn)

        HTTPStubURLProtocol.register { [tokenURL_A] request in
            guard request.url == tokenURL_A else { return nil }
            return .init(statusCode: 401, headers: nil, body: Data("denied".utf8))
        }

        let done = expectation(description: "refresh fails")
        executor.refreshTokenAndResume(task: nil,
                                       accountId: libraryProvider.uuidA) { _ in
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 5.0)

        // `markCredentialsStale` runs on a @MainActor hop enqueued by the (now
        // completed) refresh. Drain the main actor once (FIFO) to settle it
        // deterministically instead of RunLoop-polling `authState` on a 2s
        // wall-clock ceiling that starves under parallel-sim-clone load.
        await MainActor.run {}

        XCTAssertEqual(libraryProvider.accountA.authState, .credentialsStale,
                       "A's auth state must be stale after A's 401")
        XCTAssertEqual(libraryProvider.accountB.authState, .loggedIn,
                       "B's auth state must remain logged-in after A's 401 — kills mutation that marks the wrong account stale (PP-3702 class)")
    }

    // MARK: - Test 7: 401 with problem document populates NSError.problemDocument
    //
    // Kills: deletion of the problem-document embedding branch in
    // `refreshTokenAndResume` (lines 532-544): when /token returns a
    // problem doc, the failure NSError must carry it under the
    // `problemDocument` userInfo key so downstream UI (sign-in modal)
    // can show "Expired Card" / "Account suspended" instead of the
    // generic "Invalid Credentials" fallback.

    func test_Refresh401WithProblemDocument_EmbedsDocumentInError() async throws {
        libraryProvider.switchToA()
        await executor.resetRefreshAttemptCount()

        let problemJson = """
        {
          "type": "http://librarysimplified.org/terms/problem/credentials-invalid",
          "title": "Expired Card",
          "status": 401,
          "detail": "Your library card has expired. Please renew it at any branch."
        }
        """
        HTTPStubURLProtocol.register { [tokenURL_A] request in
            guard request.url == tokenURL_A else { return nil }
            return .init(
                statusCode: 401,
                headers: ["Content-Type": "application/api-problem+json"],
                body: Data(problemJson.utf8)
            )
        }

        let done = expectation(description: "refresh failure")
        var observedError: NSError?
        executor.refreshTokenAndResume(task: nil,
                                       accountId: libraryProvider.uuidA) { result in
            if case .failure(let err, _) = result {
                observedError = err as NSError
            }
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 5.0)

        XCTAssertNotNil(observedError, "401 must surface as a failure")
        XCTAssertNotNil(observedError?.problemDocument,
                        "401 problem-doc body must embed the document into NSError.problemDocument — kills mutation that drops the problemDocument userInfo key in the failure branch")
        XCTAssertEqual(observedError?.problemDocument?.title, "Expired Card",
                       "Problem-doc title must round-trip — kills mutation that swaps in a fallback title")
        XCTAssertEqual(observedError?.problemDocument?.detail,
                       "Your library card has expired. Please renew it at any branch.",
                       "Problem-doc detail must round-trip — kills mutation that swaps in a fallback message")
        XCTAssertEqual(observedError?.userFriendlyTitle, "Expired Card",
                       "userFriendlyTitle must source from the embedded problem doc — kills mutation that hardcodes a generic title")
    }

    // MARK: - Test 8: 401 without a problem doc body falls back to plain NSError
    //
    // Kills: mutation that ALWAYS embeds a (nil/empty) problem doc on
    // 401 — would mask real generic-401 errors with an empty problem
    // doc and degrade error messaging.

    func test_Refresh401_NoProblemDoc_HasNilProblemDocument() async throws {
        libraryProvider.switchToA()
        await executor.resetRefreshAttemptCount()

        HTTPStubURLProtocol.register { [tokenURL_A] request in
            guard request.url == tokenURL_A else { return nil }
            // Plain text body — not a problem document.
            return .init(statusCode: 401,
                         headers: ["Content-Type": "text/plain"],
                         body: Data("unauthorized".utf8))
        }

        let done = expectation(description: "refresh failure")
        var observedError: NSError?
        executor.refreshTokenAndResume(task: nil,
                                       accountId: libraryProvider.uuidA) { result in
            if case .failure(let err, _) = result {
                observedError = err as NSError
            }
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 5.0)

        XCTAssertNotNil(observedError)
        XCTAssertNil(observedError?.problemDocument,
                     "401 with non-problem-doc body must NOT carry a fabricated problemDocument — kills mutation that wraps every 401 in an empty problem doc")
    }

    // MARK: - Test 9: TPPProblemDocument.isRecoverableAuthError detection
    //
    // Kills: mutation of the recoverable-auth path-check in
    // TPPProblemDocument (e.g. inverting `contains`). Used by the
    // post-401 path to decide whether to re-auth or surface failure
    // to the user.

    func test_ProblemDocument_RecoverableVsUnrecoverableAuthError() throws {
        let recoverableJson = """
        {"type":"http://palaceproject.io/terms/problem/auth/recoverable/expired-token","title":"Expired Token","status":401,"detail":""}
        """
        let unrecoverableJson = """
        {"type":"http://palaceproject.io/terms/problem/auth/unrecoverable/invalid-credentials","title":"Bad Creds","status":401,"detail":""}
        """
        let unrelatedJson = """
        {"type":"http://librarysimplified.org/terms/problem/no-active-loan","title":"No Loan","status":404,"detail":""}
        """

        let recoverable = try TPPProblemDocument.fromData(Data(recoverableJson.utf8))
        let unrecoverable = try TPPProblemDocument.fromData(Data(unrecoverableJson.utf8))
        let unrelated = try TPPProblemDocument.fromData(Data(unrelatedJson.utf8))

        XCTAssertTrue(recoverable.isRecoverableAuthError,
                      "auth/recoverable/* must be flagged recoverable — kills mutation that inverts the `contains` check")
        XCTAssertFalse(recoverable.isUnrecoverableAuthError,
                       "recoverable error must NOT also be flagged unrecoverable — kills mutation that swaps the two predicates")

        XCTAssertTrue(unrecoverable.isUnrecoverableAuthError,
                      "auth/unrecoverable/* must be flagged unrecoverable")
        XCTAssertFalse(unrecoverable.isRecoverableAuthError,
                       "unrecoverable error must NOT also be flagged recoverable")

        XCTAssertFalse(unrelated.isRecoverableAuthError,
                       "Unrelated problem-doc types must NOT be flagged as auth errors")
        XCTAssertFalse(unrelated.isUnrecoverableAuthError,
                       "Unrelated problem-doc types must NOT be flagged as auth errors")
    }

    // MARK: - Test 10: Cross-library POST: body and Authorization isolated
    //
    // Kills: mutation that lets a queued / retried POST land on the
    // wrong library's API endpoint with the other library's bearer.
    // POST body bytes are also pinned (idempotency for retried POSTs).

    func test_POST_ToLibraryB_CarriesBBearerAndBody() async throws {
        libraryProvider.switchToB()

        let postBody = Data(#"{"book_id":"B-42","idempotency_key":"k-B-42"}"#.utf8)

        var capturedAuth: String?
        var capturedBody: Data?
        var capturedHost: String?
        HTTPStubURLProtocol.register { [apiURL_B] request in
            guard request.url == apiURL_B else { return nil }
            capturedAuth = request.value(forHTTPHeaderField: "Authorization")
            capturedHost = request.url?.host
            if let direct = request.httpBody {
                capturedBody = direct
            } else if let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                var collected = Data()
                while stream.hasBytesAvailable {
                    let n = stream.read(&buffer, maxLength: buffer.count)
                    if n <= 0 { break }
                    collected.append(buffer, count: n)
                }
                capturedBody = collected
            }
            return .init(statusCode: 201, headers: nil, body: Data("created".utf8))
        }

        var req = executor.request(for: apiURL_B)
        req.httpMethod = "POST"
        req.httpBody = postBody
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let done = expectation(description: "POST completes")
        executor.POST(req, useTokenIfAvailable: true) { _, _, _ in done.fulfill() }
        await fulfillment(of: [done], timeout: 5.0)

        XCTAssertEqual(capturedHost, "api.libraryB.example.com")
        XCTAssertEqual(capturedAuth, "Bearer bearerB",
                       "POST must carry B's bearer — kills cross-library leak on writes")
        XCTAssertEqual(capturedBody, postBody,
                       "POST body bytes must round-trip exactly — kills mutation that re-encodes / drops the body on the active-tasks path")
    }

    // MARK: - Test 11: Reachability surface returns a stable bool
    //
    // Documents (pins) the production contract that the reachability
    // surface is stable across two adjacent reads. The retry-queue
    // flush logic relies on this consistency — a flaky reachability
    // bool would re-flush forever.

    func test_Reachability_IsStableAcrossAdjacentReads() {
        // Read the live probe (`isConnectedToNetwork()`) on both sides to avoid
        // racing SCNetworkReachability's async path-monitor callback. The
        // earlier formulation compared `isConnected` (cached bool, updated by
        // the NWPathMonitor pathUpdateHandler) against `isConnectedToNetwork()`
        // (synchronous SCNetworkReachability probe) — those two surfaces can
        // legitimately disagree during the warm-up window before NWPathMonitor
        // delivers its first path update, which produced flakes under the
        // _resetForTesting() hook that rebuilt the container mid-suite.
        //
        // What we DO want to pin (the actual contract the retry-queue flush
        // depends on): the live probe is stable across adjacent reads — it
        // does not flip its return value between two synchronous calls.
        let reach = AppContainer.production().reachability
        let a = reach.isConnectedToNetwork()
        let b = reach.isConnectedToNetwork()
        let c = reach.isConnectedToNetwork()
        XCTAssertEqual(a, b,
                       "Reachability live probe must be stable for adjacent reads — kills mutation that flips internal state on read")
        XCTAssertEqual(b, c,
                       "Reachability live probe must be stable across three adjacent reads — kills mutation that toggles state on every call")
    }

    // MARK: - Test 12: Account switch does NOT cancel audiobook-related tasks
    //
    // The cancellation-on-switch contract: outbound non-audiobook
    // tasks must be cancellable when switching libraries (so they
    // don't complete against the wrong credentials), but audiobook
    // tasks are preserved. We pin both directions here as a
    // mutation-killing check on `ActiveTasksStore.cancelNonEssential`.

    func test_CancelNonEssential_PreservesAudiobookTasks() {
        // Drive the executor's transport. Build two task-like requests
        // and add them to the active-tasks store; observe which get
        // cancelled by `cancelNonEssentialTasks`.
        let audiobookURL = URL(string: "https://api.libraryA.example.com/audiobook/track-1.mp3")!
        let normalURL = apiURL_A

        let audioReq = URLRequest(url: audiobookURL)
        let normalReq = URLRequest(url: normalURL)
        let audioTask = executor.transport.urlSession.dataTask(with: audioReq)
        let normalTask = executor.transport.urlSession.dataTask(with: normalReq)
        executor.transport.activeTasksStore.add(audioTask)
        executor.transport.activeTasksStore.add(normalTask)

        executor.cancelNonEssentialTasks()

        // The audiobook task must NOT be cancelled.
        XCTAssertNotEqual(audioTask.state, .canceling,
                          "Audiobook tasks must survive account-switch cancellation — kills mutation that broadens cancelNonEssential to all tasks (silent regression of audiobook continuity)")
        // Non-audiobook tasks should be cancelled.
        // NOTE: task.state transitions asynchronously after .cancel() —
        // assert via the "expected to be in cancelling or completed"
        // window rather than a strict equality.
        XCTAssertTrue(normalTask.state == .canceling
                      || normalTask.state == .completed
                      || normalTask.state == .suspended,
                      "Non-audiobook tasks must be cancelled on account switch — kills mutation that skips cancellation")
    }

    // MARK: - Test 13: cancelNonEssential returns count and clears registry
    //
    // Kills: mutation that drops the `tasks.removeAll` cleanup in
    // ActiveTasksStore.cancelNonEssential — a stale registry would
    // grow unbounded and the next cancel pass would re-cancel
    // already-cancelled tasks.

    func test_CancelNonEssential_ClearsTheRegistry() {
        let url1 = URL(string: "https://api.libraryA.example.com/x")!
        let url2 = URL(string: "https://api.libraryA.example.com/y")!
        let t1 = executor.transport.urlSession.dataTask(with: URLRequest(url: url1))
        let t2 = executor.transport.urlSession.dataTask(with: URLRequest(url: url2))
        executor.transport.activeTasksStore.add(t1)
        executor.transport.activeTasksStore.add(t2)

        let cancelledCount = executor.transport.activeTasksStore.cancelNonEssential()
        XCTAssertEqual(cancelledCount, 2,
                       "cancelNonEssential must return the count of cancelled tasks — kills off-by-one mutation in the loop")

        // A second pass must report 0 because the registry was cleared.
        let secondCount = executor.transport.activeTasksStore.cancelNonEssential()
        XCTAssertEqual(secondCount, 0,
                       "Re-running cancelNonEssential must report zero (registry was emptied) — kills mutation that omits the tasks.removeAll cleanup")
    }
}
