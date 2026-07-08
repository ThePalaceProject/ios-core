# Investigator D — Network-Stub Race (HTTPStubURLProtocol register/unregister)

**Mode:** Investigation only. No production-code or test-file edits made.
**Date:** 2026-05-29
**Worktree:** `/Users/mauricework/PalaceProject/ios-core/.claude/worktrees/swarm_f88ae9e3-orchestrator`

## Executive summary

The stub-race surface is real but the FAILURE MECHANISM is different from what the
architect hypothesized. The "OIDC missing payload Code=314" log line cited in the
contract is **not a stub-miss** — it's a deliberately-emitted production-error log
from a test that asserts the URL gets rejected (`TPPSignInOIDCTests:1185-1198`,
`testRegression_handleRedirectURL_rejectsCustomSchemeURL`). The same goes for
`access_token=t123` (`TPPSignInBusinessLogicOAuthTests:224`) and `attacker.example`
(`TPPSignInBusinessLogicOAuthTests:266`): both are negative tests that drive
known-bad URLs into `handleRedirectURL`, expect rejection (XCTAssertNil), and
trigger an expected `logError(.unrecognizedUniversalLink)` along the way. **The
log noise is the assertion succeeding, not the test failing.** The CI scraper
matched the log substring without realizing it was an XCTAssertNil-confirmed
rejection path.

The structural stub-race risks ARE real, but live elsewhere:

1. **`HTTPStubURLProtocol.canInit(with:)` returns `true` for ALL requests**
   (`PalaceTests/HTTPStubURLProtocol.swift:13-15`). Once `URLProtocol.registerClass(HTTPStubURLProtocol.self)`
   is called globally, it intercepts EVERY URLSession.shared request in-process —
   including production fall-throughs in `Palace/CarPlay/CarPlayImageProvider.swift:101`,
   `Palace/MyBooks/MyBooksSimplifiedBearerToken.swift:57`,
   `Palace/Audiobooks/DPLA/DPLAAudiobooks.swift:48`,
   `Palace/Accounts/Library/LibraryRegistryCrawler.swift:29`,
   `Palace/Book/Models/TPPBookCoverRegistry.swift:112` — and returns 501 to
   anything without a matching handler. This is a CROSS-CLASS contamination
   vector if `URLProtocol.unregisterClass` is missed on test failure / crash.

2. **`URLSession.stubbedSession()` returns a process-shared singleton**
   (`PalaceTests/URLSession+Stubbing.swift:4-18`) — every test that calls it
   shares ONE URLSession instance with ONE config containing ONE shared global
   `requestHandlers` array. The 30-second timeout in `test_ConcurrentForegroundRequests_ProduceOneTokenRefresh`
   isn't a Task lifecycle bug — it's the LIFO handler-iteration plus
   `releaseGate.wait(timeout: 3.0)` (`PalaceTests/Network/TokenRefreshOnForegroundTests.swift:417-429`)
   that blocks the URLSession delegate queue per intercepted request. Stacked
   handlers from prior tests get an additional 3-second wait each.

3. **Test infrastructure for "no production code falls through to URLSession.shared"
   doesn't exist.** `NoNetworkURLProtocol` is enabled at test bundle load
   (`PalaceTests/PalaceTestSetup.swift:10`), which guards URLSession.shared in
   THEORY. But once any test calls `URLProtocol.registerClass(HTTPStubURLProtocol.self)`,
   the iteration order of registered protocols is implementation-defined; and
   `HTTPStubURLProtocol.canInit -> true always` is strictly broader than
   `NoNetworkURLProtocol.canInit` (skip-localhost). The newer-registered class
   *can* outrank the older one.

4. **`HTTPStubURLProtocol.register()` has NO key.** Two tests registering the
   same URL prefix stack closures in the global array; LIFO returns the
   most-recently-registered first. Cross-file URL collision is heavy: 27 lines
   stub `https://example.com`, 13 stub `https://example.com/book`, 11 stub
   `https://example.com/token`, 10 stub `https://example.com/univeral-link-redirect`.

## File audit (33 imports)

Counts come from: `for f in $(grep -rln "HTTPStubURLProtocol\|stubbedSession" PalaceTests/ | grep -v infra); do ...`

