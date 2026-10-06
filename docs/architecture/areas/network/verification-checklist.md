---
name: network-verification-checklist
type: evolving
status: active
created: 2026-05-28
last_refresh: 2026-10-06
freshness_window: 180d
owners: [network]
description: Per-area verification reference; refresh before next swarm/rigorous-fix
# The code this checklist describes, and the develop commit it was last checked against.
# If any of these files changed since `verified_ref`, re-check the line citations below:
#   git diff --stat <verified_ref> -- <paths>
# `fingerprint` is reproducible with plain git from the repo root (paths in any order):
#   git ls-tree <verified_ref> -- <paths> | git hash-object --stdin | cut -c1-8
sources:
  verified_ref: 4c65025be5a40bfdbe0da6dbd14f4158744d1397
  last_verified: 2026-10-06
  fingerprint: '6d3df409'
  paths:
    - Palace/Network/TPPNetworkResponder.swift
    - Palace/Network/TPPNetworkExecutor.swift
    - Palace/Network/TPPNetworkQueue.swift
    - Palace/Packages/PalaceAuth/Sources/PalaceAuth/AuthErrorClassifier.swift
    - Palace/Packages/PalaceAuth/Sources/PalaceAuth/URLResponse+TPPAuthentication.swift
    - Palace/MyBooks/TokenRefreshInterceptor.swift
    - Palace/MyBooks/DownloadAuthRetryHandler.swift
---

