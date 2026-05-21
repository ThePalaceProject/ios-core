//
//  TokenRefreshAndRetryQueueTests.swift
//  PalaceTests
//
//  Mutation-killing tests for the token-refresh + 401 retry-queue logic in
//  `TPPNetworkExecutor.refreshTokenAndResume`. Each test pins a specific
//  branch in the executor's refresh path so a mutation flips behaviour
//  observable from the test surface. See Coverage_Roadmap §2.1.
//
//  Conventions:
//   - All HTTP is intercepted by `HTTPStubURLProtocol`; no real network.
//   - The executor under test is constructed via the full-DI initializer
//     so its `accountsManager` is a `TPPLibraryAccountMock`, decoupled from
//     `AppContainer.production().accountsManager`.
//   - Each test comment names the mutant(s) it kills in plain English.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import XCTest
import PalaceAuth
import PalaceCatalog
@testable import Palace

final class TokenRefreshAndRetryQueueTests: XCTestCase {

    // MARK: - Fixtures

    private var executor: TPPNetworkExecutor!
    private var libraryAccount: TPPLibraryAccountMock!
    private var userAccount: TPPUserAccountMock!

    /// Fixed token endpoint URL. The stub matches by absolute string so we
    /// can route /token traffic separately from arbitrary API requests.
    private let tokenURL = URL(string: "https://token.example.com/oauth/token")!
    private let apiURL = URL(string: "https://api.example.com/protected")!

    override func setUp() {
        super.setUp()
        HTTPStubURLProtocol.reset()
        TPPUserAccountMock.resetShared()

        // Build a token-typed authentication definition. We need
        // `isToken == true`, `tokenURL == self.tokenURL`, and
        // `reauthStrategy == .tokenRefresh` so the refresh code path is
        // eligible to run.
        let authDef = Self.makeTokenAuth(tokenURL: tokenURL)

        userAccount = TPPUserAccountMock()
        userAccount._authDefinition = authDef
        userAccount._credentials = .token(
            authToken: "stale-token",
            barcode: "user-12345",
            pin: "1234",
            expirationDate: Date().addingTimeInterval(3600) // not near-expiry
        )
        userAccount.markLoggedIn()

        libraryAccount = TPPLibraryAccountMock()
        libraryAccount.userAccountResolver = { [unowned self] _ in self.userAccount }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HTTPStubURLProtocol.self]

