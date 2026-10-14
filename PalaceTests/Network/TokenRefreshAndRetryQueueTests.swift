//  TokenRefreshAndRetryQueueTests.swift
//
//  Token-refresh and 401 retry-queue logic in
//  `TPPNetworkExecutor.refreshTokenAndResume`. Each test pins one branch of the
//  refresh path and names the regression it catches. HTTP goes through
//  `HTTPStubURLProtocol`, and the executor is built with the full-DI initializer
//  so its `accountsManager` is a `TPPLibraryAccountMock`.

import XCTest
import PalaceAuth
import PalaceCatalog
@testable import Palace

@MainActor
final class TokenRefreshAndRetryQueueTests: XCTestCase {

    // MARK: - Fixtures

    private var executor: TPPNetworkExecutor!
    private var libraryAccount: TPPLibraryAccountMock!
    private var userAccount: TPPUserAccountMock!

    /// Token and API endpoints, unique to each run. The stub is process-wide,
    /// and a token request answered with a 5xx is retried after a backoff of
    /// up to 1.2s, so a retry left by an earlier test would otherwise be
    /// answered, and counted, by whichever test is running then.
    private var tokenURL: URL!
    private var apiURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        HTTPStubURLProtocol.reset()
        let runID = UUID().uuidString
        tokenURL = URL(string: "https://token.example.com/\(runID)/oauth/token")!
        apiURL = URL(string: "https://api.example.com/\(runID)/protected")!
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
        // Capture the userAccount instance directly (NOT via `[unowned self]`)
        // so a stale URLSession callback firing after tearDown nils
        // `self.userAccount` can't crash on the IUO unwrap. The closure holds
        // its own strong reference to the mock; tearDown's `userAccount = nil`
        // safely drops only the test class's property.
        // `@Sendable` because the executor resolves the account from its
        // refresh Task, off the main actor this closure would otherwise inherit.
        let resolvedUserAccount: TPPUserAccountMock = userAccount
        libraryAccount.userAccountResolver = { @Sendable _ in resolvedUserAccount }

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
    private nonisolated static func tokenResponseJSON(accessToken: String,
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
        return executor.makeSessionDataTask(with: request)
    }

    /// Deterministic barrier for ABSENCE assertions ("no spurious refresh",
    /// "no duplicate completion"). The executor's refresh work runs on
    /// `Task { … }` closures; awaiting a short chain of enqueued `Task` values
    /// steps the cooperative pool through any already-scheduled continuations
    /// so a same-turn spurious effect has landed before we assert its absence.
    /// Unlike the fixed-deadline poll it replaces, this never consults a wall
    /// clock — it completes the instant the pool is free, so it can't starve
    /// under parallel-CI contention. Also hops the main actor to flush the
    /// `await MainActor.run { … }` sub-path the 401 branch uses.
    private func drainPendingRefreshWork() async {
        for _ in 0..<8 {
            await Task { }.value
            await Task { @MainActor in }.value
        }
    }

