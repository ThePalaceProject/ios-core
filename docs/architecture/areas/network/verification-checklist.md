---
name: network-verification-checklist
type: evolving
status: active
created: 2026-05-28
last_refresh: 2026-10-09
freshness_window: 180d
owners: [network]
description: Per-area verification reference; refresh before changing this area
# The code this checklist describes, and the commit it was last checked against
# (a develop commit, or the head of the PR whose diff moved these lines).
# If any of these files changed since `verified_ref`, re-check the line citations below:
#   git diff --stat <verified_ref> -- <paths>
# `fingerprint` is reproducible with plain git from the repo root (paths in any order):
#   git ls-tree <verified_ref> -- <paths> | git hash-object --stdin | cut -c1-8
sources:
  verified_ref: 883590f66dbe2b894fe519e0aaf548349177ce9e
  last_verified: 2026-10-09
  fingerprint: 'f51bd9aa'
  paths:
    - Palace/Network/TPPNetworkResponder.swift
    - Palace/Network/TPPNetworkExecutor.swift
    - Palace/Network/TPPNetworkExecutor+Async.swift
    - Palace/Network/TPPNetworkExecutor+RetryRequest.swift
    - Palace/Network/TPPNetworkQueue.swift
    - Palace/Packages/PalaceAuth/Sources/PalaceAuth/AuthErrorClassifier.swift
    - Palace/Packages/PalaceAuth/Sources/PalaceAuth/URLResponse+TPPAuthentication.swift
    - Palace/MyBooks/TokenRefreshInterceptor.swift
    - Palace/MyBooks/DownloadAuthRetryHandler.swift
    - Palace/Reader2/Bookmarks/TPPAnnotations.swift
    - Palace/OPDS2/Service/TPPCirculationAnalytics.swift
    - Palace/Packages/PalaceNetwork/Sources/PalaceNetwork/CirculationOfflineSupport.swift
    - Palace/Network/Core/URLSessionNetworkClient.swift
    - Palace/AppInfrastructure/AppContainer.swift
    - Palace/MyBooks/LoanRenewalService.swift
    - Palace/MyBooks/BookReturnService.swift
    - Palace/Packages/PalaceAuth/Sources/PalaceAuth/AuthDecisionPayload.swift
    - Palace/Packages/PalaceCatalog/Sources/PalaceCatalog/TPPProblemDocument.swift
    - Palace/ErrorHandling/TPPProblemDocument+Localized.swift
    - Palace/Platform/OfflineQueueService.swift
    - Palace/Packages/PalaceNetwork/Sources/PalaceNetwork/NetworkTransport.swift
    - Palace/Packages/PalaceNetwork/Sources/PalaceNetwork/TPPBasicAuth.swift
    - Palace/Accounts/Library/AccountCredentialResolver.swift
    - Palace/Accounts/User/TPPUserAccount.swift
---