        executor = TPPNetworkExecutor(
            credentialsProvider: nil,
            cachingStrategy: .ephemeral,
            sessionConfiguration: config,
            accountsManager: libraryAccount,
            delegateQueue: nil
        )
    }

    override func tearDown() {
        HTTPStubURLProtocol.reset()
        executor = nil
        libraryAccount = nil
        userAccount = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private static func makeTokenAuth(tokenURL: URL) -> AccountDetails.Authentication {
        // OPDS2 authentication-document JSON for the token auth type. The
        // memberwise init on the OPDS2 type is internal to PalaceCatalog;
        // round-tripping through JSON is the supported construction path.
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

    /// Encodes a TokenResponse JSON body the way the server would return it.
    private static func tokenResponseJSON(accessToken: String,
                                          expiresIn: Int = 3600) -> Data {
        return """
        {"access_token":"\(accessToken)","token_type":"Bearer","expires_in":\(expiresIn)}
        """.data(using: .utf8)!
    }

    /// Builds a (not-yet-resumed) data task for the API URL using the
    /// executor's session. The task carries an `originalRequest` so the
    /// retry-queue path can reconstruct a follow-up request from it.
    private func makeQueueableTask(url: URL? = nil) -> URLSessionDataTask {
        let request = executor.request(for: url ?? apiURL, useTokenIfAvailable: false)
        // Create via the executor's session so the task identifier space
        // matches what the responder would normally see. We deliberately
        // do NOT call resume() — the refresh code only reads
        // originalRequest / taskIdentifier and then cancels it.
        return executor.transport.urlSession.dataTask(with: request)
    }

    /// Waits up to `timeout` seconds for `condition` to become true, polling
    /// every 25ms on the test thread (with `RunLoop.run(mode:before:)` so
    /// async URLSession callbacks can land). Returns true if the condition
    /// fired, false on timeout.
    private func waitForCondition(timeout: TimeInterval = 5.0,
                                   _ condition: @escaping () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.025))
        }
        return condition()
    }

    // MARK: - Test 1: 401-failure path marks credentials stale
    //
    // Kills: removing the `nsError.code == 401` branch (line 485) — i.e.
    // mutating `==` to `!=`, deleting the markCredentialsStale call, or
    // turning the `if let nsError ... == 401` guard into `true`.
    //
    // Setup: token refresh returns 401 from the token endpoint. The
    // executor must:
    //   1. Surface a `.failure` to the caller.
    //   2. Mark the user account's authState as `.credentialsStale`.
    //   3. NOT loop the refresh — refreshAttemptCount stays at exactly 1.

    func testRefresh_TokenEndpointReturns401_MarksCredentialsStaleAndDoesNotLoop() async throws {
        await executor.resetRefreshAttemptCount()

        var tokenRequestCount = 0
        HTTPStubURLProtocol.register { [tokenURL] request in
            guard request.url == tokenURL else { return nil }
            tokenRequestCount += 1
            // 401 from the token endpoint — credentials no longer accepted.
            return .init(statusCode: 401, headers: nil, body: Data("denied".utf8))
        }

        let finished = expectation(description: "refresh completion fired")
        var observedFailure = false

        executor.refreshTokenAndResume(task: nil, accountId: nil) { result in
            switch result {
            case .success: break
            case .failure: observedFailure = true
            }
            finished.fulfill()
        }

        await fulfillment(of: [finished], timeout: 5.0)

        // markCredentialsStale hops to MainActor — give it a tick.
        _ = waitForCondition(timeout: 2.0) { [weak self] in
            self?.userAccount.authState == .credentialsStale
        }

        XCTAssertTrue(observedFailure,
                      "401 from /token must surface as a .failure to the caller")
        XCTAssertEqual(userAccount.authState, .credentialsStale,
                       "A 401 from /token must mark the user's credentials stale (kills `==` → `!=` on the 401-check, and deletion of markCredentialsStale)")
        XCTAssertEqual(tokenRequestCount, 1,
                       "Failed /token must NOT be retried by the executor — kills any mutation that turns the failure path into a retry loop")

        let attempts = await executor.refreshAttemptCount
        XCTAssertEqual(attempts, 1,
                       "Exactly one refresh attempt was claimed; the failure path must not re-enter the single-flight slot")
    }

    // MARK: - Test 2: Network-error refresh failure does NOT mark stale
    //
    // Kills: broadening the `nsError.code == 401` branch to fire on any
    // failure (e.g. `nsError.code != 0` or `true`). A transient network
    // error must NOT brand the user as having bad credentials — that
    // would force a sign-in prompt on every offline blip.

    func testRefresh_TokenEndpointNetworkError_DoesNotMarkCredentialsStale() async throws {
        await executor.resetRefreshAttemptCount()
        // Sanity: user starts loggedIn.
        XCTAssertEqual(userAccount.authState, .loggedIn)

        // Return a 500 — NOT a 401. The TokenRequest layer maps non-200
        // into an NSError with `.code == statusCode` (so .code == 500).
        // The executor branch we care about gates on .code == 401 only.
        HTTPStubURLProtocol.register { [tokenURL] request in
            guard request.url == tokenURL else { return nil }
            return .init(statusCode: 500, headers: nil, body: Data("boom".utf8))
        }

        let finished = expectation(description: "refresh completion fired")
        var observedFailure = false

        executor.refreshTokenAndResume(task: nil, accountId: nil) { result in
            if case .failure = result { observedFailure = true }
            finished.fulfill()
        }

        await fulfillment(of: [finished], timeout: 5.0)

        // Give any MainActor work a tick to settle (we expect none, but
        // we need to avoid a flake from missing a delayed mutation).
        _ = waitForCondition(timeout: 1.0) { false }

        XCTAssertTrue(observedFailure,
                      "Non-401 refresh failure must still surface to caller")
        XCTAssertEqual(userAccount.authState, .loggedIn,
                       "A non-401 token-refresh failure (e.g. 500) must NOT mark credentials stale — kills any mutation that broadens the `code == 401` guard")
    }

    // MARK: - Test 3: 401 with no refresh credentials → no /token attempt
    //
    // Kills: deletion of the early-return guard on missing barcode/pin
    // (`guard let username = ..., !username.isEmpty, let password = ..., let tokenURL = ...`)
    // and the matching `setRefreshing(false)` release. If the guard is
    // removed/inverted, the executor will either (a) attempt the /token
    // request with empty credentials, (b) leave isRefreshing latched at
    // true so subsequent refresh requests deadlock, or (c) fail to surface
    // an error to the caller. All three are observable.

    func testRefresh_WithoutCredentials_FailsImmediatelyAndReleasesSlot() async throws {
        await executor.resetRefreshAttemptCount()
        // Wipe credentials but keep the authDefinition so the tokenURL is
        // still present. The guard at line 424-432 must trip on missing
        // barcode/pin.
        userAccount._credentials = nil
        XCTAssertNil(userAccount.barcode)

        var tokenEndpointCalls = 0
        HTTPStubURLProtocol.register { [tokenURL] request in
            if request.url == tokenURL { tokenEndpointCalls += 1 }
            return .init(statusCode: 200,
                         headers: nil,
                         body: Self.tokenResponseJSON(accessToken: "should-not-be-returned"))
        }

        let finished = expectation(description: "refresh completion fired")
        var observedFailure = false

        executor.refreshTokenAndResume(task: nil, accountId: nil) { result in
            if case .failure = result { observedFailure = true }
            finished.fulfill()
        }

        await fulfillment(of: [finished], timeout: 5.0)

        XCTAssertTrue(observedFailure,
                      "Missing credentials must surface as .failure (kills deletion of completion(.failure) in the missing-creds branch)")
        XCTAssertEqual(tokenEndpointCalls, 0,
                       "No HTTP call to /token can occur without credentials (kills inversion of the credentials guard)")

        let attempts = await executor.refreshAttemptCount
        XCTAssertEqual(attempts, 1,
                       "The credentials-missing branch still claimed and released the slot exactly once")

        // The slot must have been RELEASED (setRefreshing(false)). Verify
        // by issuing a second refresh — if the slot were still held, this
        // would coalesce as a queued retry (no task → returns
        // 'Token refresh in progress' error path), not the fresh failure
        // we just observed. The second refresh must surface a NEW
        // failure with the same message, not a coalescence message.
        let finished2 = expectation(description: "second refresh completion fired")
        var secondMessage: String?
        executor.refreshTokenAndResume(task: nil, accountId: nil) { result in
            if case .failure(let err, _) = result {
                secondMessage = (err as NSError).localizedDescription
            }
            finished2.fulfill()
        }
        await fulfillment(of: [finished2], timeout: 5.0)

        XCTAssertNotNil(secondMessage)
        XCTAssertFalse(secondMessage?.contains("in progress") ?? false,
                       "After the credentials-missing branch the single-flight slot must be released — a second refresh must re-enter the missing-creds path, not stall behind a latched isRefreshing=true (kills deletion of setRefreshing(false) on the missing-creds branch)")
    }

    // MARK: - Test 4: Concurrent refreshes coalesce — only one /token fires
    //
    // Kills: removing the atomic `tryClaimRefreshSlot()` check (line 403)
    // or replacing `!claimed` with `claimed`. If the single-flight guard
    // is broken, N concurrent refreshes produce N /token requests instead
    // of 1.

    func testConcurrentRefreshes_OnlyOneTokenRequestFires() async throws {
        await executor.resetRefreshAttemptCount()

        // Gate the token response so multiple in-flight refresh callers
        // pile up behind the same /token request. We release after we've
        // observed all callers entering the queue.
        let releaseGate = DispatchSemaphore(value: 0)
        var tokenRequestCount = 0
        let counterQueue = DispatchQueue(label: "token.count")

        HTTPStubURLProtocol.register { [tokenURL] request in
            guard request.url == tokenURL else { return nil }
            counterQueue.sync { tokenRequestCount += 1 }
            // Block the protocol thread until the test releases. Cap at
            // 3s so a broken single-flight guard surfaces as N>1 instead
            // of a hung test.
            _ = releaseGate.wait(timeout: .now() + 3.0)
            return .init(statusCode: 200,
                         headers: nil,
                         body: Self.tokenResponseJSON(accessToken: "fresh-token"))
        }

        // Fan out 5 simultaneous refreshes. Each one provides a unique
        // task so the queue can be observed (the no-task path collapses
        // to a "Token refresh in progress" error and would mask
        // single-flight collapse — pass real tasks).
        let callerCount = 5
        var completions: [XCTestExpectation] = []
        var tasks: [URLSessionDataTask] = []
        for i in 0..<callerCount {
            let exp = expectation(description: "refresh caller \(i)")
            completions.append(exp)
            // First caller passes nil task (it's the one whose completion
            // we observe), other callers pass real tasks so they take the
            // queueing branch.
            if i == 0 {
                executor.refreshTokenAndResume(task: nil, accountId: nil) { _ in
                    exp.fulfill()
                }
            } else {
                let task = makeQueueableTask()
                tasks.append(task)
                executor.refreshTokenAndResume(task: task, accountId: nil) { _ in
                    exp.fulfill()
                }
            }
        }

        // Give the actor a moment to serialize all entrances before we
        // release the gate. Polling: when all 5 callers have entered, the
        // refreshAttemptCount must still be exactly 1.
        _ = waitForCondition(timeout: 2.0) { [counterQueue] in
            // Wait until the /token request has been received. After that,
            // any other in-flight refresh callers have either coalesced
            // or are stuck in the actor hop.
            counterQueue.sync { tokenRequestCount } == 1
        }

        // Sample the attempt counter while /token is still blocked: this
        // is the moment that proves single-flight. If the guard is broken
        // we'd see >1 here.
        let inFlightAttempts = await executor.refreshAttemptCount
        XCTAssertEqual(inFlightAttempts, 1,
                       "Only ONE refresh slot may be claimed across concurrent callers (kills `!claimed` → `claimed` and removal of tryClaimRefreshSlot guard)")

        releaseGate.signal()
        // 30s budget — 5 concurrent refresh completions race CI runner load;
        // 10s was hanging the test runner past the 60min step timeout and
        // corrupting the xcresult bundle. Same family as ColdStartResume and
        // OPDSFeedService timeout bumps applied elsewhere on develop.
        await fulfillment(of: completions, timeout: 30.0)

        XCTAssertEqual(tokenRequestCount, 1,
                       "Exactly one /token HTTP call may fire for N concurrent refresh requests (kills removal of single-flight collapse)")
    }

    // MARK: - Test 5: Queued tasks get the NEW token after refresh
    //
    // Kills: replacement of `self.request(for: originalURL)` (line 461)
    // with a stale `oldTask.originalRequest` reuse, or replacement of
    // `oldTask.cancel()` with `oldTask.resume()`. The retry MUST go out
    // with the freshly-stored bearer, not the original (stale) one.

    func testQueuedRequest_AfterRefresh_RetriesWithNewBearer() async throws {
        await executor.resetRefreshAttemptCount()

        let newToken = "fresh-bearer-after-refresh"
        var capturedRetryAuth: String?
        var retryHits = 0

        HTTPStubURLProtocol.register { [tokenURL, apiURL] request in
            if request.url == tokenURL {
                return .init(statusCode: 200,
                             headers: nil,
                             body: Self.tokenResponseJSON(accessToken: newToken))
            }
            if request.url == apiURL {
                retryHits += 1
                capturedRetryAuth = request.value(forHTTPHeaderField: "Authorization")
                return .init(statusCode: 200, headers: nil, body: Data("ok".utf8))
            }
            return nil
        }

        // Queue a task carrying the (now stale) bearer.
        let queuedTask = makeQueueableTask()

        executor.refreshTokenAndResume(task: queuedTask, accountId: nil)

        // Wait until the retry request has been observed.
        let retried = waitForCondition(timeout: 5.0) { retryHits >= 1 }
        XCTAssertTrue(retried, "The queued task must be retried after the /token refresh succeeds")

        XCTAssertEqual(capturedRetryAuth,
                       "Bearer \(newToken)",
                       "The retried request must carry the NEW bearer (kills any mutation that reuses oldTask.originalRequest or the stale token)")
        XCTAssertNotEqual(capturedRetryAuth,
                          "Bearer stale-token",
                          "The retried request must NOT carry the stale token — kills mutation that resumes the original task instead of constructing a new one")
        XCTAssertEqual(userAccount.authToken, newToken,
                       "Refresh success must update the user account's auth token (kills deletion of setAuthToken on success)")
    }

    // MARK: - Test 6: Single-flight slot is released on success
    //
    // Kills: deletion of `setRefreshing(false)` (line 471) on the success
    // path. If the slot stays latched, subsequent refresh attempts will
    // be incorrectly coalesced into the (already-completed) refresh.

    func testRefresh_Success_ReleasesSingleFlightSlot() async throws {
        await executor.resetRefreshAttemptCount()
        // Two successive successful refreshes must both increment the
        // attempt counter (1 → 2). If the slot is never released, the
        // second attempt would coalesce and the counter would stay at 1.
        var tokenHits = 0
        HTTPStubURLProtocol.register { [tokenURL] request in
            guard request.url == tokenURL else { return nil }
            tokenHits += 1
            return .init(statusCode: 200,
                         headers: nil,
                         body: Self.tokenResponseJSON(accessToken: "tok-\(tokenHits)"))
        }

        let first = expectation(description: "first refresh")
        executor.refreshTokenAndResume(task: nil, accountId: nil) { _ in first.fulfill() }
        await fulfillment(of: [first], timeout: 5.0)

        // Give the actor's setRefreshing(false) hop a chance to land.
        _ = waitForCondition(timeout: 1.0) { false }

        let second = expectation(description: "second refresh")
        executor.refreshTokenAndResume(task: nil, accountId: nil) { _ in second.fulfill() }
        await fulfillment(of: [second], timeout: 5.0)

        let attempts = await executor.refreshAttemptCount
        XCTAssertEqual(attempts, 2,
                       "Two successive successful refreshes must each claim the slot — kills deletion of setRefreshing(false) on the success branch")
        XCTAssertEqual(tokenHits, 2,
                       "Each released-and-reclaimed refresh must fire its own /token request")
    }

    // MARK: - Test 7: Retried task identifier is rewired before resume
    //
    // Kills: deletion of `responder.updateCompletionId(oldTask.taskIdentifier, newId: newTask.taskIdentifier)`
    // (line 463). Without that rewire, the new (retried) task lands in
    // the responder with no associated completion, so the success-body
    // delivery never happens — only the cancelled-old-task completion
    // (`.failure(cancelled)`) fires.
    //
    // Production timing note: the queued task is cancelled and replaced
    // by a new task. URLSession fires `didCompleteWithError` for the
    // cancelled OLD task (with `NSURLErrorCancelled`) AND, separately,
    // for the new task on success. So the caller's completion can be
    // invoked twice. We collect all invocations and assert that at
    // least one of them carries the retried success body.

    func testQueuedRequest_CompletionFiresWithRetryBodyAfterRetry() async throws {
        await executor.resetRefreshAttemptCount()
        HTTPStubURLProtocol.register { [tokenURL, apiURL] request in
            if request.url == tokenURL {
                return .init(statusCode: 200,
                             headers: nil,
                             body: Self.tokenResponseJSON(accessToken: "fresh"))
            }
            if request.url == apiURL {
                return .init(statusCode: 200,
                             headers: nil,
                             body: Data("retry-body".utf8))
            }
            return nil
        }

        let queuedTask = makeQueueableTask()

        // Register a completion via the same surface `performDataTask`
        // uses. We collect every invocation rather than asserting
        // single-fire — production fires both the cancellation event
        // for the original task and the success event for the retry,
        // so we rely on polling for the retry-body to land rather than
        // an XCTestExpectation that would over-fulfill.
        var successBodies: [Data] = []
        var failureCount = 0
        let observerQueue = DispatchQueue(label: "test.observer")
        executor.responder.addCompletion({ result in
            observerQueue.sync {
                switch result {
                case .success(let data, _):
                    successBodies.append(data)
                case .failure:
                    failureCount += 1
                }
            }
        }, taskID: queuedTask.taskIdentifier)

        executor.refreshTokenAndResume(task: queuedTask, accountId: nil)

        // Wait for at least one success body to land. The cancellation
        // failure may fire first; we keep polling until the retry-body
        // success arrives (or we time out, which means updateCompletionId
        // was bypassed and the new task has no completion mapping).
        let sawRetryBody = waitForCondition(timeout: 5.0) {
            observerQueue.sync { successBodies.contains(Data("retry-body".utf8)) }
        }

        let snapshotSuccess = observerQueue.sync { successBodies.count }
        let snapshotFailure = observerQueue.sync { failureCount }
        XCTAssertTrue(sawRetryBody,
                      "The retried task's success must reach the caller's completion (kills deletion of responder.updateCompletionId — without rewiring, no success body ever fires). successBodies=\(snapshotSuccess), failureCount=\(snapshotFailure)")
    }

    // MARK: - Test 8: DELETE 401 short-circuits refresh
    //
    // Kills: removal of the DELETE early-return in
    // `handleExpiredTokenIfNeeded` (line 400-402). The executor itself
    // is invoked through `executeRequest` here so we exercise the
    // delegate path. DELETE 401s must NOT trigger a refresh — they
    // surface failure directly so revoke/return flows fail closed
    // instead of looping on an expired credential.
    //
    // Coverage rationale: this path lives in `TPPNetworkResponder` but
    // is a refresh-loop guard. End-to-end the executor must NOT
    // increment refreshAttemptCount.

    func testDELETE_401_DoesNotTriggerRefresh() async throws {
        // executeRequest's DELETE path passes enableTokenRefresh=false
        // through the public surface; we exercise the underlying executor
        // and verify no token-endpoint request fires when the delete 401s.
        await executor.resetRefreshAttemptCount()

        var tokenHits = 0
        HTTPStubURLProtocol.register { [tokenURL] request in
            if request.url == tokenURL { tokenHits += 1 }
            // Fail-closed 401 on the DELETE; no body required.
            if request.httpMethod == "DELETE" {
                return .init(statusCode: 401, headers: nil, body: nil)
            }
            return .init(statusCode: 200, headers: nil, body: nil)
        }

        var delReq = URLRequest(url: apiURL)
        delReq.httpMethod = "DELETE"

        let done = expectation(description: "delete completes")
        executor.DELETE(delReq, useTokenIfAvailable: false) { _, _, _ in
            done.fulfill()
        }

        await fulfillment(of: [done], timeout: 5.0)
        // Give any spurious refresh task a chance to launch (so absence
        // is meaningful, not just earliness).
        _ = waitForCondition(timeout: 0.5) { false }

        XCTAssertEqual(tokenHits, 0,
                       "A DELETE 401 must not trigger a token refresh — kills removal of the DELETE early-return in handleExpiredTokenIfNeeded")
        let attempts = await executor.refreshAttemptCount
        XCTAssertEqual(attempts, 0,
                       "DELETE 401 must not consume a single-flight refresh slot")
    }

    // MARK: - Test 9: refresh continuation completes (success-path resume)
    //
    // Kills: deletion of the `if task == nil { completion?(.success(...)) }`
    // block on the success branch (line 473-475). Callers of
    // refreshTokenAndResume that supplied a completion AND nil task
    // expect the success path to call completion exactly once. Skipping
    // it leaves the caller's continuation suspended forever (observed as
    // an async hang / test timeout).

    func testRefresh_SuccessWithoutTask_FiresSuccessCompletion() async throws {
        await executor.resetRefreshAttemptCount()
        HTTPStubURLProtocol.register { [tokenURL] request in
            guard request.url == tokenURL else { return nil }
            return .init(statusCode: 200,
                         headers: nil,
                         body: Self.tokenResponseJSON(accessToken: "ok"))
        }

        let exp = expectation(description: "completion fires on success/no-task")
        var sawSuccess = false
        var callCount = 0
        executor.refreshTokenAndResume(task: nil, accountId: nil) { result in
            callCount += 1
            if case .success = result { sawSuccess = true }
            exp.fulfill()
        }
        await fulfillment(of: [exp], timeout: 5.0)

        // Pump a brief idle window so any duplicate completion (which
        // would indicate the success-path didn't gate on task == nil)
        // has a chance to land.
        _ = waitForCondition(timeout: 0.4) { false }

        XCTAssertTrue(sawSuccess,
                      "task == nil + refresh success must emit a .success completion (kills deletion of the success-callback branch)")
        XCTAssertEqual(callCount, 1,
                       "Completion must fire EXACTLY once (kills mutation that emits both success-and-failure)")
    }
}