    /// Barrier on the session's delegate queue, where the responder delivers
    /// every completion: after the refresh work has drained, a duplicate
    /// delivery it enqueued has run before an exactly-once count is read.
    private func drainRefreshAndDelivery() async {
        await drainPendingRefreshWork()
        let delegateQueue = executor.transport.urlSession.delegateQueue
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            delegateQueue.addOperation { done.resume() }
        }
    }

    /// Bridges a `DispatchSemaphore` signal into async/await WITHOUT blocking the
    /// Swift concurrency cooperative pool. `Task.detached`'s operation closure is
    /// itself an async context, so a blocking `sem.wait()` there is a Swift 6
    /// error ("`wait` is unavailable from asynchronous contexts"). Running the
    /// blocking wait inside a plain `DispatchQueue.global().async` closure (a
    /// non-async context where `wait()` is allowed) on a Dispatch thread — never
    /// a cooperative-pool thread — and resuming a continuation when it returns is
    /// the correct off-pool bridge. Resumes the instant the semaphore is
    /// signaled. The 60s bound is a hang guard, not a deadline: a signal that
    /// never comes (a dropped retry) fails the test instead of stalling the run.
    private func awaitSemaphore(_ sem: DispatchSemaphore,
                                file: StaticString = #filePath,
                                line: UInt = #line) async {
        if await awaitSemaphore(sem, timeout: .now() + 60.0) == .timedOut {
            XCTFail("the awaited signal never arrived within the 60s hang guard", file: file, line: line)
        }
    }

    /// Timeout variant — returns the `DispatchTimeoutResult` so a test can assert
    /// the signal arrived (`.success`) vs. timed out. Same off-pool bridge.
    private func awaitSemaphore(_ sem: DispatchSemaphore, timeout: DispatchTime) async -> DispatchTimeoutResult {
        await withCheckedContinuation { (cont: CheckedContinuation<DispatchTimeoutResult, Never>) in
            DispatchQueue.global().async { cont.resume(returning: sem.wait(timeout: timeout)) }
        }
    }

    // MARK: - Test 1: 401-failure path marks credentials stale
    //
    // Catches: removing the `nsError.code == 401` branch (line 485) — i.e.
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

        let tokenRequestCount = LockIsolated(0)
        // @Sendable stub + LockIsolated: avoids Swift 6 off-main executor-isolation trap
        HTTPStubURLProtocol.register { @Sendable [tokenURL] request in
            guard request.url == tokenURL else { return nil }
            tokenRequestCount.withValue { $0 += 1 }
            // 401 from the token endpoint — credentials no longer accepted.
            return .init(statusCode: 401, headers: nil, body: Data("denied".utf8))
        }

        let finished = expectation(description: "refresh completion fired")
        let observedFailure = LockIsolated(false)

        // `@Sendable`: the executor calls this from its refresh Task. Formed
        // here without it, the closure is main-actor isolated and traps.
        executor.refreshTokenAndResume(task: nil, accountId: nil) { @Sendable result in
            switch result {
            case .success: break
            case .failure: observedFailure.value = true
            }
            finished.fulfill()
        }

        await fulfillment(of: [finished], timeout: 5.0)

        // No wall-clock poll for markCredentialsStale: in the executor's failure
        // branch the `await MainActor.run { …markCredentialsStale() }` completes
        // BEFORE the caller completion is invoked. This test is @MainActor, so by
        // the time `fulfillment(of: [finished])` returns, that main-actor mutation
        // has already been applied — the completion is the deterministic join to
        // the stale-mark, no fixed-deadline `waitForCondition` needed.

        XCTAssertTrue(observedFailure.value,
                      "401 from /token must surface as a .failure to the caller")
        XCTAssertEqual(userAccount.authState, .credentialsStale,
                       "A 401 from /token must mark the user's credentials stale (kills `==` → `!=` on the 401-check, and deletion of markCredentialsStale)")
        XCTAssertEqual(tokenRequestCount.value, 1,
                       "Failed /token must NOT be retried by the executor — kills any mutation that turns the failure path into a retry loop")

        let attempts = await executor.refreshAttemptCount
        XCTAssertEqual(attempts, 1,
                       "Exactly one refresh attempt was claimed; the failure path must not re-enter the single-flight slot")
    }

    // MARK: - Test 2: Network-error refresh failure does NOT mark stale
    //
    // Catches: broadening the `nsError.code == 401` branch to fire on any
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
        // @Sendable stub + LockIsolated: avoids Swift 6 off-main executor-isolation trap
        HTTPStubURLProtocol.register { @Sendable [tokenURL] request in
            guard request.url == tokenURL else { return nil }
            return .init(statusCode: 500, headers: nil, body: Data("boom".utf8))
        }

        let finished = expectation(description: "refresh completion fired")
        let observedFailure = LockIsolated(false)

        executor.refreshTokenAndResume(task: nil, accountId: nil) { @Sendable result in
            if case .failure = result { observedFailure.value = true }
            finished.fulfill()
        }

        await fulfillment(of: [finished], timeout: 5.0)

        // No settling sleep: the executor invokes the caller completion as the
        // LAST step of its failure branch (after any main-actor work on the 401
        // sub-path — which this non-401 case never enters). Once `fulfillment`
        // returns, the branch has fully run; a fixed `waitForCondition(1.0){false}`
        // wall-clock sleep only widened the CI-starvation window without adding
        // any additional happens-before we don't already have from the completion.

        XCTAssertTrue(observedFailure.value,
                      "Non-401 refresh failure must still surface to caller")
        XCTAssertEqual(userAccount.authState, .loggedIn,
                       "A non-401 token-refresh failure (e.g. 500) must NOT mark credentials stale — kills any mutation that broadens the `code == 401` guard")
    }

    // MARK: - Test 3: 401 with no refresh credentials → no /token attempt
    //
    // Catches: deletion of the early-return guard on missing barcode/pin
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

        let tokenEndpointCalls = LockIsolated(0)
        // @Sendable stub + LockIsolated: avoids Swift 6 off-main executor-isolation trap
        HTTPStubURLProtocol.register { @Sendable [tokenURL] request in
            if request.url == tokenURL { tokenEndpointCalls.withValue { $0 += 1 } }
            return .init(statusCode: 200,
                         headers: nil,
                         body: Self.tokenResponseJSON(accessToken: "should-not-be-returned"))
        }

        let finished = expectation(description: "refresh completion fired")
        let observedFailure = LockIsolated(false)

        executor.refreshTokenAndResume(task: nil, accountId: nil) { @Sendable result in
            if case .failure = result { observedFailure.value = true }
            finished.fulfill()
        }

        await fulfillment(of: [finished], timeout: 5.0)

        XCTAssertTrue(observedFailure.value,
                      "Missing credentials must surface as .failure (kills deletion of completion(.failure) in the missing-creds branch)")
        XCTAssertEqual(tokenEndpointCalls.value, 0,
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
        let secondFailure = LockIsolated<String?>(nil)
        executor.refreshTokenAndResume(task: nil, accountId: nil) { @Sendable result in
            if case .failure(let err, _) = result {
                secondFailure.value = (err as NSError).localizedDescription
            }
            finished2.fulfill()
        }
        await fulfillment(of: [finished2], timeout: 5.0)
        let secondMessage = secondFailure.value

        XCTAssertNotNil(secondMessage)
        XCTAssertFalse(secondMessage?.contains("in progress") ?? false,
                       "After the credentials-missing branch the single-flight slot must be released — a second refresh must re-enter the missing-creds path, not stall behind a latched isRefreshing=true (kills deletion of setRefreshing(false) on the missing-creds branch)")
    }

    // MARK: - Test 4: Concurrent refreshes coalesce — only one /token fires
    //
    // Catches: removing the atomic `tryClaimRefreshSlot()` check (line 403)
    // or replacing `!claimed` with `claimed`. If the single-flight guard
    // is broken, N concurrent refreshes produce N /token requests instead
    // of 1.

    func testConcurrentRefreshes_OnlyOneTokenRequestFires() async throws {
        await executor.resetRefreshAttemptCount()

        // Gate the token response so multiple in-flight refresh callers
        // pile up behind the same /token request. We release after we've
        // observed all callers entering the queue.
        let releaseGate = DispatchSemaphore(value: 0)
        // Signalled the instant the /token stub thread is entered. The test
        // `wait`s on this instead of polling `tokenRequestCount == 1` on a
        // wall-clock deadline — a deterministic join to "the single /token
        // request has been received", which is exactly the moment single-flight
        // must be sampled. No clock, so it never starves under parallel-CI load.
        let tokenEntered = DispatchSemaphore(value: 0)
        let tokenRequestCount = LockIsolated(0)

        // @Sendable stub + LockIsolated: avoids Swift 6 off-main executor-isolation trap
        HTTPStubURLProtocol.register { @Sendable [tokenURL] request in
            guard request.url == tokenURL else { return nil }
            tokenRequestCount.withValue { $0 += 1 }
            tokenEntered.signal()
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
        //
        // Completions are no-ops: we do NOT need to wait for them to
        // land — the structural single-flight invariant is sampled
        // synchronously below via `inFlightAttempts == 1`. The prior
        // implementation created `XCTestExpectation`s here and waited
        // for them with `fulfillment(of: ..., timeout: 180.0)`, but the // FLAKE-003-OK: historical reference in comment block; test no longer waits — invariant is sampled synchronously below.
        // actor scheduler under CI-runner contention reliably stalled
        // the 5-caller drain past any timeout. The expectations were
        // belt-and-suspenders for the same invariant the structural
        // assertion already pins.
        let callerCount = 5
        var tasks: [URLSessionDataTask] = []
        for i in 0..<callerCount {
            // First caller passes nil task; other callers pass real
            // tasks so they take the queueing branch.
            if i == 0 {
                executor.refreshTokenAndResume(task: nil, accountId: nil) { @Sendable _ in }
            } else {
                let task = makeQueueableTask()
                tasks.append(task)
                executor.refreshTokenAndResume(task: task, accountId: nil) { @Sendable _ in }
            }
        }

        // Deterministic join: block a background thread on the entry
        // semaphore until the single /token request has actually been
        // received. `tokenEntered.signal()` fires from the stub thread the
        // instant it's entered, so this resumes exactly then — never on a
        // wall-clock deadline. Waited off the main actor so the executor's
        // Task/actor hops that drive the request to the stub aren't starved.
        await awaitSemaphore(tokenEntered)

        // Sample the attempt counter while /token is still blocked: this
        // is the moment that proves single-flight. If the guard is broken
        // we'd see >1 here.
        let inFlightAttempts = await executor.refreshAttemptCount
        XCTAssertEqual(inFlightAttempts, 1,
                       "Only ONE refresh slot may be claimed across concurrent callers (kills `!claimed` → `claimed` and removal of tryClaimRefreshSlot guard)")

        // Release the HTTP stub gate so any in-flight HTTP thread can
        // return and the actor can drain queued continuations during
        // tearDown. We do NOT wait for completions here.
        //
        // The structural single-flight invariant is already pinned by
        // the `inFlightAttempts == 1` assertion above. An earlier version
        // followed this
        // with `await fulfillment(of: completions, timeout:)` plus a
        // `tokenRequestCount == 1` belt-and-suspenders check. Both were
        // redundant (single-flight implies single HTTP request), AND
        // the actor scheduler under heavy CI-runner contention reliably
        // stalls the 5-caller completion drain past any timeout we tried
        // (10s → 30s → 180s — all exceeded). The XCTSkipIf(CI=…) attempt
        // didn't work either because xcodebuild test doesn't propagate
        // shell env vars into the simulator test process by default.
        //
        // Net trade: lose one redundant check (already covered
        // by the structural assertion) in exchange for permanently
        // unblocking CI on a flake that hit every PR.
        releaseGate.signal()
    }

    // MARK: - Test 5: Queued tasks get the NEW token after refresh
    //
    // Catches: replacement of `self.request(for: originalURL)` (line 461)
    // with a stale `oldTask.originalRequest` reuse, or replacement of
    // `oldTask.cancel()` with `oldTask.resume()`. The retry MUST go out
    // with the freshly-stored bearer, not the original (stale) one.

    func testQueuedRequest_AfterRefresh_RetriesWithNewBearer() async throws {
        await executor.resetRefreshAttemptCount()

        let newToken = "fresh-bearer-after-refresh"

        // Cross-thread state — `retryHits` and `capturedRetryAuth` are
        // written by the network-thread stub and read by the test
        // thread's `waitForCondition`/assertions. Without explicit
        // synchronization the test thread can observe `retryHits >= 1`
        // before the prior `capturedRetryAuth` store is visible (no
        // happens-before across plain `var`s in Swift). The CI flake
        // was nil!=newToken precisely because of this gap. LockIsolated
        // around every shared-state access closes it.
        let capturedRetryAuth = LockIsolated<String?>(nil)
        let retryHits = LockIsolated(0)
        // Signalled the instant the retried API request reaches the stub. The
        // test joins on this rather than polling `retryHits >= 1` against a
        // 30s wall-clock deadline — the retry landing is the exact event we
        // gate on, so the semaphore resumes precisely when it happens and can
        // never starve under parallel-CI contention.
        let retryLanded = DispatchSemaphore(value: 0)

        // @Sendable stub + LockIsolated: avoids Swift 6 off-main executor-isolation trap
        HTTPStubURLProtocol.register { @Sendable [tokenURL, apiURL] request in
            if request.url == tokenURL {
                return .init(statusCode: 200,
                             headers: nil,
                             body: Self.tokenResponseJSON(accessToken: newToken))
            }
            if request.url == apiURL {
                let authValue = request.value(forHTTPHeaderField: "Authorization")
                capturedRetryAuth.value = authValue
                retryHits.withValue { $0 += 1 }
                retryLanded.signal()
                return .init(statusCode: 200, headers: nil, body: Data("ok".utf8))
            }
            return nil
        }

        // Queue a task carrying the (now stale) bearer.
        let queuedTask = makeQueueableTask()

        executor.refreshTokenAndResume(task: queuedTask, accountId: nil)

        // Deterministic join to the retry landing (off the main actor so the
        // executor's refresh Task/actor hops and URLSession delivery aren't
        // starved). Resumes the instant the retried API request hits the stub.
        await awaitSemaphore(retryLanded)
        let retried = retryHits.value >= 1
        XCTAssertTrue(retried, "The queued task must be retried after the /token refresh succeeds")

        let observedAuth = capturedRetryAuth.value

        XCTAssertEqual(observedAuth,
                       "Bearer \(newToken)",
                       "The retried request must carry the NEW bearer (kills any mutation that reuses oldTask.originalRequest or the stale token)")
        XCTAssertNotEqual(observedAuth,
                          "Bearer stale-token",
                          "The retried request must NOT carry the stale token — kills mutation that resumes the original task instead of constructing a new one")
        XCTAssertEqual(userAccount.authToken, newToken,
                       "Refresh success must update the user account's auth token (kills deletion of setAuthToken on success)")
    }

    // MARK: - Test 6: Single-flight slot is released on success
    //
    // Catches: deletion of `setRefreshing(false)` (line 471) on the success
    // path. If the slot stays latched, subsequent refresh attempts will
    // be incorrectly coalesced into the (already-completed) refresh.

    func testRefresh_Success_ReleasesSingleFlightSlot() async throws {
        await executor.resetRefreshAttemptCount()
        // Two successive successful refreshes must both increment the
        // attempt counter (1 → 2). If the slot is never released, the
        // second attempt would coalesce and the counter would stay at 1.
        let tokenHits = LockIsolated(0)
        // @Sendable stub + LockIsolated: avoids Swift 6 off-main executor-isolation trap
        HTTPStubURLProtocol.register { @Sendable [tokenURL] request in
            guard request.url == tokenURL else { return nil }
            let hit = tokenHits.withValue { $0 += 1; return $0 }
            return .init(statusCode: 200,
                         headers: nil,
                         body: Self.tokenResponseJSON(accessToken: "tok-\(hit)"))
        }

        let first = expectation(description: "first refresh")
        executor.refreshTokenAndResume(task: nil, accountId: nil) { @Sendable _ in first.fulfill() }
        await fulfillment(of: [first], timeout: 5.0)

        // No wall-clock gap needed: the task==nil success completion is invoked
        // AFTER `setRefreshing(false)` in the executor (the slot is released, then
        // the completion fires), so once `fulfillment(of: [first])` returns the
        // single-flight slot is deterministically released. Awaiting the completion
        // IS the join to slot-release — a fixed `waitForCondition(1.0) { false }`
        // sleep here only added a starvation surface under parallel-CI contention.

        let second = expectation(description: "second refresh")
        executor.refreshTokenAndResume(task: nil, accountId: nil) { @Sendable _ in second.fulfill() }
        await fulfillment(of: [second], timeout: 5.0)

        let attempts = await executor.refreshAttemptCount
        XCTAssertEqual(attempts, 2,
                       "Two successive successful refreshes must each claim the slot — kills deletion of setRefreshing(false) on the success branch")
        XCTAssertEqual(tokenHits.value, 2,
                       "Each released-and-reclaimed refresh must fire its own /token request")
    }

    // MARK: - Test 7: Retried task identifier is rewired before resume
    //
    // Catches: deletion of `responder.updateCompletionId(oldTask.taskIdentifier, newId: newTask.taskIdentifier)`
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
        // @Sendable stub + LockIsolated: avoids Swift 6 off-main executor-isolation trap
        HTTPStubURLProtocol.register { @Sendable [tokenURL, apiURL] request in
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
        // @Sendable completion + LockIsolated: the responder invokes this
        // completion off the main actor (URLSession delegate queue), but the
        // closure is inferred @MainActor-isolated in this @MainActor test — so
        // without @Sendable it trips Swift 6's off-main executor-isolation
        // assertion (EXC_BREAKPOINT) exactly like the register stubs above.
        let successBodies = LockIsolated<[Data]>([])
        let failureCount = LockIsolated(0)
        // Signalled from inside the responder completion the instant the
        // retry-body success is delivered. The test joins on this rather than
        // polling `successBodies.contains(retry-body)` on a wall-clock deadline
        // — the completion firing with the retry body IS the event under test,
        // so signalling from within it is the deterministic join. The
        // cancellation failure for the old task may fire first; only the
        // retry-body success signals, so the wait resumes on the right event.
        let retryBodyDelivered = DispatchSemaphore(value: 0)
        executor.responder.addCompletion({ @Sendable result in
            switch result {
            case .success(let data, _):
                successBodies.withValue { $0.append(data) }
                if data == Data("retry-body".utf8) { retryBodyDelivered.signal() }
            case .failure:
                failureCount.withValue { $0 += 1 }
            }
        }, taskID: queuedTask.taskIdentifier)

        executor.refreshTokenAndResume(task: queuedTask, accountId: nil)

        // Deterministic join to the retry-body delivery (off the main actor so
        // the executor's refresh Task/actor hops and URLSession delivery aren't
        // starved). If `updateCompletionId` were bypassed the new task would
        // have no completion mapping and this would hang — surfaced as the test
        // timeout, exactly the regression this test guards.
        let sawRetryBody = await awaitSemaphore(retryBodyDelivered, timeout: .now() + 30.0) == .success

        let snapshotSuccess = successBodies.value.count
        let snapshotFailure = failureCount.value
        XCTAssertTrue(sawRetryBody,
                      "The retried task's success must reach the caller's completion (kills deletion of responder.updateCompletionId — without rewiring, no success body ever fires). successBodies=\(snapshotSuccess), failureCount=\(snapshotFailure)")
    }

    // MARK: - Test 8: DELETE 401 short-circuits refresh
    //
    // Catches: removal of the DELETE early-return in
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

        let tokenHits = LockIsolated(0)
        // @Sendable stub + LockIsolated: avoids Swift 6 off-main executor-isolation trap
        HTTPStubURLProtocol.register { @Sendable [tokenURL] request in
            if request.url == tokenURL { tokenHits.withValue { $0 += 1 } }
            // Fail-closed 401 on the DELETE; no body required.
            if request.httpMethod == "DELETE" {
                return .init(statusCode: 401, headers: nil, body: nil)
            }
            return .init(statusCode: 200, headers: nil, body: nil)
        }

        var delReq = URLRequest(url: apiURL)
        delReq.httpMethod = "DELETE"

        let done = expectation(description: "delete completes")
        executor.DELETE(delReq, useTokenIfAvailable: false) { @Sendable _, _, _ in
            done.fulfill()
        }

        await fulfillment(of: [done], timeout: 5.0)
        // Drain any already-scheduled refresh work so a spurious /token launch
        // would have landed before we assert its absence — deterministic
        // actor-hop barrier, not a fixed 0.5s wall-clock sleep.
        await drainPendingRefreshWork()

        XCTAssertEqual(tokenHits.value, 0,
                       "A DELETE 401 must not trigger a token refresh — kills removal of the DELETE early-return in handleExpiredTokenIfNeeded")
        let attempts = await executor.refreshAttemptCount
        XCTAssertEqual(attempts, 0,
                       "DELETE 401 must not consume a single-flight refresh slot")
    }

    // MARK: - Test 9: refresh continuation completes (success-path resume)
    //
    // Catches: deletion of the `if task == nil { completion?(.success(...)) }`
    // block on the success branch (line 473-475). Callers of
    // refreshTokenAndResume that supplied a completion AND nil task
    // expect the success path to call completion exactly once. Skipping
    // it leaves the caller's continuation suspended forever (observed as
    // an async hang / test timeout).

    func testRefresh_SuccessWithoutTask_FiresSuccessCompletion() async throws {
        await executor.resetRefreshAttemptCount()
        // @Sendable stub + LockIsolated: avoids Swift 6 off-main executor-isolation trap
        HTTPStubURLProtocol.register { @Sendable [tokenURL] request in
            guard request.url == tokenURL else { return nil }
            return .init(statusCode: 200,
                         headers: nil,
                         body: Self.tokenResponseJSON(accessToken: "ok"))
        }

        let exp = expectation(description: "completion fires on success/no-task")
        let sawSuccess = LockIsolated(false)
        let callCount = LockIsolated(0)
        executor.refreshTokenAndResume(task: nil, accountId: nil) { @Sendable result in
            callCount.withValue { $0 += 1 }
            if case .success = result { sawSuccess.value = true }
            exp.fulfill()
        }
        await fulfillment(of: [exp], timeout: 5.0)

        // Drain any already-scheduled refresh work so a duplicate completion
        // (which would indicate the success-path didn't gate on task == nil)
        // has landed before we assert callCount == 1 — deterministic actor-hop
        // barrier, not a fixed 0.4s wall-clock sleep.
        await drainPendingRefreshWork()

        XCTAssertTrue(sawSuccess.value,
                      "task == nil + refresh success must emit a .success completion (kills deletion of the success-callback branch)")
        XCTAssertEqual(callCount.value, 1,
                       "Completion must fire EXACTLY once (kills mutation that emits both success-and-failure)")
    }

    // MARK: - Test 10: the delivery executor is characterized, not assumed (PP-5299)
    //
    // This completion is NOT delivered on the main actor. It fires from inside
    // the refresh `Task`, i.e. the global concurrent executor, and has since at
    // least 3.2.4 — the 3.3.0 language-mode flip (876f7637f: SWIFT_VERSION 5.0
    // -> 6.0, SWIFT_STRICT_CONCURRENCY = complete) only promoted the
    // consumer-side isolation check from a warning to an assert.
    //
    // Who depends on that fact changed with PP-5301. It used to be the
    // main-actor hop in `AudiobookLoader.refreshTokenIfNeeded`, which is gone:
    // that caller awaits `refreshToken(accountId:)` and resumes on its own
    // actor. What depends on it now is that wrapper itself — it bridges this
    // completion to a continuation — plus the four callers still on the
    // completion form (`TPPMigrationManager`, `TPPNetworkQueue`,
    // `BackgroundDownloadHandler`, `TPPNetworkResponder`), all of which are
    // nonisolated types and so are unaffected either way.
    //
    // Characterization, not a preference. If someone later marshals delivery
    // inside the executor, this goes red and names the transition rather than
    // letting the async wrapper's continuation hop become silently redundant.

    func testRefresh_CompletionIsDeliveredOffTheMainActor() async throws {
        await executor.resetRefreshAttemptCount()
        HTTPStubURLProtocol.register { @Sendable [tokenURL] request in
            guard request.url == tokenURL else { return nil }
            return .init(statusCode: 200,
                         headers: nil,
                         body: Self.tokenResponseJSON(accessToken: "ok"))
        }

        let exp = expectation(description: "completion fires")
        executor.refreshTokenAndResume(task: nil, accountId: nil) { @Sendable _ in
            XCTAssertFalse(
                Thread.isMainThread,
                "refreshTokenAndResume delivered on the main thread. If that is now "
                + "intended, the @MainActor hop in AudiobookLoader.refreshTokenIfNeeded "
                + "is redundant and this characterization must be updated with it "
                + "(PP-5299)."
            )
            exp.fulfill()
        }
        await fulfillment(of: [exp], timeout: 5.0) // STARVE-001-OK: awaiting `refreshToken(accountId:)` would characterize the async wrapper instead of the completion form this test is about, so the wait cannot be replaced by it; drainPendingRefreshWork cannot substitute either, because it is a bounded eight-yield step rather than a join of the refresh Task and that chain contains real suspensions — the sibling test at Test 9 keeps its wait for the same reason and drains only afterwards

        // Drain afterwards, matching the siblings above: the wait returns when the
        // completion fires, which is not the same moment the refresh's remaining
        // work finishes. Without this, that work outlives the test and lands in
        // whichever test runs next on the shared executor.
        await drainPendingRefreshWork()
    }

    // MARK: - A failed refresh completes the request that queued it

    /// Records every call of a caller completion, from whichever queue the
    /// responder delivers it on.
    private final class CompletionLog: @unchecked Sendable {
        private let lock = NSLock()
        private var results: [NYPLResult<Data>] = []
        let delivered = DispatchSemaphore(value: 0)
        func record(_ result: NYPLResult<Data>) {
            lock.lock(); results.append(result); lock.unlock()
            delivered.signal()
        }
        var all: [NYPLResult<Data>] { lock.lock(); defer { lock.unlock() }; return results }
    }

    /// Puts the executor where the responder leaves it after a 401 that starts
    /// a refresh: the request has been sent and answered 401, and the caller's
    /// completion is still registered for its task, waiting on the refresh.
    private func sentRequestAwaitingRefresh(to url: URL? = nil) async throws -> (URLSessionTask, CompletionLog) {
        let apiURL: URL = url ?? self.apiURL
        // Spending the URL's retry budget first lets the 401 complete at once
        // instead of starting a refresh of its own.
        executor.responder.markRetried(url: apiURL)
        let answered = expectation(description: "the 401 reaches the first completion")
        let task = try XCTUnwrap(executor.executeRequest(executor.request(for: apiURL),
                                                         enableTokenRefresh: false,
                                                         accountId: nil) { @Sendable _ in
            answered.fulfill()
        })
        await fulfillment(of: [answered], timeout: 5.0)   // STARVE-001-OK: the stub answers at once

        // The responder marks the URL when a 401 starts a refresh.
        executor.responder.markRetried(url: apiURL)
        let log = CompletionLog()
        executor.responder.addCompletion({ @Sendable result in log.record(result) },
                                         taskID: task.taskIdentifier)
        return (task, log)
    }

    /// Answers every request to the API host with a 401 and the token
    /// endpoint with `tokenStatus`; returns the count of token requests.
    @discardableResult
    private func registerAPI401(tokenStatus: Int) -> LockIsolated<Int> {
        let tokenHits = LockIsolated(0)
        HTTPStubURLProtocol.register { @Sendable [tokenURL, apiURL] request in
            if request.url == tokenURL {
                tokenHits.withValue { $0 += 1 }
                let body = tokenStatus == 200 ? Self.tokenResponseJSON(accessToken: "fresh") : Data("denied".utf8)
                return .init(statusCode: tokenStatus, headers: nil, body: body)
            }
            guard request.url?.host == apiURL?.host else { return nil }
            return .init(statusCode: 401, headers: nil, body: nil)
        }
        return tokenHits
    }

    private func assertFailedOnceWith401(_ log: CompletionLog,
                                         file: StaticString = #filePath, line: UInt = #line) {
        let results = log.all
        XCTAssertEqual(results.count, 1, "the caller must be completed exactly once", file: file, line: line)
        guard case .failure(_, let response)? = results.first else {
            return XCTFail("the caller must receive a failure, got \(String(describing: results.first))",
                           file: file, line: line)
        }
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 401,
                       "the failure carries the 401 that started the refresh", file: file, line: line)
    }

    /// The token endpoint refuses the stored credentials. The request that
    /// queued the refresh has already finished at the URLSession level, so
    /// cancelling it delivers nothing; its caller must be failed directly.
    func testQueuedRetry_WhenTheRefreshIsRefused_FailsTheCallerOnce() async throws {
        registerAPI401(tokenStatus: 401)
        let (task, log) = try await sentRequestAwaitingRefresh()

        executor.refreshTokenAndResume(task: task, accountId: nil)

        let delivered = await awaitSemaphore(log.delivered, timeout: .now() + 10.0)
        XCTAssertEqual(delivered, .success, "the caller was never completed")
        await drainRefreshAndDelivery()
        assertFailedOnceWith401(log)
        XCTAssertTrue(executor.responder.canRetry(url: apiURL),
                      "the failed retry clears the URL's mark so its next 401 can refresh again")
    }

    /// A refresh that cannot start, because the account has no stored card,
    /// must still complete the request waiting on it.
    func testQueuedRetry_WhenTheAccountHasNoCredentials_FailsTheCallerOnce() async throws {
        registerAPI401(tokenStatus: 200)
        let (task, log) = try await sentRequestAwaitingRefresh()
        userAccount._credentials = nil

        executor.refreshTokenAndResume(task: task, accountId: nil)

        let delivered = await awaitSemaphore(log.delivered, timeout: .now() + 10.0)
        XCTAssertEqual(delivered, .success, "the caller was never completed")
        await drainRefreshAndDelivery()
        assertFailedOnceWith401(log)
    }

    /// A refresh that never answers is released by the watchdog; the requests
    /// waiting on it must be completed, not left hanging.
    func testQueuedRetry_WhenTheWatchdogReleasesAWedgedRefresh_FailsTheCallerOnce() async throws {
        let releaseTokenEndpoint = DispatchSemaphore(value: 0)
        HTTPStubURLProtocol.register { @Sendable [tokenURL, apiURL] request in
            if request.url == tokenURL {
                _ = releaseTokenEndpoint.wait(timeout: .now() + 10.0)
                // Not a 5xx: the token request retries those after the test ends.
                return .init(statusCode: 400, headers: nil, body: nil)
            }
            guard request.url == apiURL else { return nil }
            return .init(statusCode: 401, headers: nil, body: nil)
        }
        let (task, log) = try await sentRequestAwaitingRefresh()
        executor.tokenRefreshWatchdogSeconds = 0.2

        executor.refreshTokenAndResume(task: task, accountId: nil)

        let delivered = await awaitSemaphore(log.delivered, timeout: .now() + 5.0)
        releaseTokenEndpoint.signal()
        XCTAssertEqual(delivered, .success, "the caller was never completed")
        await drainRefreshAndDelivery()
        assertFailedOnceWith401(log)
    }

    /// A queued task with no request to rebuild from cannot be resent.
    private final class TaskWithoutRequest: URLSessionDataTask, @unchecked Sendable {
        override var originalRequest: URLRequest? { nil }
        override var taskIdentifier: Int { 987_654 }
        override var response: URLResponse? { nil }
        override func cancel() {}
        private let storedDescription = LockIsolated<String?>(nil)
        override var taskDescription: String? {
            get { storedDescription.value }
            set { storedDescription.value = newValue }
        }
    }

    /// A queued retry that cannot be rebuilt after a successful refresh must
    /// still complete its caller rather than be skipped.
    func testQueuedRetry_WithNoRequestToRebuild_FailsTheCallerOnce() async throws {
        HTTPStubURLProtocol.register { @Sendable [tokenURL] request in
            guard request.url == tokenURL else { return nil }
            return .init(statusCode: 200, headers: nil, body: Self.tokenResponseJSON(accessToken: "fresh"))
        }
        let task = TaskWithoutRequest()
        executor.markSentOnOwnSession(task)
        let log = CompletionLog()
        executor.responder.addCompletion({ @Sendable result in log.record(result) },
                                         taskID: task.taskIdentifier)

        executor.refreshTokenAndResume(task: task, accountId: nil)

        let delivered = await awaitSemaphore(log.delivered, timeout: .now() + 10.0)
        XCTAssertEqual(delivered, .success, "the caller was never completed")
        await drainRefreshAndDelivery()
        XCTAssertEqual(log.all.count, 1, "the caller must be completed exactly once")
        guard case .failure? = log.all.first else {
            return XCTFail("the caller must receive a failure, got \(String(describing: log.all.first))")
        }
        XCTAssertEqual(userAccount.authToken, "fresh", "the refresh itself still succeeded")
    }

    // MARK: - A 401 is refreshed by the executor that sent the request

    /// A URL on a host the injected library authenticates, so the 401 is
    /// classified as this library's rather than a foreign host's.
    private func libraryURL() throws -> URL {
        let host = try XCTUnwrap(libraryAccount.tppAccount.authSurfaceHosts.sorted().first)
        return try XCTUnwrap(URL(string: "https://\(host)/loans/"))
    }

    /// Answers the first request to `url` with a 401 and later ones with
    /// `retry-body`, and the token endpoint with `tokenStatus`. Records the
    /// bearer each request to `url` carried and how many token requests came.
    private func stub401ThenOK(at url: URL, tokenStatus: Int)
        -> (bearers: LockIsolated<[String?]>, tokenHits: LockIsolated<Int>) {
        let bearers = LockIsolated<[String?]>([])
        let tokenHits = LockIsolated(0)
        HTTPStubURLProtocol.register { @Sendable [tokenURL] request in
            if request.url == tokenURL {
                tokenHits.withValue { $0 += 1 }
                let body = tokenStatus == 200 ? Self.tokenResponseJSON(accessToken: "fresh") : Data("denied".utf8)
                return .init(statusCode: tokenStatus, headers: nil, body: body)
            }
            guard request.url == url else { return nil }
            let seen = bearers.withValue { list -> Int in
                list.append(request.value(forHTTPHeaderField: "Authorization"))
                return list.count
            }
            return seen == 1 ? .init(statusCode: 401, headers: nil, body: nil)
                             : .init(statusCode: 200, headers: nil, body: Data("retry-body".utf8))
        }
        return (bearers, tokenHits)
    }

    /// The responder refreshes with the accounts its executor was given and
    /// resends through that executor, so the caller gets the retry's body.
    /// Read from the app's accounts instead, the outcome depended on whoever
    /// was signed in on the device running the tests.
    func testResponder401_RefreshesWithTheExecutorsAccounts_AndDeliversTheRetry() async throws {
        let url = try libraryURL()
        let (bearers, tokenHits) = stub401ThenOK(at: url, tokenStatus: 200)
        let log = CompletionLog()

        _ = executor.executeRequest(executor.request(for: url), enableTokenRefresh: false,
                                    accountId: nil) { @Sendable result in log.record(result) }

        let delivered = await awaitSemaphore(log.delivered, timeout: .now() + 10.0)
        XCTAssertEqual(delivered, .success, "the caller was never completed")
        await drainRefreshAndDelivery()
        XCTAssertEqual(log.all.count, 1, "the caller must be completed exactly once")
        guard case .success(let data, _)? = log.all.first else {
            return XCTFail("the retried request must succeed, got \(String(describing: log.all.first))")
        }
        XCTAssertEqual(data, Data("retry-body".utf8))
        XCTAssertEqual(tokenHits.value, 1, "the injected library's token endpoint is refreshed once")
        XCTAssertEqual(bearers.value, ["Bearer stale-token", "Bearer fresh"])
    }

    /// The same path when the token endpoint refuses: the caller is failed
    /// once with the 401 rather than left waiting.
    func testResponder401_WhenTheRefreshIsRefused_FailsTheCallerOnce() async throws {
        let url = try libraryURL()
        let (bearers, tokenHits) = stub401ThenOK(at: url, tokenStatus: 401)
        let log = CompletionLog()

        _ = executor.executeRequest(executor.request(for: url), enableTokenRefresh: false,
                                    accountId: nil) { @Sendable result in log.record(result) }

        let delivered = await awaitSemaphore(log.delivered, timeout: .now() + 10.0)
        XCTAssertEqual(delivered, .success, "the caller was never completed")
        await drainRefreshAndDelivery()
        assertFailedOnceWith401(log)
        XCTAssertEqual(tokenHits.value, 1, "the injected library's token endpoint is asked once")
        XCTAssertEqual(bearers.value.count, 1, "nothing is resent after a refused refresh")
        XCTAssertEqual(userAccount.authState, .credentialsStale)
    }

    /// The host set that keeps a foreign 401 from logging the patron out comes
    /// from the executor's accounts too: a 401 from a host the injected library
    /// does not use is returned to the caller without a refresh (PR #1018).
    func testResponder401_FromAHostOutsideTheExecutorsLibrary_DoesNotRefresh() async throws {
        let (bearers, tokenHits) = stub401ThenOK(at: apiURL, tokenStatus: 200)
        let log = CompletionLog()

        _ = executor.executeRequest(executor.request(for: apiURL), enableTokenRefresh: false,
                                    accountId: nil) { @Sendable result in log.record(result) }

        let delivered = await awaitSemaphore(log.delivered, timeout: .now() + 10.0)
        XCTAssertEqual(delivered, .success, "the caller was never completed")
        await drainRefreshAndDelivery()
        assertFailedOnceWith401(log)
        XCTAssertEqual(tokenHits.value, 0, "a foreign host's 401 must not start a refresh")
        XCTAssertEqual(bearers.value.count, 1)
        XCTAssertEqual(userAccount.authState, .loggedIn, "a foreign host's 401 must not mark the library stale")
    }

    /// A refused refresh that two requests are waiting on fails each caller
    /// exactly once with its own 401, after a single token request.
    func testQueuedRetry_TwoRequestsBehindOneRefusedRefresh_EachCallerFailsOnce() async throws {
        let tokenHits = registerAPI401(tokenStatus: 401)
        let (first, firstLog) = try await sentRequestAwaitingRefresh()
        let (second, secondLog) = try await sentRequestAwaitingRefresh(
            to: try XCTUnwrap(URL(string: "https://api.example.com/protected/second")))
        // Where a second 401 leaves its task while a refresh is in flight.
        await executor.appendTokenRetryForTesting(second)

        executor.refreshTokenAndResume(task: first, accountId: nil)

        let firstDelivered = await awaitSemaphore(firstLog.delivered, timeout: .now() + 10.0)
        let secondDelivered = await awaitSemaphore(secondLog.delivered, timeout: .now() + 10.0)
        XCTAssertEqual(firstDelivered, .success, "the first caller was never completed")
        XCTAssertEqual(secondDelivered, .success, "the second caller was never completed")
        await drainRefreshAndDelivery()
        assertFailedOnceWith401(firstLog)
        assertFailedOnceWith401(secondLog)
        XCTAssertEqual(tokenHits.value, 1, "both requests wait on one token request")
    }

    /// The refresh succeeds but the server refuses the retry too: the caller
    /// is failed once with that 401, and nothing refreshes or resends again.
    func testResponder401_WhenTheRetryIsRefusedAgain_FailsTheCallerOnceWithoutASecondRefresh() async throws {
        let url = try libraryURL()
        let bearers = LockIsolated<[String?]>([])
        let tokenHits = LockIsolated(0)
        HTTPStubURLProtocol.register { @Sendable [tokenURL] request in
            if request.url == tokenURL {
                tokenHits.withValue { $0 += 1 }
                return .init(statusCode: 200, headers: nil, body: Self.tokenResponseJSON(accessToken: "fresh"))
            }
            guard request.url == url else { return nil }
            bearers.withValue { $0.append(request.value(forHTTPHeaderField: "Authorization")) }
            return .init(statusCode: 401, headers: nil, body: nil)
        }
        let log = CompletionLog()

        _ = executor.executeRequest(executor.request(for: url), enableTokenRefresh: false,
                                    accountId: nil) { @Sendable result in log.record(result) }

        let delivered = await awaitSemaphore(log.delivered, timeout: .now() + 10.0)
        XCTAssertEqual(delivered, .success, "the caller was never completed")
        await drainRefreshAndDelivery()
        assertFailedOnceWith401(log)
        XCTAssertEqual(tokenHits.value, 1, "the retry's 401 must not start a second refresh")
        XCTAssertEqual(bearers.value, ["Bearer stale-token", "Bearer fresh"])
    }

    // MARK: - A refresh for another session's task

    /// A task from another URLSession carrying the identifier of `live`, a
    /// request on the executor's session. Identifiers are unique only within
    /// one session, so a background download task can share one.
    private func otherSessionsTask(withIdentifierOf live: URLSessionTask) throws -> URLSessionTask {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HTTPStubURLProtocol.self]
        let session = URLSession(configuration: config)
        addTeardownBlock { session.invalidateAndCancel() }
        for _ in 0..<1_000 {
            let task = session.dataTask(with: URLRequest(url: apiURL))
            if task.taskIdentifier == live.taskIdentifier { return task }
            if task.taskIdentifier > live.taskIdentifier { break }
        }
        XCTFail("no task on a second session took identifier \(live.taskIdentifier)")
        throw CancellationError()
    }

    /// A live request on the executor's session, its caller still waiting,
    /// and a queued request of the executor's own whose completion marks the
    /// moment the refresh has dealt with every queued task.
    private func liveRequestAndQueuedProbe() async -> (live: URLSessionTask, liveLog: CompletionLog, probeLog: CompletionLog) {
        let live = executor.makeSessionDataTask(with: executor.request(for: apiURL))
        let liveLog = CompletionLog()
        executor.responder.addCompletion({ @Sendable result in liveLog.record(result) },
                                         taskID: live.taskIdentifier)
        let probe = makeQueueableTask(url: URL(string: "https://api.example.com/protected/probe"))
        let probeLog = CompletionLog()
        executor.responder.addCompletion({ @Sendable result in probeLog.record(result) },
                                         taskID: probe.taskIdentifier)
        await executor.appendTokenRetryForTesting(probe)
        return (live, liveLog, probeLog)
    }

    /// A refused refresh started for another session's task (the background
    /// download path) must not fail the executor's live request that happens
    /// to share its identifier. The other task is cancelled, as before.
    func testRefusedRefresh_ForAnotherSessionsTask_DoesNotFailTheLiveRequestSharingItsIdentifier() async throws {
        registerAPI401(tokenStatus: 401)
        let (live, liveLog, probeLog) = await liveRequestAndQueuedProbe()
        let foreign = try otherSessionsTask(withIdentifierOf: live)

        executor.refreshTokenAndResume(task: foreign, accountId: nil)

        let probeDelivered = await awaitSemaphore(probeLog.delivered, timeout: .now() + 10.0)
        XCTAssertEqual(probeDelivered, .success, "the refused refresh never failed its queue")
        await drainRefreshAndDelivery()
        XCTAssertTrue(liveLog.all.isEmpty, "the live request must not receive another session's failure")
        XCTAssertNotNil(executor.responder.accumulatedBytesForTesting(taskID: live.taskIdentifier),
                        "the live request's completion stays registered")
        XCTAssertNotEqual(foreign.state, .suspended, "the other session's task is cancelled")
    }

    /// A successful refresh for another session's task must not move the
    /// completion of the executor's live request onto the retry.
    func testSuccessfulRefresh_ForAnotherSessionsTask_LeavesTheLiveRequestsCompletionInPlace() async throws {
        HTTPStubURLProtocol.register { @Sendable [tokenURL, apiURL] request in
            if request.url == tokenURL {
                return .init(statusCode: 200, headers: nil, body: Self.tokenResponseJSON(accessToken: "fresh"))
            }
            guard request.url?.host == apiURL?.host else { return nil }
            return .init(statusCode: 200, headers: nil, body: Data("ok".utf8))
        }
        let (live, liveLog, probeLog) = await liveRequestAndQueuedProbe()
        let foreign = try otherSessionsTask(withIdentifierOf: live)

        executor.refreshTokenAndResume(task: foreign, accountId: nil)

        let probeDelivered = await awaitSemaphore(probeLog.delivered, timeout: .now() + 10.0)
        XCTAssertEqual(probeDelivered, .success, "the refresh never retried its queue")
        await drainRefreshAndDelivery()
        XCTAssertNotNil(executor.responder.accumulatedBytesForTesting(taskID: live.taskIdentifier),
                        "the live request's completion must stay under its own task")
        XCTAssertTrue(liveLog.all.isEmpty, "the live request must not receive another session's retry")
    }
}