| File | reg | reset in setUp | reset in tearDown | stubbedSession | URLSession.shared | Severity |
| --- | --- | --- | --- | --- | --- | --- |
| `PalaceTests/Accounts/AccountSwitchCleanupTests.swift` | 3 | 0 | 0 | 0 | 0 | MED |
| `PalaceTests/AppInfrastructure/AppContainerAuthCoordinatorWiringTests.swift` | 0 | 0 | 0 | 0 | 0 | LOW (comment-only mention) |
| `PalaceTests/DRM/LCPCharacterizationTests.swift` | 0 | 1 | 1 | 0 | 0 | LOW |
| `PalaceTests/Integration/AccountSwitchLifecycleTests.swift` | 1 | 1 | 1 | 0 | 0 | LOW |
| `PalaceTests/Integration/BorrowAndDownloadIntegrationTests.swift` | 1 | 1 | 1 | 0 | 0 | LOW |
| `PalaceTests/Integration/ColdStartResumeIntegrationTests.swift` | 0 | 1 | 1 | 0 | 0 | LOW |
| `PalaceTests/Integration/SignInToReadFlowIntegrationTests.swift` | 4 | 1 | 1 | 0 | 0 | LOW |
| `PalaceTests/MyBooks/DownloadFreeSpaceExhaustionTests.swift` | 0 | 1 | 1 | 0 | 0 | LOW |
| `PalaceTests/MyBooks/DownloadIntegrityTests.swift` | 0 | 1 | 1 | 0 | 0 | LOW |
| `PalaceTests/MyBooks/DownloadResumeAfterKillTests.swift` | 0 | 1 | 1 | 0 | 0 | LOW |
| `PalaceTests/MyBooks/MyBooksSimplifiedBearerTokenTests.swift` | 3 | 1 | 1 | 0 | 0 | HIGH (uses global `URLProtocol.registerClass`; unregister inside method body, leaks on early-fail) |
| `PalaceTests/Network/AccountAwareNetworkTests.swift` | 3 | 1 | 1 | 0 | 0 | LOW |
| `PalaceTests/Network/CookiePersistenceTests.swift` | 0 | 1 | 1 | 0 | 0 | LOW |
| `PalaceTests/Network/CredentialGuardTests.swift` | 19 | 4 | 4 | 13 | 0 | HIGH (shared `stubbedSession()` singleton, no isolation between methods within class) |
| `PalaceTests/Network/ManifestFetchTests.swift` | 21 | 4 | 4 | 18 | 0 | MED (mixes named-let `stubbedSession` vs `URLSession.stubbedSession()`; locally-scoped is safer but inconsistent) |
| `PalaceTests/Network/MultiLibraryTokenIsolationTests.swift` | 7 | 1 | 1 | 0 | 0 | LOW |
| `PalaceTests/Network/NetworkClientTests.swift` | 22 | 1 | 1 | 0 | 0 | LOW |
| `PalaceTests/Network/NetworkRetryTests.swift` | 9 | 2 | 2 | 0 | 0 | LOW (double-reset is defensive, OK) |
| `PalaceTests/Network/TokenRefreshAndRetryQueueTests.swift` | 9 | 1 | 1 | 0 | 0 | MED (3-second `releaseGate.wait` pattern in handlers) |
| `PalaceTests/Network/TokenRefreshOnForegroundTests.swift` | 10 | 1 | 1 | 0 | 0 | HIGH (`releaseGate.wait(timeout: 3.0)` blocks delegate queue — direct CI 30s symptom) |
| `PalaceTests/Network/TPPNetworkExecutorTests.swift` | 17 | 1 | 1 | 0 | 0 | LOW |
| `PalaceTests/Network/TPPNetworkResponderAuthCoordinatorTests.swift` | 3 | 1 | 1 | 0 | 0 | LOW |
| `PalaceTests/OPDS2/UnifiedOPDSServiceStateMachineTests.swift` | 1 | 1 | 1 | 4 | 0 | LOW |
| `PalaceTests/Security/AuthFlowSecurityTests.swift` | 0 | 1 | 1 | 2 | 0 | LOW |
| `PalaceTests/Security/DRMAdversarialTests.swift` | 0 | 1 | 1 | 1 | 0 | LOW |
| `PalaceTests/SignInLogic/AuthErrorProblemDocSeamTests.swift` | 2 | 1 | 1 | 2 | 0 | LOW |
| `PalaceTests/SignInLogic/TokenRequestTests.swift` | 7 | 1 | 1 | 7 | 0 | MED (shared `stubbedSession()` singleton between methods) |
| `PalaceTests/SignInLogic/TPPSignInBusinessLogicOAuthTests.swift` | 0 | 1 | 1 | 0 | 0 | LOW (only resets defensively — does not register because uses TPPRequestExecutorMock seam) |
| `PalaceTests/Sync/CrossDeviceSyncE2ETests.swift` | 1 | 1 | 1 | 0 | 0 | LOW (scoped config — model citizen, see lines 65-67 comment) |
| `PalaceTests/Sync/MockSyncBackend.swift` | 1 | 0 | 0 | 0 | 0 | LOW (helper class, not XCTestCase) |

