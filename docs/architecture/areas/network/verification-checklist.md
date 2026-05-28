---
name: network-verification-checklist
type: evolving
status: active
created: 2026-05-28
last_refresh: 2026-05-28
freshness_window: 180d
owners: [network]
description: Per-area verification reference; refresh before next swarm/rigorous-fix
---

<!-- audit-verified: Owner files in Palace/Network/ confirmed by `ls Palace/Network/` (Core/, TPPNetworkExecutor.swift, TPPNetworkResponder.swift, TPPNetworkQueue.swift, TPPRequestExecuting.swift, TPPUserFriendlyError.swift, Bundled/RemoteHTMLViewController.swift). Line citations in Sections 1, 4, and 7 verified by grep against the current branch (chore/swarm-rigor-meta-improvement). The "MIGRATED in PR #1018 / swarm_66819d80" status reflects the swarm-scaffold branch (swarm/swarm_66819d80-scaffold, commit f9e57f7f5) — that work has NOT yet landed on develop, so on develop the responder still routes via `indicatesAuthenticationNeedsRefresh`. Section 1's "Migration status" column therefore describes the design baseline this checklist documents, not the develop tip. Refresh the next architect: re-grep before assuming. -->

# Network area — verification checklist

**Owner area:** `Palace/Network/` (`TPPNetworkExecutor.swift`, `TPPNetworkResponder.swift`, `TPPNetworkQueue.swift`, `TPPRequestExecuting.swift`, `Core/URLSessionNetworkClient.swift`), plus the auth-error classifier extension `Palace/Packages/PalaceAuth/Sources/PalaceAuth/URLResponse+TPPAuthentication.swift` and the test stub infrastructure at `PalaceTests/HTTPStubURLProtocol.swift`. Two consumer-side files still hold direct auth-classification calls and are tracked in Section 1 as next-sprint candidates: `Palace/MyBooks/TokenRefreshInterceptor.swift` and `Palace/MyBooks/DownloadAuthRetryHandler.swift`.