<!-- audit-verified: Owner files in Palace/Network/ confirmed by `ls Palace/Network/` (Core/, TPPNetworkExecutor.swift, TPPNetworkExecutor+AccountNetworking.swift, TPPNetworkResponder.swift, TPPNetworkQueue.swift, TPPRequestExecuting.swift, TPPUserFriendlyError.swift, BundledHTMLViewController.swift, RemoteHTMLViewController.swift). Line citations in Sections 1, 4, 5, 7, 7b and 8 re-verified by grep against develop at 3ad580c0d (2026-10-05). The classifier migration (PR #1018) landed on develop in f380e37c3: `TPPNetworkResponder.handleExpiredTokenIfNeeded` constructs `AuthErrorClassifier` and routes on its outcome; the responder no longer calls `indicatesAuthenticationNeedsRefresh`. Re-grep before assuming. -->

# Network area — verification checklist

**Owner area:** `Palace/Network/` (`TPPNetworkExecutor.swift`, `TPPNetworkResponder.swift`, `TPPNetworkQueue.swift`, `TPPRequestExecuting.swift`, `Core/URLSessionNetworkClient.swift`), plus the auth-error classifier extension `Palace/Packages/PalaceAuth/Sources/PalaceAuth/URLResponse+TPPAuthentication.swift` and the test stub infrastructure at `PalaceTests/HTTPStubURLProtocol.swift`. Two consumer-side files still hold direct auth-classification calls and are tracked in Section 1 as next-sprint candidates: `Palace/MyBooks/TokenRefreshInterceptor.swift` and `Palace/MyBooks/DownloadAuthRetryHandler.swift`.

**Purpose:** the architect's first deliverable on ANY swarm or /rigorous-fix in this area is *update this file*. Verify what's still true, add what's changed, mark what's UNKNOWN. Without it, every new initiative re-discovers the same surface (the auth area's PR #1018 architect produced ~1,000 lines of recon docs that should have started from a baseline like this — and the network slice of that recon is what this file captures).

**Last refresh:** 2026-10-05 (classifier migration confirmed on develop; line citations and the Section 8 self-check re-verified against 3ad580c0d). Prior: 2026-09-23 (Section 7b, the decode seam — PR #1462 / PP-5202); 2026-05-28 (post PR #1018 / swarm_66819d80 — see `docs/architecture/areas/auth/verification-checklist.md` for the paired auth surface).
**Refreshing architect:** sign and date the next-refresh row at the bottom of this file.

---

## 1. Call-site map (sites in the network layer that handle 401/403, manage token refresh, or hand off to PalaceAuth)

| File | Lines | What it does | Migration status |
|------|-------|-------------|------------------|
| `Palace/Network/TPPNetworkResponder.swift` | 426, 435, 516 | Top-of-pipeline `statusCode == 401` checks in `urlSession(_:task:didCompleteWithError:)` that decide whether to drive `refreshTokenAndResume` | **MIGRATED** in PR #1018 (on develop since f380e37c3) — the responder is a thin router. The retry budget is per URL, not per task: `canRetry(url:)` / `markRetried(url:)` against `maxRetryAttempts = 1` (lines 105–107, 208–231), cleared on success (line 534) and on permanent failure (line 523). `tokenRefreshAttempts` (line 75) is declared and reset in `clearAllRetries` (line 238) but never read. |
| `Palace/Network/TPPNetworkResponder.swift` | 597–709 (`handleExpiredTokenIfNeeded`) | Cross-domain 401 carve-out + `markCredentialsStale` + dispatch to `refreshTokenAndResume` | **MIGRATED** in PR #1018 — routes the 401 decision through `AuthErrorClassifier.classify(...)` (constructed at line 635). Cross-domain detection lives behind the classifier (`.ok` outcome short-circuits, line 651). Browser auth: the `/patrons/me` bypass returns early (659–669); any other browser-auth 401 dispatches `AuthCoordinator.refreshCredentialsIfNeeded` (670–687). Non-browser auth keeps the inline `markCredentialsStale` + `refreshTokenAndResume` (690–706) — see Section 4. |
| `Palace/Network/TPPNetworkExecutor.swift` | 520 | `urlRequest.assumesHTTP3Capable = false` — disables optimistic HTTP/3 upgrade on first contact per host | **STABLE** — historical, not part of PR #1018. Do not re-enable; see Section 7 trap. |
| `Palace/Network/TPPNetworkExecutor.swift` | 743 (`refreshTokenAndResume(task:accountId:completion:)`) | Single-flight token-refresh + post-refresh resume of the original `URLSessionTask` | **STABLE** — responder-owned task-resume seam. The coordinator's silent refresh path can refresh the token but does NOT re-run THIS URLSessionTask, so this seam stays in the network layer. |
| `Palace/Network/TPPNetworkExecutor.swift` | 445–455 (proactive refresh branch) | Pre-flight refresh + resume when the token is near expiry (`authTokenNearExpiry`, token/OAuth auth only; SAML skips it at 440–443) | **STABLE** — paired with the responder's reactive path; both call into `refreshTokenAndResume`. |
| `Palace/Network/TPPNetworkQueue.swift` | 319 (`addRequest`), 479 (`retryQueue`), 511 (`retry`), 564 (`send`), 590–630 (`refreshThenResend`, `finishRefresh`, `resend`), 656 (`RowChallengeResponder`) | Offline retry queue (SQLite-backed); reachability-driven `retryQueue()` + per-row retry counter. Resends use `dataTask(with:completionHandler:)`, which URLSession does not report to the session delegate's `didCompleteWithError`, so the responder's 401 path never sees a queued request. The queue handles its own 401 (line 571): one `refreshTokenAndResume(task: nil, accountId: <row's library>)` per library per drain, then one resend of every row that 401'd for that library. A failed refresh keeps the rows; `MaxRetriesInQueue` still deletes them. Authentication challenges do reach completion-handler tasks, so each resend carries a task delegate (line 583) that answers Basic challenges with the row's library credentials instead of the responder's selected-library fallback. | **QUEUE-OWNED 401** — the refresh itself is the executor's single-flight `refreshTokenAndResume`; the queue only decides when to call it. Production binding: `AppContainer.swift:606–609`. |
| `Palace/Packages/PalaceAuth/Sources/PalaceAuth/URLResponse+TPPAuthentication.swift` | 43, 105, 143–159 | `indicatesAuthenticationNeedsRefresh(with:originalRequestURL:)` — the legacy auth-error classifier extension | **LIVE BUT FENCED** — moved into PalaceAuth in earlier extraction. Still called by the two unmigrated consumer-side sites below. Inside `AuthErrorClassifier` it remains the underlying primitive; outside callers should switch to the classifier. |
| `Palace/Network/Core/URLSessionNetworkClient.swift` | n/a | Pure-transport SPM-bound URLSession wrapper (`PalaceNetwork` module trunk) | **STABLE** — no auth surface; transport-only. |

**STILL UNMIGRATED** (next-sprint candidates, explicit PR #1018 deferral):
- `Palace/MyBooks/TokenRefreshInterceptor.swift:139` — still calls `httpResponse?.indicatesAuthenticationNeedsRefresh(with: problemDoc, originalRequestURL: originalURL)`. Out-of-scope for the TPPNetworkResponder-focused migration; tracked as follow-up.
- `Palace/MyBooks/DownloadAuthRetryHandler.swift:197` — same call shape, same deferral.

These two sites are network-adjacent (they're consumer-side auth-decision sites that happen to live in MyBooks/) and will move to the classifier in the next pass. Any new code in Palace/Network/ MUST go through `AuthErrorClassifier` — do not add new callers of `indicatesAuthenticationNeedsRefresh`.

---

## 2. Module ownership

| Module | Owner | Public surface (what changes here is a contract break) |
|--------|-------|---------------------------------------------------------|
| `Palace/Network/` (main target) | Main target — network layer for the app | `TPPNetworkResponder` (per-task budget + cross-domain detection + task-resume routing), `TPPNetworkExecutor` (request building, HTTP/3 disable, `refreshTokenAndResume`, account-aware credential snapshotting), `TPPNetworkQueue` (SQLite offline queue), `TPPRequestExecuting` protocol, `TPPUserFriendlyError` |
| `Palace/Network/Core/` (PalaceNetwork SPM) | SPM trunk — pure transport | `URLSessionNetworkClient`, `NetworkTransport` — extracted in commits 3d63372d6 / c00ebc789 / d962f7358. Singleton-free. No `.shared` reads. |
| `Palace/Packages/PalaceAuth/` | SPM trunk — auth boundary | `AuthErrorClassifier` (the seam for ALL auth-error decisions), `AuthCoordinator`, `AuthOutcome`, `URLResponse+TPPAuthentication` extension (`indicatesAuthenticationNeedsRefresh`). PalaceAuth does NOT link Firebase; emits via the `AuthDecisionRecording` protocol. |
| `PalaceTests/HTTPStubURLProtocol.swift` | Test infrastructure | `HTTPStubURLProtocol` + `URLSession.stubbedSession()` factory. Single canonical stubbing seam — do not add ad-hoc `URLProtocol` subclasses elsewhere. |

---

## 3. Request/response flow matrix (verify before changing routing logic)

Rows = HTTP method; columns = server-side response shape. Cell = what the network layer does at the responder/executor seam.

| Method | 2xx success | 401 + valid bearer in `Authorization` | 401 + expired bearer | 403 | 5xx | Network failure (no response) | Timeout | Cross-domain 301/302 → 401 |
|--------|-------------|--------------------------------------|---------------------|-----|-----|------------------------------|---------|---------------------------|
| GET | completion(.success) | classifier → `.expiredToken` → `refreshTokenAndResume(task:)` (responder-owned, single-flight) | same as above; per-task budget caps at 2 | propagate via NYPLProblemReport / completion(.failure) | propagate; queue does NOT auto-retry 5xx (queue is offline-retry only) | offline queue intercepts via `TPPNetworkQueue.addRequest` when reachability is down | propagate as `NSError` URLErrorTimedOut; no auth dispatch | classifier returns `.ok` (cross-domain carve-out) — DO NOT mark stale, DO NOT refresh |
| POST | completion(.success) | classifier dispatch + per-task budget (same as GET) | same | propagate | propagate; **enqueued** in `TPPNetworkQueue` for retry on reachability-up when `cachePolicy` permits | enqueued for offline retry (the queue's primary use case) | propagate | classifier returns `.ok` |
| PATCH | completion(.success) | same as POST | same | propagate | enqueued (same as POST) | enqueued | propagate | classifier returns `.ok` |
| PUT | completion(.success) | same as POST | same | propagate | enqueued | enqueued | propagate | classifier returns `.ok` |
| DELETE | completion(.success) | same as POST | same | propagate | enqueued | enqueued | propagate | classifier returns `.ok` |

Notes:
- **GET requests are NOT enqueued** by `TPPNetworkQueue` — only state-mutating verbs (POST/PATCH/PUT/DELETE) survive a reachability-down window. GET caller is expected to refetch.
- **The queue enqueues on transport failure only, never on 401.** Once a row is queued, a 401 on its resend refreshes the row's library token through `refreshTokenAndResume(task: nil, accountId:)` and resends once (Section 1). The responder's per-URL budget does not apply to queued resends; the queue's own bound is one refresh per library per drain and one resend per row after it.
- **Cross-domain 401** is detected by `URLResponse+TPPAuthentication.isSameDomain` (called from the classifier). The historical anti-pattern was marking Palace credentials stale because biblioboard.com returned 401 — see commit 10b5ecf0a.

---

## 4. Decision boundary — network layer vs PalaceAuth

The responder is now a thin router. The boundary is explicit:

**Stays in the network layer (responder/executor own these):**

1. **Per-URL token-refresh budget** — one refresh-and-retry per URL: `canRetry(url:)` at `TPPNetworkResponder.swift:427` against `maxRetryAttempts = 1` (line 107), recorded by `markRetried(url:)` (line 430), cleared on success (line 534) and on permanent failure (line 523). This is a REQUEST-layer circuit-breaker; the coordinator's single-flight is a BEARER-layer circuit-breaker. Both serve different roles and both must exist.
2. **Cross-domain 401 detection** at `TPPNetworkResponder.swift:635–654`. Since PR #1018 this is computed by `AuthErrorClassifier` (classifier returns `.ok` for cross-domain), but the call site is in the responder. The classifier is the seam — the predicate (`URLResponse+TPPAuthentication.isSameDomain`) is the implementation. DO NOT route the cross-domain decision through the coordinator — the coordinator never sees a `.ok` outcome.
3. **Task resume after refresh** — `networkExecutor.refreshTokenAndResume(task:accountId:)` at `TPPNetworkResponder.swift:704` and `TPPNetworkExecutor.swift:743`. The coordinator can refresh the bearer but cannot re-run a specific `URLSessionTask`; that's a network-executor concern.
4. **`/patrons/me` browser-auth bypass** — at `TPPNetworkResponder.swift:659–669`. Browser-auth (SAML/OIDC) has two surfaces (bearer + IdP cookie) and the IdP cookie expires faster than the bearer in Gorgon. A 401 from `/patrons/me` while the bearer is still good drove the cross-launch credentials-stale loop fixed in the 3.0.2 hotfix stack (commits 8d1dacafb, 46da46fb7). DO NOT remove this bypass.
5. **HTTP/3 disable** at `TPPNetworkExecutor.swift:520` (`assumesHTTP3Capable = false`).
6. **Offline retry queue** — `TPPNetworkQueue` enqueues on transport failure and drains on reachability-up. A 401 on a drained row is handled by the queue, not the responder (completion-handler tasks bypass `didCompleteWithError`): it calls the executor's single-flight refresh for the row's library and resends. It does not consult `AuthErrorClassifier`; queued rows go only to their own library's annotation host, so the cross-domain and foreign-host rules have nothing to separate.

**Delegated to PalaceAuth (the auth decision is NOT the network layer's concern):**

1. **Auth-error classification** — `AuthErrorClassifier.classify(response:problemDocument:body:originalRequestURL:callSite:)` returns `AuthOutcome` (`.ok`, `.expiredToken`, `.invalidCredentials`, `.forbidden`, `.serverError`, `.networkError`). The responder reads the outcome and ROUTES; it does not DECIDE.
2. **Dispatch matrix per AuthMechanism** — basic/token/saml/oidc/oauthIntermediary fan-out lives in `AuthCoordinator`. See `docs/architecture/areas/auth/verification-checklist.md` Section 3 for the matrix.
3. **Single-flight semantics** — coordinator owns the per-coordinator-instance single-flight + 30s post-failure cooldown. The network layer's per-task budget is in ADDITION to this, not a substitute for it.
4. **Telemetry** — the classifier reports outcomes through `AuthDecisionRecording`, but the responder's classifier has no recorder (see Section 5), so only `AuthCoordinator` steps reach Crashlytics. Network layer does not emit auth telemetry directly.

Architects: if you find yourself adding a new `if statusCode == 401` branch in Palace/Network/, STOP — that decision belongs in `AuthErrorClassifier`. The network layer routes; it does not classify.

---

## 5. Telemetry surface points (network layer)

| Surface point | File | Event / Log | What it tells you |
|---------------|------|-------------|-------------------|
| Cross-domain 401 carve-out | `TPPNetworkResponder.swift:652` | `Log.info — 401 from cross-domain redirect or non-401 outcome (<outcome>) — not marking credentials stale` | Confirms cross-domain detection fired; absence on a known cross-domain 401 indicates regression |
| `/patrons/me` browser-auth bypass | `TPPNetworkResponder.swift:667` | `Log.info — Browser-auth 401 from /patrons/me/ poll — IdP cookie expired but bearer still likely valid; not dispatching coordinator` | Confirms the bypass is reached; absence on a SAML `/patrons/me` 401 means we'd mark stale |
| Browser-auth action-endpoint dispatch | `TPPNetworkResponder.swift:683` | `Log.info — Server returned 401 for browser-based auth on action endpoint — dispatching coordinator with reason=<reason>` | Confirms the 401 was handed to `AuthCoordinator` (which marks credentials stale before re-auth) |
| Token-refresh dispatch | `TPPNetworkResponder.swift:703` | `Log.info — Server returned 401 - triggering token refresh (server authority); classifier outcome=<outcome>` | Confirms we entered `refreshTokenAndResume` |
| Offline queue retry attempt | `TPPNetworkQueue.swift:499` | `Log.debug — Executing "retry" with N row(s) in the table` | Reachability-up retry pass; row count is the offline backlog |
| Offline queue 401 refresh | `TPPNetworkQueue.swift:601` | `Log.info — Queued request got 401; refreshing the token for its library` | A drained row 401'd and started its library's one refresh for this drain |
| Offline queue refresh failed | `TPPNetworkQueue.swift:618` | `Log.warn — Token refresh failed; keeping N queued request(s) for a later drain` | Refresh did not succeed; rows stay until `MaxRetriesInQueue` |
| Offline queue 4xx/5xx on retry | `TPPNetworkQueue.swift:575` | `Log.warn — Queued Request retry failed with status N` | Queued retry hit an HTTP error (or a 401 that was not refreshed); row is dropped after counter exhausted |
| Classifier outcome | `AuthErrorClassifier.swift:112` (PalaceAuth) | `AuthDecisionStep.classifierClassified` (`"classifier.classified"`, `AuthDecisionPayload.swift:22`), sent to the classifier's injected `AuthDecisionRecording` | Not emitted for network-layer 401s today. `TPPNetworkResponder.swift:635` (and `LoanRenewalService.swift:156`) construct the classifier without a recorder, so it uses the default `NullAuthDecisionRecorder`. The Crashlytics-backed `AuthDecisionRecorder` is passed only to `AuthCoordinator` (`AppContainer.swift:530–537`), so coordinator steps are recorded and responder classifications are not. |

---

## 6. Test surface

**Existing network test files** (`PalaceTests/Network/` — 31 test files as of 2026-10-05, plus 1 cross-cutting `MyBooks/TokenRefreshInterceptorTests.swift`):

Token refresh / auth dispatch:
- `PalaceTests/Network/TokenRefreshTests.swift`
- `PalaceTests/Network/TokenRefreshAndRetryQueueTests.swift`
- `PalaceTests/Network/TokenRefreshOnForegroundTests.swift`
- `PalaceTests/Network/TokenResponseTests.swift`
- `PalaceTests/MyBooks/TokenRefreshInterceptorTests.swift` (consumer-side)

Responder behavior:
- `PalaceTests/Network/TPPNetworkResponderTests.swift`
- `PalaceTests/Network/TPPNetworkResponderAuthCoordinatorTests.swift`
- `PalaceTests/Network/URLResponseAuthenticationTests.swift`
- `Palace/Packages/PalaceUtilities/Tests/PalaceUtilitiesTests/URLResponseNYPLTests.swift`
- `Palace/Packages/PalaceAuth/Tests/PalaceAuthTests/AuthErrorClassifierTests.swift` and `AuthErrorClassifierPropertyTests.swift` (classifier outcomes, including the cross-domain and foreign-host `.ok` rules)

Executor / transport / queue:
- `PalaceTests/Network/TPPNetworkExecutorTests.swift`
- `PalaceTests/Network/NetworkClientTests.swift`
- `PalaceTests/Network/NetworkQueueTests.swift`
- `PalaceTests/Network/NetworkQueueTokenRefreshTests.swift` (queued 401 refresh-and-resend; challenge answered with the row's library)
- `PalaceTests/Network/NetworkRetryTests.swift`
- `PalaceTests/Network/ReachabilityTests.swift`
- `PalaceTests/Network/AccountAwareNetworkTests.swift`
- `PalaceTests/Network/MultiLibraryTokenIsolationTests.swift`
- `PalaceTests/Network/CookiePersistenceTests.swift`
- `PalaceTests/Network/SAMLCookieSyncTests.swift`
- `PalaceTests/Network/CredentialGuardTests.swift`

Domain / contract:
- `PalaceTests/Network/APIContractTests.swift`
- `PalaceTests/Network/DefaultCatalogAPITests.swift`
- `PalaceTests/Network/ManifestFetchTests.swift`
- `PalaceTests/Network/OPDSFormatTests.swift`
- `Palace/Packages/PalaceUtilities/Tests/PalaceUtilitiesTests/URLExtensionsTests.swift`
- `PalaceTests/Network/URLRequestExtensionsTests.swift`
- `PalaceTests/Network/URLRequestNYPLAdditionsTests.swift`

**Stubbing pattern (mandatory for any new network test):**
- `URLSession.stubbedSession()` factory + `HTTPStubURLProtocol.setHandler { request in (Data, HTTPURLResponse) }` per test. File: `PalaceTests/HTTPStubURLProtocol.swift`.
- Never hit a real URLSession; never call `.shared` URLSession.
- Reset the handler in `tearDown` to avoid handler-leak between tests.
- For per-account credential snapshotting tests, inject an `AccountsManager` via `AppContainer` rather than relying on `.shared`.

**Tests that test BEHAVIOR (must-survive any refactor):**
- 401 → classifier → refresh-and-resume round-trip (`TokenRefreshAndRetryQueueTests`, `TPPNetworkResponderAuthCoordinatorTests`)
- Cross-domain 401 does NOT mark Palace credentials stale (`AuthErrorClassifierTests`, `URLResponseAuthenticationTests`, `TPPNetworkResponderAuthCoordinatorTests`)
- `/patrons/me` browser-auth bypass — bearer-still-valid case (`URLResponseAuthenticationTests`, responder integration)
- One 401-driven refresh-and-retry per URL (`TokenRefreshTests` / `TokenRefreshAndRetryQueueTests`)
- Offline queue enqueues on transport failure and drains on reachability-up (`NetworkQueueTests`, `NetworkRetryTests`)
- Queued 401: one refresh per library per drain, resend with the new token, rows kept on refresh failure and still capped by `MaxRetriesInQueue`; a Basic challenge on a queued request is answered with the row's library, never the selected one (`NetworkQueueTokenRefreshTests`)
- Multi-library credential isolation across concurrent token refreshes (`MultiLibraryTokenIsolationTests`)

**Tests that test IMPLEMENTATION (can be rewritten when underlying changes):**
- Tests that assert on specific call orders inside `TPPNetworkResponder`
- Tests that exercise the legacy `indicatesAuthenticationNeedsRefresh` direct-call path (only relevant until the two unmigrated consumer-side sites in MyBooks/ are routed through the classifier)

---

## 7. Known traps / anti-patterns (lessons from prior work)

- **Do NOT re-enable optimistic HTTP/3.** `urlRequest.assumesHTTP3Capable = false` at `TPPNetworkExecutor.swift:520`. Some library servers advertise h3 but have broken QUIC; iOS retries twice (~260ms wasted) before falling back to h2. With the flag off, first requests use h2 and the session upgrades to h3 automatically on subsequent requests if the server confirms working QUIC via Alt-Svc. The performance win from re-enabling would be wiped out by per-host first-contact retries — and the regression mode is silent (extra latency on cold first contact, no error surface). Don't change without testing each known-broken-h3 host.
- **Do NOT route cross-domain 401 through the coordinator.** Cross-domain detection lives in `URLResponse+TPPAuthentication.isSameDomain`, surfaced as `AuthOutcome.ok` from the classifier. The coordinator never sees this outcome — it's a network-layer carve-out at `TPPNetworkResponder.swift:635–654`. Routing it through the coordinator would mark Palace credentials stale on a biblioboard CDN 401 (the bug fixed in commit 10b5ecf0a).
- **Foreign-library cross-host 401 — base-domain matching is NOT enough** (added 2026-06-05 per wall-failure `2026-06-05-pr1018-icarus-cross-host-logout.md`). The `isSameDomain` helper does BASE-DOMAIN matching (last two host components), so `gorgon.staging.palaceproject.io` and `minotaur.dev.palaceproject.io` return true. When the request URL's host is outside the current account's auth surface (different library backend within the same base domain), the responder MUST classify it as `.ok` via the new Rule 4b in `AuthErrorClassifier`. In production, `TPPNetworkResponder` at line 635 constructs the classifier with a `currentAccountHostsProvider` closure that reads `AppContainer.production().accountsManager.currentAccount?.authSurfaceHosts`. The default `{ nil }` provider (used by tests and any other consumer that doesn't opt in) preserves legacy behavior. A new responder construction site that omits the provider is shipping the latent foreign-host mis-attribution bug.
- **One 401-driven refresh-and-retry per URL** (`canRetry(url:)` at `TPPNetworkResponder.swift:427`, `maxRetryAttempts = 1` at line 107). This is a REQUEST-layer circuit-breaker; the coordinator's single-flight is a BEARER-layer circuit-breaker. They are NOT substitutes — keep both. A URL that 401s again after its retry should fail, not loop the coordinator.
- **Task-resume after token refresh is responder-owned** — `networkExecutor.refreshTokenAndResume(task:accountId:)` at `TPPNetworkResponder.swift:704` and `TPPNetworkExecutor.swift:743`. The coordinator's silent refresh refreshes the bearer; it does NOT re-run a specific `URLSessionTask`. If you push task-resume into PalaceAuth, you're conflating two layers.
- **`TokenRefreshInterceptor.swift:139` and `DownloadAuthRetryHandler.swift:197` still call `indicatesAuthenticationNeedsRefresh` directly.** This is a known PR #1018 deferral — out of scope for the TPPNetworkResponder-focused migration. Any new code in Palace/Network/ MUST go through `AuthErrorClassifier`; do NOT add a third call site of the legacy predicate while the deferral is in flight.
- **The auth decision is delegated to PalaceAuth.** The network layer should not implement its own auth-error decision logic. The single seam is `AuthErrorClassifier.classify(...)`; the single dispatcher is `AuthCoordinator`. New conditionals on `response.statusCode == 401` or on problem-doc shape should be at the classifier level, not at the responder.
- **Queued resends do not pass through the responder.** `TPPNetworkQueue` sends with `dataTask(with:completionHandler:)`, so the responder's `didCompleteWithError` (and its 401 refresh and per-URL budget) never runs for them, while its authentication-challenge handler still does. That is why the queue owns its 401 handling and sets a per-task challenge delegate. Routing queued resends back through the responder instead would refresh the SELECTED library's token (`handleExpiredTokenIfNeeded` reads `currentAccountId`) and rebuild the retry with `request(for:accountId:)`, which drops the method and body of a POST. Keep the refresh single-flight: call `refreshTokenAndResume`, do not add a second refresh path in the queue.
- **Account-aware credential snapshotting** — `TPPNetworkExecutor.request(for:useTokenIfAvailable:accountId:)` at line 512 takes a credential snapshot per request to prevent TOCTOU races during account switches. Without this, another thread changing `libraryUUID` between `sharedAccount()` and the property reads causes cross-account credential leaks. PR #1018 preserves this — do not optimize the snapshot away.

---

## 7b. Problem-document DECODE seam (added 2026-09-23, PR #1462)

Sections 1–7 cover auth-error *classification* over an **already-parsed** problem document.
They say nothing about how the document gets parsed, and that gap shipped a sign-in regression.
This section covers the decode itself.

**Two parse paths, different contracts. Know which one you are on.**

| | `TPPProblemDocument.fromData` | `TPPProblemDocument.fromProblemResponseData` |
|---|---|---|
| behavior | **throws** on any malformed member | never throws; returns `nil` only if nothing is extractable |
| mechanism | `JSONDecoder` + `.convertFromSnakeCase` | tries `fromData`, falls back to `JSONSerialization` + `as?` casts |
| callers | `TPPNetworkResponder.swift:727` (**sign-in**), `TPPProblemDocument+Localized.swift:11` (`try?`) | OPDS feed, `TPPUserFriendlyError`, `TokenRequest`, `OPDSParser`, `DownloadCompletionParser`, `LoanRenewalService` |

**The throwing contract is load-bearing — do NOT make `fromData` lenient.** Callers rely on the
throw to tell "this is a problem document" from "this is some other JSON." A never-throwing
`fromData` would manufacture bogus problem documents out of unrelated response bodies.
`fromProblemResponseData` already exists for callers that want leniency. Pinned by
`ProblemDocumentTests.testProblemDocument_fromData_otherMembersStayStrict` and the three
`XCTAssertThrowsError` assertions at `TPPBookLocationTests.swift:253-260`.

**Declaring a new member on `TPPProblemDocument` is a breaking change to every strict caller.**
Synthesized `Codable` throws `typeMismatch` on a present-but-wrong-typed value and aborts the
WHOLE decode, so a member that was previously an ignored unknown key becomes able to discard the
entire document. On the sign-in path the responder's `catch` arm returns an `NSError` with no
problem document, `userFacingSignInError` receives `nil`, and the patron is told their password
is wrong. Before adding a member, decide explicitly whether it may cost the document. PR #1462's
`show_title` decided NO and decodes inside a `do`/`catch`; the five RFC 7807 members decided YES
(pre-existing, deliberately unchanged).

**The `CodingKeys` trap.** `fromData` sets `.convertFromSnakeCase`, which rewrites the incoming
key BEFORE `CodingKeys` matching. A case spelled `showTitle = "show_title"` therefore matches
**nothing**, silently — the feature is deleted with no throw and no log, and it passes any test
that only asserts the document decoded. Keep `CodingKeys` raw values camelCase. **Not gated yet** — a detector for this class is
designed and written but deliberately split into its own PR (see the wall-failure entry's
"Detector script — QUEUED" section for the matching rule and the false-positive trap). Until it
lands, this is a review-time check. Full forensic:
wall-failure `2026-09-23-pr1462-snakecase-codingkeys`.

**No custom `encode(to:)` — deliberately.** `init(from:)` keys on the POST-strategy camelCase
name, so the synthesized encoder round-trips through a plain `JSONDecoder`. A hand-written
encoder emitting `show_title` would break that: the flag would survive a `.convertFromSnakeCase`
decoder and be silently lost by every other one, including the existing round-trip test at
`TPPBookLocationTests.swift:451`. Both round trips are pinned in `ProblemDocumentTests`.

**KNOWN DEBT — the two paths diverge only when a SECOND member is also malformed.** Measured
against the shipped code, not reasoned about:

```
{"title":"T","detail":"D","show_title":0}                 fromData: true   fromProblemResponseData: true
{"title":"T","detail":"D","status":"403","show_title":0}  fromData: THREW  fromProblemResponseData: false
```

`show_title: 0` **alone** no longer diverges, because after this fix `fromData` stops throwing,
so `fromProblemResponseData`'s `try? fromData` succeeds and its `JSONSerialization` fallback is
never entered. The fallback is only reached when something ELSE in the body is fatal — and there
`as? Bool` bridges `NSNumber(0)` to `false`, so the lenient path suppresses the title while the
strict path would have shown it. Reconciling means changing `fromDictionary`'s public contract,
which was out of scope for a sign-in fix. Not user-visible today: the circulation manager sends a
real JSON boolean.

(An earlier draft of this section claimed the two paths diverged on `show_title: 0` on its own.
That was wrong — it described the code BEFORE the fix. Caught in qa review by measuring.)

**Two testing rules this incident produced.** PR #1462 shipped eight well-formed-JSON
`show_title` tests and none of them could see the bug, for two separate reasons:
1. A test helper that takes the well-formed Swift type cannot produce the malformed body —
   `Bool?` cannot express `"false"` or `0`. The four sign-in tests were fenced out by their own
   helper's signature. Where a member has a wire type, the helper must accept a RAW literal.
   See `TPPSignInBusinessLogicTests.blockedByPolicyDocument(showTitleLiteral:)`.
2. The four decode tests used inline JSON literals and could have written the malformed body
   at any time — that half was simply missing coverage. **When you add a typed member to a
   decoded model, the wrong-type row is not an edge case; it is the row that decides whether
   the member can cost you the whole document.**

**Related wall, same end-user harm.** PP-3956 / PR #935: an `NSError` re-wrap that DROPS
the document downstream. This section covers the document never being constructed. Both end
with the patron told their password is wrong. Check both when triaging that report.

---

## 8. Architect's pre-swarm checklist (what to verify before writing a new contract)

Before any new swarm or /rigorous-fix in this area, the architect should:

1. **Refresh this file's sections 1, 3, and 4** — confirm the call-site map, the request/response flow matrix, and the decision boundary are still accurate. Re-grep `statusCode == 401` and `statusCode == 403` across `Palace/Network/` (`grep -rn 'statusCode == 40[13]' Palace/Network/`) — expected matches are `TPPNetworkResponder.swift` lines 426, 435, 516 and 656; anything else needs triage.
2. **Verify the cross-domain 401 carve-out still exists.** `grep -n "AuthErrorClassifier(\|outcome == .ok\|patrons/me" Palace/Network/TPPNetworkResponder.swift` — expect exactly these lines: 540, 624, 625 (comments mentioning `/patrons/me`), 635 (classifier construction), 651 (the `.ok` short-circuit), and 660, 663, 667 (the `/patrons/me` browser bypass). The responder should no longer call `indicatesAuthenticationNeedsRefresh`. Read the surrounding comments; both bypasses have hotfix-driven rationale that should not be silently removed.
3. **Verify the per-URL token-refresh budget hasn't been re-implemented somewhere else.** `grep -n 'maxRetryAttempts\|canRetry(url\|markRetried(url' Palace/Network/TPPNetworkResponder.swift` — the budget is `retriedURLs` + `maxRetryAttempts = 1`, owned by `TPPNetworkResponder`. (`tokenRefreshAttempts` still exists at lines 75 and 238 but is never read; it is not the budget.) The coordinator's single-flight is separate and lives in `AuthCoordinator`.
4. **Confirm `AuthErrorClassifier` is the single seam for auth-error decisions.** `grep -rn 'indicatesAuthenticationNeedsRefresh' Palace/` — only the two known deferrals (`TokenRefreshInterceptor.swift:139`, `DownloadAuthRetryHandler.swift:197`) plus the comments above them (lines 124 and 185) should appear outside the PalaceAuth package's own implementation. Any new call sites are scope debt.
5. **Re-run the test inventory** — `find PalaceTests/Network -name '*Tests*.swift' | wc -l` was 32 on 2026-10-06. `TPPNetworkResponderAuthCoordinatorTests` and the PalaceAuth `AuthErrorClassifierTests` should be present.
6. **Re-check critical-path tests pass on develop BEFORE the swarm starts.** Run `TokenRefreshTests`, `TokenRefreshAndRetryQueueTests`, `URLResponseAuthenticationTests`, `MultiLibraryTokenIsolationTests`, `NetworkQueueTests`, and `NetworkQueueTokenRefreshTests` in isolation so post-swarm regressions are attributable.
7. **Confirm HTTP/3 disable is still in place.** `grep -n assumesHTTP3Capable Palace/Network/TPPNetworkExecutor.swift` — should match at line 520. If missing, that's a regression on the historical fix and needs investigation before any new network change ships.
8. **Confirm the queue still owns its 401 and challenge handling.** `grep -n 'code == 401\|task.delegate = \|refreshTokenAndResume' Palace/Network/TPPNetworkQueue.swift` — expect the 401 branch in `send` (line 571), the per-task challenge delegate (line 583) and the refresh call (line 602). If the resend moves to a delegate-based task, re-check both: the responder's 401 path and challenge fallback both use the selected library.
9. **Update Section 9 (refresh history)** with date + your initials, and the frontmatter `sources:` block (`verified_ref` = the commit you checked against).

---

## 9. Refresh history

| Date | Refreshed by | Notes |
|------|-------------|-------|
| 2026-10-06 | queued-401 fix (fix/network-queue-401-refresh) | Updated the queue rows in Sections 1, 3, 4, 5, 6, 7 and 8 for the fix: queued resends bypass the responder's `didCompleteWithError`, so the queue now refreshes the row's library token on 401 (one refresh per library per drain) and answers Basic challenges with the row's library credentials. Re-stamped `sources:` to 4c65025be, this branch's base; none of the listed paths changed between 3ad580c0d and 4c65025be, so the fingerprint is unchanged. `TPPNetworkQueue.swift` line citations refer to the file after this fix, not to `verified_ref`. Other sections were not re-verified. |
| 2026-10-05 | network checklist refresh | Confirmed the PR #1018 classifier migration is on develop (f380e37c3) and removed the "not yet landed" notes. Re-verified every line citation and the Section 8 self-check against 3ad580c0d. Corrected the retry-budget description: it is one retry per URL (`maxRetryAttempts = 1`), not `tokenRefreshAttempts < 2`. Replaced two test files that were never added (`CrossDomain401Tests`, `AuthErrorCategoryTests`) with the classifier tests that cover the same rules. Added the `sources:` frontmatter. |
| 2026-09-23 | /rigorous-fix, PR #1462 (PP-5202) | Added Section 7b — the problem-document DECODE seam. Sections 1–7 covered classification over an already-parsed document and were silent on parsing; that gap shipped a sign-in regression where a wrong-typed `show_title` discarded the whole document and a blocked patron was told their password was wrong. Section 7b documents the two parse paths and their different contracts, the `.convertFromSnakeCase` CodingKeys trap and its detector, the no-custom-encoder decision, and the strict/lenient `0` disagreement as known debt. |
| 2026-05-28 | swarm rigor meta-improvement (chore/swarm-rigor-meta-improvement) | Initial baseline. Mirrors the auth area's `verification-checklist.md` structure. Migration status in Section 1 reflects the swarm_66819d80 design baseline (commit f9e57f7f5 on swarm/swarm_66819d80-scaffold); develop tip still calls `indicatesAuthenticationNeedsRefresh` directly until that swarm lands on develop. |

---

**This file is owned by the network area.** If you change anything in `Palace/Network/`, in the `URLResponse+TPPAuthentication` extension, or in the two consumer-side classifier callers (`TokenRefreshInterceptor.swift:139`, `DownloadAuthRetryHandler.swift:197`), update the relevant section here before you commit. The Definition of Done (CLAUDE.md) treats out-of-date area checklists as scope debt. Paired with `docs/architecture/areas/auth/verification-checklist.md` — auth-layer decisions and network-layer routing meet at the classifier seam; keep both files in sync when that seam moves.