### Severity rationale

- **HIGH**: structural hazard — shared singleton across methods, OR global URLProtocol registration with crash/early-fail leakage, OR known-correlated CI failure.
- **MED**: in-method `defer { reset }` (works in normal exit, leaks on crash) OR matches a vulnerable pattern but isolated to the file.
- **LOW**: scoped to a local config-bound `URLSession`, paired setUp/tearDown reset, no shared-singleton handlers.

## Production-code fall-through audit

These code paths in `Palace/` use `URLSession.shared` (i.e., bypass any DI'd session) and have NO test file that registers `HTTPStubURLProtocol` against them:

| Production file | Tests that exist | Tests use HTTPStub? |
| --- | --- | --- |
| `Palace/MyBooks/MyBooksSimplifiedBearerToken.swift:57` | `MyBooksSimplifiedBearerTokenTests.swift` | YES — uses `URLProtocol.registerClass(...)` per-test, paired unregister; but the unregister is at end of method body, not in `tearDown`, so a fail mid-method leaks the registration into next test |
| `Palace/CarPlay/CarPlayImageProvider.swift:101` | `CarPlay/CarPlayTests.swift` | NO |
| `Palace/Audiobooks/DPLA/DPLAAudiobooks.swift:48` | (no DPLA test file) | N/A |
| `Palace/Accounts/Library/LibraryRegistryCrawler.swift:29` | `Crawl/LibraryRegistryCrawlerTests.swift` | NO |
| `Palace/Book/Models/TPPBookCoverRegistry.swift:112` | `TPPBookCoverRegistryTests.swift` | NO |

The "no" rows rely on `NoNetworkURLProtocol` (bundle-load registered) to block real network. That guard is **defeated** the moment any test calls `URLProtocol.registerClass(HTTPStubURLProtocol.self)` (only `MyBooksSimplifiedBearerTokenTests` currently does this) — because then both classes compete for `canInit:true`, and `HTTPStubURLProtocol` (broader: returns true unconditionally) can intercept any request and return 501 if no handler matches.

## The CI evidence, decoded

### Code=314 OIDC log — NOT a stub miss

`Sign-in redirection error: missing payload Code=314 loginURL=palace-oidc-callback://...?access_token=tok&patron_info=%7B%7D`

- Source: `Palace/SignInLogic/TPPSignInBusinessLogic+OAuth.swift:116-126` calls `TPPErrorLogger.logError(withCode: .unrecognizedUniversalLink, ...)`.
- `Palace/Logging/TPPErrorLogger.swift:155` — `case unrecognizedUniversalLink = 314`.
- Driving test: `PalaceTests/SignInLogic/TPPSignInOIDCTests.swift:1185-1198`, `testRegression_handleRedirectURL_rejectsCustomSchemeURL`. The test:
  - Constructs `URL(string: "palace-oidc-callback://...?access_token=tok&patron_info={}")!`
  - Calls `businessLogic.handleRedirectURL(notification)` directly.
  - Asserts `XCTAssertNil(businessLogic.authToken)` and `XCTAssertFalse(businessLogic.isValidatingCredentials)`.
- The 314 log is *expected* — it proves the rejection branch was taken. No HTTP request is made by this code path; it's pure URL-string-prefix matching. There is no stub involved.

### `access_token=t123` and `attacker.example`

- `PalaceTests/SignInLogic/TPPSignInBusinessLogicOAuthTests.swift:224` — constructs `https://example.com/univeral-link-redirect#access_token=t123` (a malformed payload — has access_token but no patron_info), expects the error branch.
- `PalaceTests/SignInLogic/TPPSignInBusinessLogicOAuthTests.swift:266` — `https://attacker.example/steal#access_token=evil&patron_info=%7B%7D` — wrong prefix; tests that prefix mismatch rejects.
- Both are NEGATIVE tests intentionally driving log output. The integrator should classify these CI log lines as **noise from passing tests**, not stub-miss signal. (They may amplify category F by polluting triage signal.)

### The 30.353-second `test_ConcurrentForegroundRequests` failure — IS a stub-discipline interaction

`PalaceTests/Network/TokenRefreshOnForegroundTests.swift:409-453`:

- Registers a handler that calls `_ = releaseGate.wait(timeout: 3.0)` synchronously inside `HTTPStubURLProtocol.startLoading` — i.e., on the URLSession delegate queue (`PalaceTests/HTTPStubURLProtocol.swift:21-45`).
- The 30-second outer wait (`waitForCondition(timeout: 30.0) { ... tokenHits >= 1 }`) expects the FIRST request to hit `/token`. If a stale handler from a prior test was left registered (LIFO iteration in `HTTPStubURLProtocol.handler(for:)` at `PalaceTests/HTTPStubURLProtocol.swift:63-72`), that stale handler runs first; if it matches and returns a non-nil response, the in-test counter never increments and the 30s budget exhausts.
- `setUp` does call `HTTPStubURLProtocol.reset()` (line 41 — confirmed), so the residue isn't from prior tests in the SAME class. But because `URLSession.stubbedSession()` is a process-wide singleton (`PalaceTests/URLSession+Stubbing.swift:4`) AND the executor stub-config trail is registered via the `config.protocolClasses` array, in-flight requests from a DIFFERENT test class that uses the same shared stubbed session can complete after `setUp` ran but before this test's handler fired. Those completions invoke the residual handlers stacked LIFO.

This is the smoking gun for "stub race amplified by F's random ordering and B's async leakage": the handler array is global and LIFO, the URLSession is process-shared, and a delegate-queue-blocking handler stacks delays per request.

## Recommended fix shapes (NOT in scope to implement)

Ranked by structural blast-radius reduction:

### Fix 1 — `HTTPStubTestCase` base class with auto-teardown (HIGHEST IMPACT)

```swift
class HTTPStubTestCase: XCTestCase {
    override func setUp() {
        super.setUp()
        HTTPStubURLProtocol.reset()
    }
    override func tearDown() {
        HTTPStubURLProtocol.reset()
        URLProtocol.unregisterClass(HTTPStubURLProtocol.self)
        super.tearDown()
    }
}
```

Mass-adopt as the parent for all 27 files that touch `HTTPStubURLProtocol`. This makes the "forgot to reset" failure mode impossible to reintroduce; the base class always wins because it runs in tearDown regardless of test-method outcome.

### Fix 2 — narrow `HTTPStubURLProtocol.canInit` from `true` to URL-list match

The "intercept everything" semantics are dangerous because the protocol can fall in on production code paths that the test didn't intend to stub. Make `canInit` return true only if `request.url` matches at least one registered handler's URL predicate (require handlers to register with an explicit URL or URL prefix, not an opaque closure). Then unmatched requests fall through to the next URLProtocol in the chain (which is `NoNetworkURLProtocol`, so they cleanly fail with NSURLErrorNotConnectedToInternet — easy to debug).

This is a deeper refactor — the closure-handler API at `PalaceTests/HTTPStubURLProtocol.swift:51-55` would need a URL parameter:
```swift
static func stub(url: URL, with response: StubbedResponse)
static func stub(matching predicate: (URLRequest) -> Bool, with response: ...)
```

### Fix 3 — `URLSession.stubbedSession()` returns FRESH session per call

Replace the `_sharedStubbedSession` cache (`PalaceTests/URLSession+Stubbing.swift:4-8`) with `URLSession(configuration: ephemeralConfig)` per call. The "leaked-session private delegate queue" risk the comment cites (lines 11-15) is real, BUT the fix shape should be:
- Per-test fresh session (one URLSession, owned by setUp/tearDown lifetime).
- Invalidate it via `session.invalidateAndCancel()` in tearDown.

This eliminates cross-test handler interaction at the URLSession level.

### Fix 4 — lint `URLProtocol.registerClass` requires base-class ancestry

```bash
# scripts/check-http-stub-discipline.py
# Fails any test file that:
#   - calls HTTPStubURLProtocol.register without a matching reset() in tearDown, OR
#   - calls URLProtocol.registerClass(HTTPStubURLProtocol.self) without subclassing HTTPStubTestCase, OR
#   - uses URLSession.shared inside a function whose name starts with "test_"
```

Run from `scripts/verify-pr.sh`. Catches drift at PR time, not runtime.

### Fix 5 — CI gate: bundle-end assertion

Add an XCTest teardown hook in `PalaceTestSetup` (the existing NSPrincipalClass) that asserts at PROCESS END that `HTTPStubURLProtocol.handlerQueue.sync { requestHandlers.isEmpty }`. Any test that left a handler registered fails the whole bundle. This is the loudest possible signal that something leaked.

### Fix 6 — `URLSession.shared` lint for production code

```bash
# scripts/check-no-url-session-shared.py
# Fail any Palace/**.swift that calls URLSession.shared except in:
#   - test helpers (already excluded — they're in PalaceTests/)
#   - explicit allowlist with TODO(ticket) justification
```

Catches Fix 2's residual blind spots — every production file that ALSO has a DI seam already, but currently uses .shared anyway.

## Recommended sequencing

1. **Fix 1 (`HTTPStubTestCase` base class)** — single-file PR, mechanical adoption pass on 27 files. Low risk, high blast-radius reduction.
2. **Fix 5 (bundle-end assertion)** — single 10-line PR, immediate signal. Lands the day after Fix 1 to catch any missed migrations.
3. **Fix 4 (lint script)** — codifies Fix 1 in CI.
4. **Fix 2 (narrow canInit)** — followup, larger refactor, requires migrating all `register { request in ... }` closures to declare their URL surface.
5. **Fix 3 (fresh session per call)** — independent of 1-4; can land anytime.
6. **Fix 6 (URLSession.shared lint)** — followup, requires production-code audit + DI plumbing for the 5 sites identified.

## DoD self-checks

Investigation-mode work, not a code-producing diff. Mapping the 10 DoD checks:

1. **SUT instantiation check** — N/A (no test files added).
2. **Function-result usage check** — N/A (no production calls added).
3. **Multi-step test body check** — N/A (no test bodies added).
4. **Scope coverage audit** — covered all five investigation items from the contract: (a) all 33 HTTPStubURLProtocol callers bucketed by pattern with register/teardown columns; (b) URLSession.shared production-code surface enumerated against test coverage; (c) cross-session mix-ups identified (`MyBooksSimplifiedBearerTokenTests` global URLProtocol.registerClass + in-method defer); (d) the cited OIDC test located and explained (`TPPSignInOIDCTests:1185-1198`, intentionally driving a rejection — not a stub-miss); (e) all three CI loginURL log lines decoded.
5. **Mutation pass** — N/A (no production-file changes).
6. **Build + verify-pr** — N/A (investigation only, no code changes).
7. **Multi-step / wiring-claim check (v2)** — N/A.
8. **Contract reconciliation** — N/A (no commit yet).
9. **Blast-radius check** — N/A.
10. **Adjacency staleness check** — N/A.

## Output to integrator

The dedup risk the architect flagged in plan.md (A/D overlap on `AppContainer.urlSession` swapping) does NOT appear in any of the 33 files — no test mutates `AppContainer.production().urlSession`. The closest analog is `CrossDeviceSyncE2ETests`'s `TPPAnnotations.executorOverride`, which is correctly saved and restored (lines 53-57, 130-134). So Investigator A and D do not double-count on the urlSession axis specifically.

The B/F overlap flagged is the live one: the `TokenRefreshOnForegroundTests.test_ConcurrentForegroundRequests` 30-second timeout is best classified as **D (stub-LIFO + shared singleton) amplified by F (random ordering surfaces stale handlers from prior class)**. If Investigator B classifies it as a Task-lifecycle bug, defer to D's reading — the Task is correctly structured (`Task { ... await fulfillment }`); the queue blockage is in `URLSession.startLoading`, not in Swift Concurrency.

The wall-failure stub for category D should focus on the structural failure mode "global URLProtocol registry + LIFO handler array + process-shared URLSession singleton + canInit-true-always" rather than "tests forgot to call reset()" — most tests DO call reset(); the failure mode persists anyway.