**Purpose:** the architect's first deliverable on ANY swarm or /rigorous-fix in this area is *update this file*. Verify what's still true, add what's changed, mark what's UNKNOWN. Without it, every new initiative re-discovers the same surface (the auth area's PR #1018 architect produced ~1,000 lines of recon docs that should have started from a baseline like this — and the network slice of that recon is what this file captures).

**Last refresh:** 2026-05-28 (post PR #1018 / swarm_66819d80 — see `docs/architecture/areas/auth/verification-checklist.md` for the paired auth surface).
**Refreshing architect:** sign and date the next-refresh row at the bottom of this file.

---

## 1. Call-site map (sites in the network layer that handle 401/403, manage token refresh, or hand off to PalaceAuth)

| File | Lines | What it does | Migration status |
|------|-------|-------------|------------------|
| `Palace/Network/TPPNetworkResponder.swift` | 221, 230, 367 | Top-of-pipeline `statusCode == 401` checks that decide whether to enqueue + drive `refreshTokenAndResume` | **MIGRATED** in PR #1018 / swarm_66819d80 — the responder is now a thin router. Per-task `tokenRefreshAttempts < 2` budget (lines 34, 96, 369) preserved as a responder-owned concern (task-layer, not auth-layer). |
| `Palace/Network/TPPNetworkResponder.swift` | 436–498 (`handleExpiredTokenIfNeeded`) | Cross-domain 401 carve-out + `markCredentialsStale` + dispatch to `refreshTokenAndResume` | **MIGRATED** in PR #1018 / swarm_66819d80 — routes the 401 decision through `AuthErrorClassifier.classify(...)`. Cross-domain detection now lives behind the classifier (`.ok` outcome short-circuits). The `/patrons/me` browser-auth bypass + the non-browser inline `markCredentialsStale + refreshTokenAndResume` are preserved by design — see Section 4. |
| `Palace/Network/TPPNetworkExecutor.swift` | 272 | `urlRequest.assumesHTTP3Capable = false` — disables optimistic HTTP/3 upgrade on first contact per host | **STABLE** — historical, not part of PR #1018. Do not re-enable; see Section 7 trap. |
| `Palace/Network/TPPNetworkExecutor.swift` | 490 (`refreshTokenAndResume(task:accountId:completion:)`) | Single-flight token-refresh + post-refresh resume of the original `URLSessionTask` | **STABLE** — responder-owned task-resume seam. The coordinator's silent refresh path can refresh the token but does NOT re-run THIS URLSessionTask, so this seam stays in the network layer. |
| `Palace/Network/TPPNetworkExecutor.swift` | 230 (refresh-then-execute branch) | Pre-flight refresh + resume when account credentials are already stale | **STABLE** — paired with the responder's reactive path; both call into `refreshTokenAndResume`. |
| `Palace/Network/TPPNetworkQueue.swift` | 58, 70, 181–253 | Offline retry queue (SQLite-backed); reachability-driven `retryQueue()` + per-row retry counter | **STABLE** — no auth-error semantics; queue retries by HTTP status only (`code != 401/403/5xx` paths in the per-row `retry`). Queue does NOT trigger token refresh — it relies on the responder to do that on retry-completion. |
| `Palace/Packages/PalaceAuth/Sources/PalaceAuth/URLResponse+TPPAuthentication.swift` | 42–158 | `indicatesAuthenticationNeedsRefresh(with:originalRequestURL:)` — the legacy auth-error classifier extension | **LIVE BUT FENCED** — moved into PalaceAuth in earlier extraction. Still called by the two unmigrated consumer-side sites below. Inside `AuthErrorClassifier` it remains the underlying primitive; outside callers should switch to the classifier. |
| `Palace/Network/Core/URLSessionNetworkClient.swift` | n/a | Pure-transport SPM-bound URLSession wrapper (`PalaceNetwork` module trunk) | **STABLE** — no auth surface; transport-only. |

**STILL UNMIGRATED** (next-sprint candidates, explicit PR #1018 deferral):
- `Palace/MyBooks/TokenRefreshInterceptor.swift:79` — still calls `httpResponse?.indicatesAuthenticationNeedsRefresh(with: problemDoc, originalRequestURL: originalURL)`. Out-of-scope for the TPPNetworkResponder-focused migration; tracked as follow-up.
- `Palace/MyBooks/DownloadAuthRetryHandler.swift:95` — same call shape, same deferral.

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
- **No verb gets retried by the queue on 401** — the queue retries on transport failure, not auth failure. Token refresh is responder-driven, not queue-driven.
- **Cross-domain 401** is detected by `URLResponse+TPPAuthentication.isSameDomain` (called from the classifier). The historical anti-pattern was marking Palace credentials stale because biblioboard.com returned 401 — see commit 10b5ecf0a.

---

## 4. Decision boundary — network layer vs PalaceAuth

The responder is now a thin router. The boundary is explicit:

**Stays in the network layer (responder/executor own these):**

1. **Per-task token-refresh budget** — `tokenRefreshAttempts < 2` at `TPPNetworkResponder.swift:369` (counter at line 34, reset at line 96). This is a TASK-layer circuit-breaker; the coordinator's single-flight is a BEARER-layer circuit-breaker. Both serve different roles and both must exist.
2. **Cross-domain 401 detection** at `TPPNetworkResponder.swift:436–443`. After PR #1018 / swarm_66819d80 this is computed by `AuthErrorClassifier` (classifier returns `.ok` for cross-domain), but the call site is in the responder. The classifier is the seam — the predicate (`URLResponse+TPPAuthentication.isSameDomain`) is the implementation. DO NOT route the cross-domain decision through the coordinator — the coordinator never sees a `.ok` outcome.
3. **Task resume after refresh** — `networkExecutor.refreshTokenAndResume(task:accountId:)` at `TPPNetworkResponder.swift:495` and `TPPNetworkExecutor.swift:490`. The coordinator can refresh the bearer but cannot re-run a specific `URLSessionTask`; that's a network-executor concern.
4. **`/patrons/me` browser-auth bypass** — at `TPPNetworkResponder.swift:467–475`. Browser-auth (SAML/OIDC) has two surfaces (bearer + IdP cookie) and the IdP cookie expires faster than the bearer in Gorgon. A 401 from `/patrons/me` while the bearer is still good drove the cross-launch credentials-stale loop fixed in the 3.0.2 hotfix stack (commits 8d1dacafb, 46da46fb7). DO NOT remove this bypass.
5. **HTTP/3 disable** at `TPPNetworkExecutor.swift:272` (`assumesHTTP3Capable = false`).
6. **Offline retry queue** — `TPPNetworkQueue` retries on reachability-up, not on auth failure.

**Delegated to PalaceAuth (the auth decision is NOT the network layer's concern):**

1. **Auth-error classification** — `AuthErrorClassifier.classify(response:problemDocument:body:originalRequestURL:callSite:)` returns `AuthOutcome` (`.ok`, `.expiredToken`, `.invalidCredentials`, `.forbidden`, `.serverError`, `.networkError`). The responder reads the outcome and ROUTES; it does not DECIDE.
2. **Dispatch matrix per AuthMechanism** — basic/token/saml/oidc/oauthIntermediary fan-out lives in `AuthCoordinator`. See `docs/architecture/areas/auth/verification-checklist.md` Section 3 for the matrix.
3. **Single-flight semantics** — coordinator owns the per-coordinator-instance single-flight + 30s post-failure cooldown. The network layer's per-task budget is in ADDITION to this, not a substitute for it.
4. **Telemetry** — every classifier outcome emits via `AuthDecisionRecording`. Network layer does not emit auth telemetry directly.

Architects: if you find yourself adding a new `if statusCode == 401` branch in Palace/Network/, STOP — that decision belongs in `AuthErrorClassifier`. The network layer routes; it does not classify.

---

## 5. Telemetry surface points (network layer)

| Surface point | File | Event / Log | What it tells you |
|---------------|------|-------------|-------------------|
| Cross-domain 401 carve-out | `TPPNetworkResponder.swift:441` | `Log.info — 401 from cross-domain redirect - not marking credentials stale` | Confirms cross-domain detection fired; absence on a known cross-domain 401 indicates regression |
| `/patrons/me` browser-auth bypass | `TPPNetworkResponder.swift:473` | `Log.info — Browser-auth 401 from /patrons/me/ poll — IdP cookie expired but bearer still likely valid` | Confirms the bypass is reached; absence on a SAML `/patrons/me` 401 means we'd mark stale |
| Browser-auth action-endpoint stale | `TPPNetworkResponder.swift:479` | `Log.info — Server returned 401 for browser-based auth on action endpoint - credentials marked stale` | Confirms we entered the modal-prompting path |
| Token-refresh dispatch | `TPPNetworkResponder.swift:494` | `Log.info — Server returned 401 - triggering token refresh (server authority)` | Confirms we entered `refreshTokenAndResume` |
| Offline queue retry attempt | `TPPNetworkQueue.swift:199` | `Log.debug — Executing "retry" with N row(s) in the table` | Reachability-up retry pass; row count is the offline backlog |
| Offline queue 4xx/5xx on retry | `TPPNetworkQueue.swift:247` | `Log.warn — Queued Request retry failed with status N` | Queued retry hit an HTTP error; row is dropped after counter exhausted |
| Classifier outcome (post-migration) | `AuthErrorClassifier.swift` (PalaceAuth) | `classifierOutcome` telemetry event | Source-of-truth for auth-decision audit; payload `(idp_type, library_uuid, status_code, problem_doc_type, decision)` |

---

## 6. Test surface

**Existing network test files** (`PalaceTests/Network/` — 24 test files, plus 1 cross-cutting `MyBooks/TokenRefreshInterceptorTests.swift`):

Token refresh / auth dispatch:
- `PalaceTests/Network/TokenRefreshTests.swift`
- `PalaceTests/Network/TokenRefreshAndRetryQueueTests.swift`
- `PalaceTests/Network/TokenRefreshOnForegroundTests.swift`
- `PalaceTests/Network/TokenResponseTests.swift`
- `PalaceTests/MyBooks/TokenRefreshInterceptorTests.swift` (consumer-side)

Responder behavior:
- `PalaceTests/Network/TPPNetworkResponderTests.swift`
- `PalaceTests/Network/TPPNetworkResponderAuthCoordinatorTests.swift` *(lands with swarm_66819d80; verify presence)*
- `PalaceTests/Network/URLResponseAuthenticationTests.swift`
- `PalaceTests/Network/URLResponseNYPLTests.swift`
- `PalaceTests/Network/CrossDomain401Tests.swift` *(lands with swarm_66819d80; verify presence)*
- `PalaceTests/Network/AuthErrorCategoryTests.swift` *(lands with swarm_66819d80; verify presence)*

Executor / transport / queue:
- `PalaceTests/Network/TPPNetworkExecutorTests.swift`
- `PalaceTests/Network/NetworkClientTests.swift`
- `PalaceTests/Network/NetworkQueueTests.swift`
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
- `PalaceTests/Network/URLExtensionsTests.swift`
- `PalaceTests/Network/URLRequestExtensionsTests.swift`
- `PalaceTests/Network/URLRequestNYPLAdditionsTests.swift`

**Stubbing pattern (mandatory for any new network test):**
- `URLSession.stubbedSession()` factory + `HTTPStubURLProtocol.setHandler { request in (Data, HTTPURLResponse) }` per test. File: `PalaceTests/HTTPStubURLProtocol.swift`.
- Never hit a real URLSession; never call `.shared` URLSession.
- Reset the handler in `tearDown` to avoid handler-leak between tests.
- For per-account credential snapshotting tests, inject an `AccountsManager` via `AppContainer` rather than relying on `.shared`.

**Tests that test BEHAVIOR (must-survive any refactor):**
- 401 → classifier → refresh-and-resume round-trip (`TokenRefreshAndRetryQueueTests`, `TPPNetworkResponderAuthCoordinatorTests`)
- Cross-domain 401 does NOT mark Palace credentials stale (`CrossDomain401Tests`, `URLResponseAuthenticationTests`)
- `/patrons/me` browser-auth bypass — bearer-still-valid case (`URLResponseAuthenticationTests`, responder integration)
- Per-task token-refresh budget caps at 2 (`TokenRefreshTests` / `TokenRefreshAndRetryQueueTests`)
- Offline queue retries POST/PATCH/PUT/DELETE on reachability-up, NOT on auth failure (`NetworkQueueTests`, `NetworkRetryTests`)
- Multi-library credential isolation across concurrent token refreshes (`MultiLibraryTokenIsolationTests`)

**Tests that test IMPLEMENTATION (can be rewritten when underlying changes):**
- Tests that assert on specific call orders inside `TPPNetworkResponder` (these will shift when the swarm classifier is added — verify post-migration)
- Tests that exercise the legacy `indicatesAuthenticationNeedsRefresh` direct-call path (only relevant until the two unmigrated consumer-side sites in MyBooks/ are routed through the classifier)

---

## 7. Known traps / anti-patterns (lessons from prior work)

- **Do NOT re-enable optimistic HTTP/3.** `urlRequest.assumesHTTP3Capable = false` at `TPPNetworkExecutor.swift:272`. Some library servers advertise h3 but have broken QUIC; iOS retries twice (~260ms wasted) before falling back to h2. With the flag off, first requests use h2 and the session upgrades to h3 automatically on subsequent requests if the server confirms working QUIC via Alt-Svc. The performance win from re-enabling would be wiped out by per-host first-contact retries — and the regression mode is silent (extra latency on cold first contact, no error surface). Don't change without testing each known-broken-h3 host.
- **Do NOT route cross-domain 401 through the coordinator.** Cross-domain detection lives in `URLResponse+TPPAuthentication.isSameDomain`, surfaced as `AuthOutcome.ok` from the classifier. The coordinator never sees this outcome — it's a network-layer carve-out at `TPPNetworkResponder.swift:436–443`. Routing it through the coordinator would mark Palace credentials stale on a biblioboard CDN 401 (the bug fixed in commit 10b5ecf0a).
- **Per-task token-refresh budget caps at 2** (`TPPNetworkResponder.swift:369`). This is a TASK-layer circuit-breaker; the coordinator's single-flight is a BEARER-layer circuit-breaker. They are NOT substitutes — keep both. A task that 401s thrice should fail, not loop the coordinator.
- **Task-resume after token refresh is responder-owned** — `networkExecutor.refreshTokenAndResume(task:accountId:)` at `TPPNetworkResponder.swift:495` and `TPPNetworkExecutor.swift:490`. The coordinator's silent refresh refreshes the bearer; it does NOT re-run a specific `URLSessionTask`. If you push task-resume into PalaceAuth, you're conflating two layers.
- **`TokenRefreshInterceptor.swift:79` and `DownloadAuthRetryHandler.swift:95` still call `indicatesAuthenticationNeedsRefresh` directly.** This is a known PR #1018 deferral — out of scope for the TPPNetworkResponder-focused migration. Any new code in Palace/Network/ MUST go through `AuthErrorClassifier`; do NOT add a third call site of the legacy predicate while the deferral is in flight.
- **The auth decision is delegated to PalaceAuth.** The network layer should not implement its own auth-error decision logic. The single seam is `AuthErrorClassifier.classify(...)`; the single dispatcher is `AuthCoordinator`. New conditionals on `response.statusCode == 401` or on problem-doc shape should be at the classifier level, not at the responder.
- **`TPPNetworkQueue` is offline-retry, not auth-retry.** The queue retries POST/PATCH/PUT/DELETE on reachability-up; it does NOT trigger token refresh and does NOT enqueue on 401. Don't add auth-aware behavior to the queue — it'll race with the responder's per-task budget.
- **Account-aware credential snapshotting** — `TPPNetworkExecutor.request(for:useTokenIfAvailable:accountId:)` at line 264 takes a credential snapshot per request to prevent TOCTOU races during account switches. Without this, another thread changing `libraryUUID` between `sharedAccount()` and the property reads causes cross-account credential leaks. PR #1018 / swarm_66819d80 preserves this — do not optimize the snapshot away.

---

## 8. Architect's pre-swarm checklist (what to verify before writing a new contract)

Before any new swarm or /rigorous-fix in this area, the architect should:

1. **Refresh this file's sections 1, 3, and 4** — confirm the call-site map, the request/response flow matrix, and the decision boundary are still accurate. Re-grep `statusCode == 401` and `statusCode == 403` across `Palace/Network/` (`grep -rn 'statusCode == 40[13]' Palace/Network/`) — any new matches outside Section 1's known sites need triage.
2. **Verify the cross-domain 401 carve-out still exists.** `grep -n "indicatesAuthenticationNeedsRefresh\|isSameDomain\|cross-domain" Palace/Network/TPPNetworkResponder.swift` — both the `.ok` short-circuit and the `/patrons/me` browser bypass should be present. Read the surrounding comments; both bypasses have hotfix-driven rationale that should not be silently removed.
3. **Verify the per-task token-refresh budget hasn't been re-implemented somewhere else.** `grep -rn 'tokenRefreshAttempts\|refreshAttempts' Palace/` — there should be exactly one counter, owned by `TPPNetworkResponder`. The coordinator's single-flight is separate and lives in `AuthCoordinator`.
4. **Confirm `AuthErrorClassifier` is the single seam for auth-error decisions.** `grep -rn 'indicatesAuthenticationNeedsRefresh' Palace/` — only the two known deferrals (`TokenRefreshInterceptor.swift:79`, `DownloadAuthRetryHandler.swift:95`) should appear outside the PalaceAuth package's own implementation. Any new call sites are scope debt.
5. **Re-run the test inventory** — `find PalaceTests/Network -name '*Tests*.swift' | wc -l` should be ≥24. New responder tests (`TPPNetworkResponderAuthCoordinatorTests`, `CrossDomain401Tests`, `AuthErrorCategoryTests`) should be present post-swarm — if missing, the swarm hasn't landed yet.
6. **Re-check critical-path tests pass on develop BEFORE the swarm starts.** Run `TokenRefreshTests`, `TokenRefreshAndRetryQueueTests`, `URLResponseAuthenticationTests`, `MultiLibraryTokenIsolationTests`, and `NetworkQueueTests` in isolation so post-swarm regressions are attributable.
7. **Confirm HTTP/3 disable is still in place.** `grep -n assumesHTTP3Capable Palace/Network/TPPNetworkExecutor.swift` — should match at line 272. If missing, that's a regression on the historical fix and needs investigation before any new network change ships.
8. **Update Section 9 (refresh history)** with date + your initials.

---

## 9. Refresh history

| Date | Refreshed by | Notes |
|------|-------------|-------|
| 2026-05-28 | swarm rigor meta-improvement (chore/swarm-rigor-meta-improvement) | Initial baseline. Mirrors the auth area's `verification-checklist.md` structure. Migration status in Section 1 reflects the swarm_66819d80 design baseline (commit f9e57f7f5 on swarm/swarm_66819d80-scaffold); develop tip still calls `indicatesAuthenticationNeedsRefresh` directly until that swarm lands on develop. |

---

**This file is owned by the network area.** If you change anything in `Palace/Network/`, in the `URLResponse+TPPAuthentication` extension, or in the two consumer-side classifier callers (`TokenRefreshInterceptor.swift:79`, `DownloadAuthRetryHandler.swift:95`), update the relevant section here before you commit. The Definition of Done (CLAUDE.md) treats out-of-date area checklists as scope debt. Paired with `docs/architecture/areas/auth/verification-checklist.md` — auth-layer decisions and network-layer routing meet at the classifier seam; keep both files in sync when that seam moves.
