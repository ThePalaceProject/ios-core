# Wave-2 wall-clock-wait conversion — module `SignInLogic`

Worktree: `swarm_ad0b4c65-w2-signin` (seam commit `b4e6ba841`, not branched further)
Scope: `PalaceTests/SignInLogic/` only. No production or other-module files touched.

## Bottom line

**Zero conversions applied. Zero files modified.**

Grep-verified: no `Thread.sleep|usleep|asyncAfter.*fulfill|while.*Date().*<`
anywhere in `PalaceTests/SignInLogic/*.swift` (DELETE bucket is empty), and —
critically — **no test in this directory instantiates the real
`TPPNetworkExecutor` or `TokenRefreshInterceptor`** (the two seams this module
was assigned):

```
$ grep -rn "TPPNetworkExecutor(\|= TPPNetworkExecutor\|TokenRefreshInterceptor(" PalaceTests/SignInLogic/*.swift
(no output)
```

Every SignInLogic test that exercises network/token flow does so through a
local test double — `TPPRequestExecutorMock`, `TPPNetworkErrorMock`,
`TokenRefresherMock` — never the concrete seamed classes. Per the playbook's
inviolable rule ("If a wait does NOT map to an enumerated seam, do NOT invent
one"), none of those waits could be safely CONVERTed. This is a real finding,
not a shortcut: the seam catalog's `TPPNetworkExecutor._awaitInFlightForTesting()`
/ `TokenRefreshInterceptor._awaitAuthDispatchForTesting()` have no applicable
call site inside this module's own test dir.

## Verification

```
$ grep -c 'wait(for:\|waitForExpectations\|fulfillment(of:' PalaceTests/SignInLogic/*.swift
```
(per-file counts below; before == after everywhere, since 0 files changed)

## Per-file tally (87 total occurrences, all files unchanged)

| File | Count | Bucket | Why |
|---|---:|---|---|
| AuthErrorProblemDocSeamTests.swift | 0 | — | no wait/expectation |
| AuthReducerTests.swift | 0 | — | no wait/expectation |
| EffectBoundaryTests.swift | 0 | — | no wait/expectation |
| ForceResetTests.swift | 0 | — | no wait/expectation |
| **LegacySAMLProblemDocumentPropagationTests.swift** | 5 | **KEEP** | `handler(problemDoc)` → `LegacySAMLWebViewPresenter.makeProblemFoundHandler()` dispatches via `TPPMainThreadRun.asyncIfNeeded`, which runs the block **synchronously** when already on the main thread (confirmed: `if Thread.isMainThread { work() }` — `TPPMainThreadChecker.swift:53-56`). Test class is `@MainActor`. `expectation.fulfill()` fires before `wait(for:)` is ever reached — direct synchronous callback, no async hop. |
| **ScopedResetTests.swift** | 1 | **UNMAPPED** | `performScopedReset` completion fires via a real `DispatchQueue.main.async` inside `TPPSignInBusinessLogic+ForceReset.swift:354` (after `removeScopedWebCookies`). No catalog seam on `TPPSignInBusinessLogic`. Legitimate callback-driven wait, just unmapped. |
| **SignInModalLifecycleTests.swift** | 1 | **UNMAPPED** | `TPPReauthenticator.authenticateIfNeeded` wraps its body in `Task { @MainActor in }` (`TPPReauthenticator.swift:99`) — genuine Task scheduling hop, no catalog seam on this class. |
| SignInModalPredicateTests.swift | 0 | — | |
| SignInModalSAMLOIDCTests.swift | 0 | — | |
| **SignInOAuthErrorPropagationTests.swift** | 8 | **KEEP** | All exercise `TPPSignInBusinessLogic.handleRedirectURL(_:completion:)` (`TPPSignInBusinessLogic+OAuth.swift:85`), which is **fully synchronous** — every branch calls `completion?(...)` inline, no dispatch/Task anywhere in the method. Completion fires before `wait(for:)`. |
| **SignInWebSheetIntegrationTests.swift** | 2 | **KEEP** | Real `WKWebView` cold-start (`await fulfillment(of:...timeout: 30.0)` / `15.0`), already annotated `// FLAKE-003-OK` — 3rd-party completion with no production seam possible (bucket-3 rule). |
| SignInWebSheetViewModelTests.swift | 0 | — | |
| TokenRequestTests.swift | 0 | — | |
| **TPPAccountAuthStateTests.swift** | 2 | **KEEP** | `credentialsStalePublisher` / `authStateDidChangePublisher` are plain `$authState`-derived Combine publishers (`UserAccountPublisher.swift:75-88`), no `.receive(on:)` — `.sink` fires synchronously inside `markLoggedIn()`/`markCredentialsStale()`. Direct synchronous callback. |
| TPPAgeCheckIsValidTests (in TPPAgeCheckDeepTests.swift) | 0 | — | pure logic, no waits |
| **TPPAgeCheckDeepTests.swift** (Completion + VerifyDecision classes) | 5 | **UNMAPPED** | `TPPAgeCheck.verifyCurrentAccountAgeRequirement` / `didCompleteAgeCheck` always complete via its own private `serialQueue.async` (`TPPAgeCheck.swift:89,95,110,125`). The class DOES have an in-file test-only drain (`flushPendingForTests()`, `TPPAgeCheck.swift:225`, already used elsewhere in the same file) but it is **not** one of the Wave-2 enumerated catalog seams — per the inviolable rule I did not invent a conversion onto it. Flagging as a Wave-3 candidate: `TPPAgeCheck.flushPendingForTests()` could plausibly retire the `wait(for: […], timeout: 30.0)` at line 180 if the orchestrator wants to add it to the catalog. |
| TPPAuthDocumentContractTests.swift | 0 | — | |
| TPPBasicAuthTests.swift | 0 | — | |
| TPPCredentialsCoverageTests.swift | 0 | — | |
| TPPCredentialSnapshotCoherenceTests.swift | 0 | — | |
| TPPCredentialsTests.swift | 0 | — | |
| **TPPCredentialVisibilityTests.swift** | 14 | **UNMAPPED** | Two shapes, neither maps to the catalog: (1) `validateCredentials()` / `logIn()` / `finalizeSignIn` chains that route through `TPPRequestExecutorMock.executeRequest`, whose completion is wrapped in a genuine `DispatchQueue.main.async` (`NYPLNetworkExecutorMock.swift:103`) — a test-double async hop, not the real `TPPNetworkExecutor`; (2) `TPPCredentialConcurrencyTests` (lines 733, 774) which fan out raw `DispatchQueue.global().async` stress-test blocks directly in the test body (no production class to seam at all). |
| **TPPCrossLibrarySignOutTests.swift** | 4 | **UNMAPPED** | All via `performLogOut()` → `networker.executeRequest` → mock's `DispatchQueue.main.async`. Same shape as above, no catalog seam. |
| **TPPDeferredAdobeActivationTests.swift** | 5 | **2 KEEP / 3 UNMAPPED** | Lines 116, 138 (`TPPSaveDRMCredentialsTests`) call `saveDRMCredentials(...)` which falls straight through to `finalizeSignIn(forDRMAuthorization:)` — synchronous via `TPPMainThreadRun.asyncIfNeeded` on-main fast path → **KEEP**. Lines 207, 225, 256 (`TPPLoginNoActivationTests`) call `validateCredentials()` → mock async hop → **UNMAPPED**. |
| TPPIdleSignOutRegressionTests.swift | 17 | **OUT OF SCOPE (per dispatch)** | Timer-driven idle-sign-out tests; explicitly called out as KEEP/UNMAPPED-and-do-not-touch in the dispatch (inject-clock is a production change, out of this module's scope). Not Task-joined, not re-bucketed line-by-line, left byte-for-byte. |
| TPPPreferredAuthSelectionTests.swift | 0 | — | |
| TPPReauthenticatorTests.swift | 0 | — | |
| TPPSAMLFlowTests.swift | 0 | — | |
| TPPSAMLLogoutTests.swift | 0 | — | |
| **TPPSAMLSignInTests.swift** | 1 | **KEEP** | `finalizeSignIn(forDRMAuthorization: true)` synchronous via `TPPMainThreadRun.asyncIfNeeded` on-main fast path (test class is `@MainActor`); `signedIn.fulfill()` already fires before `wait(for:)`. Comment in the test explicitly documents this replaced an older fixed-delay `asyncAfter` pattern. |
| **TPPSignInAdobeSkipTests.swift** | 3 | **KEEP** | Line 121: `ensureAuthenticationDocumentIsLoaded` hits the `libraryAccount?.details != nil` fast path and calls `completion(true)` synchronously (`TPPSignInBusinessLogic.swift:786-788`). Line 227: `NotificationCenter.default.post(name: .TPPIsSigningIn, object: true)` inside `logIn()` (`TPPSignInBusinessLogic.swift:673`) delivers to `XCTNSNotificationExpectation` synchronously (default `NotificationCenter.post` is synchronous). Line 242: test-authored `DispatchQueue.main.async { assert…; fulfill() }` wrapped around a check that is already true synchronously (`businessLogicWillSignIn` also goes through the on-main-synchronous `TPPMainThreadRun.asyncIfNeeded` path) — redundant but harmless, no owning-class seam applies, left as-is. |
| **TPPSignInBusinessLogicExtendedTests.swift** | 2 | **UNMAPPED** | `performLogOut()` → mock async hop, no catalog seam. |
| **TPPSignInBusinessLogicOAuthTests.swift** | 4 | **UNMAPPED** | `getBearerToken(...)` wraps its callback in `Task { @MainActor in … }` (`TPPSignInBusinessLogic.swift:540`) — genuine Task scheduling hop; the seam-friendly overload takes a `TokenRefreshing`-typed **test-local** `TokenRefresherMock` (synchronous inline reply), not the real `TokenRefreshInterceptor`, so the catalog seam doesn't attach. One more via `TPPNetworkErrorMock` (same shape as `TPPRequestExecutorMock`). |
| **TPPSignInBusinessLogicSignOutTests.swift** | 5 | **UNMAPPED (already well-optimized)** | This file is the best-designed one in the module: it already uses `drmAuthorizer._awaitDeauthorizeCalledForTesting()` (a mock-owned deterministic join, replacing a former `Timer.scheduledTimer` poll — see its own inline comments) and `await drainMainQueueAsync()` for the coalescing check. The 5 remaining `wait(for:)`/`fulfillment(of:)` calls bridge the *final* `didFinishDeauthorizingHandler` completion, which still has no catalog seam (it terminates a chain that starts with the mock's network `DispatchQueue.main.async`). Nothing further to convert without inventing a new seam. |
| **TPPSignInBusinessLogicStateMachineTests.swift** | 1 | **KEEP (already exemplary)** | `testLogIn_racingAuthDocLoad_firesRequestOnceReady` already uses the mock's own `onExecuteRequest` hook (fires synchronously the instant `executeRequest` records a URL) as a deterministic join instead of polling — its own comment says "JOIN, don't poll." Nothing to improve; not touched. |
| **TPPSignInOIDCTests.swift** | 7 | **UNMAPPED** | All via `handleOIDCCallback(...)` (→ `validateCredentials()` on success) or `performLogOut()` — same mock `DispatchQueue.main.async` shape, no catalog seam. |
| UserAccountValidationTests.swift | 0 | — | |

## Bucket totals

- **CONVERT:** 0
- **DELETE:** 0 (grep for `Thread.sleep|usleep|asyncAfter.*fulfill|while.*Date().*<` across the whole dir returned nothing)
- **KEEP:** 24 (LegacySAML 5, SignInOAuthErrorProp 8, SignInWebSheetIntegration 2, TPPAccountAuthState 2, TPPDeferredAdobeActivation 2, TPPSAMLSignIn 1, TPPSignInAdobeSkip 3, TPPSignInBusinessLogicStateMachine 1)
- **UNMAPPED:** 46 (ScopedReset 1, SignInModalLifecycle 1, TPPAgeCheckDeep 5, TPPCredentialVisibility 14, TPPCrossLibrarySignOut 4, TPPDeferredAdobeActivation 3, TPPSignInBusinessLogicExtended 2, TPPSignInBusinessLogicOAuth 4, TPPSignInBusinessLogicSignOut 5, TPPSignInOIDC 7)
- **Out-of-scope (dispatch-excluded):** 17 (TPPIdleSignOutRegressionTests — Timer-driven, untouched per instructions)
- **Total:** 24 + 46 + 17 = 87, matching the raw grep count. No silent drops.

## Bounded-await proof

N/A — zero conversions means zero new `await`s were introduced. No bare
`await someTask.value` on a raw handle anywhere in this diff (there is no
diff).

## UNMAPPED list for the orchestrator (Wave-3 candidates)

1. **`TPPSignInBusinessLogic`** has no `_awaitXxxForTesting()` seam at all
   (confirmed via `grep -rn "ForTesting\|_await" Palace/SignInLogic/*.swift` →
   no output). Every network-driven completion in this class
   (`validateCredentials`, `logIn`, `performLogOut`, `getBearerToken`,
   `handleOIDCCallback`, `performScopedReset`) ultimately depends on either a
   real `DispatchQueue.main.async` inside the test's `TPPRequestExecutorMock`
   double, or a `Task { @MainActor in }` hop with no join point. If Wave-3
   wants to convert the 46 UNMAPPED waits above, the natural seam would be a
   `TPPSignInBusinessLogic._awaitInFlightWorkForTesting()` (or similar) that
   grow-until-stable-joins any outstanding Task/dispatch the business logic
   spawned — but that is a **production change**, out of this module's
   test-only scope.
2. **`TPPAgeCheck`** already has an in-class `flushPendingForTests()`
   (`serialQueue.sync {}`) that isn't in the Wave-2 catalog; 5 waits in
   `TPPAgeCheckDeepTests.swift` could likely drop straight to synchronous
   assertions if it were added to the catalog (no production change needed —
   the seam already exists).
3. **`TPPCredentialConcurrencyTests`** (2 waits, lines 733/774 of
   `TPPCredentialVisibilityTests.swift`) drives raw `DispatchQueue.global().async`
   fan-out directly in the test body against `TPPUserAccountMock` — there is no
   production class to seam here; these are inherently a concurrency stress
   test and the wait is legitimate as-is.

## Files changed

None. `PalaceTests/SignInLogic/*.swift` — read-only pass, zero writes.
Verified via `git status` / `git diff` in the worktree at the end of the pass:
clean, no changes.