<!-- audit-verified: Owner files in Palace/Network/ confirmed by `ls Palace/Network/` (Core/, TPPNetworkExecutor.swift, TPPNetworkExecutor+AccountNetworking.swift, TPPNetworkResponder.swift, TPPNetworkQueue.swift, TPPRequestExecuting.swift, TPPUserFriendlyError.swift, BundledHTMLViewController.swift, RemoteHTMLViewController.swift). Line citations in Sections 1, 2, 3, 4, 5, 7, 7b and 8, the Section 8 self-check outputs and the negative claims re-verified by grep against develop at 503ef9965 (2026-10-06, after #1613). The classifier migration (PR #1018) landed on develop in f380e37c3: `TPPNetworkResponder.handleExpiredTokenIfNeeded` constructs `AuthErrorClassifier` and routes on its outcome; the responder no longer calls `indicatesAuthenticationNeedsRefresh`. Re-grep before assuming. -->

# Network area — verification checklist

**Owner area:** `Palace/Network/` (`TPPNetworkExecutor.swift`, `TPPNetworkResponder.swift`, `TPPNetworkQueue.swift`, `TPPRequestExecuting.swift`, `Core/URLSessionNetworkClient.swift`), plus the auth-error classifier extension `Palace/Packages/PalaceAuth/Sources/PalaceAuth/URLResponse+TPPAuthentication.swift` and the test stub infrastructure at `PalaceTests/HTTPStubURLProtocol.swift`. Two consumer-side files still hold direct auth-classification calls and are tracked in Section 1 as next-sprint candidates: `Palace/MyBooks/TokenRefreshInterceptor.swift` and `Palace/MyBooks/DownloadAuthRetryHandler.swift`.

**Purpose:** the first deliverable of any non-trivial change in this area is *update this file*. Verify what's still true, add what's changed, mark what's UNKNOWN. Without it, every new initiative re-discovers the same surface (the auth area's PR #1018 architect produced ~1,000 lines of recon docs that should have started from a baseline like this — and the network slice of that recon is what this file captures).

**Last refresh:** 2026-10-06 (citations, Section 8 self-checks and negative claims re-checked against 503ef9965). Prior: 2026-10-06 (Section 3 offline-queue rows corrected; negative claims re-checked against 4c65025be). Prior: 2026-10-05 (classifier migration confirmed on develop; line citations and the Section 8 self-check re-verified against 3ad580c0d). Prior: 2026-09-23 (Section 7b, the decode seam — PR #1462 / PP-5202); 2026-05-28 (post PR #1018 — see `docs/architecture/areas/auth/verification-checklist.md` for the paired auth surface).
**Refreshing architect:** sign and date the next-refresh row at the bottom of this file.

---

## 1. Call-site map (sites in the network layer that handle 401/403, manage token refresh, or hand off to PalaceAuth)

| File | Lines | What it does | Migration status |
|------|-------|-------------|------------------|
| `Palace/Network/TPPNetworkResponder.swift` | 426, 435, 516 | Top-of-pipeline `statusCode == 401` checks in `urlSession(_:task:didCompleteWithError:)` that decide whether to drive `refreshTokenAndResume` | **MIGRATED** in PR #1018 (on develop since f380e37c3) — the responder is a thin router. The retry budget is per URL, not per task: `canRetry(url:)` / `markRetried(url:)` against `maxRetryAttempts = 1` (lines 105–107, 208–231), cleared on success (line 534) and on permanent failure (line 523). `tokenRefreshAttempts` (line 75) is declared and reset in `clearAllRetries` (line 238) but never read. |
| `Palace/Network/TPPNetworkResponder.swift` | 609–724 (`handleExpiredTokenIfNeeded`) | Cross-domain 401 carve-out + `markCredentialsStale` + dispatch to `refreshTokenAndResume` | **MIGRATED** in PR #1018 — routes the 401 decision through `AuthErrorClassifier.classify(...)` (constructed at line 647). Cross-domain detection lives behind the classifier (`.ok` outcome short-circuits, line 651). Browser auth: the `/patrons/me` bypass returns early (659–669); any other browser-auth 401 dispatches `AuthCoordinator.refreshCredentialsIfNeeded` (670–687). Non-browser auth keeps the inline `markCredentialsStale` + `refreshTokenAndResume` (690–706) — see Section 4. |
| `Palace/Network/TPPNetworkExecutor.swift` | 637 | `urlRequest.assumesHTTP3Capable = false` — disables optimistic HTTP/3 upgrade on first contact per host | **STABLE** — historical, not part of PR #1018. Do not re-enable; see Section 7 trap. |
| `Palace/Network/TPPNetworkExecutor.swift` | 867 (`refreshTokenAndResume(task:accountId:presentsSignInOnFailure:completion:)`) | Single-flight token-refresh + post-refresh resume of the original `URLSessionTask`. When the token endpoint refuses the stored credentials it marks them stale and, if `presentsSignInOnFailure` (default `true`) and the account is the selected one, presents the sign-in sheet through `presentSignInAfterRefusedRefresh` (line 230; call at 915). A `task: nil` call that finds the slot already held fails at once with `refreshInProgressKey` (line 755) set in the error's `userInfo`. | **STABLE** — responder-owned task-resume seam; the offline queue also calls it, with `task: nil` and `presentsSignInOnFailure: false`. The coordinator's silent refresh path can refresh the token but does NOT re-run THIS URLSessionTask, so this seam stays in the network layer. |
| `Palace/Network/TPPNetworkExecutor.swift` | 499–505 (the near-expiry branch of `preflight`) | Pre-flight refresh + resume when the token is near expiry (`authTokenNearExpiry`, token/OAuth auth only; SAML skips it at 494) | **STABLE** — paired with the responder's reactive path; both call into `refreshTokenAndResume`. |
| `Palace/Network/TPPNetworkQueue.swift` | 365 (`addRequest`), 525 (`retryQueue`), 557 (`retry`), 578 (`makeRequest`), 610 (`send`), 637–704 (`refreshThenResend`, `finishRefresh`), 705 (`resend`), 717 (`refundRetry`), 737 (`deleteRowIfUnchanged`), 771 (`RowChallengeResponder`), 811 (`live`), 853–868 (`enqueueOfflineRequest`) | Offline retry queue (SQLite-backed); reachability-driven `retryQueue()` (lines 194–199) + per-row retry counter | **QUEUE-OWNED 401.** The drain sends on the executor's `URLSession`, whose delegate is the responder (`TPPNetworkExecutor.swift:275`), but with `dataTask(with:completionHandler:)` (line 612). The responder's `urlSession(_:task:didCompleteWithError:)` 401 refresh (`TPPNetworkResponder.swift:425`) is not called for that task; an iOS simulator probe confirmed it. So the queue handles its own 401 (lines 618–619), for libraries whose stored credentials can be exchanged for a token (`canRefreshToken`, line 830, the responder's test): it calls `refreshTokenAndResume(task: nil, accountId: <row's library>, presentsSignInOnFailure: false)` (line 656) once per library per drain, then resends each waiting row once. Outcomes are in Section 3. Authentication challenges do still reach a completion-handler task, so each send sets a task delegate (line 631) that URLSession consults before the session delegate; it answers HTTP Basic with the row's library credentials and declines when that library has none. Production builds the queue through `NetworkQueue.live(executor:reachability:accountsManager:)` (line 803; called at `AppContainer.swift:599`), which keys the bearer, the challenge credentials and `canRefreshToken` on the row's library. |
| `Palace/Packages/PalaceAuth/Sources/PalaceAuth/URLResponse+TPPAuthentication.swift` | 43, 105, 143–159 | `indicatesAuthenticationNeedsRefresh(with:originalRequestURL:)` — the legacy auth-error classifier extension | **LIVE BUT FENCED** — moved into PalaceAuth in earlier extraction. Still called by the two unmigrated consumer-side sites below. Inside `AuthErrorClassifier` it remains the underlying primitive; outside callers should switch to the classifier. |
| `Palace/Network/Core/URLSessionNetworkClient.swift` | 12, 30, 59–77 | Main-target adapter from the `PalaceNetwork` `NetworkClient` protocol onto `TPPNetworkExecutor` | **STABLE** — not transport-only. It builds each request with `executor.request(for:)` (line 30) and sends through the executor with `useTokenIfAvailable: true` (GET/HEAD, POST, PUT, DELETE) or `addBearerAndExecute` (PATCH) (lines 59–77), so it attaches the bearer and gets the responder's 401 refresh. |

**STILL UNMIGRATED** (next-sprint candidates, explicit PR #1018 deferral):
- `Palace/MyBooks/TokenRefreshInterceptor.swift:139` — still calls `httpResponse?.indicatesAuthenticationNeedsRefresh(with: problemDoc, originalRequestURL: originalURL)`. Out-of-scope for the TPPNetworkResponder-focused migration; tracked as follow-up.
- `Palace/MyBooks/DownloadAuthRetryHandler.swift:197` — same call shape, same deferral.

These two sites are network-adjacent (they're consumer-side auth-decision sites that happen to live in MyBooks/) and will move to the classifier in the next pass. Any new code in Palace/Network/ MUST go through `AuthErrorClassifier` — do not add new callers of `indicatesAuthenticationNeedsRefresh`.

---

## 2. Module ownership

| Module | Owner | Public surface (what changes here is a contract break) |
|--------|-------|---------------------------------------------------------|
| `Palace/Network/` (main target) | Main target — network layer for the app | `TPPNetworkResponder` (per-task budget + cross-domain detection + task-resume routing), `TPPNetworkExecutor` (request building, HTTP/3 disable, `refreshTokenAndResume`, account-aware credential snapshotting), `TPPNetworkQueue` (SQLite offline queue), `TPPRequestExecuting` protocol, `TPPUserFriendlyError` |
| `Palace/Packages/PalaceNetwork/` (SPM) and `Palace/Network/Core/` (main target) | SPM package — transport; main-target adapter | `NetworkTransport` (`Palace/Packages/PalaceNetwork/Sources/PalaceNetwork/NetworkTransport.swift:97`, owns the `URLSession`; no `.shared` or `AppContainer` reads) and the `NetworkClient` protocol live in the package. `URLSessionNetworkClient` lives in the main target at `Palace/Network/Core/`; its `init` takes the executor with no default (`URLSessionNetworkClient.swift:12`), and `AppContainer.catalogAPI` passes its container's `networkExecutor`. Extracted in commits 3d63372d6 / c00ebc789 / d962f7358. |
| `Palace/Packages/PalaceAuth/` | SPM trunk — auth boundary | `AuthErrorClassifier` (the seam for ALL auth-error decisions), `AuthCoordinator`, `AuthOutcome`, `URLResponse+TPPAuthentication` extension (`indicatesAuthenticationNeedsRefresh`). PalaceAuth does NOT link Firebase; emits via the `AuthDecisionRecording` protocol. |
| `PalaceTests/HTTPStubURLProtocol.swift` | Test infrastructure | `HTTPStubURLProtocol` + `URLSession.stubbedSession()` factory. The preferred stubbing seam for new tests, though not the only one: ten other direct `URLProtocol` subclasses exist under `PalaceTests/` (for example `NoNetworkURLProtocol.swift:23`, `Bookmarks/TPPAnnotationsTests.swift:18`, `Chaos/ChaosHarness.swift:35`). Prefer `HTTPStubURLProtocol` over adding another. |

---

## 3. Request/response flow matrix (verify before changing routing logic)

Rows = HTTP method; columns = server-side response shape. Cell = what the network layer does at the responder/executor seam.

| Method | 2xx success | 401 + valid bearer in `Authorization` | 401 + expired bearer | 403 | 5xx | Network failure (no response) | Timeout | Cross-domain 301/302 → 401 |
|--------|-------------|--------------------------------------|---------------------|-----|-----|------------------------------|---------|---------------------------|
| GET, POST, PUT | completion(.success) | classifier → `.expiredToken` → `refreshTokenAndResume(task:)` (responder-owned, single-flight) | same as above; one refresh-and-retry per URL (Section 4, item 1) | propagate via NYPLProblemReport / completion(.failure) | propagate | propagate | propagate as `NSError` URLErrorTimedOut; no auth dispatch | classifier returns `.ok` (cross-domain carve-out) — DO NOT mark stale, DO NOT refresh |
| DELETE | completion(.success) | no refresh: `handleExpiredTokenIfNeeded` returns early for DELETE (`TPPNetworkResponder.swift:613–615`) | same (no refresh) | propagate | propagate | propagate | propagate | not classified (same early return) |

`TPPNetworkExecutor` and `TPPNetworkResponder` never write to `TPPNetworkQueue`; no cell above enqueues. A request reaches the queue only when a caller enqueues it after its own request failed.

**What `TPPNetworkQueue` enqueues** (verified at 503ef9965). The queue stores whatever method its caller passes (`addRequest`, `TPPNetworkQueue.swift:365`; `HTTPMethodType` at lines 18–19 has GET, POST, HEAD, PUT, DELETE, OPTIONS, CONNECT and no PATCH). Two enqueue paths exist:

| Path | Method | Production caller | Condition |
|------|--------|-------------------|-----------|
| `TPPAnnotations.addToOfflineQueue` → `addRequest` (`TPPAnnotations.swift:830–837`) | POST | `postAnnotation` at `TPPAnnotations.swift:440`, reached with `queueOffline: true` only from `postReadingPosition` (line 269), which also serves `postListeningPosition` (line 206) and the audiobook bookmark post (line 213). The bookmark posts at lines 333 and 370 pass `queueOffline: false`. | The POST failed with an `NSError` whose code is in `NetworkQueue.StatusCodes` (`TPPNetworkQueue.swift:134–142`: timeout, cannot find or connect to host, connection lost, not connected, roaming off, call active, data not allowed, secure connection failed), checked at `TPPAnnotations.swift:433`. HTTP error responses, including 401 and 5xx, are not enqueued. |
| `NetworkQueue.enqueueOfflineRequest` (`TPPNetworkQueue.swift:853–868`, added in 3f659ff2e) → `addRequest` | GET | `TPPCirculationAnalytics.addToOfflineAnalyticsQueue` (`TPPCirculationAnalytics.swift:55–72`), which passes `.GET`. That function has no production caller: `post(_:withURL:)` enqueues nothing on failure (lines 40–44); the enqueue shape is pinned only by `TPPCirculationAnalyticsRequestShapeContractTests`. | None today. Wiring the analytics failure path to this function would start enqueuing GET requests. A package `HTTPMethod` with no `HTTPMethodType` case (PATCH) is stored as GET in release builds: the check is only an `assert` (`TPPNetworkQueue.swift:865–866`). |

Notes:
- **GET can be enqueued.** The queue accepts GET through `enqueueOfflineRequest`. No production code calls it today, so the only rows written in practice are annotation POSTs. Do not assume GET is never queued when changing the queue or its drain.
- **Enqueue is never triggered by a 401; a queued row that gets a 401 refreshes its library's token and is resent once.** The live producer enqueues only on transport failure. During a drain, `retry` increments the row's `retries` before the send (`TPPNetworkQueue.swift:560`). A 401 from a library that can refresh (`canRefreshToken`: token or OAuth auth with a token URL and a stored card and PIN, line 830) starts the executor's single-flight refresh for the row's library (line 656), at most once per library per drain; a library that cannot refresh keeps the row without calling the executor. Rows that 401 while the refresh is in flight wait for it (line 641). Outcomes, per library per drain (`finishRefresh`, line 678): **succeeded**, each waiting row is re-read from the database and resent once with the library's current bearer (lines 705–714; a row that a newer `addRequest` replaced or removed meanwhile is left for the next drain), and later 401s in the drain resend straight away; **refused or timed out**, rows are kept with the retry spent, and later 401s are kept without another refresh (line 644); **slot held by another refresh** (the executor's `refreshInProgressKey` error), rows are kept and their retry is refunded (`refundRetry`, line 717), since their credentials were not refused. A refresh that has not answered within `defaultRefreshTimeout` (90s, line 101, above the executor's 75s watchdog, which does not call a `task: nil` caller back) counts as failed so the drain can end; a completion that arrives later is ignored (guard at line 675). A resend does not refresh again. Queue-initiated refreshes pass `presentsSignInOnFailure: false` (line 650): a refused refresh marks the credentials stale but does not present the sign-in sheet from a background drain. A delivered row is deleted only if it still holds what was sent (`deleteRowIfUnchanged`, line 729), so a write that superseded it while the request was in flight stays queued. The responder's per-URL budget does not apply. The next drain deletes rows with `retries > MaxRetriesInQueue` (5, line 143) before sending (lines 532–534). Superseding a row through `addRequest` resets its count to 0 (lines 415–417). Pinned by `NetworkQueueTokenRefreshTests`.
- **Authentication challenges on a queued request are answered with the row's library credentials.** Apple documents that challenge delegate methods are still called for completion-handler tasks (https://developer.apple.com/documentation/foundation/urlsession/1407613-datatask), and an iOS simulator probe confirmed that the responder's challenge handler (`TPPNetworkResponder.swift:831–837`) was consulted for the queued resend, reading its selected-library fallback (line 867). Each send now sets a per-task delegate (`TPPNetworkQueue.swift:631`, class at line 771), which URLSession consults instead of the session delegate (same probe). It answers through `TPPBasicAuth` (`TPPBasicAuth.swift:43–55`) with `accountsManager.userAccount(for: <row's library>)`, bound in `NetworkQueue.live` and keyed on `sqlLibraryID` (`TPPNetworkQueue.swift:183`) like the bearer. A library with no stored credentials declines the Basic challenge instead of falling back; a server-trust challenge gets default handling without reading the credentials. Pinned by the challenge and `testLive_*` tests in `NetworkQueueTokenRefreshTests`. Not confirmed: that any endpoint the queue drains to (the annotations URL) sends a Basic challenge; the probe synthesised the challenge with a `URLProtocol`.
- **Offline returns use a different queue.** `BookReturnService`'s `.enqueueOffline` case (`BookReturnService.swift:500`) goes through `offlineReturnEnqueuer` / `OfflineQueueService`, not `TPPNetworkQueue`.
- **Cross-domain 401** is detected by `URLResponse+TPPAuthentication.isSameDomain` (called from the classifier). The historical anti-pattern was marking Palace credentials stale because biblioboard.com returned 401 — see commit 10b5ecf0a.

---

## 4. Decision boundary — network layer vs PalaceAuth

The responder is now a thin router. The boundary is explicit:

**Stays in the network layer (responder/executor own these):**

1. **Per-URL token-refresh budget** — one refresh-and-retry per URL: `canRetry(url:)` at `TPPNetworkResponder.swift:208` against `maxRetryAttempts = 1` (line 107), recorded by `markRetried(url:)` (line 217), cleared on success (line 546) and on permanent failure (line 535). This is a REQUEST-layer circuit-breaker; the coordinator's single-flight is a BEARER-layer circuit-breaker. Both serve different roles and both must exist.
2. **Cross-domain 401 detection** at `TPPNetworkResponder.swift:647–666`. Since PR #1018 this is computed by `AuthErrorClassifier` (classifier returns `.ok` for cross-domain), but the call site is in the responder. The classifier is the seam — the predicate (`URLResponse+TPPAuthentication.isSameDomain`) is the implementation. DO NOT route the cross-domain decision through the coordinator — the coordinator never sees a `.ok` outcome.
3. **Task resume after refresh** — `networkExecutor.refreshTokenAndResume(task:accountId:)` at `TPPNetworkResponder.swift:716` and `TPPNetworkExecutor.swift:884`. The coordinator can refresh the bearer but cannot re-run a specific `URLSessionTask`; that's a network-executor concern.
4. **`/patrons/me` browser-auth bypass** — at `TPPNetworkResponder.swift:671–680`. Browser-auth (SAML/OIDC) has two surfaces (bearer + IdP cookie) and the IdP cookie expires faster than the bearer in Gorgon. A 401 from `/patrons/me` while the bearer is still good drove the cross-launch credentials-stale loop fixed in the 3.0.2 hotfix stack (commits 8d1dacafb, 46da46fb7). DO NOT remove this bypass.
5. **HTTP/3 disable** at `TPPNetworkExecutor.swift:654` (`assumesHTTP3Capable = false`).
6. **Offline retry queue** — `TPPNetworkQueue` drains on reachability-up (`TPPNetworkQueue.swift:194–199`). The responder's 401 handling does not see its requests, so the queue calls the executor's single-flight `refreshTokenAndResume` for the row's library on a 401 (token and OAuth libraries only, without the sign-in sheet) and resends once; it answers authentication challenges itself with the row's library credentials (Section 3). It does not consult `AuthErrorClassifier`: each row goes to its own library's annotation host, so the cross-domain and foreign-host rules have nothing to separate.

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
| Cross-domain 401 carve-out | `TPPNetworkResponder.swift:664` | `Log.info — 401 from cross-domain redirect or non-401 outcome (<outcome>) — not marking credentials stale` | Confirms cross-domain detection fired; absence on a known cross-domain 401 indicates regression |
| `/patrons/me` browser-auth bypass | `TPPNetworkResponder.swift:679` | `Log.info — Browser-auth 401 from /patrons/me/ poll — IdP cookie expired but bearer still likely valid; not dispatching coordinator` | Confirms the bypass is reached; absence on a SAML `/patrons/me` 401 means we'd mark stale |
| Browser-auth action-endpoint dispatch | `TPPNetworkResponder.swift:695` | `Log.info — Server returned 401 for browser-based auth on action endpoint — dispatching coordinator with reason=<reason>` | Confirms the 401 was handed to `AuthCoordinator` (which marks credentials stale before re-auth) |
| Token-refresh dispatch | `TPPNetworkResponder.swift:715` | `Log.info — Server returned 401 - triggering token refresh (server authority); classifier outcome=<outcome>` | Confirms we entered `refreshTokenAndResume` |
| Offline queue retry attempt | `TPPNetworkQueue.swift:545` | `Log.debug — Executing "retry" with N row(s) in the table` | Reachability-up retry pass; row count is the offline backlog |
| Offline queue 401 refresh | `TPPNetworkQueue.swift:653` | `Log.info — Queued request got 401; refreshing the token for its library` | A drained row 401'd and started its library's one refresh for this drain |
| Offline queue refresh failed | `TPPNetworkQueue.swift:695–696` | `Log.warn — Token refresh failed; keeping N queued request(s) for a later drain`, or `… did not finish in 90.0s; …` on timeout | The refresh was refused or timed out; the rows stay until `MaxRetriesInQueue` |
| Offline queue refresh slot busy | `TPPNetworkQueue.swift:689` | `Log.info — Another token refresh was in progress; keeping N queued request(s) without spending a retry` | Another request held the executor's refresh slot (common right after reconnect) |
| Offline queue 4xx/5xx on retry | `TPPNetworkQueue.swift:623` | `Log.warn — Queued Request retry failed with status N` | Queued retry hit an HTTP error, or a 401 that this drain does not refresh again; row is dropped after counter exhausted |
| Classifier outcome | `AuthErrorClassifier.swift:112` (PalaceAuth) | `AuthDecisionStep.classifierClassified` (`"classifier.classified"`, `AuthDecisionPayload.swift:22`), sent to the classifier's injected `AuthDecisionRecording` | Not emitted for network-layer 401s today. `TPPNetworkResponder.swift:647` (and `LoanRenewalService.swift:156`) construct the classifier without a recorder, so it uses the default `NullAuthDecisionRecorder`. The Crashlytics-backed `AuthDecisionRecorder` is passed only to `AuthCoordinator` (`AppContainer.swift:555–562`), so coordinator steps are recorded and responder classifications are not. |

---

## 6. Test surface

**Existing network test files** (`PalaceTests/Network/` — 32 test files as of 2026-10-06, the main ones listed below, plus 1 cross-cutting `MyBooks/TokenRefreshInterceptorTests.swift`):

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
- `PalaceTests/Network/NetworkQueueTokenRefreshTests.swift` (queued 401 refresh and resend; challenge answered with the row's library)
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
- Offline queue drains its rows on reachability-up and enqueues on transport failure, NOT on auth failure (`NetworkQueueTests`, `NetworkRetryTests`)
- Queued 401: one refresh per library per drain, no sign-in sheet, no refresh for non-token libraries, one resend with the new token from the row as stored now, rows kept when the refresh fails or times out (retry refunded when another refresh held the slot) and still capped by `MaxRetriesInQueue`; a Basic challenge on a queued request is answered with the row's library, never the selected one; `NetworkQueue.live` binds each lookup to the row's library and the refresher to the executor (`NetworkQueueTokenRefreshTests`)
- Multi-library credential isolation across concurrent token refreshes (`MultiLibraryTokenIsolationTests`)

**Tests that test IMPLEMENTATION (can be rewritten when underlying changes):**
- Tests that assert on specific call orders inside `TPPNetworkResponder`
- Tests that exercise the legacy `indicatesAuthenticationNeedsRefresh` direct-call path (only relevant until the two unmigrated consumer-side sites in MyBooks/ are routed through the classifier)

---

## 7. Known traps / anti-patterns (lessons from prior work)

- **Do NOT re-enable optimistic HTTP/3.** `urlRequest.assumesHTTP3Capable = false` at `TPPNetworkExecutor.swift:654`. Some library servers advertise h3 but have broken QUIC; iOS retries twice (~260ms wasted) before falling back to h2. With the flag off, first requests use h2 and the session upgrades to h3 automatically on subsequent requests if the server confirms working QUIC via Alt-Svc. The performance win from re-enabling would be wiped out by per-host first-contact retries — and the regression mode is silent (extra latency on cold first contact, no error surface). Don't change without testing each known-broken-h3 host.
- **Do NOT route cross-domain 401 through the coordinator.** Cross-domain detection lives in `URLResponse+TPPAuthentication.isSameDomain`, surfaced as `AuthOutcome.ok` from the classifier. The coordinator never sees this outcome — it's a network-layer carve-out at `TPPNetworkResponder.swift:647–666`. Routing it through the coordinator would mark Palace credentials stale on a biblioboard CDN 401 (the bug fixed in commit 10b5ecf0a).
- **Foreign-library cross-host 401 — base-domain matching is NOT enough** (added 2026-06-05 with #1044, which fixed a cross-host logout regression from PR #1018). The `isSameDomain` helper does BASE-DOMAIN matching (last two host components), so `gorgon.staging.palaceproject.io` and `minotaur.dev.palaceproject.io` return true. When the request URL's host is outside the current account's auth surface (different library backend within the same base domain), the responder MUST classify it as `.ok` via the new Rule 4b in `AuthErrorClassifier`. In production, `TPPNetworkResponder` at line 647 constructs the classifier with a `currentAccountHostsProvider` closure that reads `AppContainer.production().accountsManager.currentAccount?.authSurfaceHosts`. The default `{ nil }` provider (used by tests and any other consumer that doesn't opt in) preserves legacy behavior. A new responder construction site that omits the provider is shipping the latent foreign-host mis-attribution bug.
- **One 401-driven refresh-and-retry per URL** (`canRetry(url:)` at `TPPNetworkResponder.swift:208`, `maxRetryAttempts = 1` at line 107). This is a REQUEST-layer circuit-breaker; the coordinator's single-flight is a BEARER-layer circuit-breaker. They are NOT substitutes — keep both. A URL that 401s again after its retry should fail, not loop the coordinator.
- **Task-resume after token refresh is responder-owned** — `networkExecutor.refreshTokenAndResume(task:accountId:)` at `TPPNetworkResponder.swift:716` and `TPPNetworkExecutor.swift:884`. The coordinator's silent refresh refreshes the bearer; it does NOT re-run a specific `URLSessionTask`. If you push task-resume into PalaceAuth, you're conflating two layers.
- **`TokenRefreshInterceptor.swift:139` and `DownloadAuthRetryHandler.swift:197` still call `indicatesAuthenticationNeedsRefresh` directly.** This is a known PR #1018 deferral — out of scope for the TPPNetworkResponder-focused migration. Any new code in Palace/Network/ MUST go through `AuthErrorClassifier`; do NOT add a third call site of the legacy predicate while the deferral is in flight.
- **The auth decision is delegated to PalaceAuth.** The network layer should not implement its own auth-error decision logic. The single seam is `AuthErrorClassifier.classify(...)`; the single dispatcher is `AuthCoordinator`. New conditionals on `response.statusCode == 401` or on problem-doc shape should be at the classifier level, not at the responder.
- **Queued resends do not pass through the responder's completion path.** `TPPNetworkQueue` sends with `dataTask(with:completionHandler:)` (`TPPNetworkQueue.swift:612`), so the responder's `didCompleteWithError` 401 refresh and per-URL budget never run for it; the queue owns its 401 and calls `refreshTokenAndResume(task: nil, accountId:, presentsSignInOnFailure: false)` once per library per drain. Do not switch the drain to a delegate-style task to get the responder's handling instead: `handleExpiredTokenIfNeeded` refreshes the selected library, not the row's (`TPPNetworkResponder.swift:624`). Since #1629 the resume keeps the method, body and headers and swaps only the bearer (`resendableRetry`, `TPPNetworkExecutor.swift:1004`), so a queued POST would now survive the rebuild — but a row with a stream body is failed rather than resent (`TPPNetworkExecutor+RetryRequest.swift:33`), and the refresh still goes to the wrong library. Do not add a second refresh mechanism in the queue either; it must go through the executor's single-flight. Keep the queue's refresh silent (`presentsSignInOnFailure: false`) and bounded (`refreshTimeout`): a drain runs on reconnect with nobody looking, and a refresh completion that never arrives would otherwise stop every later drain.
- **A queued request's auth challenge must be answered by the row's library.** Challenge callbacks still reach a completion-handler task. The queue sets a per-task delegate (`TPPNetworkQueue.swift:631`) so the responder's handler, which answers with `currentUserAccount` in production (`TPPNetworkResponder.swift:867`), is not consulted. Removing that delegate, creating the task somewhere that does not set it, or binding `challengeCredentialsProvider` in `NetworkQueue.live` to the selected account sends the selected library's barcode and PIN to another library's server on a Basic challenge. Details: Section 3.
- **Account-aware credential snapshotting** — `TPPNetworkExecutor.request(for:useTokenIfAvailable:accountId:)` at line 646 takes a credential snapshot per request to prevent TOCTOU races during account switches. Without this, another thread changing `libraryUUID` between `sharedAccount()` and the property reads causes cross-account credential leaks. PR #1018 preserves this — do not optimize the snapshot away.

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
| callers | `TPPNetworkResponder.swift:739` (**sign-in**), `TPPProblemDocument+Localized.swift:11` (`try?`) | OPDS feed, `TPPUserFriendlyError`, `TokenRequest`, `OPDSParser`, `DownloadCompletionParser`, `LoanRenewalService` |

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
designed and written but deliberately split into its own PR. Until it lands, this is a
review-time check (PR #1462).

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

## 7c. Delivery isolation — where a completion runs (added 2026-10-08, PP-5301)

Section 7b covers what a response *says*. This section covers *where the answer
arrives*, which is a separate question and the one that crashed 3.3.0.

### The mechanism

The executor builds its sessions with `delegateQueue: nil`, so
`TPPNetworkResponder` fires every caller completion on a background thread.
That has been true since long before 3.3.0 and did not change.

What changed is the language mode (`876f7637f`: `SWIFT_VERSION` 5.0 → 6.0,
`SWIFT_STRICT_CONCURRENCY = complete`). A closure written inside a `@MainActor`
type **inherits main-actor isolation**, and a parameter typed
`(NYPLResult<Data>) -> Void` carries no isolation of its own, so the mismatch
type-checks. Under Swift 5 that was a warning nobody read; under Swift 6 the
isolation check is an assert, and the first main-actor-only call inside such a
completion traps in `swift_task_isCurrentExecutorWithFlags`.

Three instances reached patrons or review this way, and every one was found by a
person reading code:

| Where | Found | Outcome |
|---|---|---|
| `AudiobookLoader.refreshTokenIfNeeded` | 3.3.0 field crash (PP-5299) | fixed on 3.3.x with a hop, then made unrepresentable here |
| `AudiobookPositionResolver.awaitRemotePosition` | 3.3.0 field crash | fixed separately |
| `EpubSampleFactory.createSample` → `BookCellModel` | reading, PP-5301 | fixed here; reachable by tapping a sample with no network |

### The reviewer rule

Three questions, in order. Stop at the first "no".

1. **Is the closure written inside a `@MainActor` type or function?** If not,
   it is nonisolated and this class cannot apply.
2. **Is it delivered by something that answers off the main actor?** Anything
   through `TPPNetworkExecutor`, `TPPNetworkResponder`, `refreshTokenAndResume`,
   `URLSession`, Firebase Messaging, or a `Task` the callee started. A callee
   that documents main delivery, or one whose parameter is `@Sendable`, is not
   this.
3. **Does the closure body reach main-actor-only work?** A `@MainActor` method
   or property, a published property, UIKit. Note it reaches it at the **first**
   such statement — a `DispatchQueue.main.async` further down is below the thing
   being checked and does not save the statements above it.

Three yeses is an instance. The tell that finds them fastest is an **asymmetric
hop**: one arm of the same closure wrapped in a main hop and another not. Both
3.3.0 crashes and the sample-factory instance had exactly that shape, and the
author of each had clearly known the main thread mattered on the path they
wrapped.

### The remedy, in preference order

1. **Await the call.** A continuation resumes on the awaiting caller's actor, so
   the hazard is not guarded — it cannot be written. This is what PP-5301 did
   across sign-in, the audiobook load path, the sample paths and the profile
   document.
2. **Mark the callee's completion parameter `@Sendable`.** The closure can then
   no longer inherit isolation, and the compiler names every call site that was
   relying on it. Correct, but it leaves each caller to arrange its own hop.
3. **Hop inside the closure.** Fixes nothing the isolation check objects to
   unless the hop is the *first* statement and nothing above it touches
   main-actor state. Treat as a last resort and say why.

A `@unchecked Sendable` box around a completion is not a remedy for this class.
It silences the Sendable diagnostic, which is a different question, and leaves
the isolation mismatch exactly as it was — that is what every carrier PP-5301
deleted was doing.

### Decision: no new gate

An automated check was considered and **declined**, because the compiler already
is one. Remedies 1 and 2 are both compiler-enforced: once a completion parameter
is `@Sendable` or the call is `async`, a future caller cannot reintroduce the
mismatch without a build error. A `check-*` script would re-derive, less
reliably, what the type system already decides — and would need a heuristic for
"reaches main-actor-only work", which is exactly the part reading gets wrong.

Two measurements support this over a detector:

- Reading does not enumerate the population. Four sites were traced by hand
  during this work and the consequence was wrong at every one.
- `-enable-actor-data-race-checks` *does* reproduce the class on demand (it
  turns the sign-out suite red at the same assert as the field crash), but it is
  stricter than a release build: it also objects to a completion's own entry,
  not just to main-actor work inside it. That makes it a good instrument for
  finding candidates and a commitment as a gate — switching it on in CI means
  finishing the parameter migration everywhere first, not only where a patron
  could crash. It is not on today, and turning it on is its own decision.

What is in place instead: `TPPRequestExecuting` has no completion-handler
requirement left, so the laundering shape is unreachable through the protocol.
Where a completion-handler entry point survives on the concrete executor, the
caller rings that reach main-actor work have been converted.

### Still completion-shaped, and why that is safe

These were examined and cleared rather than converted. Each is safe for a stated
reason, not by inspection of the happy path:

- `URLSessionNetworkClient` (5 sites) — every call is inside a
  cancellation-aware continuation bridge; the closure only resumes it.
- `TPPOPDSFeed.withURL` → `OPDSFeedService` — the handler's every exit is
  dispatched through `TPPAsyncDispatch`, which is the **global** queue, not
  main; the single Swift consumer is an `actor` that bridges it straight to a
  continuation. The signature is Objective-C-facing (`NSDictionary`).
- `NetworkExecutorRenewalPoster.post` — a continuation bridge inside a
  nonisolated `Sendable` type; `RenewalPosting` is already `async`.
- `NotificationService`'s three `addBearerAndExecute` calls — the type is
  nonisolated, so its closures are, and none reaches main-actor-only work. The
  separate `accountId` defect on this path (PP-4986) is recorded at
  `TPPNetworkExecutor.performDataTask`.
- `Account.loadAuthenticationDocument` — `Account` is nonisolated, so the
  closure it builds is too. Its *callers* pass main-actor-isolated closures and
  those callers hop; the hops are present at all nine call sites today. This is
  remedy 3, and it is the largest remaining completion surface in the app —
  nine sites, plus the injected closure seam in `AccountRegistryLoader` and the
  sign-in single-flight guard in `AuthDocumentLoader`. Converting it is tracked
  work, not a claim about today's safety.
  (`Account.loadLogo` was in this list until PP-5301 converted it; it takes no
  closure now and its fetch is awaited.)

---

## 7d. The three callback surfaces outside the network layer (PP-5301)

PP-5301 named three surfaces the first pass never reached. Each was audited by
the rule in 7c. Two are clear for a stated reason; one has a defect that is
upstream, and one unresolved candidate.

### Firebase — clear by construction

Both consumers are nonisolated: `FirebaseManager` and `NotificationService` are
each `@unchecked Sendable` classes with no actor isolation. Every closure they
hand Firebase Messaging or Remote Config is therefore nonisolated, so question 1
of the rule answers no. This holds for the whole surface, not a sampled part of
it — a future `@MainActor` consumer of a Firebase callback would need the rule
applied again.

### The reading engine (Readium 3.x) — clear, and enforced by the compiler

`NavigatorDelegate`, `VisualNavigatorDelegate` and `EPUBNavigatorDelegate` are
declared `@MainActor` in the pinned toolkit, and `PDFNavigatorDelegate` inherits
it. Readium states the isolation in its own types, so the four Palace
conformances cannot be entered off the main actor without a build error. This is
remedy 2 from 7c applied upstream, and it is why none of those four needs
`@preconcurrency`.

`DecorableNavigator` is the exception: it is nonisolated, and
`TPPEPUBViewController` conforms `@preconcurrency`. It is cleared because
nothing in Readium calls it on an external conformer — the protocol is mentioned
in two files there, its own declaration and `EPUBNavigatorViewController`'s
conformance — so the only caller is Palace, from the main actor. If a Readium
upgrade starts dispatching decorations itself, re-check this one first.

The `@preconcurrency import ReadiumShared` / `ReadiumNavigator` at the top of
the reader files are about `Sendable` on value types (`Locator`, `Decoration`),
a different question; the reason is recorded at
`TPPBaseReaderViewController.swift:40`.

### The audiobook toolkit — the hazard is real and the hops are present

`AudiobookBookmarkDelegate` is a nonisolated protocol, but every completion
passed to it is built inside `DefaultAudiobookManager`, which is `@MainActor`.
Those closures therefore inherit main-actor isolation, and two of them write
`bookmarks` on the manager — `saveBookmark` at `AudiobookManager.swift:815` and
`deleteBookmark` at `:826`. Palace's conformer,
`AudiobookBookmarkBusinessLogic`, is nonisolated and does its work on the
network. So this is the full shape: a main-actor closure, invoked by nonisolated
Palace code, that touches main-actor state.

It does not fire today because Palace hops at every exit that reaches those two
closures (`saveBookmark`, `deleteBookmark`, `deleteBookmarkByContentMatch`,
`finalizeSync` all deliver through `DispatchQueue.main.async`). That is remedy 3
— correct, and dependent on four separate call sites staying correct.
`saveListeningPosition`'s early exit does not hop, and is safe only because the
toolkit's closure for it writes a local variable and touches nothing isolated.

The durable fix is upstream: marking the four `AudiobookBookmarkDelegate`
completions `@MainActor`, which makes the hops the compiler's job instead of the
author's. That is a change in the toolkit submodule and is not made here.

### Unresolved: `AVSpeechSynthesizerDelegate` in reader TTS

`TPPPublicationSpeechSynthesizer` is `@MainActor` and conforms
`@preconcurrency AVSpeechSynthesizerDelegate`
(`TPPPublicationSpeechSynthesizer.swift:364`). The one implemented method calls
`didFinishUtterance()`, which reads `state` and can call `playNextUtterance` —
main-actor state on a main-actor type. A `@preconcurrency` conformance accepts
the isolation mismatch and checks it at runtime, so if AVFoundation delivers
this callback off the main actor it traps rather than warns.

Whether it does is not settled. Apple does not document a delivery queue for
`AVSpeechSynthesizerDelegate`, and reading cannot answer it — that is the
mistake 7c records. The sibling case has an answer and states it:
`AudiobookSamplePlayer`'s `AVAudioPlayerDelegate` conformance carries a comment
explaining that AVFoundation delivers on the run loop where the player was
created, which is always main there. This one carries no such comment.

The discriminating check, for whoever picks it up: build with
`-enable-actor-data-race-checks`, start TTS on an EPUB, and let one utterance
finish. A trap in `speechSynthesizer(_:didFinish:)` settles it; a clean finish
means the delivery is main and the conformance should say so in a comment.

---

## 8. Pre-change checklist

Before any non-trivial change in this area:

1. **Refresh this file's sections 1, 3, and 4** — confirm the call-site map, the request/response flow matrix, and the decision boundary are still accurate. Re-grep `statusCode == 401` and `statusCode == 403` across `Palace/Network/` (`grep -rn 'statusCode == 40[13]' Palace/Network/`) — expected matches are `TPPNetworkResponder.swift` lines 426, 435, 516 and 656; anything else needs triage.
2. **Verify the cross-domain 401 carve-out still exists.** `grep -n "AuthErrorClassifier(\|outcome == .ok\|patrons/me" Palace/Network/TPPNetworkResponder.swift` — expect exactly these lines: 540, 624, 625 (comments mentioning `/patrons/me`), 635 (classifier construction), 651 (the `.ok` short-circuit), and 660, 663, 667 (the `/patrons/me` browser bypass). The responder should no longer call `indicatesAuthenticationNeedsRefresh`. Read the surrounding comments; both bypasses have hotfix-driven rationale that should not be silently removed.
3. **Verify the per-URL token-refresh budget hasn't been re-implemented somewhere else.** `grep -n 'maxRetryAttempts\|canRetry(url\|markRetried(url' Palace/Network/TPPNetworkResponder.swift` — the budget is `retriedURLs` + `maxRetryAttempts = 1`, owned by `TPPNetworkResponder`. (`tokenRefreshAttempts` still exists at lines 75 and 238 but is never read; it is not the budget.) The coordinator's single-flight is separate and lives in `AuthCoordinator`.
4. **Confirm `AuthErrorClassifier` is the single seam for auth-error decisions.** `grep -rn 'indicatesAuthenticationNeedsRefresh' Palace/` — only the two known deferrals (`TokenRefreshInterceptor.swift:139`, `DownloadAuthRetryHandler.swift:197`) plus the comments above them (lines 124 and 185) should appear outside the PalaceAuth package's own implementation. Any new call sites are scope debt.
5. **Re-run the test inventory** — `find PalaceTests/Network -name '*Tests*.swift' | wc -l` was 32 on 2026-10-06. `TPPNetworkResponderAuthCoordinatorTests` and the PalaceAuth `AuthErrorClassifierTests` should be present.
6. **Confirm what reaches the offline queue.** `grep -rn 'enqueueOfflineRequest\|addToOfflineAnalyticsQueue\|addToOfflineQueue\|\.addRequest(' Palace --include='*.swift'` — expect `TPPAnnotations.swift` lines 440, 830, 836, `TPPCirculationAnalytics.swift` lines 55, 64, `TPPNetworkQueue.swift` line 845, and the protocol declaration at `Palace/Packages/PalaceNetwork/Sources/PalaceNetwork/CirculationOfflineSupport.swift:15`. A new caller of `addToOfflineAnalyticsQueue` or `enqueueOfflineRequest` means GET requests are queued in production; update Section 3.
7. **Re-check critical-path tests pass on develop BEFORE the change starts.** Run `TokenRefreshTests`, `TokenRefreshAndRetryQueueTests`, `URLResponseAuthenticationTests`, `MultiLibraryTokenIsolationTests`, `NetworkQueueTests`, and `NetworkQueueTokenRefreshTests` in isolation so later regressions are attributable.
8. **Confirm HTTP/3 disable is still in place.** `grep -n assumesHTTP3Capable Palace/Network/TPPNetworkExecutor.swift` — should match at line 637. If missing, that's a regression on the historical fix and needs investigation before any new network change ships.
9. **Confirm the queue still owns its 401 and challenge handling.** `grep -n 'code == 401\|task.delegate = \|refreshTokenAndResume(task: nil\|presentsSignInOnFailure: false' Palace/Network/TPPNetworkQueue.swift` — expect the 401 branch in `send` (line 610), the per-task challenge delegate (line 623), the refresh call (line 648) and its sign-in opt-out (line 650). `grep -n 'NetworkQueue.live(' Palace/AppInfrastructure/AppContainer.swift` should match once (line 599). If the drain stops using a completion-handler task, or a send path stops setting the task delegate, re-check Sections 3 and 7: the responder's 401 refresh and its challenge fallback both act for the selected library.
10. **Update Section 9 (refresh history)** with date + your initials, and the frontmatter `sources:` block (`verified_ref` = the commit you checked against).

---

## 9. Refresh history

| Date | Refreshed by | Notes |
|------|-------------|-------|
| 2026-10-07 | PP-5301 | `TPPRequestExecuting` now exposes one `async execute` and the two completion-handler requirements are gone; `TPPNetworkExecutor` gained a native async entry point, and the account resolution, SAML short-circuit and near-expiry refresh both entry points need are one private `preflight`. Merging develop (#1613, #1617) shifted every citation into `TPPNetworkExecutor.swift` again, so each was re-measured against the merged file by symbol rather than by arithmetic: the HTTP/3 opt-out to 637, `refreshTokenAndResume` to 867, the credential-snapshot request builder to 629, the near-expiry branch to 499–505 with the SAML skip at 494 (both inside `preflight`), the refresh-and-resend request rebuild to 984, and the initializer range to 261–263. `verified_ref` and `fingerprint` are left at the re-stamp's 503ef9965 / 1b7d5e8c: this change moves `TPPNetworkExecutor.swift`, one of the fingerprinted paths, and only its citations were re-checked here, so the hash mismatch is the drift signal rather than a claim of whole-set freshness. Source comments that cited executor line numbers name the symbol instead. |
| 2026-10-06 | network checklist re-stamp | Re-verified every line citation into `sources.paths`, the Section 8 self-check outputs and the negative claims against 503ef9965 (#1613). Corrected the `refreshThenResend` / `finishRefresh` range to 629–692, the count of other `URLProtocol` subclasses in Section 2 to ten (#1613 added two), and the Section 6 test-file count to 32. Re-stamped `verified_ref` to 503ef9965 and recomputed `fingerprint`. |
| 2026-10-06 | queued-401 fix (fix/network-queue-401-refresh) | Updated the queue passages in Sections 1, 3, 4, 5, 6, 7 and 8 for the fix: on a 401 the queue calls the executor's single-flight `refreshTokenAndResume` for the row's library (once per library per drain, token and OAuth libraries only, `presentsSignInOnFailure: false`) and resends once from the row as stored; a busy refresh slot refunds the retry; a refresh is bounded by `defaultRefreshTimeout`; a delivered row is deleted only if unchanged; Basic challenges are answered with the row's library credentials through a per-task delegate. Production builds the queue through `NetworkQueue.live`. Added the executor's `presentsSignInOnFailure` parameter, `presentSignInAfterRefusedRefresh` and `refreshInProgressKey` to Section 1 and re-cited the shifted `TPPNetworkExecutor.swift` lines. Both delegate behaviours were confirmed on an iOS simulator by probe (the macOS probe cited earlier is superseded). `TPPNetworkQueue.swift`, `TPPNetworkExecutor.swift` and `AppContainer.swift` line citations refer to the files after this fix. Re-stamped `verified_ref` to fb6533e1a, this branch's base; of the listed paths, `TPPAnnotations.swift` (#1607) and `URLSessionNetworkClient.swift` (#1606) changed since 4c65025be; the `TPPAnnotations.swift` citations in Sections 3 and 8 were re-checked and updated, and the `URLSessionNetworkClient.swift` change did not move any cited line. |
| 2026-10-06 | network checklist refresh | Corrected Section 3: the executor and responder never enqueue; the queue's live producer is the annotation POST on transport failure, and `enqueueOfflineRequest` (3f659ff2e) accepts GET but has no production caller. Removed the 5xx, `cachePolicy` and PATCH enqueue cells and the "GET requests are NOT enqueued" note; added the DELETE no-refresh row; replaced "per-task budget caps at 2". Corrected the queue's retry description in Section 1 and the "single stubbing seam" claim in Section 2. Added a Section 8 queue self-check and the files these claims cite to `sources.paths`; corrected the `AppContainer.swift` coordinator-recorder citation to 555–562. Stated that queued requests get no token refresh (the drain's completion-handler task does not get the responder's `didCompleteWithError` 401 handling) and are resent on 401 up to the retry cap; corrected the `URLSessionNetworkClient` and `NetworkTransport` descriptions; noted the release-build GET fallback in `enqueueOfflineRequest`. Narrowed the delegate claim: challenge callbacks still reach the responder for queued requests and answer with the selected library's credentials; added that path and its cross-library consequence to Sections 3 and 7. Re-checked the remaining negative claims against 4c65025be. |
| 2026-10-06 | owned-services routing | Section 2: `URLSessionNetworkClient.init` no longer defaults `executor` to `AppContainer.production().networkExecutor`; every caller passes one. |
| 2026-10-05 | network checklist refresh | Confirmed the PR #1018 classifier migration is on develop (f380e37c3) and removed the "not yet landed" notes. Re-verified every line citation and the Section 8 self-check against 3ad580c0d. Corrected the retry-budget description: it is one retry per URL (`maxRetryAttempts = 1`), not `tokenRefreshAttempts < 2`. Replaced two test files that were never added (`CrossDomain401Tests`, `AuthErrorCategoryTests`) with the classifier tests that cover the same rules. Added the `sources:` frontmatter. |
| 2026-09-23 | PR #1462 (PP-5202) | Added Section 7b — the problem-document DECODE seam. Sections 1–7 covered classification over an already-parsed document and were silent on parsing; that gap shipped a sign-in regression where a wrong-typed `show_title` discarded the whole document and a blocked patron was told their password was wrong. Section 7b documents the two parse paths and their different contracts, the `.convertFromSnakeCase` CodingKeys trap and its detector, the no-custom-encoder decision, and the strict/lenient `0` disagreement as known debt. |
| 2026-05-28 | PR #1019 (initial baseline) | Initial baseline. Mirrors the auth area's `verification-checklist.md` structure. Migration status in Section 1 reflects the PR #1018 design baseline (commit f9e57f7f5); at the time, develop still called `indicatesAuthenticationNeedsRefresh` directly. |

---

**This file is owned by the network area.** If you change anything in `Palace/Network/`, in the `URLResponse+TPPAuthentication` extension, or in the two consumer-side classifier callers (`TokenRefreshInterceptor.swift:139`, `DownloadAuthRetryHandler.swift:197`), update the relevant section here before you commit. The Definition of Done (CLAUDE.md) treats out-of-date area checklists as scope debt. Paired with `docs/architecture/areas/auth/verification-checklist.md` — auth-layer decisions and network-layer routing meet at the classifier seam; keep both files in sync when that seam moves.
